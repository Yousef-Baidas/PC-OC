# writer craft: BIOS runbooks for the Z790 GAMING X AX

A senior technical writer on firmware procedures writes for a reader alone at the BIOS screen, with no search box and no agent. Every step is one action on a menu item whose exact printed name is on file, a value someone else cited, what the screen should show after, and how to undo it.

## Sources

| id | Document | URL | Revision |
|---|---|---|---|
| gb-um | Z790 GAMING X AX / Z790 GAMING X User's Manual | https://download.gigabyte.com/FileList/Manual/mb_manual_z790-gx-series_e_1201.pdf | Rev. 1201, © 2023, sha256 `b5cd7063…46455d`, 40 pages |
| gb-bg | BIOS Setup Guide (Intel 700 Series), linked from the board's support page | https://download.gigabyte.com/FileList/Manual/mb_manual_intel700series-bios_e.pdf | no revision printed; PDF created 2022-09-27, sha256 `33772611…c7a8b1b3`, 29 pages |
| gb-support | Z790 GAMING X AX (rev. 1.x) support page (BIOS list and release notes) | https://www.gigabyte.com/Motherboard/Z790-GAMING-X-AX-rev-1x/support | read 2026-09-30 |
| g-proc | Google developer documentation style guide: Procedures | https://developers.google.com/style/procedures | read 2026-09-30 |
| dia-howto | Diátaxis: How-to guides | https://diataxis.fr/how-to-guides/ | read 2026-09-30 |

Printed page numbers equal PDF page numbers in both Gigabyte files.

## What the manuals do and do not say

- The board manual does not document the BIOS menus. Chapter 3 (gb-um p31) points to the web, and the support page lists the separate BIOS Setup Guide (gb-bg). `bios/menu-paths.tsv` therefore carries a `doc` column (`gb-um` or `gb-bg`) next to the page number.
- gb-bg dates from Sep 2022, and its screenshots come from a Z790 AORUS XTREME with BIOS "T0d" (gb-bg p25). The F8 release note (Sep 12, 2023) says "Introduction of new BIOS user interface" (gb-support). The installed BIOS may use other menu names. Rule: a menu path is `confirmed` only after a human reading on this board shows it. Until then its row is `manual-only`, and a runbook step that uses it asks the human to report the name on screen.
- These names are not in gb-bg under any spelling tried: "Package Power Limit1/2", "Tau", "AC/DC loadline", "CPU Vcore Loadline Calibration", "Intel Default Settings". gb-bg has only "Power Limit TDP (Watts) / Power Limit Time" and "Core Current Limit (Amps)" (p13), plus "Advanced Voltage Settings" (p16), described as "configure Load-Line Calibration level, over-voltage protection level, and over-current protection level" with no items listed. The first runbook that needs these items starts with a discovery step: the human photographs or transcribes the submenu, and those rows go into `menu-paths.tsv` marked `human-reading <date>`.

## Menu map confirmed from the manuals

Names are exactly as printed.

| Menu path | Doc, page |
|---|---|
| Startup keys `<DEL>: BIOS SETUP\Q-FLASH`, `<F12>: BOOT MENU`, `<END>: Q-FLASH` | gb-um p32; gb-bg p3 |
| Advanced Mode hotkeys: `<F3>` save to a profile, `<F4>` load a profile, `<F7>` Load Optimized Defaults, `<F8>` Q-Flash | gb-bg p4 |
| Easy Mode (`<F2>` toggles) | gb-bg p5 |
| Top tabs: Favorites (F11), Tweaker, Settings, System Info., Boot, Save & Exit | gb-bg p4 |
| Tweaker: CPU Upgrade, CPU Base Clock, Enhanced Multi-Core Performance, Performance CPU Clock Ratio, Efficiency CPU Clock Ratio, Max Ring Ratio, Min Ring Ratio | gb-bg p9 |
| Tweaker > Advanced CPU Settings: Hyper-Threading Technology, CPU EIST Function, Intel(R) Turbo Boost Technology | gb-bg p10 |
| Tweaker > Advanced CPU Settings: IA CEP (Current Excursion Protection), Under Voltage Protection, AVX Settings, Active Turbo Ratios | gb-bg p11 |
| Tweaker > Advanced CPU Settings: C-States Control, CPU Enhanced Halt (C1E), Package C State limit | gb-bg p12 |
| Tweaker > Advanced CPU Settings > Turbo Power Limits: Power Limit TDP (Watts) / Power Limit Time, Core Current Limit (Amps); Turbo Per Core Limit Control | gb-bg p13 |
| Tweaker: DDR5 Auto Booster, DDR5 XMP Booster, Extreme Memory Profile (X.M.P.) (Disabled / Profile1 / Profile2), System Memory Multiplier | gb-bg p13 |
| Tweaker > Advanced Memory Settings: Gear Mode, Memory Boot Mode, SA GV, SPD Info, SPD Setup, Memory Channels Timings, Memory Training Settings | gb-bg p14–15 |
| Tweaker > CPU/PCH Voltage Control/DRAM Voltage Control | gb-bg p15 |
| Tweaker > DDR5 Voltage Control; Advanced Voltage Settings | gb-bg p16 |
| Settings > Platform Power; IO Ports (Re-Size BAR Support, Above 4G Decoding); Miscellaneous; PC Health Status (CPU Vcore readout) | gb-bg p17–24 |
| System Info. | gb-bg p25 |
| Boot (CFG Lock, Fast Boot, CSM Support, Secure Boot) | gb-bg p26–28 |
| Save & Exit: Save & Exit Setup, Exit Without Saving, Load Optimized Defaults, Boot Override, Save Profiles, Load Profiles | gb-bg p29 |

