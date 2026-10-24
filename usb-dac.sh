#!/system/bin/sh
# ZX500 hi-res USB-DAC control (UAC2-only; keep the USB HAL running).
#   usb-dac.sh on                  bring up the DAC now
#   usb-dac.sh dac                 enable autostart + bring up the DAC now
#   usb-dac.sh mtp                 clear DAC autostart (reboot to restore MTP/adb)
#   usb-dac.sh off                 tear down now (reboot still needed to restore USB)
#   usb-dac.sh status | appstatus
G=/config/usb_gadget/g1
UDC=ci_hdrc.0
# The release kernel is output-only (one host Playback device, no mic) and
# exposes all eight rates from 44.1k to 384k for native host switching.
# uac2bridge reads the host-selected rate from the "Capture
# Current Rate" control and opens card2/card1 at it, doing single-frame drift
# correction; it re-opens automatically when the host switches format. Safety
# includes host-stream handshake, DROP+PREPARE of the pcm_open(card1) backlog,
# full-buffer start_threshold, HOST_STALL rebuild, XRUN-storm watchdog).
# Production exposes only the validated auto-rate + fine-drift path. The launcher
# sends bridge output to /dev/null, so streaming and recovery never write a log.
BRIDGE=/data/local/tmp/uac2bridge
BNAME=uac2bridge                       # Linux comm (<=15 chars)
PIDFILE=/dev/.zx-usbdac.pid             # tmpfs only
bridge_pid(){
  [ -r "$PIDFILE" ] || return 1
  read BP BN < "$PIDFILE" 2>/dev/null || return 1
  case "$BP" in ''|*[!0-9]*) return 1;; esac
  [ "$BN" = "$BNAME" ] || return 1
  kill -0 "$BP" 2>/dev/null || return 1
  [ "$(cat "/proc/$BP/comm" 2>/dev/null)" = "$BN" ] || return 1
  printf '%s\n' "$BP"
}
stop_bridge_pid(){
  SP=$1
  case "$SP" in ''|*[!0-9]*) return;; esac
  SN=$(cat "/proc/$SP/comm" 2>/dev/null)
  [ "$SN" = uac2bridge ] || return
  kill "$SP" 2>/dev/null
  SI=0
  while kill -0 "$SP" 2>/dev/null && [ "$SI" -lt 20 ]; do sleep 0.05; SI=$((SI+1)); done
  [ "$(cat "/proc/$SP/comm" 2>/dev/null)" = "$SN" ] && kill -9 "$SP" 2>/dev/null
}
kill_bridges(){
  # Normal lifecycle uses the exact child PID captured at launch.
  if [ -r "$PIDFILE" ]; then
    read KP KN < "$PIDFILE" 2>/dev/null
    stop_bridge_pid "$KP"
  fi
  rm -f "$PIDFILE"
  # Recover an orphan left by an interrupted launcher before the PID file landed.
  for KP in $(pidof uac2bridge 2>/dev/null); do stop_bridge_pid "$KP"; done
}
FLAG=/data/adb/usbdac.autostart
# Why the last start failed. A failed start is rare, and when it happens the USB
# link is usually gone with it -- no adb, and the boot service discards output --
# so one small write here is what makes the failure diagnosable at all. Success
# writes nothing; it only clears a stale file if one exists.
ERRFILE=/data/adb/usbdac.lasterror
# Set once on() has taken the ordinary gadget down, so failures know they have
# something to put back. Empty means USB was never touched and must be left alone.
USBCFG_PREV=
# Highest Sony hardware volume index the host's slider is allowed to reach. The
# host range is always anchored at index 0 (-60 dB) and one 0.5 dB step is one
# index, so this alone decides how loud USB playback can get. Written to configfs
# before bind; the kernel advertises it and the bridge reads it back from the
# control. Only `maxvol` writes the file, so a normal boot performs no flash write.
MAXVOL_FILE=/data/adb/usbdac.maxvol
MAXVOL_DEFAULT=100                      # -10 dB; Sony's own scale ends at 120
MAXVOL_LIMIT=120                        # 0 dB, full scale
# Fraction of the ceiling to fall back to when the inherited volume exceeds it.
# Starting at the ceiling itself would be startlingly loud, so come up quiet.
MAXVOL_FALLBACK_PCT=30

