# platform craft: i7-14700 power and DDR5

A senior overclocking engineer on a Raptor Lake Refresh part in 2026 does not start with frequency. They start from Intel's published power specification and the Vmin Shift history. The gains on a locked 65 W part come from the power limits, the memory, and lowering voltage where the platform allows it. They come from nothing that raises voltage or ratios.

## Sources

| id | Document | URL | Revision |
|---|---|---|---|
| intel-ark-14700 | Intel Core i7-14700 specifications (SKU 236781) | https://www.intel.com/content/www/us/en/products/sku/236781/intel-core-i7-processor-14700-33m-cache-up-to-5-40-ghz/specifications.html | read 2026-09-30 |
| intel-ds-v1 | 13th Gen / 14th Gen Intel Core … Datasheet, Volume 1 of 2 | https://cdrdv2-public.intel.com/743844/743844-015.pdf | Doc. No. 743844, Rev. 015, May 2025 |
| intel-vmin-rc | Intel Core 13th and 14th Gen Desktop Instability Root Cause Determination | https://community.intel.com/t5/Mobile-and-Desktop-Processors/Intel-Core-13th-and-14th-Gen-Desktop-Instability-Root-Cause/m-p/1633239 | 2024-09-25 |
| intel-0x129 | Microcode 0x129 Update for Intel Core 13th and 14th Gen Desktop | https://community.intel.com/t5/Mobile-and-Desktop-Processors/Microcode-0x129-Update-for-Intel-Core-13th-and-14th-Gen-Desktop/m-p/1622129 | 2024-08-09 |
| intel-0x12f | Intel Core 13th and 14th Gen Vmin Shift Instability Update (0x12F) | https://community.intel.com/t5/Mobile-and-Desktop-Processors/Intel-Core-13th-and-14th-Gen-Vmin-Shift-Instabilty-Update-New/m-p/1686948 | 2025-05-01 |
| intel-uvp | Intel support article 000094219, Undervolt Protection | https://www.intel.com/content/www/us/en/support/articles/000094219/processors.html | last reviewed 2026-04-07 |
| intel-nonk-uv | Intel support article 000094707, undervolting on non-K processors | https://www.intel.com/content/www/us/en/support/articles/000094707/processors.html | last reviewed 2026-04-09 |
| kernel-powercap | Linux power capping framework | https://docs.kernel.org/power/powercap/powercap.html | kernel 7.3.0-rc5 docs |
| kernel-rapl-src | `drivers/powercap/intel_rapl_common.c` | https://raw.githubusercontent.com/torvalds/linux/master/drivers/powercap/intel_rapl_common.c | master, lines 60–62 |
| jedec-ddr5-pr | JEDEC DDR5 standard press release | https://www.jedec.org/news/pressreleases/jedec-publishes-new-ddr5-standard-advancing-next-generation-high-performance | 2020-07-14 |
| jedec-79-5c-pr | JEDEC JESD79-5C update press release | https://www.jedec.org/news/pressreleases/jedec-updates-jesd79-5c-ddr5-sdram-standard-elevating-performance-and-security | 2024-04-17 |
| jedec-79-5d | JESD79-5D standard page (paywalled) | https://www.jedec.org/standards-documents/docs/jesd79-5d | Version 1.41, Nov 2025 |
| gb-support | Gigabyte Z790 GAMING X AX (rev. 1.x) support page and BIOS release notes | https://www.gigabyte.com/Motherboard/Z790-GAMING-X-AX-rev-1x/support | read 2026-09-30 |
| gb-bg | Gigabyte BIOS Setup Guide (Intel 700 Series) | https://download.gigabyte.com/FileList/Manual/mb_manual_intel700series-bios_e.pdf | PDF 2022-09-27 |

## This machine (live probe, 2026-09-30)

- `model name: Intel(R) Core(TM) i7-14700`. `/sys/devices/cpu_core/cpus` = `0-15` (8 P-cores, 2 threads each). `/sys/devices/cpu_atom/cpus` = `16-27` (12 E-cores). That makes it an 8P+12E part, the row used below.
- Board `Z790 GAMING X AX`, BIOS `F13c`. Running microcode `0x137`, newer than any version named in the Intel posts below. Record it in every fingerprint; no primary source describing 0x137 was found.
- `/sys/class/powercap/intel-rapl:0/constraint_0_name` = `long_term`, `constraint_1_name` = `short_term`.

## Power limits: the cited ceiling

| Value | Number | Source |
|---|---|---|
| Processor Base Power | 65 W | intel-ark-14700: "Processor Base Power 65 W" |
| Maximum Turbo Power | 219 W | intel-ark-14700: "Maximum Turbo Power 219 W" |
| PL1, S Refresh LGA 8P+12E 65W | 65 W | intel-ds-v1 Table 17, p104 |
| PL2, same row | 219 W | intel-ds-v1 Table 17, p104 |
| PL1 Tau, same row | min 0.1 s, recommended 28 s, max 448 s | intel-ds-v1 Table 17, p104 |
| Tau note | "Hardware default of PL1 Tau=1s … the recommended is to use PL1 Tau=28s" | intel-ds-v1 Table 17 header, p101 |
| IccMAX, S Refresh 65W 8P+16E/8P+12E | 279 A | intel-ds-v1, VCCCORE current table, p190 |
| IccMAX.App, same row | 231 A | intel-ds-v1, p190 |
| Supported memory | "Up to DDR5 5600 MT/s" | intel-ark-14700 |

