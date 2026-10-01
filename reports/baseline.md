# baseline

Date: 2026-10-01

Results dir: 2026-10-01-baseline

## Results

| key | value |
|---|---|
| result.compile.run1_s | 84.741 |
| result.compile.run2_s | 87.302 |
| result.compile.run3_s | 87.859 |
| result.compile.median_s | 87.302 |
| result.stability.ycruncher | PASS |
| result.stability.stressng | PASS |
| result.stability.journal | PASS |
| result.stability | PASS |
| result.game.run1.avg_fps | 106.2 |
| result.game.run1.low1_fps | 76.9 |
| result.game.run2.avg_fps | 104.1 |
| result.game.run2.low1_fps | 76.9 |
| result.game.run3.avg_fps | 103.5 |
| result.game.run3.low1_fps | 76.7 |
| result.game.avg_fps | 104.6 |
| result.game.low1_fps | 76.8 |

## Settings snapshot

| key | value |
|---|---|
| cpu.model | Intel(R) Core(TM) i7-14700 |
| cpu.microcode | 0x137 |
| cpu.pl1_uw | 65000000 |
| cpu.pl1_tau_us | 27983872 |
| cpu.pl2_uw | 219000000 |
| ram.total_kb | 32610596 |
| ram.dmi | needs-root |
| gpu.name | NVIDIA GeForce RTX 4060 Ti |
| gpu.driver | 615.71.09 |
| gpu.vbios | 95.06.2B.00.CC |
| gpu.pl_w | 160.00 |
| gpu.pl_default_w | 160.00 |
| gpu.pl_min_w | 100.00 |
| gpu.pl_max_w | 216.00 |
| gpu.clock_max_mhz | 3120 |
| gpu.mem_clock_max_mhz | 9001 |
| os.kernel | 7.2.8-1-cachyos |
| os.pstate_status | active |
| os.governor | powersave |
| os.epp | performance |
| os.governors_uniform | yes |
| os.scx_state | disabled |
| os.scx_ops | none |
| os.swappiness | 150 |
| os.thp | always |

## Inputs

```
source=/proc/cpuinfo,/sys/class/powercap/intel-rapl:0/constraint_0_name,/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw,/sys/class/powercap/intel-rapl:0/constraint_0_time_window_us,/sys/class/powercap/intel-rapl:0/constraint_1_name,/sys/class/powercap/intel-rapl:0/constraint_1_power_limit_uw,/sys/class/powercap/intel-rapl:0/constraint_2_name bytes=48840 items=5
source=/proc/meminfo bytes=1671 items=2
source=/usr/bin/nvidia-smi bytes=98 items=9
source=/proc/sys/kernel/osrelease,/sys/devices/system/cpu/intel_pstate/status,/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu10/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu10/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu11/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu11/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu12/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu12/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu13/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu13/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu14/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu14/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu15/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu15/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu16/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu16/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu17/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu17/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu18/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu18/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu19/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu19/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu1/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu1/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu20/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu20/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu21/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu21/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu22/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu22/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu23/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu23/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu24/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu24/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu25/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu25/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu26/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu26/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu27/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu27/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu2/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu2/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu3/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu3/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu4/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu4/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu5/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu5/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu6/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu6/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu7/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu7/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu8/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu8/cpufreq/energy_performance_preference,/sys/devices/system/cpu/cpu9/cpufreq/scaling_governor,/sys/devices/system/cpu/cpu9/cpufreq/energy_performance_preference,/sys/kernel/sched_ext/state,/proc/sys/vm/swappiness,/sys/kernel/mm/transparent_hugepage/enabled bytes=675 items=9
input.source=/home/tuff/.cache/pc-oc/linux-6.18.54.tar.xz bytes=154801608 items=97287
input.kernel_version=6.18.54
input.sha256=9df30b02dd8102bbd0be52556288ef6889ddbe7f1ddb96fbf847d0becf3eacac
input.gcc=gcc (GCC) 16.2.1 20260810
input.make=GNU Make 4.4.1
input.nproc=28
input.runs=3
input.source=/usr/bin/journalctl bytes=41152 items=391
input.journalctl=systemd 262 (262-1-arch)
input.since=2026-10-01 04:09:49
input.ycruncher=y-cruncher v0.8.7 Build 9547-gcc
input.stressng=stress-ng, version 0.22.01 (gcc 16.2.1, x86_64 Linux 7.2.8-1-cachyos)
input.minutes=10
input.ycruncher_args=skip-warnings colors:0 pause:-2 stress -TL:600
input.stressng_args=--cpu 0 --cpu-method all --vm 4 --vm-bytes 80% --verify -t 600s
input.source=/home/tuff/PC-OC-proteus/24/results/2026-10-01-baseline/Cyberpunk2077_2026-10-01_03-33-01.csv,/home/tuff/PC-OC-proteus/24/results/2026-10-01-baseline/Cyberpunk2077_2026-10-01_03-36-00.csv,/home/tuff/PC-OC-proteus/24/results/2026-10-01-baseline/Cyberpunk2077_2026-10-01_03-37-39.csv bytes=1633655 items=21676
input.skipped=/home/tuff/PC-OC-proteus/24/results/2026-10-01-baseline/Cyberpunk2077_2026-10-01_03-33-01_summary.csv,/home/tuff/PC-OC-proteus/24/results/2026-10-01-baseline/Cyberpunk2077_2026-10-01_03-36-00_summary.csv,/home/tuff/PC-OC-proteus/24/results/2026-10-01-baseline/Cyberpunk2077_2026-10-01_03-37-39_summary.csv
input.mangohud=0.8.4-1+
input.files=3
input.low1_definition=MangoHud: frametime at index 0.01*n-1 of frametimes sorted slowest first, as fps
```
