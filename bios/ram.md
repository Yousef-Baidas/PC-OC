# RAM: DDR5 frequency and timings

Note: the human does every BIOS step here at the firmware screen; this guide never claims a value is in place until the human reports it.
Note: kit is Kingston FURY Beast KF556C40BB-16, two modules (kingston-kf556c40).

## Prerequisite

- Note: bios/undervolt.md is complete and its final value passed its soak.
- Run: sudo /usr/local/lib/pc-oc/pc-oc probe ram
- Record: ram.dimm0.part, ram.dimm1.part, ram.dimm0.configured_mv, ram.dimm1.configured_mv (stock DRAM rail), ram.spd0.dram_mfr, ram.spd1.dram_mfr
- Read: ram.dimm0.configured_mts = 5600 means XMP Profile1 is active.
- Note: any other configured_mts means stop here and report it.
- Note: the chip maker is recorded only; no value below depends on it (human decision on #79, 2026-10-01).
- Note: a dram_mfr of unknown, or spd=no-spd5118, is a valid reading.

## Menus

- Note: each key's menu path is its row in bios/menu-paths.tsv, with its gb-bios700 page.
- Note: every row there is confirm-on-screen: find the item with Alt+F (gb-bios700 p4) and record the on-screen path in the reading.
- Note: the menu text of the mem.freq row trips the runbook lint, so this guide names the key only.
- Note: that gap is debt on issue #80.
- Note: the profile and exit items this guide names are in the fence below (gb-bios700 p4, p29).

```text
slot:            Save & Exit > Save Profiles > Setup Profile 1 to 8
profile file:    Save & Exit > Save Profiles > Select File in HDD/FDD/USB
profile return:  Save & Exit > Load Profiles > the slot or the file
defaults:        Save & Exit > Load Optimized Defaults
exit:            Save & Exit > Save & Exit Setup
search:          Alt+F, then the item name
```

## Limits

- Note: the DRAM rail cap is the human hard limit of this run; the lint (#72) checks every rail line.
- Note: only the keys on the lines of this guide differ from the step 1 slot; every other item stays as that slot has it.
- Note: no POST at any step: the No-POST recovery section, then the Revert line of that step.

## Start values

- Note: CAS is mem.tcl, RAS-to-CAS mem.trcd, precharge mem.trp, row active mem.tras, refresh mem.trfc.
- Why: start values hold the kit's own nanoseconds at each data rate, rounded to whole cycles (kingston-kf556c40 p1).
- Why: CAS, RAS-to-CAS and precharge round to the next even cycle count, as every CAS value in the kit datasheet is even (kingston-kf556c40 p1).

```text
cycle time in ns = 2000 / data rate
kit Profile1 (kingston-kf556c40 p1): 40-40-40 at 5600
kit minimums (kingston-kf556c40 p1): row active 32 ns, refresh 295 ns
CAS, RAS-to-CAS, precharge: 40 x 2000 / 5600 = 14.29 ns
  at 6000: 14.29 x 6000 / 2000 = 42.9 -> 44
  at 6400: 14.29 x 6400 / 2000 = 45.7 -> 46
row active: at 6000: 32 x 6000 / 2000 = 96.0 -> 96
            at 6400: 32 x 6400 / 2000 = 102.4 -> 103
refresh:    at 6000: 295 x 6000 / 2000 = 885.0 -> 885
            at 6400: 295 x 6400 / 2000 = 944.0 -> 944
```

## Save the current profile

1. Save the current profile to a free Setup Profile slot by the slot path in the menu fence (gb-bios700 p29).
- Save: the same profile to a USB stick by the profile-file path in the menu fence (gb-bios700 p29).
- Report: the slot number (the step 1 slot) and the USB file name.
- Revert: none; this step only stores a profile.

## XMP check

2. Read: mem.xmp on screen, BIOS version in System Info. (gb-bios700 p25).
- Note: any value other than Profile1 means stop here and report it.
- Note: the fence below names items with no row in bios/menu-paths.tsv; find each with Alt+F (gb-bios700 p4).

```text
Memory Context Restore
Retry Loop Count
Memory Boot Mode
```

- Why: gb-bios700 lists the last two (p15, p14) and not the first.
- Record: the on-screen path and value of each item in the fence above, or not found.
- Note: no step here alters those three items.
- Save: Save & Exit Setup by the exit path in the menu fence.
- Report: mem.xmp as seen, BIOS version, the three items as seen.
- Revert: none; this step only reads.

## Frequency

- Note: one BIOS visit per step; exit by the exit path in the menu fence, boot Linux, then the gate.
- Note: step 4 runs only after a PASS at step 3; a FAIL at step 3 or 4 means step 21 next.
- Why: the DRAM rail value is the hard limit of this run; the kit rates Profile1 below it (kingston-kf556c40 p1).

3. Note: first frequency rung.
- SET mem.vdd = 1.35 V  # src: kingston-kf556c40
- SET mem.vddq = 1.35 V  # src: kingston-kf556c40
- SET mem.freq = 6000  # src: gb-bios700
- SET mem.tcl = 44  # src: kingston-kf556c40
- SET mem.trcd = 44  # src: kingston-kf556c40
- SET mem.trp = 44  # src: kingston-kf556c40
- SET mem.tras = 96  # src: kingston-kf556c40
- SET mem.trfc = 885  # src: kingston-kf556c40
- Read: each key above on screen shows the value of its line, before the exit.
- Run: sudo /usr/local/lib/pc-oc/pc-oc probe ram
- Run: bench/stability.sh cpu 10
- Report: ram.dimm0.configured_mts, ram.dimm0.configured_mv, result.stability and every result.stability.* line.
- Record: reading row: step 3, every mem key as seen, result.stability.
- Revert on FAIL or no POST: the step 1 slot by the profile-return path in the menu fence; XMP 5600 is final, step 21 next.

4. Note: second frequency rung.
- Save: first, the current values to a free slot, the pass slot (gb-bios700 p29).
- SET mem.freq = 6400  # src: gb-bios700
- SET mem.tcl = 46  # src: kingston-kf556c40
- SET mem.trcd = 46  # src: kingston-kf556c40
- SET mem.trp = 46  # src: kingston-kf556c40
- SET mem.tras = 103  # src: kingston-kf556c40
- SET mem.trfc = 944  # src: kingston-kf556c40
- Read: each key above on screen shows the value of its line, before the exit.
- Run: sudo /usr/local/lib/pc-oc/pc-oc probe ram
- Run: bench/stability.sh cpu 10
- Report: ram.dimm0.configured_mts, result.stability and every result.stability.* line.
- Record: reading row: step 4, every mem key as seen, result.stability.
- Revert on FAIL or no POST: the pass slot, which holds mem.freq = 6000, mem.tcl = 44, mem.trcd = 44, mem.trp = 44, mem.tras = 96, mem.trfc = 885; step 21 next.

## Timing ladders at 6400

- Note: steps 5 to 20 run only after a PASS at step 4.
- Note: one key, or the RAS-to-CAS and precharge pair, per step; one BIOS visit per step, then the gate.
- Note: each step opens with the pass slot: it holds the values that passed the last gate (gb-bios700 p29).
- Note: PASS on a rung means the next rung; PASS on the last rung of a ladder means the next ladder.
- Note: FAIL or no POST on a rung means its Revert line, the gate again, then the next ladder.
- Note: a FAIL of the gate after a back-off means the pass slot, then step 21.
- Why: the CAS rung is two cycles, as every CAS value in the kit datasheet is even (kingston-kf556c40 p1).
- Why: the other ladders take the CAS rung's share of its start value, rounded to whole cycles.
- Why: the back-off is one rung plus one margin rung from the failed value, the rule of bios/undervolt.md.
- Why: four rungs per ladder hold the search to sixteen gates; no rung past the fourth has a basis here.

```text
CAS rung: 2 cycles
share of start: 2 / 46 = 0.043
row active rung: 103 x 0.043 = 4.5 -> 4 cycles
refresh rung:    944 x 0.043 = 41.0 -> 41 cycles
back-off: failed value + 2 rungs; above the start value when rung one fails
CAS and RAS-to-CAS and precharge: 46 -> 44, 42, 40, 38; back-off 48, 46, 44, 42
row active: 103 -> 99, 95, 91, 87; back-off 107, 103, 99, 95
refresh:    944 -> 903, 862, 821, 780; back-off 985, 944, 903, 862
```

5. Note: CAS ladder, rung one of four.
- Save: the pass slot first.
- SET mem.tcl = 44  # src: kingston-kf556c40
- Run: bench/stability.sh cpu 10
- Report: result.stability and every result.stability.* line.
- Record: reading row: step 5, every mem key as seen, result.stability.
- Revert on FAIL or no POST: mem.tcl = 48, then the gate again, then step 9.
- Report: after a back-off, result.stability and every result.stability.* line of that gate.
- Record: after a back-off, reading row: step 5 back-off, every mem key as seen, result.stability.

6. Note: CAS ladder, rung two of four.
- Save: the pass slot first.
- SET mem.tcl = 42  # src: kingston-kf556c40
- Run: bench/stability.sh cpu 10
- Report: result.stability and every result.stability.* line.
- Record: reading row: step 6, every mem key as seen, result.stability.
- Revert on FAIL or no POST: mem.tcl = 46, then the gate again, then step 9.
- Report: after a back-off, result.stability and every result.stability.* line of that gate.
- Record: after a back-off, reading row: step 6 back-off, every mem key as seen, result.stability.

7. Note: CAS ladder, rung three of four.
- Save: the pass slot first.
- SET mem.tcl = 40  # src: kingston-kf556c40
- Run: bench/stability.sh cpu 10
- Report: result.stability and every result.stability.* line.
- Record: reading row: step 7, every mem key as seen, result.stability.
- Revert on FAIL or no POST: mem.tcl = 44, then the gate again, then step 9.
- Report: after a back-off, result.stability and every result.stability.* line of that gate.
- Record: after a back-off, reading row: step 7 back-off, every mem key as seen, result.stability.

8. Note: CAS ladder, rung four of four.
- Save: the pass slot first.
- SET mem.tcl = 38  # src: kingston-kf556c40
- Run: bench/stability.sh cpu 10
- Report: result.stability and every result.stability.* line.
- Record: reading row: step 8, every mem key as seen, result.stability.
- Revert on FAIL or no POST: mem.tcl = 42, then the gate again, then step 9.
- Report: after a back-off, result.stability and every result.stability.* line of that gate.
- Record: after a back-off, reading row: step 8 back-off, every mem key as seen, result.stability.

9. Note: RAS-to-CAS and precharge ladder, rung one of four.
- Save: the pass slot first.
- SET mem.trcd = 44  # src: kingston-kf556c40
- SET mem.trp = 44  # src: kingston-kf556c40
- Run: bench/stability.sh cpu 10
- Report: result.stability and every result.stability.* line.
- Record: reading row: step 9, every mem key as seen, result.stability.
- Revert on FAIL or no POST: mem.trcd = 48 and mem.trp = 48, then the gate again, then step 13.
- Report: after a back-off, result.stability and every result.stability.* line of that gate.
- Record: after a back-off, reading row: step 9 back-off, every mem key as seen, result.stability.

10. Note: RAS-to-CAS and precharge ladder, rung two of four.
- Save: the pass slot first.
- SET mem.trcd = 42  # src: kingston-kf556c40
- SET mem.trp = 42  # src: kingston-kf556c40
- Run: bench/stability.sh cpu 10
- Report: result.stability and every result.stability.* line.
- Record: reading row: step 10, every mem key as seen, result.stability.
- Revert on FAIL or no POST: mem.trcd = 46 and mem.trp = 46, then the gate again, then step 13.
- Report: after a back-off, result.stability and every result.stability.* line of that gate.
- Record: after a back-off, reading row: step 10 back-off, every mem key as seen, result.stability.

11. Note: RAS-to-CAS and precharge ladder, rung three of four.
- Save: the pass slot first.
- SET mem.trcd = 40  # src: kingston-kf556c40
- SET mem.trp = 40  # src: kingston-kf556c40
- Run: bench/stability.sh cpu 10
- Report: result.stability and every result.stability.* line.
- Record: reading row: step 11, every mem key as seen, result.stability.
- Revert on FAIL or no POST: mem.trcd = 44 and mem.trp = 44, then the gate again, then step 13.
- Report: after a back-off, result.stability and every result.stability.* line of that gate.
- Record: after a back-off, reading row: step 11 back-off, every mem key as seen, result.stability.

12. Note: RAS-to-CAS and precharge ladder, rung four of four.
- Save: the pass slot first.
- SET mem.trcd = 38  # src: kingston-kf556c40
- SET mem.trp = 38  # src: kingston-kf556c40
- Run: bench/stability.sh cpu 10
- Report: result.stability and every result.stability.* line.
- Record: reading row: step 12, every mem key as seen, result.stability.
- Revert on FAIL or no POST: mem.trcd = 42 and mem.trp = 42, then the gate again, then step 13.
- Report: after a back-off, result.stability and every result.stability.* line of that gate.
- Record: after a back-off, reading row: step 12 back-off, every mem key as seen, result.stability.

13. Note: row active ladder, rung one of four.
- Save: the pass slot first.
- SET mem.tras = 99  # src: kingston-kf556c40
- Run: bench/stability.sh cpu 10
- Report: result.stability and every result.stability.* line.
- Record: reading row: step 13, every mem key as seen, result.stability.
- Revert on FAIL or no POST: mem.tras = 107, then the gate again, then step 17.
- Report: after a back-off, result.stability and every result.stability.* line of that gate.
- Record: after a back-off, reading row: step 13 back-off, every mem key as seen, result.stability.

14. Note: row active ladder, rung two of four.
- Save: the pass slot first.
- SET mem.tras = 95  # src: kingston-kf556c40
- Run: bench/stability.sh cpu 10
- Report: result.stability and every result.stability.* line.
- Record: reading row: step 14, every mem key as seen, result.stability.
- Revert on FAIL or no POST: mem.tras = 103, then the gate again, then step 17.
- Report: after a back-off, result.stability and every result.stability.* line of that gate.
- Record: after a back-off, reading row: step 14 back-off, every mem key as seen, result.stability.

15. Note: row active ladder, rung three of four.
- Save: the pass slot first.
- SET mem.tras = 91  # src: kingston-kf556c40
- Run: bench/stability.sh cpu 10
- Report: result.stability and every result.stability.* line.
- Record: reading row: step 15, every mem key as seen, result.stability.
- Revert on FAIL or no POST: mem.tras = 99, then the gate again, then step 17.
- Report: after a back-off, result.stability and every result.stability.* line of that gate.
- Record: after a back-off, reading row: step 15 back-off, every mem key as seen, result.stability.

16. Note: row active ladder, rung four of four.
- Save: the pass slot first.
- SET mem.tras = 87  # src: kingston-kf556c40
- Run: bench/stability.sh cpu 10
- Report: result.stability and every result.stability.* line.
- Record: reading row: step 16, every mem key as seen, result.stability.
- Revert on FAIL or no POST: mem.tras = 95, then the gate again, then step 17.
- Report: after a back-off, result.stability and every result.stability.* line of that gate.
- Record: after a back-off, reading row: step 16 back-off, every mem key as seen, result.stability.

17. Note: refresh ladder, rung one of four.
- Save: the pass slot first.
- SET mem.trfc = 903  # src: kingston-kf556c40
- Run: bench/stability.sh cpu 10
- Report: result.stability and every result.stability.* line.
- Record: reading row: step 17, every mem key as seen, result.stability.
- Revert on FAIL or no POST: mem.trfc = 985, then the gate again, then step 21.
- Report: after a back-off, result.stability and every result.stability.* line of that gate.
- Record: after a back-off, reading row: step 17 back-off, every mem key as seen, result.stability.

18. Note: refresh ladder, rung two of four.
- Save: the pass slot first.
- SET mem.trfc = 862  # src: kingston-kf556c40
- Run: bench/stability.sh cpu 10
- Report: result.stability and every result.stability.* line.
- Record: reading row: step 18, every mem key as seen, result.stability.
- Revert on FAIL or no POST: mem.trfc = 944, then the gate again, then step 21.
- Report: after a back-off, result.stability and every result.stability.* line of that gate.
- Record: after a back-off, reading row: step 18 back-off, every mem key as seen, result.stability.

19. Note: refresh ladder, rung three of four.
- Save: the pass slot first.
- SET mem.trfc = 821  # src: kingston-kf556c40
- Run: bench/stability.sh cpu 10
- Report: result.stability and every result.stability.* line.
- Record: reading row: step 19, every mem key as seen, result.stability.
- Revert on FAIL or no POST: mem.trfc = 903, then the gate again, then step 21.
- Report: after a back-off, result.stability and every result.stability.* line of that gate.
- Record: after a back-off, reading row: step 19 back-off, every mem key as seen, result.stability.

20. Note: refresh ladder, rung four of four.
- Save: the pass slot first.
- SET mem.trfc = 780  # src: kingston-kf556c40
- Run: bench/stability.sh cpu 10
- Report: result.stability and every result.stability.* line.
- Record: reading row: step 20, every mem key as seen, result.stability.
- Revert on FAIL or no POST: mem.trfc = 862, then the gate again, then step 21.
- Report: after a back-off, result.stability and every result.stability.* line of that gate.
- Record: after a back-off, reading row: step 20 back-off, every mem key as seen, result.stability.

## Final soak

21. Run: bench/stability.sh soak 60
- Report: result.stability, result.stability.soak_minutes and every other result.stability.* line.
- Record: reading row: step 21, every mem key as seen, result.stability.
- Revert on FAIL: each mem key to the PASS row before the row the soak ran on, then the soak again; a FAIL back at the step 3 row ends at the step 1 slot.
- Save: on PASS, the final values to a free slot, the final slot (gb-bios700 p29).
- Report: the final slot number.

## No-POST recovery and CMOS clear

- Note: after a failed memory training the board retrains as many times as Retry Loop Count holds (gb-bios700 p15); its value is in the step 2 reading.
- Note: a board that reaches the BIOS screen after the retries needs no CMOS clear; the profile-return path is next.
- Note: no BIOS screen after the retries: PSU off, power cord out of the outlet (gb-um p29).
- Short: the two CLR_CMOS pins with a metal object such as a screwdriver for a few seconds (gb-um p29).
- Note: power cord back in, PSU on, Del at the logo for BIOS Setup (gb-bios700 p3).
- Revert: the defaults path in the menu fence, as gb-um p29 asks after a CMOS clear.
- Revert: the pass slot by the profile-return path in the menu fence; the step 1 slot when no pass slot exists yet.
- Note: the USB file holds the step 1 state, not the pass slot.
- Revert: when only the USB file returns, each mem key to the last PASS row of the reading, then the gate of that row again.
- Revert: then the Revert line of the step that failed.
- Read: each key on screen matches the reading row of that slot.
- Report: BIOS version, retries seen, CMOS clear yes or no, which slot or file returned.
- Record: reading row: no POST at the step, with the Report fields above.

## Rollback to the kit profile

- Revert: the step 1 slot by the profile-return path in the menu fence (gb-bios700 p29).
- Read: mem.xmp = Profile1 and mem.freq = 5600 on screen.
- Run: sudo /usr/local/lib/pc-oc/pc-oc probe ram
- Report: ram.dimm0.configured_mts and ram.dimm0.configured_mv.
- Record: reading row: rollback, every mem key as seen.

## Reading

- Record: copy bios/readings/TEMPLATE.md to bios/readings/YYYY-MM-DD-ram.md, one row per step in its Settings as seen table.
- Record: the gate keys of each step under Gate, and the Prerequisite probe lines under Probe.
- Note: a reading row holds mem.xmp, mem.freq, mem.vdd, mem.vddq, mem.tcl, mem.trcd, mem.trp, mem.tras and mem.trfc as seen.
- Note: the lead commits the reading from the human's report; nobody invents a value.
