# Runbook: CPU undervolt by AC loadline

Note: the human does every BIOS step at the firmware screen; a value is in effect only once a reading shows it.

## Before you start

- Read: bios/power-limits.md finished, with its reading in bios/readings/.
- Record: the BIOS version that System Info. shows; this runbook is written for F17a.
- Record: the state Intel Default Settings shows; the stock loadline below holds with it on (intel-ll).
- Run: once per boot, in Linux, so the gate can read the voltage telemetry:

```bash
sudo modprobe msr
```

## Step 1: Save the current profile

1. Save the current settings in Save & Exit > Save Profiles to a free slot, Setup Profile N, named pre-undervolt and the date (gb-bios700 p29).
- Report: the slot number N.
- Revert: nothing on this step.

## Step 2: Stock reading

- Run: Alt+F for Option Search, and search for AC loadline; the manual has it under Tweaker > Advanced Voltage Settings (gb-bios700 p4, p16, p23).
- Record: the on-screen path to the AC loadline item and to the DC loadline item, as printed.
- Record: the AC loadline and DC loadline values as shown, and the unit the screen prints beside them.
- Report: when the stock AC loadline reads as anything but Auto or 1.10 mOhm (110 in hundredths), stop here and report it; every row below assumes that stock (intel-14-pl Table 77 p191, intel-ll).
- Note: this runbook writes only the AC loadline item; every other item on that screen stays as found.
- Run: Esc, then Save & Exit > Exit Without Saving, and boot to Linux.
- Run: the gate at stock:

```bash
bench/stability.sh cpu 10
```

- Record: result.stability.ycruncher, result.stability.stressng, result.stability.journal, vcore_max_mv, pkg_w_avg and mhz_avg, as row 0 of the reading.
- Report: row 0 is the stock baseline; when it is not all PASS, stop here and report it, since the fault is not the loadline.
- Revert: nothing on this step.

## Step 3: Units and why these values

- Note: values in this runbook are in mOhm. When Step 2 shows the unit as hundredths of a mOhm, the field takes the second column.

```text
mOhm   hundredths
1.10   110
1.00   100
0.90   90
0.80   80
0.70   70
0.60   60
```

- Why: in Intel's spec the AC loadline equals the DC loadline at the design limit, and a smaller AC loadline only cuts the operating voltage (intel-14-pl Table 77 notes 14 and 18; intel-ll).
- Why: one step is a tenth of a mOhm; at the rated application current of this part, one step moves the operating voltage by about one tolerance band of the rail (intel-14-pl Table 77).
- Why: the DC loadline stays at its stock value because it feeds the power measurement, not the voltage, and the board's real loadline does not move, so the power limits still act on true power (intel-14-pl Table 77 note 14).
- Why: the floor ends the loop after five steps even when the gate passes; a ten-minute gate cannot show the margin a deeper cut needs (intel-14-pl Table 77 note 7).

## Step 4: Loop, one step per boot

- Report: a row is PASS when the machine boots, ycruncher, stressng and journal all read PASS, and vcore_max_mv is at or below the row before; anything else, a freeze, a reboot or a hardware error in the journal included, is FAIL.
- Note: the loop ends at the first FAIL, or after row 5, the floor, even on PASS.

### Row 1

- SET cpu.ac_ll = 1.00 mOhm  # src: intel-14-pl,intel-ll
- Record: the AC loadline and DC loadline values the screen shows now; the DC loadline still shows its stock reading.
- Run: Save & Exit > Save & Exit Setup, Yes, then boot to Linux and run the gate:

```bash
bench/stability.sh cpu 10
```

- Record: the six keys of row 0, as row 1, with vcore_max_mv.
- Revert: on FAIL, Step 5; on PASS, row 2.

### Row 2

- SET cpu.ac_ll = 0.90 mOhm  # src: intel-14-pl,intel-ll
- Record: the AC loadline and DC loadline values the screen shows now; the DC loadline still shows its stock reading.
- Run: Save & Exit > Save & Exit Setup, Yes, then boot to Linux and run the gate:

```bash
bench/stability.sh cpu 10
```

- Record: the six keys of row 0, as row 2, with vcore_max_mv.
- Revert: on FAIL, Step 5; on PASS, row 3.

### Row 3