# Read one integer mixer control on card1. `tinymix -D 1 <id>` prints
# "master volume: 30 (dsrange 0->120)", so the value has to be cut out from
# between the colon and the range -- taking everything after the colon drags the
# range along and every comparison against it then fails.
read_ctl(){
  tinymix -D 1 "$1" 2>/dev/null | sed 's/.*: *//; s/[^0-9].*//'
}

read_maxvol(){
  RM=$(cat "$MAXVOL_FILE" 2>/dev/null)
  case "$RM" in ''|*[!0-9]*) RM=$MAXVOL_DEFAULT;; esac
  [ "$RM" -ge 1 ] && [ "$RM" -le "$MAXVOL_LIMIT" ] || RM=$MAXVOL_DEFAULT
  printf '%s\n' "$RM"
}
mixer(){ tinymix -D 1 "$@" >/dev/null 2>&1; }

record_failure(){
  mkdir -p /data/adb 2>/dev/null
  printf '%s (uptime %ss)\n' "$1" "$(cut -d' ' -f1 /proc/uptime 2>/dev/null)" \
    > "$ERRFILE" 2>/dev/null
}
clear_failure(){ [ -e "$ERRFILE" ] && rm -f "$ERRFILE"; return 0; }

# What USB should look like when the DAC is not running. Android keeps the user's
# own choice here, so restoring it is closer to "as it was" than assuming adb.
default_usb_config(){
  DC=$(getprop persist.sys.usb.config 2>/dev/null)
  case "$DC" in ''|none) DC=adb;; esac
  printf '%s\n' "$DC"
}

# Put back an ordinary gadget after the DAC one has been dismantled. The imx HAL
# does not fully resynchronise without a reboot, so this is best-effort -- but
# trying costs nothing, and not trying leaves the user with no USB at all.
restore_usb_config(){
  RC=$USBCFG_PREV
  case "$RC" in ''|none) RC=$(default_usb_config);; esac
  setprop sys.usb.config "$RC" 2>/dev/null
}
clear_links(){ for l in "$G"/configs/b.1/*; do [ -L "$l" ] && rm -f "$l"; done; }

# configfs may accept a write syscall yet retain an old value. Audio-format and
# identity attributes therefore need both a successful write and exact readback.
write_attr_checked(){
  printf '%s\n' "$2" > "$1" 2>/dev/null || return 1
  [ "$(cat "$1" 2>/dev/null)" = "$2" ]
}

# Unbind is the safety boundary for every failed start. Retry transient configfs
# failures and verify the UDC attribute is truly empty; merely suppressing echo's
# error can leave a live host endpoint after its bridge has been killed.
unbind_udc(){
  [ -e "$G/UDC" ] || return 1
  UTRY=0
  while [ "$UTRY" -lt 3 ]; do
    printf '\n' > "$G/UDC" 2>/dev/null
    [ -z "$(cat "$G/UDC" 2>/dev/null)" ] && return 0
    UTRY=$((UTRY+1)); sleep 0.1
  done
  return 1
}

# Once an old bridge has been stopped, every failure must leave one explicit,
# safe state: no bridge and no bound UAC gadget. Never leave the host streaming
# into a bound function with no consumer. Callers print the reason and return.
abort_start(){
  kill_bridges
  if unbind_udc; then
    clear_links
    rmdir "$G/functions/uac2.0" 2>/dev/null
    # Only meaningful once the ordinary gadget was actually dismantled. Without
    # this the device is left with no gadget at all: no DAC, no MTP, no adb, and
    # nothing the user can do but reboot.
    [ -n "$USBCFG_PREV" ] && restore_usb_config
    echo "ERROR: $1; USB-DAC confirmed unbound" >&2
    record_failure "$1; unbound, USB restore attempted"
  else
    echo "CRITICAL: $1; UDC still bound and no bridge is running" >&2
    record_failure "$1; UDC STILL BOUND"
  fi
}

restart_adbd_tcp_after_gadget(){
  # Android owns whether debugging is enabled; this launcher only supplies its
  # TCP transport. Restart AFTER UAC2 is fully bound so any FunctionFS/USB-HAL
  # reaction has already happened and DAC remains the final gadget layout.
  # With debugging disabled this is a complete no-op.
  [ "$(settings get global adb_enabled 2>/dev/null)" = 1 ] ||
    [ "$USBDAC_RESTART_ADBD" = 1 ] || return 0
  [ "$(getprop persist.adb.tcp.port)" = 5555 ] || setprop persist.adb.tcp.port 5555
  setprop service.adb.tcp.port 5555
  setsid sh -c 'sleep 1; stop adbd; start adbd' \
    </dev/null >/dev/null 2>&1 &
}

mixer_enum_value(){
  ENUM_TEXT=$(tinymix -D 1 "$1" 2>/dev/null) || return 1
  # Sony tinymix lists every enum choice and prefixes the selected one with >.
  # Matching the entire list selects btl even when the actual value is >none.
  case "$ENUM_TEXT" in
    *'>'*) printf '%s\n' "$ENUM_TEXT" | sed -n 's/.*>\([^[:space:]]*\).*/\1/p';;
    *) printf '%s\n' "$ENUM_TEXT" | sed 's/.*: *//';;
  esac
}