The datasheet says "No Specifications for Min/Max PL1/PL2 values" (Table 17). The lint ceiling is therefore the recommended row: PL1 ≤ 65 W and PL2 ≤ 219 W, in the units the file uses. A PL1 raised to 219 W (sustained turbo power) exceeds the cited PL1 and is red.

Intel Default Settings table for 65 W non-K parts: not found in a primary source. Intel's June 2024 guidance post covers K/KF/KS only. Figures in search snippets for non-K came from third-party sites, so they are not cited. The datasheet row above is the primary value.

## RAPL through sysfs (kernel-powercap, kernel-rapl-src)

- `constraint_X_power_limit_uw` (rw): "Power limit in micro watts, which should be applicable for the time window specified by 'constraint_X_time_window_us'."
- `constraint_X_time_window_us` (rw): "Time window in micro seconds."
- The names come from source: `[POWER_LIMIT1] = "long_term"`, `[POWER_LIMIT2] = "short_term"`, `[POWER_LIMIT4] = "peak_power"`. Map by reading `constraint_X_name`, never by index.
- So: PL1 65 W = `65000000` µW; PL2 219 W = `219000000` µW; Tau 28 s = `28000000` µs.
- The firmware can also hold a PL in MSR/MMIO that caps the sysfs value. Apply reads back `constraint_*_power_limit_uw` and fails on mismatch.

## Vmin Shift: why nothing raises voltage

- Root cause (intel-vmin-rc): "a clock tree circuit within the IA core which is particularly vulnerable to reliability aging under elevated voltage and temperature."
- 0x125 (June 2024) "addresses eTVB algorithm issue". 0x129 (Aug 2024) "addresses high voltages requested by the processor". 0x12B "encompasses 0x125 and 0x129 … and addresses elevated voltage requests by the processor during idle and/or light activity periods" and "must be loaded via BIOS update" (intel-vmin-rc).
- 0x129 "will limit voltage requests above 1.55V as a preventative mitigation" (intel-0x129).
- 0x12F follows "reports regarding systems continuously running for multiple days with low-activity and lightly-threaded workloads". Intel asks users to "ensure they have the latest BIOS updates installed and utilize the Intel Default Settings profile in their BIOS" (intel-0x12f).
- On this board: F11 "Introduce the "Intel Default Settings" and enabled as default, user needs to disable it first to use GIGABYTE PerfDrive profiles" (0x12B). F13c "Introduce microcode 0x12F" (gb-support). The installed F13c has both.
- Intel publishes no statement in the words "positive offsets must never be used". The ban on positive offsets and on ratio or BCLK changes is this repo's rule (CONVENTIONS "Forbidden"), grounded in the aging mechanism above. Cite `intel-vmin-rc` for it, not an invented quote.

## Undervolting on a locked part

- "Undervolt Protection is only available on 12th Gen Intel® Core™ Processors and newer processors." "UVP is enabled by default … Disabling UVP exposes risks and vulnerabilities and is not recommended." It can be disabled only on "certain unlocked K/KF/KS/X processors paired with a Z/X PCH" (intel-uvp). The i7-14700 is not unlocked, so UVP stays on. Runtime offset tools (`intel-undervolt`, `wrmsr`) are out; the security team's deny-list is red on them.
- "Intel® does not provide undervolting controls/software/tools for locked non-K processors." and "System manufacturers set the undervolt options in BIOS" (intel-nonk-uv). An AC-loadline undervolt is therefore a BIOS runbook, if the board exposes it. gb-bg lists "Under Voltage Protection" (p11) and "Advanced Voltage Settings" (p16), with no loadline items named. The first undervolt ticket starts with a human reading of those submenus.

## DDR5

- JEDEC: "Improved power efficiency enabled by Vdd going from 1.2V to 1.1V as compared to DDR4". DDR5 was "expected to be launched at 4.8 Gbps" (jedec-ddr5-pr). JESD79-5C extends "timing parameters definition from 6800 Mbps to 8800 Mbps" (jedec-79-5c-pr).
- The full speed-bin tables and VDDQ are in the paywalled JESD79-5D (jedec-79-5d). Not sourced here; take kit values from the DIMM's SPD/XMP readout (a human reading or `decode-dimms`) and cite that reading.
- The CPU's supported speed is 5600 MT/s (intel-ark-14700). Running XMP above that is memory overclocking, so it goes through the pass protocol below.

## RAM pass protocol (rubric)

1. Pass 0: stock, then XMP Profile1 only (gb-bg p13, "Extreme Memory Profile (X.M.P.)"). Gate: the bench stability pass green, and a reading of the speed in Linux.
2. Each later pass changes exactly one variable: one timing, one voltage (never above the kit's XMP value), or one ratio of memory speed. The ticket names the variable, its old value, its new value, and its source.
3. Gate each pass with the bench stability pass. Red → revert that variable to its last green value, and record the failure in `results/`.
4. Never stack two untested changes. Never start a pass while the previous gate is open.

## Worked example: PL1/PL2 apply

`cpu/apply.sh` reads `constraint_0_name`, expects `long_term`, writes `65000000` through the `lib/` helper, and reads it back. It does the same for `short_term` and `219000000`, and for Tau `28000000`. Each value's row carries `intel-ds-v1#table17`. The values lint compares each against the ceiling table above. A fixture with `short_term` = `253000000` (the 125 W part's PL2, same table p104) must turn it red.
