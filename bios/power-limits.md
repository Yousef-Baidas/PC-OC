# Runbook: power limits

Why: first runbook; only the two package power limits are touched, nothing else.

## Before

Note: keys are Del (open setup), F2 (Advanced Mode), Alt+F (search), F10 (save and exit); cite gb-bios700.

1. Save the current profile to a slot: in Save & Exit > Save Profiles, store it in a slot that holds no profile, name it pre-power-limits, confirm with the Return key (gb-bios700 p29).
   - Revert: the profile saved in this step.
   - Report: the slot number.
2. Read /usr/local/lib/pc-oc/VERSION in Linux and compare it with the output of `git rev-parse HEAD` run in the checkout this runbook is read from; an older installed copy prints n/a for the voltage and power fields the later guides gate on.
   - Revert: none, read-only.
   - Report: both values, and whether they match; a missing file or a VERSION ending in -dirty counts as not matching.
3. Run `sudo os/install.sh` from the root of that checkout when step 2 shows no match, a missing file or a VERSION ending in -dirty, then read /usr/local/lib/pc-oc/VERSION again and continue only when it matches the checkout; skip this step when step 2 matched.
   - Revert: none, the installer only replaces the installed copy.
   - Report: the installer output and the VERSION line read after it.
4. Run `sudo /usr/local/lib/pc-oc/pc-oc probe cpu` in Linux and save the output as the stock record.
   - Revert: none, read-only.
   - Report: the full probe output.
5. Read the BIOS version in System Info. and stop when it is older than F13c.
   - Revert: none, read-only.
   - Report: the BIOS version as printed.

## Limits

Note: path from gb-bios700 p13: Tweaker > Advanced CPU Settings > Turbo Power Limits > Power Limit TDP (Watts) / Power Limit Time. Find each item with Alt+F search; the screen may print other names.

- SET cpu.pl1 = 219 W # src: intel-14-pl,gb-bios700
- SET cpu.pl2 = 219 W # src: intel-14-pl,gb-bios700
- Report: the path as printed on screen for cpu.pl1 and for cpu.pl2, and the stock values shown before step 6.
- Report: when the two limits are greyed out or do not accept a value, stop and send the screen; they are configurable only under Turbo Power Limits (gb-bios700 p13).
- Note: with Alt+F, search for Power Limit (gb-bios700 p4).
- Report: the on-screen name of the long-duration limit for cpu.pl1 and of the short-duration limit for cpu.pl2 (intel-14-pl).
- Revert: both limits to the stock record from step 4.

6. Save the two values with F10 (Save & Exit Setup), then boot Linux.
   - Revert: the stock record from step 4.
   - Report: whether the machine posts.

## Verify

7. Run `sudo /usr/local/lib/pc-oc/pc-oc probe cpu` after the boot.
   - Revert: none, read-only.
   - Report: the probe must print cpu.pl1_uw=219000000 and cpu.pl2_uw=219000000; for any other value, stop and send the full output.

## Gate

8. Run `watch -n 5 sensors` in a second terminal, then `bench/stability.sh cpu 10` in Linux.
   - Revert: none, read-only.
   - Report: PASS needs result.stability=PASS; send the result lines.
9. Record vcore_max_mv, pkg_w_avg and mhz_avg from the gate output.
   - Revert: none, read-only.
   - Report: the three values.

## Thermal rule

10. Read `sensors` coretemp Package id 0 in the second terminal while step 8 runs, and the journal for throttle messages.
   - Revert: none, read-only.
   - Report: TjMax of 100 C reached or throttle messages seen: stop and send the reading; both limits 20 W under their first value, then the gate repeats; never above 219 W (intel-14-pl).

## Roll back

11. Revert: cpu.pl1 and cpu.pl2 to the stock record from step 4, not the defaults entry (that entry affects XMP too).
   - Note: only when step 7 or step 8 does not pass, or after a thermal stop in step 10.
   - Report: the output of `sudo /usr/local/lib/pc-oc/pc-oc probe cpu` after F10 and boot.

## Reading

12. Record what you saw: copy bios/readings/TEMPLATE.md to bios/readings/DATE-power-limits.md and fill it from the screen and the gate output.
    - Revert: none.
    - Report: the filled file.

## CMOS clear recovery

Note: for when the machine fails to post after step 6.

1. Run: unplug AC power, short the two CLR_CMOS pins with a metal object for a few seconds, then plug in and power on (gb-um p29).
   - Revert: none.
   - Report: whether the machine posts.
2. Revert: F4 in Advanced Mode, then the slot from step 1 (gb-bios700 p4).
   - Report: what the screen shows after the profile is in place.