Profile slots: Save Profiles stores "up to 8 profiles and save as Setup Profile 1~ Setup Profile 8", or to a file on USB. Load Profiles includes "last known good record" (gb-bg p29). Every runbook's step 1 saves to a named slot, and its revert loads that slot.

## CMOS-clear recovery (every runbook)

The CLR_CMOS jumper is item "18) CLR_CMOS (Clear CMOS Jumper)" (gb-um p29): "Open: Normal / Short: Clear CMOS Values". Unplug AC power, short the two pins with a metal object for a few seconds, and after boot "select Load Optimized Defaults" (gb-um p29). The spec table lists "1 x Clear CMOS jumper" (gb-um p8). After a CMOS clear, recover by loading the step-1 profile slot through Load Profiles (gb-bg p29), or from the USB file if the slots were lost.

## BIOS version facts for runbook preconditions (gb-support)

- F11 (Sep 27, 2024): "Introduce the "Intel Default Settings" and enabled as default, user needs to disable it first to use GIGABYTE PerfDrive profiles"; microcode 0x12B.
- F13c (May 27, 2025): "Introduce microcode 0x12F as it further improves system conditions that can potentially contribute to Vmin Shift Instability".
- F13 (Jun 19, 2025): "CPU Microcode Update (0x3A & 0x12F)".
- Latest listed on 2026-09-30: F17a (Jul 31, 2026). Every runbook's precondition records the BIOS version the human reads in System Info. and stops when it is older than F13c.

## Procedure style (g-proc, dia-howto)

- Write procedures as numbered steps. Start the first sentence of each step with an imperative verb, and state where to act before the action ("In Tweaker > Advanced CPU Settings, set …"). Mark optional steps with "Optional:" as the first word (g-proc, summary table).
- Use lettered sub-steps under a step; a step that has sub-steps ends like an introductory sentence (g-proc, "Sub-steps in numbered procedures").
- Introduce a procedure with a full sentence ("To enable XMP, follow these steps:"), never a fragment finished by the list (g-proc, "Introductory sentences").
- A how-to is "action and only action", with "no digression, explanation, teaching"; link to explanation instead (dia-howto, "Key principles"). Why a value was chosen belongs in the owning team's cited source, not in the runbook.

## Step template

```
N. In <exact menu path from menu-paths.tsv>, set **<item>** to **<value>** (<source id>).
   - Screen shows after: <expected text>
   - Revert: set **<item>** to **<stock reading from bios/readings/>**
   - Report: <reading-to-report field, e.g. value shown, BIOS version>
```

## Worked example: enable XMP

1. Save the current settings: in Save & Exit > Save Profiles, pick Setup Profile <n>, name it `pre-xmp-<date>`, and press Enter (gb-bg p29). Report the slot number.
2. In Tweaker, set **Extreme Memory Profile (X.M.P.)** to **Profile1** (gb-bg p13; value from platform `ram/` with its source id). Revert: set it to the stock reading. Report: the speed shown next to the item.
3. In Save & Exit, choose Save & Exit Setup. Report: whether the machine posts, and `dmidecode -t memory` speed from Linux.
Recovery: if the machine does not post, clear CMOS as above, then Load Profiles > Setup Profile <n>.