dac_path(){
  BTL=$(mixer_enum_value 33)
  SE=$(mixer_enum_value 32)
  case "$BTL" in btl) AMP=smaster-btl;; *)
    case "$SE" in 3pin|4pin|5pin) AMP=smaster-se;; *) AMP=smaster-btl;; esac ;; esac
  # Do not force-unmute (ctl 13). The current hardware mute state is preserved
  # and seeded into the Feature Unit, so if the device was muted entering DAC mode it
  # stays muted until the host explicitly unmutes -- never blast sound on mode entry.
  mixer 24 headphone; mixer 26 "$AMP"; mixer 15 0; mixer 16 0; mixer 34 0
  echo "$AMP"
}

on(){
  # The clock starts at 48k on bind; authoritative host SET_CUR events then drive
  # all native rate changes. The release format is always stereo 24-bit PCM.
  RATE=48000
  SS=3

  # adb push writes 0666; the bridge must be executable or setsid silently fails.
  # Only chmod if it isn't already executable (a chmod is a flash metadata write).
  [ -x "$BRIDGE" ] || chmod 0755 "$BRIDGE" 2>/dev/null
  [ -x "$BRIDGE" ] || {
    echo "ERROR: bridge missing or not executable: $BRIDGE" >&2
    record_failure "bridge missing or not executable"
    return 1
  }
  # Stop the old bridge first so its short-lived card1 control transaction cannot
  # race the safety snapshot. USB remains bound and configfs is untouched until the
  # snapshot below succeeds.
  kill_bridges; sleep 1

  # Hearing-safety preflight happens BEFORE unbinding USB. Take both values from one
  # mixer snapshot; if it fails, do not rebuild/bind a gadget with unknown volume.
  MIXSNAP=""; i=0
  while [ $i -lt 10 ]; do
    MIXSNAP=$(tinymix -D 1 2>/dev/null) && [ -n "$MIXSNAP" ] && break
    i=$((i+1)); sleep 0.1
  done
  HWVOL=$(printf '%s\n' "$MIXSNAP" | awk '$4=="master" && $5=="volume"{print $NF}')
  case "$HWVOL" in ''|*[!0-9]*) abort_start "cannot read master volume"; return 1;; esac
  [ "$HWVOL" -le 120 ] || { abort_start "master volume $HWVOL out of range"; return 1; }
  HWMUTESTR=$(printf '%s\n' "$MIXSNAP" | awk '$4=="playback" && $5=="mute"{print $NF}')
  case "$HWMUTESTR" in On) HWMUTE=1;; Off) HWMUTE=0;; *) abort_start "cannot read playback mute"; return 1;; esac

  # Hearing-safety ceiling shared with the Feature Unit and bridge.  Stop the
  # bridge first (above), lower an unsafe inherited Sony volume before binding
  # USB, and verify the write.  Thus no host can start a stream during a brief
  # full-scale window if the inherited Sony volume is above the USB-DAC ceiling.
  # Exceeding the ceiling is not a reason to refuse to start -- come up at a
  # fraction of it instead.  Only a volume we cannot set and verify is fatal,
  # because then the level going into the stream is unknown.
  MAXVOL=$(read_maxvol)
  if [ "$HWVOL" -gt "$MAXVOL" ]; then
    # Integer division makes this 0 for a ceiling below 4, which would come up
    # silent and look like a failure. One index is quiet enough.
    SAFEVOL=$(( MAXVOL * MAXVOL_FALLBACK_PCT / 100 ))
    [ "$SAFEVOL" -ge 1 ] || SAFEVOL=1
    tinymix -D 1 9 "$SAFEVOL" >/dev/null 2>&1 || { abort_start "cannot apply safe volume"; return 1; }
    HWVOL=$(read_ctl 9)
    [ "$HWVOL" = "$SAFEVOL" ] || { abort_start "safe volume readback mismatch ($HWVOL)"; return 1; }
  fi
  CVOL=$(( (HWVOL - 120) * 128 ))
  CVOLMAX=$(( (MAXVOL - 120) * 128 ))

  # Remember what USB looked like before dismantling it, so a failure past this
  # point can put it back rather than leaving the port dead.
  USBCFG_PREV=$(getprop sys.usb.config)
  setprop sys.usb.config none; sleep 1
  unbind_udc || { abort_start "cannot unbind existing UDC"; return 1; }
  clear_links
  # DAC mode gets its own serial, derived from the physical one. Hosts key their
  # per-device caches (Windows its audio endpoint properties in particular) on
  # the USB serial, and MTP and UAC2 are not the same kind of device -- sharing
  # one serial invites a host to carry state from one across to the other. Keep
  # bcdDevice at the Sony HAL value: this configfs rejects runtime rewrites.
  SERIAL=$(getprop ro.serialno)
  [ -n "$SERIAL" ] || { abort_start "device serial is unavailable"; return 1; }
  SERIAL="${SERIAL}DAC"
  write_attr_checked "$G/strings/0x409/serialnumber" "$SERIAL" || { abort_start "serialnumber readback mismatch"; return 1; }
  write_attr_checked "$G/strings/0x409/product" "ZX500 USB-DAC" || { abort_start "product readback mismatch"; return 1; }
  mkdir -p "$G/functions/uac2.0" || { abort_start "uac2 function creation failed"; return 1; }
  write_attr_checked "$G/functions/uac2.0/c_chmask" 3 || { abort_start "c_chmask readback mismatch"; return 1; }
  write_attr_checked "$G/functions/uac2.0/c_srate" "$RATE" || { abort_start "c_srate readback mismatch"; return 1; }
  write_attr_checked "$G/functions/uac2.0/c_ssize" "$SS" || { abort_start "c_ssize readback mismatch"; return 1; }
  # Seed the Feature Unit volume/mute from the live hardware BEFORE binding, so
  # the host's first GET_CUR matches the DAC's current volume (no jump to full scale)
  # and the current mute state is preserved. Read ctl 9 "master volume" (0..120) ->
  # c_volume = (hw-120)*128 (Q8.8), and ctl 13 "playback mute" -> c_mute. Strictly
  # validate, write, and READ BACK; abort (do NOT bind the UDC) on any failure --
  # never come up at an unknown/full volume.
  # c_volume_max first: the kernel clamps the seeded c_volume against it, and the
  # host must never be offered a range wider than the configured ceiling.
  echo "$CVOLMAX" > "$G/functions/uac2.0/c_volume_max" || { abort_start "c_volume_max write failed"; return 1; }
  echo "$CVOL"   > "$G/functions/uac2.0/c_volume" || { abort_start "c_volume write failed"; return 1; }
  echo "$HWMUTE" > "$G/functions/uac2.0/c_mute"   || { abort_start "c_mute write failed"; return 1; }
  [ "$(cat "$G/functions/uac2.0/c_volume_max" 2>/dev/null)" = "$CVOLMAX" ] || { abort_start "c_volume_max readback mismatch"; return 1; }
  [ "$(cat "$G/functions/uac2.0/c_volume" 2>/dev/null)" = "$CVOL" ] || { abort_start "c_volume readback mismatch"; return 1; }
  [ "$(cat "$G/functions/uac2.0/c_mute" 2>/dev/null)" = "$HWMUTE" ] || { abort_start "c_mute readback mismatch"; return 1; }
  write_attr_checked "$G/configs/b.1/strings/0x409/configuration" "USB-DAC" || { abort_start "configuration readback mismatch"; return 1; }
  ln -s "$G/functions/uac2.0" "$G/configs/b.1/f1" || { abort_start "config link failed"; return 1; }
  echo "$UDC" > "$G/UDC" || { abort_start "UDC bind failed"; return 1; }
  AMP=$(dac_path)
  setsid "$BRIDGE" </dev/null >/dev/null 2>&1 &
  BPID=$!
  printf '%s %s\n' "$BPID" "$BNAME" > "$PIDFILE" || {
    stop_bridge_pid "$BPID"; abort_start "cannot create volatile bridge pid file"; return 1;
  }
  # Validate the exact child we launched. KernelSU's boot-service context cannot
  # reliably scan unrelated /proc entries with pgrep/pkill; that formerly caused
  # a false failure and unbound a healthy DAC about 12 seconds after boot.
  i=0
  while [ $i -lt 40 ]; do
    kill -0 "$BPID" 2>/dev/null && [ "$(cat "/proc/$BPID/comm" 2>/dev/null)" = "$BNAME" ] && break
    sleep 0.1; i=$((i+1))
  done
  if ! kill -0 "$BPID" 2>/dev/null || [ "$(cat "/proc/$BPID/comm" 2>/dev/null)" != "$BNAME" ]; then
    abort_start "bridge failed to start"; return 1
  fi
  echo "USB-DAC ON: ${RATE}Hz/24bit amp=$AMP UDC=$(cat "$G/UDC") bridge=$BPID"
  clear_failure
  restart_adbd_tcp_after_gadget
  return 0
}

