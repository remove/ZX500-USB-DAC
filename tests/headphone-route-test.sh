#!/bin/sh
# Exercise the production route functions with mocked mixer commands only.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONTROLLER=${1:-$ROOT/usb-dac.sh}
# Load only the definitions, never the controller's main command dispatcher.
eval "$(sed -n '/^mixer_enum_value(){/,/^}/p' "$CONTROLLER")"
eval "$(sed -n '/^dac_path(){/,/^on(){/p' "$CONTROLLER" | sed '$d')"
tinymix(){
  case "$3" in
    33) printf '%s\n' "$BTL_FIXTURE";;
    32) printf '%s\n' "$SE_FIXTURE";;
    *) echo "Unexpected tinymix read" >&2; return 1;;
  esac
}
mixer(){
  case "$1" in
    24|26|15|16|34) :;;
    *) echo "Unexpected mixer write (including volume/mute): $*" >&2; return 1;;
  esac
}
COUNT=0
expect_route(){
  LABEL=$1; BTL_FIXTURE=$2; SE_FIXTURE=$3; EXPECTED=$4
  ACTUAL=$(dac_path)
  if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "FAIL $LABEL: expected $EXPECTED, got $ACTUAL" >&2; exit 1
  fi
  COUNT=$((COUNT+1))
}
# Captured Sony enum format: every choice is listed, with > on the selected one.
expect_route '3.5 mm / 3pin' 'jack status btl: >none btl' 'jack status se: none >3pin 4pin 5pin antenna' smaster-se
expect_route '4pin' 'jack status btl: >none btl' 'jack status se: none 3pin >4pin 5pin antenna' smaster-se
expect_route '5pin' 'jack status btl: >none btl' 'jack status se: none 3pin 4pin >5pin antenna' smaster-se
expect_route 'balanced selected' 'jack status btl: none >btl' 'jack status se: >none 3pin 4pin 5pin antenna' smaster-btl
expect_route 'balanced priority' 'jack status btl: none >btl' 'jack status se: none >3pin 4pin 5pin antenna' smaster-btl
expect_route 'no jack fallback' 'jack status btl: >none btl' 'jack status se: >none 3pin 4pin 5pin antenna' smaster-btl
expect_route 'antenna is not headphones' 'jack status btl: >none btl' 'jack status se: none 3pin 4pin 5pin >antenna' smaster-btl
# Preserve support for tinymix builds that print only the current value.
expect_route 'single-value se' 'jack status btl: none' 'jack status se: 3pin' smaster-se
expect_route 'single-value balanced' 'jack status btl: btl' 'jack status se: none' smaster-btl
echo "headphone route: $COUNT cases PASS (no hardware access)"
