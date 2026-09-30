# CONTEXT.md

Linux-side tuning, benchmarks, and BIOS runbooks for one desktop (i7-14700, Z790 GAMING X AX, RTX 4060 Ti 8 GB, CachyOS) aimed at gaming and programming performance.

## Glossary

- **Component**: a tunable part of the machine with its own folder: cpu, ram, gpu, os, toolchain.
- **Apply / Revert / Probe**: the three scripts every component has. Apply sets tuned values and reads them back; revert restores stock; probe prints current values and what it read.
- **Stock**: the values recorded by probe before the first apply. Revert targets stock, not vendor defaults from memory.
- **PL1 / PL2**: Intel RAPL long and short package power limits (watts), in `/sys/class/powercap/intel-rapl:0`.
- **Undervolt**: lowering CPU voltage through AC loadline in BIOS. The only voltage change allowed; raising voltage is forbidden.
- **XMP**: the DDR5 memory profile enabled in BIOS; manual timings build on top of it.
- **GPU offset**: core or memory clock offset set through NVML (Wayland, no Coolbits).
- **Runbook**: a markdown file in `bios/` with exact BIOS menu paths and values that the human applies and reports back.
- **Baseline**: benchmark results on stock settings, the reference every milestone's gains are measured against.
- **Stability pass**: y-cruncher, stress-ng, and a GPU loop, all completing without error or WHEA/MCE/Xid entries.
- **Bench kit**: `bench/` scripts: Cyberpunk 2077 built-in benchmark via MangoHud log, pinned Linux kernel defconfig build time, the stability pass.

## Out of scope (run oc-max)

- Local AI tuning (ollama, LLM tokens/s): deferred to a later run.
