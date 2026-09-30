# os craft: governor, EPP, sched_ext, units, sudoers, toolchain

A senior Linux systems engineer tunes this desktop in three steps. First, find out who else already writes each knob (power-profiles-daemon, game-performance, gamemode, ananicy-cpp, scx_loader). Then pick one writer per knob. Then make every write reversible. Most of the "tuning" bugs on CachyOS come from two daemons fighting over one sysfs file.

## Sources

| id | Document | URL | Revision |
|---|---|---|---|
| k-pstate | intel_pstate CPU Performance Scaling Driver | https://docs.kernel.org/admin-guide/pm/intel_pstate.html | kernel 7.3.0-rc5 docs |
| k-pstate-src | `drivers/cpufreq/intel_pstate.c` | https://raw.githubusercontent.com/torvalds/linux/master/drivers/cpufreq/intel_pstate.c | master, 2026-09-30 |
| k-cpufreq | CPU Performance Scaling | https://docs.kernel.org/admin-guide/pm/cpufreq.html | 7.3.0-rc5 |
| k-scx | Extensible Scheduler Class | https://docs.kernel.org/scheduler/sched-ext.html | 7.3.0-rc5 |
| scx-lavd | scx_lavd README | https://github.com/sched-ext/scx/blob/main/scheds/rust/scx_lavd/README.md | scx HEAD bcf2edc6ba |
| scx-bpfland | scx_bpfland README | https://github.com/sched-ext/scx/blob/main/scheds/rust/scx_bpfland/README.md | same |
| scx-loader | scx-loader README | https://github.com/sched-ext/scx-loader | HEAD 2026-09-23 |
| scx-services | scx services README (legacy `scx.service`) | https://github.com/sched-ext/scx/blob/main/services/README.md | scx HEAD |
| cachy-scx | CachyOS wiki: sched-ext | https://wiki.cachyos.org/configuration/sched-ext/ | updated 2026-09-07 |
| cachy-gaming | CachyOS wiki: Gaming | https://wiki.cachyos.org/configuration/gaming/ | updated 2026-07-26 |
| aw-cpufreq | ArchWiki: CPU frequency scaling | https://wiki.archlinux.org/title/CPU_frequency_scaling | edited 2026-09-22 |
| aw-gaming | ArchWiki: Gaming | https://wiki.archlinux.org/title/Gaming | edited 2026-09-07 |
| aw-sudo | ArchWiki: Sudo | https://wiki.archlinux.org/title/Sudo | edited 2026-05-22 |
| sudoers5 | sudoers(5), Sudo 1.9.17p2 | https://man.archlinux.org/man/sudoers.5 | 1.9.17p2 |
| visudo8 | visudo(8) | https://man.archlinux.org/man/visudo.8 | 1.9.17p2 |
| sd-service | systemd.service(5), systemd 262 | https://man.archlinux.org/man/systemd.service.5 | 262 |
| sd-exec | systemd.exec(5), systemd 262 | https://man.archlinux.org/man/systemd.exec.5 | 262 |
| sd-analyze | systemd-analyze(1), systemd 262 | https://man.archlinux.org/man/systemd-analyze.1 | 262 |
| gamemode | FeralInteractive/gamemode README | https://github.com/FeralInteractive/gamemode | 1.8.2, README 2026-04-17 |
| mold | rui314/mold README | https://github.com/rui314/mold | v2.42.1, README 2026-09-18 |
| sccache | mozilla/sccache README and docs/Local.md | https://github.com/mozilla/sccache, https://github.com/mozilla/sccache/blob/main/docs/Local.md | v0.18.0 |

## This machine (live probe, 2026-09-30)

- `intel_pstate/status` = `active`, `policy0/scaling_governor` = `powersave`, `energy_performance_preference` = `performance`.
- `energy_performance_available_preferences` = `default performance balance_performance balance_power power`. `no_turbo` = `0`.
- `vm.max_map_count` = `1048576`.
- `power-profiles-daemon`, `ananicy-cpp` and `scx_loader` are active, and `powerprofilesctl get` = `performance`. `/sys/kernel/sched_ext/state` = `disabled`, so no scx scheduler is loaded.
- `gamemode` is installed.
- Stock is whatever `probe.sh` records. These lines only show that other writers already hold the EPP knob.

## intel_pstate and EPP

- In active mode with HWP (the default on this CPU) there are two algorithms, `powersave` and `performance` (k-pstate). HWP "cannot be disabled" after init (k-pstate).
- With `performance`, the driver "will write 0 to the processor's Energy-Performance Preference (EPP) knob", and "any attempts to change the EPP/EPB to a value different from 0 ("performance") via sysfs in this configuration will be rejected" (k-pstate). With `powersave` + HWP, EPP is what sysfs or firmware last set (k-pstate). So the tunable pair is `powersave` plus an EPP value. `performance` pins EPP at 0.
- `energy_performance_preference` is per policy under `/sys/devices/system/cpu/cpufreq/policyX/` (k-pstate, k-cpufreq). It accepts an integer "between 0 to 255" (k-pstate), where 0 favors performance and 255 favors power (aw-cpufreq). The strings map in source as `0 default / 1 performance / 2 balance_performance / 3 balance_power / 4 power` (k-pstate-src).
- Global files are in `/sys/devices/system/cpu/intel_pstate/`. `no_turbo` = 1 forbids turbo. `max_perf_pct` / `min_perf_pct` are the "Maximum/Minimum P-state the driver is allowed to set in percent of the maximum supported performance level" (k-pstate).
- Changing `status` resets "all of its settings (the global as well as the per-policy ones) … to their default values" (k-pstate). Never switch modes in apply. If something else switches them, the boot unit must reapply afterwards.
- Other writers: CachyOS `game-performance` "uses power-profiles-daemon to temporarily switch the power profile to performance", and "On Intel, the governor stays at powersave, but the EPP/EPB values are adjusted for performance" (cachy-gaming). gamemode changes the "CPU governor" among other things (gamemode). os picks one owner of EPP per profile and documents the others as disabled or deferred. Apply fails loudly if its read-back is overwritten.

