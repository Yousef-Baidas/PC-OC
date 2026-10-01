# Runbook: PL1, PL2, Tau, AC_LL and DDR5 voltage

## Step 1: Save the current profile

1. Save the current profile to Setup Profile 1 in Save & Exit > Save Profiles.
- Report the slot number and the BIOS version in System Info.

## Step 2: PL1, PL2 and Tau

- SET cpu.pl1 = 125 W  # src: intel-14-pl
- SET cpu.pl2 = 219 W  # src: intel-14-pl
- SET cpu.tau = 56 s  # src: intel-14-pl
- Report: the PL1, PL2 and Tau the screen shows, in watts and seconds.
- Revert cpu.pl1 to 65 W and cpu.pl2 to 219 W (stock, intel-14-pl).

## Step 3: AC_LL, two steps down

- SET cpu.ac_ll = 0.90 mOhm  # src: intel-14-pl
- Report: the AC_LL the screen shows.
- SET cpu.ac_ll = 0.80 mOhm  # src: intel-14-pl
- Report: the AC_LL the screen shows, and cpu.vcore_mv from Linux.
- Revert cpu.ac_ll to 1.1 mOhm (stock, intel-14-pl Table 77 p191).

## Step 4: DDR5 VDD and VDDQ

- SET mem.vdd = 1.35 V  # src: ddr5-vdd
- SET mem.vddq = 1.35 V  # src: ddr5-vdd
- Read the DDR5 Voltage Control values on screen.
- Revert mem.vdd and mem.vddq to 1.10 V (stock, ddr5-vdd).

## Step 5: Gate

- Run the stability gate:

```bash
pc-oc probe cpu
pc-oc probe ram
```

- Record result.stability.vcore_max_mv and the gate result.

## Recovery: clear CMOS

- Short the CLR_CMOS jumper for a few seconds with AC power unplugged.
- Revert to Setup Profile 1 from Step 1, in this menu:

```text
Save & Exit > Load Profiles > Setup Profile 1
```
