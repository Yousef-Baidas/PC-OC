# Final pass

Test fixture, not the guide: the copy that passes every rule.

## 1. Before you start

The pass changes the BIOS power limits, the CPU undervolt, the RAM settings, the GPU clocks and the toolchain wiring. It never raises the CPU core voltage and never changes a ratio or BCLK (`CONVENTIONS.md`).

Do not update the system (pacman -Syu, yay) between the baseline and the final report.

| Section | Time |
|---|---|
| 2. Install the reviewed scripts | 5 minutes |
| 3. BIOS power limits | 30 minutes |
| 4. Undervolt | 3 hours |
| 5. RAM | 4 hours |
| 6. GPU clocks | 2 hours |
| 7. Benchmark the tuned state | 1 hour |
| 8. Report | 5 minutes |
| 9. Toolchain wiring | 10 minutes |
| 10. What to send back | 10 minutes |
| 11. Undo everything | 20 minutes |

Have ready: the baseline directory `results/2026-10-01-baseline`, Cyberpunk 2077 installed, `memtest_vulkan` installed.

## 2. Install the reviewed scripts

- Time: 5 minutes
- Do: `sudo os/install.sh`
- See: `cat /usr/local/lib/pc-oc/VERSION` prints the commit you reviewed
- If it fails: [Undo everything](#11-undo-everything)

## 3. BIOS power limits

- Time: 30 minutes
- Do: [bios/power-limits.md](bios/power-limits.md)
- See: the readings the runbook asks you to record
- If it fails: [CMOS clear recovery](bios/power-limits.md#cmos-clear-recovery)

## 4. Undervolt

- Time: 3 hours
- Do: [bios/undervolt.md](bios/undervolt.md)
- See: the readings the runbook asks you to record

## 5. RAM

- Time: 4 hours
- Do: [bios/ram.md](bios/ram.md)
- See: the readings the runbook asks you to record
- If it fails: [No-POST recovery and CMOS clear](bios/ram.md#no-post-recovery-and-cmos-clear)

## 6. GPU clocks

- Time: 2 hours
- Do: [gpu/offsets.md](gpu/offsets.md), which builds the load, checks it, and then runs these four in this order
- Do: `sudo /usr/local/lib/pc-oc/pc-oc apply gpu`
- Do: `sudo /usr/local/lib/pc-oc/pc-oc search gpu`
- Do: `sudo /usr/local/lib/pc-oc/pc-oc apply gpu`
- Do: `/usr/local/lib/pc-oc/pc-oc probe gpu`
- See: the probe prints the offsets the search kept
- If it fails: [Undo everything](#11-undo-everything)

## 7. Benchmark the tuned state

- Time: 1 hour
- Do: `bench/game.sh setup`, then record the game runs the way it says, with the label `applied`
- Do: `bench/run.sh applied`
- See: a new directory `results/<date>-applied`
- If it fails: [Undo everything](#11-undo-everything)

The toolchain wiring of section 9 must not be in place yet: `bench/compile.sh` refuses a wired environment.

## 8. Report

- Time: 5 minutes
- Do: `bench/report.sh results/<date>-applied results/2026-10-01-baseline`
- See: a report file under `reports/`
- If it fails: [Undo everything](#11-undo-everything)

Exit status 3 and a `NOT COMPARABLE` line mean a fixed axis differs between the two runs. The report is still written.

## 9. Toolchain wiring

- Time: 10 minutes
- Do: `pc-oc apply toolchain` as your user, never with sudo
- Do: `pc-oc probe toolchain`
- See: the probe prints the wiring
- If it fails: [Undo everything](#11-undo-everything)

To leave one package out, build it with `PC_OC_NO_WIRING=1`.

## 10. What to send back

- the report file
- the results directory
- the readings each runbook asks for
- the search `result` and `log`

## 11. Undo everything

1. `sudo /usr/local/lib/pc-oc/pc-oc revert all`
2. `pc-oc revert toolchain`
3. Load the BIOS profile you saved in the first step of each runbook.
4. If the machine does not start, clear CMOS: [power limits](bios/power-limits.md#cmos-clear-recovery), [undervolt](bios/undervolt.md#recovery-clear-cmos), [RAM](bios/ram.md#no-post-recovery-and-cmos-clear).