## sched_ext and the gaming scheduler

- State lives at `/sys/kernel/sched_ext/state` (`enabled`/`disabled`), and the loaded scheduler at `/sys/kernel/sched_ext/root/ops`. Any error "aborts the BPF scheduler and reverts all tasks back to the fair-class scheduler" (k-scx). Probe both files, and treat a silent fallback as red.
- Choice for gaming: **scx_lavd**. It "is initially motivated by gaming workloads. It aims to improve interactivity and reduce stuttering while playing games on Linux" (scx-lavd). It "creates a separate scheduling domain per-LLC, per-core type (e.g., P or E core on Intel…)" (scx-lavd), which fits the 8P+12E i7-14700.
- CachyOS lists LAVD's Gaming & Low Latency mode as `--performance`: "Maximizes performance by using all available cores, prioritizing physical cores". `--autopower` follows EPP (cachy-scx).
- Alternative for gaming with a compile running: scx_bpfland targets "Interactive workloads, such as gaming … especially when these workloads are running alongside CPU-intensive background tasks" (scx-bpfland). bench decides between lavd and bpfland by A/B test. This craft only sets the default candidate.
- Loader: current mechanism is `scx_loader`. Config goes in `/etc/scx_loader/config.toml` (then `/etc/scx_loader.toml`, then the vendor dir) with `default_sched` and `default_mode`, and `scxctl` controls it (scx-loader). CachyOS: copy `/usr/share/scx_loader/config.toml` to `/etc/scx_loader/config.toml`, and "Do not attempt to run the scx_loader.service alongside the scx.service" (cachy-scx). `/etc/default/scx` with `SCX_SCHEDULER` is the legacy `scx.service` path (scx-services). Do not use it.
- Revert means removing the `/etc/scx_loader/config.toml` the repo wrote, via backup-then-write restore, then restarting the loader. Probe must then show the stock `state`.

## gamemode, ananicy-cpp

- CachyOS warns: "Do Not Combine gamemode and ananicy-cpp" (cachy-gaming). Both are present here; a ticket that enables gamemode must say which one is disabled.
- gamemode reads `gamemode.ini` from `$PWD`, `$XDG_CONFIG_HOME` or `~/.config/` (where "[gpu] settings take no effect"), `/etc/`, `/usr/share/gamemode/` (gamemode). A repo-managed config goes in `/etc/` through the helper.

## sysctl

- `vm.max_map_count`: "Arch Linux uses the value 1048576 by default … A value of 2147483642 (MAX_INT - 5) is the default in SteamOS" (aw-gaming). The live value already equals the Arch default, so no change is needed without a benchmarked reason.

## systemd units

- `Type=oneshot`: "the service manager will consider the unit up after the main process exits". Without `RemainAfterExit=` it "will never enter "active" unit state" (sd-service). Reapply units use `Type=oneshot` + `RemainAfterExit=yes`, so revert can be `ExecStop=`.
- `ProtectSystem=strict` mounts everything read-only "except for the API file system subtrees /dev/, /proc/ and /sys/" (sd-exec). It is safe for a `/sys` writer. Add `ReadWritePaths=` for any `/etc` target and the backup dir.
- `ProtectKernelTunables=true` makes "kernel variables accessible through /proc/sys/, /sys/ … read-only" (sd-exec). Never set it on a unit that writes them.
- Gate: `systemd-analyze verify FILE…` "will load unit files and print warnings if any errors are detected" (sd-analyze).

## sudoers

- Drop-ins in `/etc/sudoers.d/` are read in lexical order, "skipping file names that end in '~' or contain a '.' character" (sudoers5; also aw-sudo). The name `pc-oc` is valid. `pc-oc.conf` would be silently ignored.
- Check: `visudo -cf etc/sudoers.d/pc-oc`. "As of version 1.8.27, the sudoers path can be specified without using the -f option" (visudo8), so `-c <path>` and `-cf <path>` both work.
- The listed scripts live in a user-owned checkout. Anything that can write the repo can change what runs as root. security reviews every change to a listed script as a root change.

## Toolchain

- mold: "In our August 2026 benchmarks, it links 4.9x faster than LLVM lld and 1.9x faster than wild at the median" (mold). GCC 12.1.0+: `-fuse-ld=mold`. Cargo: `rustflags = ["-C", "link-arg=-fuse-ld=mold"]`. Anything else: `mold -run make` (mold).
- sccache: `RUSTC_WRAPPER=/path/to/sccache` or `[build] rustc-wrapper` (sccache). "The default cache size is 10 gigabytes. To change this, set `SCCACHE_CACHE_SIZE`", and the default location is `~/.cache/sccache` (sccache docs/Local.md).
- Both are new dependencies unless already installed. mold and sccache were not in the installed package list on 2026-09-30, so installing them needs human approval (CONVENTIONS "Forbidden").
