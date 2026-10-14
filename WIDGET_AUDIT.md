# Widget regression audit — 2026-10-14

Scope: all seven cards, shared collectors/models, sampling policy, resizing,
settings, layout profiles and persistence. Changes are grouped in one local
commit; marketplace publication is a separate step requiring validation of
that exact commit. This is a regression audit, not a guarantee that all
hardware, media applications or future failures have been tested.

| Surface | Core checks | Fixes / outcome |
| --- | --- | --- |
| System monitor | `/proc` CPU deltas, counter resets, RAM availability, failed reads, compact gauges, visibility/resume | Reject malformed counters, clear unavailable samples, reserve stable CPU/RAM detail height. |
| GPU | Discovery/PCI identity, Intel stream parsing, NVIDIA/AMD readings, missing/stale/sleeping states, device cycling and shared temperature | Model and 10 native GPU cases pass; vendor telemetry exercised with fixtures, not every physical GPU. |
| Battery & power | UPower fraction/state/rate conventions, absent battery, profile normalization, fresh confirmation, failure/timeout, compact sizing | Bound profile command lifetime; existing state/confirmation tests pass. Actual hardware power settings were not changed for testing. |
| Media | Exact-player transport, repeat mode, repeat without a seek signal, delayed/corrected duration, rate-aware progress, drag/track/player races, missing timing, compact fit | Keep play/pause centered with repeat in a side slot at narrow, default and tall sizes. Add repeat control and bounded direct D-Bus snapshots; discard stale replies. Native repeat tests keep the player's cached position unchanged while authoritative snapshots roll back to the beginning. A private D-Bus integration fixture also checks actual Qt object-path variants, synthetic position signals and late duration updates through the real helper. |
| Artwork | Download/time/pixel limits, PNG framing/CRC/scanlines, compressed metadata, cancellation and cache pruning | Preserve and validate the existing workspace sanitizer for marketplace #11152. Remove nonessential chunks before Qt reads the image; unsupported remote formats use the placeholder. |
| Top processes | Real `/proc`, PID reuse, interval CPU, sorting/count changes, cancellation, malformed output, slow collectors, compact scrolling | Stop collection while hidden and reset the baseline on resume. Existing collector/runtime cases pass. |
| Network | Counter/reset/gap handling, route selection, interfaces, history scale, hidden/pause/resume, narrow layout | Use lowest-metric usable default route (including direct routes); reject malformed counters; clear failed route reads; pause hidden cards. |
| Disk | Mount filtering/deduplication, spaces, pseudo-mount exclusions, collector cancellation and stale responses, compact scrolling | Wait for all completion events; reject old sampling/filter generations; use directory boundaries for exclusions. |
| Temperature/fan | Sensor absence/recovery, CPU/GPU aggregate, unit conversion, blank/zero readings, semantic thresholds | Blank fan output is unavailable, not 0 RPM; accept valid zero/negative Celsius readings; correct warm/hot color order. |
| Shared shell/settings | Save/reload, teardown persistence, external conflicts, saved layouts/monitor transitions, safe paste, resize and lock/DPMS sampling | Native persistence, layout, sizing and safe-input suites pass against isolated settings. |

Validation commands:

```sh
GAUGE_QML_TESTS=1 NETWORK_QML_TESTS=1 LIST_CARD_QML_TESTS=1 node --test tests/*.test.cjs
python3 -m unittest discover -s tests -p 'test_*.py'
sh tests/run-gpu-qml-tests.sh
sh tests/sampling-run-qml-tests.sh
sh tests/run-sizing-qml-tests.sh
sh tests/run-safe-textfield-qml-tests.sh
sh tests/run-persistence-qml-tests.sh
sh tests/run-layout-qml-tests.sh
```

The last two suites require an accessible Wayland session. Python artwork
fixtures require a loopback listener. Optional Qt tests require installed
Quickshell and Omarchy Commons/Ui modules.

Live observation: BloomeeTunes 3.0.4 reported `Playing`, a stationary position
(initially zero, later 106372 microseconds), and omitted `mpris:length` and
`mpris:trackid` on repeated independent D-Bus reads. Pausing refreshed position
to 109077141 microseconds. Its audio_service_mpris 0.2.0 bridge stores position
without extrapolation and implements LoopStatus as a constant/no-op. A separate
Bloomee app repair is required; this widget update does not patch installed players. The widget cannot derive a
seek percentage from absent duration or fix Bloomee's underlying media bridge.
Brave supplied valid duration and position. No timing values are fabricated to
make Bloomee appear fixed. The fresh-read helper uses Python 3 and `busctl`, a
64 KiB output limit and a two-second process timeout.

Final results: all 19 Node test files passed with optional gauge, network and list Qt checks enabled; 42 Python tests passed (including the private D-Bus integration case). Native suites: GPU 10, sampling 9, sizing 6, safe input 6, persistence 2, layout 8 cases passed.
