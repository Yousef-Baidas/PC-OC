# gpu craft: NVML tuning on Wayland

A senior GPU tuning engineer works with what the driver reports as the limits for this board. A number from a forum post is never a bound. Every setter is followed by a getter, because NVML settings do not survive a reboot or a driver unload.

## Sources

| id | Document | URL | Revision |
|---|---|---|---|
| nvml-cmd | NVML API reference: Device Commands | https://docs.nvidia.com/deploy/nvml-api/api/group__nvmlDeviceCommands.html | "Last updated on Sep 09, 2026", NVML v615 |
| nvml-query | NVML API reference: Device Queries | https://docs.nvidia.com/deploy/nvml-api/api/group__nvmlDeviceQueries.html | same |
| nvml-offset-t | `nvmlClockOffset_v1_t` struct | https://docs.nvidia.com/deploy/nvml-api/api/structnvmlClockOffset__v1__t.html | same |
| nvml-log | NVML change log | https://docs.nvidia.com/deploy/nvml-api/change-log.html | same |
| nvml-dep | NVML deprecated list | https://docs.nvidia.com/deploy/nvml-api/api/deprecated.html | same |
| smi | nvidia-smi documentation | https://docs.nvidia.com/deploy/nvidia-smi/index.html | v610 update |
| drv-xopt | Driver README: X config options (Coolbits) | https://download.nvidia.com/XFree86/Linux-x86_64/595.91.07/README/xconfigoptions.html | 595.91.07 |
| drv-wl | Driver README: Wayland known issues | https://download.nvidia.com/XFree86/Linux-x86_64/595.91.07/README/wayland-issues.html | 595.91.07 |
| drv-pd | Driver README: nvidia-persistenced | https://download.nvidia.com/XFree86/Linux-x86_64/595.91.07/README/nvidia-persistenced.html | 595.91.07 |
| lact | LACT README and Hardware-Support wiki | https://github.com/ilya-zlobintsev/LACT/blob/master/README.md, https://github.com/ilya-zlobintsev/LACT/wiki/Hardware-Support | v0.10.1, 2026-08-29 |
| nv-4060ti | NVIDIA RTX 4060 Ti product page | https://www.nvidia.com/en-us/geforce/graphics-cards/40-series/rtx-4060-4060ti/ | undated, read 2026-09-30 |
| pynvml | nvidia-ml-py | https://pypi.org/project/nvidia-ml-py/ | 13.615.71, 2026-09-25 |

## Why not Coolbits

Coolbits is an X config option that enables "GPU clock manipulation in the NV-CONTROL X extension", and its bit 8 exposes per-clock-domain offsets in the nvidia-settings PowerMizer page (drv-xopt). The README says nvidia-settings runs "after installing the driver and starting X", and "has limited functionality on Wayland" (drv-wl). This desktop runs Wayland, so every control goes through NVML.

## Power limit

- Setter: `nvmlDeviceSetPowerManagementLimit(device, limit)`, with the "limit in milliwatts", "Requires root/admin permissions", and "Limit is not persistent across reboots or driver unloads" (nvml-cmd). `nvmlDeviceSetPowerManagementLimit_v2` "replaces" it as a drop-in (nvml-query, added v530 to v535).
- Bounds: `nvmlDeviceGetPowerManagementLimitConstraints(device, *min, *max)` in milliwatts, and `nvmlDeviceGetPowerManagementDefaultLimit` (nvml-query).
- CLI: `nvidia-smi -pl <watts>`. The value "needs to be between Min and Max Power Limit as reported by nvidia-smi. Requires root." `nvidia-smi -q -d POWER` prints `Min Power Limit`, `Max Power Limit`, `Default Power Limit`, `Current Power Limit`, `Requested Power Limit`, `Enforced Power Limit` in watts (smi). Watch the units: NVML takes mW, nvidia-smi takes W.
- This card, reference value: "Total Graphics Power (W) 165 or 160" for "16 GB or 8 GB" (nv-4060ti). The page pairs the lists by order, and the live probe below confirms 160 W for this 8 GB board.
- Live probe on 2026-09-30 (`nvidia-smi --query-gpu=…`, driver 615.71.09): min 100.00 W, max 216.00 W, default 160.00 W. The max is this partner board's limit, not NVIDIA's reference. Apply reads these at run time and never hard-codes them (PROFILE rule 2).