off(){
  # Keep the consumer alive unless/until the host endpoint is confirmed gone.
  # If unbind fails, returning with the existing bridge is safer than a bound
  # UAC function whose capture ring has nobody reading it.
  if ! unbind_udc; then
    echo "CRITICAL: cannot stop USB-DAC; UDC still bound, bridge preserved" >&2
    return 1
  fi
  kill_bridges
  clear_links; rmdir "$G/functions/uac2.0" 2>/dev/null
  # Restore Android's own USB choice rather than forcing adb on: with debugging
  # disabled that used to leave an adb interface with no daemon behind it.
  setprop sys.usb.config none; sleep 1; setprop sys.usb.config "$(default_usb_config)"
  echo "USB-DAC OFF: UDC confirmed unbound (reboot to fully restore USB)"
  return 0
}

appstatus(){
  if [ "$(getprop sys.usb.config)" = "none" ] && bridge_pid >/dev/null 2>&1; then MODE=DAC; else MODE=MTP; fi
  R=$(cat "$G/functions/uac2.0/c_srate" 2>/dev/null)
  if [ -z "$R" ] || [ "$MODE" = MTP ]; then R=48000; fi
  [ -f "$FLAG" ] && AS=1 || AS=0
  HR=$(cat /proc/asound/card2/pcm0c/sub0/hw_params 2>/dev/null | awk '/^rate/{print $2}')
  # Host-selected Feature Unit volume/mute, read-only, only in DAC mode.
  # VOLUME is signed Q8.8 dB (the app divides by 256); MUTE is 0/1.
  VOL=; MUTEV=
  if [ "$MODE" = DAC ]; then
    VOL=$(tinymix -D 2 2>/dev/null | awk '/Capture Host Volume/{print $NF}')
    MUTEV=$(tinymix -D 2 2>/dev/null | awk '/Capture Host Mute/{print $NF}')
  fi
  echo "MODE=$MODE"; echo "RATE=${R:-48000}"; echo "BITS=24"; echo "AUTOSTART=$AS"; echo "HOSTRATE=${HR:-0}"
  # MAXVOL is what is configured; MAXVOLACTIVE is what the running gadget was
  # actually built with. They differ between changing the ceiling and restarting
  # DAC mode, which is exactly when someone would wonder why nothing changed.
  MVA=
  if [ "$MODE" = DAC ]; then
    CVM=$(cat "$G/functions/uac2.0/c_volume_max" 2>/dev/null)
    case "$CVM" in ''|*[!0-9-]*) ;; *) MVA=$(( CVM / 128 + 120 ));; esac
  fi
  echo "MAXVOL=$(read_maxvol)"; echo "MAXVOLACTIVE=${MVA:-}"; echo "MAXVOLLIMIT=$MAXVOL_LIMIT"
  echo "LASTERROR=$(cat "$ERRFILE" 2>/dev/null)"
  echo "DRIFT=fine"; echo "VOLUME=${VOL:-}"; echo "MUTE=${MUTEV:-}"
}