- SET cpu.ac_ll = 0.80 mOhm  # src: intel-14-pl,intel-ll
- Record: the AC loadline and DC loadline values the screen shows now; the DC loadline still shows its stock reading.
- Run: Save & Exit > Save & Exit Setup, Yes, then boot to Linux and run the gate:

```bash
bench/stability.sh cpu 10
```

- Record: the six keys of row 0, as row 3, with vcore_max_mv.
- Revert: on FAIL, Step 5; on PASS, row 4.

### Row 4

- SET cpu.ac_ll = 0.70 mOhm  # src: intel-14-pl,intel-ll
- Record: the AC loadline and DC loadline values the screen shows now; the DC loadline still shows its stock reading.
- Run: Save & Exit > Save & Exit Setup, Yes, then boot to Linux and run the gate:

```bash
bench/stability.sh cpu 10
```

- Record: the six keys of row 0, as row 4, with vcore_max_mv.
- Revert: on FAIL, Step 5; on PASS, row 5.

### Row 5, the floor

- SET cpu.ac_ll = 0.60 mOhm  # src: intel-14-pl,intel-ll
- Record: the AC loadline and DC loadline values the screen shows now; the DC loadline still shows its stock reading.
- Run: Save & Exit > Save & Exit Setup, Yes, then boot to Linux and run the gate:

```bash
bench/stability.sh cpu 10
```

- Record: the six keys of row 0, as row 5, with vcore_max_mv.
- Revert: on FAIL, Step 5; on PASS, the floor is the final value and Step 6 is next.

## Step 5: Failure and the margin step

- Run: after a freeze or a reboot, the journal scan in Linux, from the time the gate printed after "window starts":

```bash
since='the time the gate printed after "window starts"'
bench/stability.sh scan "$since"
```

- Record: result.stability.journal and result.stability.first_error, in the FAIL row.
- Revert cpu.ac_ll to the last PASS value plus one step: that one step is the margin, and the value is never above the stock reading from Step 2. The table has the final value for each FAIL row:

```text
first FAIL   last PASS   final value, mOhm
row 1        stock       stock
row 2        1.00        stock
row 3        0.90        1.00
row 4        0.80        0.90
row 5        0.70        0.80
```

- Run: Save & Exit > Save & Exit Setup, Yes, then boot to Linux and run the gate once at the final value:

```bash
bench/stability.sh cpu 10
```

- Record: the six keys of row 0, as the final row, with vcore_max_mv.
- Report: the final value; when this gate is not all PASS, Step 7 and report it.

## Step 6: Compile and game check on the final value

- Run: in Linux, from the repo, the compile run and the game hook:

```bash
since="$(date '+%Y-%m-%d %H:%M:%S')"
bench/compile.sh 1
bench/game.sh setup
```

- Run: one Cyberpunk 2077 benchmark from its Settings > Graphics > Run Benchmark, then the scan in the same shell:

```bash
bench/stability.sh scan "$since"
```

- Record: the result.compile lines, the game run, and result.stability.journal.
- Revert cpu.ac_ll to the final value plus one step, never above the stock reading from Step 2, on any error here; then the Step 5 gate and this check again.
- Report: the final value after this check.

## Step 7: Roll back to stock

- Revert cpu.ac_ll and cpu.dc_ll to the stock readings from Step 2, then Save & Exit > Save & Exit Setup.
- Revert: or the whole Step 1 profile, from this menu (gb-bios700 p29):

```text
Save & Exit > Load Profiles > Setup Profile N
```

- Report: the AC loadline and DC loadline values the screen shows after the reboot.

## Recovery: clear CMOS

- Note: for a machine that does not boot after a row; that row counts as FAIL in Step 5.
- Short the CLR_CMOS jumper for a few seconds with the power cord out, then boot to BIOS with Del (gb-bios700 p2, p3).
- Run: these two items in BIOS, in order (gb-bios700 p29):

```text
Save & Exit > Load Optimized Defaults
Save & Exit > Load Profiles > Setup Profile N
```

- Revert: Setup Profile N is the profile from Step 1.
- Report: whether the machine boots, and the AC loadline value the screen shows.

## Reading

- Record: bios/readings/YYYY-MM-DD-undervolt.md, from bios/readings/TEMPLATE.md, with one row per step: row, cpu.ac_ll, DC loadline, ycruncher, stressng, journal, vcore_max_mv, pkg_w_avg, mhz_avg.
- Record: the on-screen paths from Step 2 in its Settings as seen table.