## Clock offsets

- Current API: `nvmlDeviceSetClockOffsets(device, nvmlClockOffset_t *info)`: "Control current clock offset of some clock domain for a given PState. For Maxwell or newer fully supported devices. Requires privileged user." `nvmlDeviceGetClockOffsets` retrieves "min, max and current clock offset" (nvml-query). It exists from driver 555 on ("exposed on NVIDIA display drivers version 555 Production or later", nvml-log section v550 to v555).
- Struct fields: `version`, `type` (`nvmlClockType_t`: graphics or memory), `pstate` (`nvmlPstates_t`), `clockOffsetMHz`, `minClockOffsetMHz`, `maxClockOffsetMHz` (nvml-offset-t).
- Deprecated: `nvmlDeviceSetGpcClkVfOffset` and `nvmlDeviceSetMemClkVfOffset`, and their getters and MinMax functions: "Will be deprecated in a future release. Use nvmlDeviceSetClockOffsets instead" (nvml-dep). Do not build on them.
- nvidia-smi has no clock-offset option for this card. `-svfd/--set-vf-derate` is "Only supported on Rubin and newer architectures" (smi).
- LACT applies offsets on Wayland through a system service "that does not depend on a graphical session", using `nvml-wrapper`'s `set_clock_offset`, which calls `nvmlDeviceSetClockOffsets`. Its wiki says offsets "are recommended to be used on driver 565 or newer, and will not show up on versions lower than 555" (lact). The installed driver is 615.71.09, so it qualifies.
- The cited range for rule 2 is the device-reported `[minClockOffsetMHz, maxClockOffsetMHz]` for the given clock type and pstate (nvml-offset-t). NVIDIA publishes no recommended or "safe" offset for the RTX 4060 Ti. Any tighter bound comes from this machine's own stability pass (bench), one domain at a time.

## Other knobs

- `nvmlDeviceSetGpuLockedClocks(device, minMHz, maxMHz)`: "Set clocks that device will lock to", root only (nvml-cmd). `nvidia-smi -lgc MIN,MAX`: "Supported on Volta+. Requires root" (smi).
- Persistence: `nvidia-smi -pm 1` "does not persist across reboots" (smi). NVML persistence mode: "After each reboot the persistence mode is reset to 'Disabled'" (nvml-cmd). With persistence, "the daemon holds the NVIDIA character device files open, preventing the NVIDIA kernel driver from tearing down device state" (drv-pd). Without it, applied limits can vanish on driver unload, so the boot unit (os team) reapplies them after persistence is on.

## How apply calls NVML (a decision for the human)

nvidia-smi covers the power limit but not offsets. Three routes, and each one is a new dependency that needs human approval under CONVENTIONS "Forbidden":
1. `nvidia-ml-py` (pynvml). Function names mirror the C API. In 13.615.71, `nvmlDeviceSetClockOffsets` and `nvmlDeviceGetClockOffsets` never call `_nvmlCheckReturn` and always return success, and the caller must pass `byref(struct)` with `.version = nvmlClockOffset_v1` (`0x1000018`) (pynvml, read from `pynvml.py` in the wheel). Read-back is therefore mandatory, not optional.
2. LACT's daemon and config (lact). A second writer to the same knobs; apply and revert would have to drive LACT, not NVML.
3. A small C helper linked against `libnvidia-ml.so` from `nvidia-utils`, checking each `nvmlReturn_t`. Needs a compiler at build time.
Until the human picks one, power-limit work uses `nvidia-smi -pl`, and offset tickets wait.

## Test pattern

- Mock `nvidia-smi` placed first on `PATH`. It prints a fixture `-q -d POWER` block (Min 100.00 W, Max 216.00 W) and records `-pl` calls to a file. Apply with 99 W or 217 W must exit non-zero with nothing recorded.
- For offsets, the helper reads min and max from `GetClockOffsets`. The test fixture gives a range, and apply must refuse min−1 and max+1.
