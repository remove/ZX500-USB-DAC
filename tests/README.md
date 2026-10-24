# Tests

`resampler-test.c` includes the bridge's drift-correction renderer and validates
all eight sample rates at the 24-bit format the DAC uses. It covers expansion,
passthrough and compression with ramps, alternating full-scale samples, impulses
and deterministic random transients. It also checks native range, endpoints,
monotonicity and allocation canaries under ASan/UBSan.

Run it with:

```bash
docker/zxbuild test
```

Expected output:

```text
resampler: 8 rates x 24-bit x 4 patterns x 3 deltas + canaries PASS
```

## Headphone route selection

```sh
sh tests/headphone-route-test.sh
```

Mocks tinymix and mixer, so it never touches a sound device. Covers Sony enum
output (including >none btl with >3pin selected), all three single-ended jack
values, balanced priority, no-jack/antenna fallback, and single-value output.
Expected output: `headphone route: 9 cases PASS (no hardware access)`.