case "${1:-status}" in
  # on() writes no log or regular runtime file. When Android debugging is enabled,
  # it may initialize persist.adb.tcp.port once; there are no periodic flash writes.
  on)   on || exit 1;;
  dac)  on || exit 1
        [ -f "$FLAG" ] || { mkdir -p /data/adb; : > "$FLAG"; };;
  # `mtp` is deliberately next-boot-only. Keep the current DAC/bridge healthy
  # until reboot instead of creating a bound endpoint with no consumer.
  mtp)  rm -f "$FLAG" || { echo "ERROR: cannot clear DAC autostart" >&2; exit 1; }
        echo "MTP set for next reboot (current USB-DAC remains active)";;
  off)  off;;
  # Persist the ceiling. This is the only path that writes it, so a normal boot
  # still performs no flash write. Takes effect the next time DAC mode starts.
  maxvol)
    NV=$2
    case "$NV" in ''|*[!0-9]*) echo "usage: $0 maxvol <1-$MAXVOL_LIMIT>" >&2; exit 1;; esac
    [ "$NV" -ge 1 ] && [ "$NV" -le "$MAXVOL_LIMIT" ] ||
      { echo "ERROR: maxvol must be 1..$MAXVOL_LIMIT (Sony hardware index)" >&2; exit 1; }
    if [ "$(cat "$MAXVOL_FILE" 2>/dev/null)" != "$NV" ]; then
      mkdir -p /data/adb; printf '%s\n' "$NV" > "$MAXVOL_FILE" ||
        { echo "ERROR: cannot persist maxvol" >&2; exit 1; }
    fi
    echo "MAXVOL=$NV (applies when DAC mode next starts)";;
  appstatus) appstatus;;
  status)
    echo "bridge=$(bridge_pid) drift=fine"; echo "config=$(getprop sys.usb.config)"; echo "UDC=$(cat "$G/UDC" 2>/dev/null)"
    cat /proc/asound/cards 2>/dev/null | grep -E "UAC2|cxd";;
  *) echo "usage: $0 on|dac|mtp|off|status|appstatus|maxvol <1-$MAXVOL_LIMIT>" >&2; exit 1;;
esac
