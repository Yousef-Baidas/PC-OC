# Runbook: power limits

Why: first runbook; only the two package power limits are touched, nothing else.

## Before

Note: keys are Del (open setup), F2 (Advanced Mode), Alt+F (search), F10 (save and exit); cite gb-bios700.

1. Save the current profile to a slot: in Save & Exit > Save Profiles, store it as Setup Profile 1, name it pre-power-limits, confirm with the Return key (gb-bios700 p29).
   - Revert: the profile saved in this step.
   - Report: the slot number of the profile.
2. Run `sudo /usr/local/lib/pc-oc/pc-oc probe cpu` in Linux and save the output as the stock record.
   - Revert: none, read-only.
   - Report: the full probe output.
3. Read the BIOS version in System Info. and stop when it is older than F13c.
   - Revert: none, read-only.
   - Report: the BIOS version as printed.

## Limits

Note: path from gb-bios700 p13: Tweaker > Advanced CPU Settings > Turbo Power Limits > Power Limit TDP (Watts) / Power Limit Time. Find each item with Alt+F search; the screen may print other names.

- SET cpu.pl1 = 219 W # src: intel-14-pl,gb-bios700
- SET cpu.pl2 = 219 W # src: intel-14-pl,gb-bios700
- Report: the path as printed on screen for cpu.pl1 and for cpu.pl2, and the stock values shown before step 4.
- Revert: both limits to the stock record from step 2.

4. Save the two values with F10 (Save & Exit Setup), then boot Linux.
   - Revert: the stock record from step 2.
   - Report: whether the machine posts.

## Verify

5. Run `sudo /usr/local/lib/pc-oc/pc-oc probe cpu` after the boot.
   - Revert: none, read-only.
   - Report: the probe must print cpu.pl1_uw=219000000 and cpu.pl2_uw=219000000; for any other value, stop and send the full output.

## Gate

6. Run `bench/stability.sh cpu 10` in Linux.
   - Revert: none, read-only.
   - Report: PASS needs result.stability=PASS; send the result lines.
7. Record vcore_max_mv, pkg_w_avg and mhz_avg from the gate output.
   - Revert: none, read-only.
   - Report: the three values.

## Thermal rule

8. Read `sensors` coretemp Package id 0 during the gate, and the journal for throttle messages.
   - Revert: none, read-only.
   - Report: TjMax of 100 C reached or throttle messages seen: stop and send the reading; both limits 20 W under their first value, then the gate repeats; never above 219 W (intel-14-pl).

## Roll back

9. Revert: cpu.pl1 and cpu.pl2 to the stock record from step 2, not the defaults entry (that entry affects XMP too).
   - Report: the probe output after the roll back.

## Reading

10. Record what you saw: copy bios/readings/TEMPLATE.md to bios/readings/DATE-power-limits.md and fill it from the screen and the gate output.
    - Revert: none.
    - Report: the filled file.

## CMOS clear recovery

Note: for when the machine fails to post after step 4.

1. Run: unplug AC power, short the two CLR_CMOS pins with a metal object for a few seconds, then plug in and power on (gb-um p29).
   - Revert: none.
   - Report: whether the machine posts.
2. Note: after posting, in Save & Exit, Setup Profile 1 from step 1 holds the stock settings (gb-bios700 p29).
