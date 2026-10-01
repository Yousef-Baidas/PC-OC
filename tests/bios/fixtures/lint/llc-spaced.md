# Fixture: clean runbook

1. Save the current profile to Setup Profile 1 in Save & Exit > Save Profiles.

## Steps

- SET cpu.pl1 = 219 W  # src: intel-14-pl,gb-bios700
- SET cpu.pl2 = 219 W  # src: intel-14-pl,gb-bios700
- SET cpu.ac_ll = 0.50 mOhm  # src: intel-ll,gb-bios700
- SET cpu.ac_ll = 0.40 mOhm  # src: intel-ll,gb-bios700
```text
Load Line Calibration: High
```
- SET mem.vdd = 1.35 V  # src: ddr5-vdd
- SET mem.vddq = 1.35 V  # src: ddr5-vdd

## Recovery: clear CMOS

Short the CLR_CMOS jumper, then revert to Setup Profile 1.
