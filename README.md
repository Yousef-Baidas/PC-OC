# PC-OC: the final pass

This page is the whole pass, in order: install the scripts, three BIOS runbooks, the GPU search, the benchmark, the report. You follow it alone at the PC. Do the sections in their order. Do not skip one.

It is written for this PC only: i7-14700, Z790 GAMING X AX, RTX 4060 Ti, CachyOS.

## 1. Before you start

### What the pass changes

- In the BIOS: the two CPU package power limits ([bios/power-limits.md](bios/power-limits.md)).
- In the BIOS: the AC loadline, which lowers the CPU voltage ([bios/undervolt.md](bios/undervolt.md)).
- In the BIOS: the RAM frequency and timings, with the DRAM rail that runbook names ([bios/ram.md](bios/ram.md)).
- On the graphics card: the power limit, and the two clock offsets the search finds. A boot unit, `pc-oc-gpu.service`, sets them again at every boot ([gpu/offsets.md](gpu/offsets.md)).
- In your home directory, last of all: three config files get a block that sends compiles through sccache and mold (section 9).

### What the pass never changes

- No CPU core voltage increase, no ratio or BCLK change. This is the rule in `CONVENTIONS.md`.
- If a step ever seems to ask for one of these, stop and report it.
- The pass does not change the CPU scheduler. No command of this page applies the `os` component.

### The one rule for the whole pass

Do not update the system (pacman -Syu, yay) between the baseline and the final report.

The report compares this pass with the baseline of 2026-10-01. It checks that six things are the same in both runs: the CPU model, the CPU microcode, the GPU name, the GPU driver, the GPU VBIOS and the kernel. An update changes the kernel or the driver, and then the two runs cannot be compared (section 8). Do not flash a new BIOS either: it can bring a new CPU microcode. Installing one package that a script asks for is not an update.

### How to type the commands

- Open a terminal and go to the checkout first: `cd /home/tuff/PC-OC`. Every command of this page is typed there.
- A command that starts with `./pc-oc` runs as you, without sudo.
- A command that starts with `sudo /usr/local/lib/pc-oc/pc-oc` runs the installed copy as root.
- The name alone, without a path, is not a command on this PC: the shell does not find it. Where a runbook or a message on the screen writes sudo, then the name, then two more words, type `sudo /usr/local/lib/pc-oc/pc-oc` and then the same two words.
- Type each command as it stands. Do not add a pipe. Do not put sudo before a command that has none here.
- Where a command holds a name in angle brackets, such as `<date>`, put the real value there and leave the brackets out.
- Your shell is fish. To see the exit status of the last command, type `echo $status` as the very next command. 0 means it worked.
- This page has its own step names, such as 6d. A step with a file name before it, such as "gpu/offsets.md step 9", is a step of that runbook.

### Time

These times are estimates. They come from the lengths of the loads in the scripts and from the number of steps in the runbooks. Nobody has timed the pass.

| Section | What | Time |
|---|---|---|
| 2 | Install the reviewed scripts | 5 minutes |
| 3 | BIOS power limits | about 1 hour |
| 4 | Undervolt | 2 to 4 hours |
| 5 | RAM | 3 to 12 hours |
| 6 | GPU clocks | about 2 hours |
| 7 | Benchmark the tuned state | about 1 hour |
| 8 | Report | 5 minutes |
| 9 | Toolchain wiring | 5 minutes |
| 10 | What to send back | 15 minutes |
| 11 | Undo everything | only when needed, about 30 minutes |

You do not have to do it all in one day. Stop only at the end of a section. The BIOS keeps its settings, and the boot unit sets the GPU values again at every boot. The no-update rule holds for the days in between as well.

### Have ready

- The baseline directory `results/2026-10-01-baseline`. It is in the checkout. Section 8 compares against it.
- Cyberpunk 2077 installed in Steam, with the graphics settings it had at the baseline. Do not change them during the pass.
- `memtest_vulkan` installed: `ls /usr/bin/memtest_vulkan` prints that path. If it is missing, gpu/offsets.md step 1 has the command.
- A USB stick. The RAM runbook saves a BIOS profile file on it.
- This page on a phone. You need it while the PC is in the BIOS or under load, and the phone takes the photos of the BIOS screens.
- Your sudo password.
- A network connection. 6a and section 7 download their sources when they are not on the disk yet.
- Something to write on: slot numbers, values read in the BIOS, and the time of every crash or freeze.
- A folder for what you send back. Make it now: `mkdir -p ~/pc-oc-send`.

### What you are the first to see

No agent has run these on this PC. You see them first:

- the real `systemctl` calls, and real `sudo` with the installed rules,
- the graphics card at its raised power limit, and the search with real loads,
- `bench/compile.sh`,
- every BIOS step.

So this page can be wrong in a detail. If something looks different from what is written here, stop, write down what you saw, and report it. Do not work around it.

### If the PC crashes or freezes

- Write down the time and what was on the screen, right away. The kernel log of this PC keeps only a few hours, so the time on paper may be all there is.
- When Linux is up again, run `bench/stability.sh scan "<time>"` with a time a little before the crash, written like `2026-10-01 14:05:00`. Send its lines.
- Then do what the runbook of that section says for a FAIL.

## 2. Install the reviewed scripts

The copy in `/usr/local/lib/pc-oc` is from an older state of the repo. This section replaces it.

- Time: 5 minutes.
- Do: 2a. Go to the checkout: `cd /home/tuff/PC-OC`.
- Do: 2b. Get the reviewed state: `git pull --ff-only`.
- See: `Already up to date.` or a list of changed files, and no line that starts with `fatal:`. If files changed, load this page again: it may be one of them.
- Do: 2c. Install: `sudo os/install.sh`. sudo asks for your password.
- See: one line, `pc-oc: os: installed <commit> to /usr/local/lib/pc-oc`.
- Do: 2d. Read the installed version, then the version of the checkout: `cat /usr/local/lib/pc-oc/VERSION`, then `git rev-parse HEAD`.
- See: the same 40 characters twice. The first of the two lines must not end in `-dirty`.
- If it fails: stop here. Nothing else of the pass works on an old copy. What to send is in step 3 of [bios/power-limits.md](bios/power-limits.md): both lines of 2d and the output of `git status --porcelain`.
  - `git pull --ff-only` prints `fatal:`: do not merge or reset by hand. Send the output.
  - `sudo os/install.sh` prints another line that starts with `pc-oc: os:`: send that line.

## 3. BIOS power limits

- Time: about 1 hour. The gate of step 8 alone runs about 20 minutes.
- Do: follow [bios/power-limits.md](bios/power-limits.md), steps 1 to 12, in their order. The values and the BIOS path are in its part "Limits".
  - Its steps 2 and 3 are section 2 of this page. If 2d matched a moment ago, step 2 matches too and step 3 is skipped.
  - Step 8: start `watch -n 5 sensors` in a second terminal first. The gate, `bench/stability.sh cpu 10`, prints its result lines only at its end.
  - Step 12: the reading is a new file in `bios/readings/`, made from `bios/readings/TEMPLATE.md`.
- See: in step 7 the probe prints the `cpu.pl1_uw` and `cpu.pl2_uw` lines with the values the runbook gives. In step 8 the last line of the gate is `result.stability=PASS`.
- If it fails: the PC does not start after step 6: [CMOS clear recovery](bios/power-limits.md#cmos-clear-recovery).
- If it fails: step 7 or step 8 does not pass: [Roll back](bios/power-limits.md#roll-back), which is step 11. Then do step 12 all the same, stop the pass and report. Do not go on to section 4.
- If it fails: the thermal rule stops you in step 10: that step of [bios/power-limits.md](bios/power-limits.md) says what to set before the gate runs again. Step 11 is the roll back after a thermal stop, when you do not go on.

## 4. Undervolt

- Time: 2 to 4 hours. Each gate runs about 20 minutes. There are up to seven of them, and more when one has to run again.
- Do: follow [bios/undervolt.md](bios/undervolt.md) from "Before you start" to the end of Step 6, then fill in its part "Reading".
  - Run `sudo modprobe msr` before every gate, after every boot. Without it the gate cannot read the voltage, and the runbook does not count that row.
  - Step 4 is a loop: one row, one boot, one gate. A FAIL in the loop is not a fault. It ends the loop, and Step 5 says which value is the final one.
  - Write down the time the gate prints after "window starts" as soon as it prints. After a freeze you need it for the scan of Step 5.
  - Step 6 runs `bench/compile.sh 1` and `bench/game.sh setup`, then one Cyberpunk 2077 benchmark. Section 9 must not be done before it.
  - An error in Step 6 is not a fault either, as long as the value is not back at stock. The table of Step 6 gives the next value; then the gate of Step 5 and the check of Step 6 run again.
- See: the gate at the final value ends with `result.stability=PASS`. That is the gate of row 5 when every row passed, and the gate of Step 5 after a FAIL. In Step 6 the compile prints `result.compile.` lines and the scan prints `result.stability.journal=PASS`.
- If it fails: the PC does not boot after a row: [Recovery: clear CMOS](bios/undervolt.md#recovery-clear-cmos). That row counts as FAIL, and Step 5 goes on from there.
- If it fails: the stock gate of Step 2 does not pass: stop there and report, as Step 2 of [bios/undervolt.md](bios/undervolt.md) says.
- If it fails: the gate of Step 5 at the final value does not pass, or Step 6 shows an error with the value already at stock: [Step 7: Roll back to stock](bios/undervolt.md#step-7-roll-back-to-stock). Then stop the pass and report. Do not go on to section 5.

## 5. RAM

- Time: 3 to 12 hours. Up to 18 steps with one gate of about 20 minutes each, some gates twice, and one soak of about 2 hours at the end.
- Do: follow [bios/ram.md](bios/ram.md) from "Prerequisite" to the end of "Final soak", which is step 21, then fill in its part "Reading".
  - Put the USB stick in before step 1: that step saves the profile to a slot and to the stick.
  - Steps 3 to 20 are each one BIOS visit, one boot and one gate, `bench/stability.sh cpu 10`.
  - A FAIL or a PC that does not start is a normal end of a step. The line "Revert on FAIL or no POST" of that step says what to set and which step is next.
  - Step 21 is `bench/stability.sh soak 60`. On PASS, save the final slot as the step says. On FAIL, its line "Revert on FAIL" says what to set before the soak runs again.
- See: step 21 ends with `result.stability=PASS`, and the final slot is saved. The reading is a new file in `bios/readings/`.
- If it fails: the PC does not start: [No-POST recovery and CMOS clear](bios/ram.md#no-post-recovery-and-cmos-clear), then the Revert line of the step that failed.
- If it fails: to give the RAM part up: [Rollback to the kit profile](bios/ram.md#rollback-to-the-kit-profile). The pass then goes on with the kit profile. Say so in your notes.

## 6. GPU clocks

The runbook is [gpu/offsets.md](gpu/offsets.md). The commands below are its commands, in its order. The runbook writes the short name of the installed script; here every command is spelled out.

Before 6a: close every game and every program that uses the graphics card, a browser that plays video too. Save your work. The card drives the screen, so the screen can freeze when a step of the search fails.

- Time: about 2 hours. The search alone takes up to about 70 minutes.
- Do: 6a. Build the core load, as yourself, without sudo: `gpu/burn-build.sh`. This is gpu/offsets.md step 2.
- See: build output, and as the last line a directory under `~/.cache/pc-oc/gpu-burn/`. A line that starts with `pc-oc: gpu: burn-build:` names what went wrong.
- Do: 6b. Check that both loads are ready: `gpu/load.sh check`, then `echo $status`.
- See: the check prints nothing and the status is 0. A line that starts with `pc-oc: gpu: load:` names what is missing; fix that, then 6b again.
- Do: 6c. Set the power limit: `sudo /usr/local/lib/pc-oc/pc-oc apply gpu`. Run it in a plain terminal. Do not pipe it into another program. This is gpu/offsets.md step 4.
- See: one line, `gpu: offsets core=<n> mem=<m> from gpu/values`. If the line ends in `from search result`, a search has finished before and its result is set now. If that was your own search of this pass, go on at 6g. If not, stop and report.
- Do: 6d. Run the search: `sudo /usr/local/lib/pc-oc/pc-oc search gpu`. This is gpu/offsets.md step 6.
  - sudo asks for your password. This command has no rule that lets it run without one, on purpose.
  - Run it in a plain terminal and keep that window open. Do not pipe it into another program, so no `| tee` and no `| less`. With a pipe that closes, the search starts no further load, sets the offsets back to 0 and ends with status 1.
  - Do not press Ctrl+S and do not press Ctrl+Z while it runs. The first freezes the output, the second suspends the search in the middle of a step.
  - Ctrl+C is the way to stop it: the load stops and the offsets go back to 0. The same command goes on later, but the step that was running counts as failed. So stop it only when you must.
  - It needs no input. It prints one line per step: `phase=<p> core=<n> mem=<m> result=<r> reason=<word>`.
- See: at the end the three lines of the result, `core_offset_mhz=<n>`, `mem_offset_mhz=<m>` and `finished=<time>`, then the line `pc-oc: gpu: search: finished. These offsets are not applied yet: gpu/offsets.md says how. The log is /var/lib/pc-oc/gpu/search/log`. A value of 0 means no offset of that clock passed.
  - A step line may end in ` clock=unchecked`. The core load ran at the power limit of the card, so the search could not check the core clock against the offset of that step.
  - A memory line may end in ` core_clock_delta=<n>`.
  - At the end there may be a line that holds `gpu: search: the core load ran at the power limit, so the core clock was not checked against the offset`, and one that holds `gpu: search: core offset <n> MHz moved the core clock by <d> MHz under the memory load`.
  - These are not errors. The first line says that the core load never showed the core at its top clock with the offset. The second says how far the offset moved the core clock while the memory load ran. The Cyberpunk benchmark of 6h is then the only check of the core offset at top clock under a real game load. Do not skip 6h.
- Do: 6e. Copy the log and the result now: `cp /var/lib/pc-oc/gpu/search/log /var/lib/pc-oc/gpu/search/result ~/pc-oc-send/`.
- See: `ls ~/pc-oc-send` shows `log` and `result`. If cp says `Permission denied`, type the same command with sudo in front, and report that it was needed.
- Do: 6f. Apply the result: `sudo /usr/local/lib/pc-oc/pc-oc apply gpu`. Plain terminal, no pipe, as in 6c. This is gpu/offsets.md step 12.
- See: one line, `gpu: offsets core=<n> mem=<m> from search result`, with the two numbers of the result.
- Do: 6g. Check: `./pc-oc probe gpu`. This is gpu/offsets.md step 13.
- See: among its lines `gpu.offsets_source=search` and `gpu.boot_unit=enabled`.
- Do: 6h. The Cyberpunk check. Type `date '+%Y-%m-%d %H:%M:%S'` and write the time down. Start Cyberpunk 2077 and run its benchmark once: `Settings > Graphics > Run Benchmark`. Watch the whole run. Then type `bench/stability.sh scan "<time>"` with that time.
- See: the benchmark runs to its end with a clean picture: no crash, no freeze, no black screen, no flicker, no coloured dots or blocks. The scan prints `result.stability.journal=PASS`.

From the end of 6d on, a reboot sets the searched offsets by itself. The boot unit is enabled since 6c and runs the same apply at every boot, whether or not you did 6f. This is gpu/offsets.md step 14.

- If you reboot before 6h: the offsets are set after the boot. Do 6g to see it, then 6h.
- To reboot without them: `sudo /usr/local/lib/pc-oc/pc-oc revert gpu` before the reboot, then 6f when you are ready for 6h.

What to do when a step of this section fails:

- If it fails: the search ends with another line that starts with `pc-oc: gpu: search:`, or the screen freezes: [gpu/offsets.md, Search](gpu/offsets.md#search), steps 7 to 10.
  - The line ends in `Run sudo pc-oc search gpu again to go on; reboot first if the screen froze or an Xid was logged.`: do 6d again. Reboot first when the line names an Xid.
  - The screen froze: reboot, with the power button held if nothing else answers. Log in, then 6d again. The step that froze counts as failed, and the search goes on below it.
  - The line holds `ZERO FAILED` in capitals: an offset may still be set. Run `sudo reboot`.
  - The line says `apply the power limit first`: do 6c, then 6d.
  - The line says `offsets are set by something else`: the result of an earlier search is set on the card. See 6c.
  - The line says `nothing was set`, or names the unit of the memory offset, or says to report before the search runs again: do not run the search again. Copy the log if there is one, `cp /var/lib/pc-oc/gpu/search/log ~/pc-oc-send/`, go on with section 7, and send the line.
- If it fails: 6h shows a crash, a freeze, a broken picture, or the scan prints `result.stability.journal=FAIL`: the searched offsets do not hold in the game. Take them off the card as below; it is the card part of [section 11](#11-undo-everything). There is no "one step lower": the pass does not try smaller offsets and does not search again.
  - Run `sudo /usr/local/lib/pc-oc/pc-oc revert gpu`. The card is at stock then, and the boot unit is disabled.
  - Run `sudo rm -r /var/lib/pc-oc/gpu/search`. The log and the result are in `~/pc-oc-send` since 6e.
  - Write down the time and what you saw. Then go on with section 7, with the card at stock, and say so when you send the results.
- If it fails: the desktop does not come up after a reboot: [gpu/offsets.md, Result](gpu/offsets.md#result), step 14, which starts with step 9.
  - At the boot menu, add `systemd.mask=pc-oc-gpu.service` to the kernel command line. That boot skips the unit.
  - In that boot run `sudo /usr/local/lib/pc-oc/pc-oc revert gpu`, do 6e if it is not done, then run `sudo rm -r /var/lib/pc-oc/gpu/search`.
  - Do not run the apply of 6c or 6f in that boot. The unit is masked there, and the apply would end with `cannot enable pc-oc-gpu.service`.
  - Reboot without the kernel option. Run the command of 6g and keep its output for section 10. Then go on with section 7, with the card as it is, and say so when you send the results.
- If it fails: 6c or 6f prints a line that starts with `pc-oc: gpu:`: send the whole line. When it says `search result /var/lib/pc-oc/gpu/search/result refused`, nothing was set: [gpu/offsets.md, Result](gpu/offsets.md#result), step 12.

Never start the search with only the `result` file removed. A progress file is left then, and the search writes the same result again without running a load. Before any new search, remove the whole directory: `sudo rm -r /var/lib/pc-oc/gpu/search`. That is gpu/offsets.md step 16.

## 7. Benchmark the tuned state

Do this section before section 9. `bench/compile.sh` refuses a wired build environment, so the wiring of section 9 comes last.

The label of this run is `applied`.

- Time: about 1 hour: three game runs, then 30 to 40 minutes for 7e.
- Do: 7a. Print the game setup: `bench/game.sh setup`.
- See: a line `input.log_dir=` with the log folder, a line of Steam launch options that starts with `MANGOHUD_CONFIGFILE=`, and the key `Shift_L+F2`. In Steam, the launch options of Cyberpunk 2077 must hold that line exactly as printed. They may still hold it from the baseline. The last line it prints is a parse command. Do not run it: 7e does the parse.
- Do: 7b. Look into the log folder: `ls ~/.local/share/pc-oc/mangohud/`.
- See: folders only, such as `baseline`. No file that ends in `.csv`, and no folder `applied`.
  - If `.csv` files are there, they are from an earlier run, such as Step 6 of the undervolt runbook. Move them away: `mkdir -p ~/.local/share/pc-oc/mangohud/earlier`, then `mv ~/.local/share/pc-oc/mangohud/*.csv ~/.local/share/pc-oc/mangohud/earlier/`.
  - If a folder `applied` is there from an earlier try, rename it: `mv ~/.local/share/pc-oc/mangohud/applied ~/.local/share/pc-oc/mangohud/applied-old`.
- Do: 7c. Record three runs. Start Cyberpunk 2077 from Steam and go to `Settings > Graphics > Run Benchmark`. Press left Shift and F2 together (`Shift_L+F2`) when the benchmark starts, and again when it ends. Do this three times. Then close the game.
- See: nothing on the screen: MangoHud draws nothing in this setup. 7d shows whether the logs were written.
- Do: 7d. Put the logs under the label: `mkdir -p ~/.local/share/pc-oc/mangohud/applied`, then `mv ~/.local/share/pc-oc/mangohud/*.csv ~/.local/share/pc-oc/mangohud/applied/`, then `ls ~/.local/share/pc-oc/mangohud/applied`.
- See: six files: three logs named `Cyberpunk2077_<date>_<time>.csv`, and beside each one a file that ends in `_summary.csv`. The move is needed because `bench/game.sh setup` names the folder without a label, and `bench/run.sh applied` reads the folder `applied` inside it.
- Do: 7e. Close every other program. Run `sudo modprobe msr`, so that the gate can read the CPU voltage. Then run `bench/run.sh applied`. Do not use the PC while it runs.
- See: first a quiet screen for some minutes: three kernel builds. Then the output of a gate of about 20 minutes; it starts with a line that holds `window starts`, which is not an error. The last line is `pc-oc: bench: wrote /home/tuff/PC-OC/results/<date>-applied`. Write that directory name down. Its date is the UTC date, which can differ from the local one by a day.
- If it fails: fish says there is no match for the `*.csv` of 7d, or 7d shows fewer than six files: a run was not logged. Check the launch options of 7a, then record the missing runs again as in 7c. To give the pass up instead: [section 11](#11-undo-everything).
- If it fails: a game run crashes, freezes or shows a broken picture: that is a failed Cyberpunk check. Do what [section 6](#6-gpu-clocks) says for a failed 6h, then start this section again at 7b.
- If it fails: 7e ends with another line that starts with `pc-oc: bench:`. The results directory is removed then. Fix the cause and run 7e again; [section 11](#11-undo-everything) is the way out when the PC is not stable.
  - `no MangoHud logs in`: the logs are not in the folder `applied`. Do 7d.
  - `wired build environment: <names>`: the names are the variables or the PATH entries in the way. Open a new terminal. If section 9 was done too early, run `./pc-oc revert toolchain`, open a new terminal, and run 7e again.
  - `refusing to overwrite`: a results directory of today with this label exists. A finished run is never overwritten. Use it, or rename it first.
  - The line ends in `failed`: one part did not pass. When the line names the stability script, the gate failed: run `bench/stability.sh cpu 10` by itself, send its result lines, stop the pass and report.

## 8. Report

- Time: 5 minutes.
- Do: 8a. Write the report: `bench/report.sh results/<date>-applied results/2026-10-01-baseline`. Put the real date in place of `<date>`: the name is in the last line of 7e, and `ls results` shows it.
- Do: 8b. As the very next command: `echo $status`.
- See: the line `pc-oc: bench: wrote /home/tuff/PC-OC/reports/applied.md`, and the status 0.
  - The report has a table "Results" with this run, the baseline and the difference. The game lines are `result.game.avg_fps` and `result.game.low1_fps`, the average and the 1% low. The compile line is `result.compile.median_s`.
  - Its table "Settings changed" lists every setting that differs. Keys the baseline did not record yet show n/a on the baseline side. That is expected.
  - Its part "Comparability" holds a line `Same on:` that names the six fixed things of section 1.
- See: status 3 means the report was written, but the two runs are not comparable. The command then prints `pc-oc: bench: fixed axis differs: <key>`, and the report holds a line `NOT COMPARABLE on <key>: <old> -> <new>` under "Comparability".
  - It means that the CPU model, the microcode, the GPU name, the driver, the VBIOS or the kernel is not the same as at the baseline. The differences in the report then do not measure the tuning alone.
  - Do not undo anything for this, and do not run the benchmark again. Send the report as it is and name the line.
- If it fails: any other status, with a line such as `missing game.txt`: the run of [section 7](#7-benchmark-the-tuned-state) is not complete, or the directory name is wrong. Check the name with `ls results`. Send the line if the name is right.

## 9. Toolchain wiring

This is the last change of the pass. Do it only after section 8.

- Time: 5 minutes.
- Do: 9a. Wire the three files, as yourself, never with sudo: `./pc-oc apply toolchain`.
- See: three lines that start with `toolchain: wired`, one each for `~/.cargo/config.toml`, `~/.config/fish/config.fish` and `~/.config/pacman/makepkg.conf`.
- Do: 9b. Check: `./pc-oc probe toolchain`.
- See: `toolchain.cargo=wired`, `toolchain.fish=wired` and `toolchain.makepkg=wired`. The lines `toolchain.sccache_bin` and `toolchain.mold_bin` each name a file in `/usr/bin`, not `missing`.
- If it fails: 9a prints a line that starts with `pc-oc: toolchain:`. It names the file and the reason. Send the line. To take the blocks out again: `./pc-oc revert toolchain`, as in [section 11](#11-undo-everything).

What the wiring does from now on:

- Cargo builds go through sccache.
- `cmake` typed in a new fish window goes through sccache and mold.
- Packages built by makepkg, so AUR builds with yay, go through sccache and mold.

To build one package without the wiring: `PC_OC_NO_WIRING=1 yay -S <pkg>`, with the package name in place of `<pkg>`. This opt-out is for package builds only.

Not tried on this PC: `yay` here is a guard script, `/usr/local/bin/yay`, that hands its arguments to the real yay. The variable should pass through it. If a build still uses the wiring with the variable set, report it.

## 10. What to send back

The files stay where they are. Name them in your report, and copy the ones outside the checkout to `~/pc-oc-send`.

- The report file: applied.md in `reports/`. Say which status 8b printed.
- The results directory of 7e, whole: `results/<date>-applied`.
- The readings: the three new files in `bios/readings/`, one per BIOS runbook. With them, everything a line marked "Report:" in [bios/power-limits.md](bios/power-limits.md), [bios/undervolt.md](bios/undervolt.md) and [bios/ram.md](bios/ram.md) asks for: slot numbers, the BIOS version, probe outputs, gate result lines, on-screen names. Photos of the BIOS screens help.
- The search `result` and `log`, both whole. They are in `/var/lib/pc-oc/gpu/search/`, and since 6e in `~/pc-oc-send`.
- Every line the search printed that is not a step line.
- The line of 6f and the whole output of 6g.
- What the part "What the first run measures" of [gpu/offsets.md](gpu/offsets.md) asks for in its line "Report:".
- The result of the Cyberpunk check of 6h: pass or fail, and what you saw.
- The output of 9a and 9b.
- The two lines of 2d.
- The time of every crash, freeze or reboot that you did not start yourself, with what was on the screen and the lines of the scan.
- Everything that looked different from this page.

Send the search log and the crash times soon. The kernel log of this PC keeps only a few hours, so nobody can look these things up later.

## 11. Undo everything

Each part can be undone by itself. To undo the whole pass, do all four parts.

1. The card, and the wiring too: `sudo /usr/local/lib/pc-oc/pc-oc revert all`, then `echo $status`.
   - It takes the wiring blocks out of your three files, sets both clock offsets to 0, restores the stock power limit and disables the boot unit.
   - See: three lines that start with `toolchain:`, and the status 0. `pc-oc: os: nothing to revert` and `pc-oc: gpu: nothing to revert` are fine: that part was not applied.
   - A line that starts with `pc-oc: all:` names the parts that did not revert. Send the whole output.
2. The wiring alone: `./pc-oc revert toolchain`, as yourself, without sudo.
   - See: per file `toolchain: unwired` with the path, or `toolchain: nothing to remove` when part 1 took the block out already.
3. The search result. Part 1 keeps it, so a later apply would set the searched offsets again. To remove it: do 6e if it is not done, then `sudo rm -r /var/lib/pc-oc/gpu/search`.
4. The BIOS. Load the saved profile, then save and exit.
   - For the whole pass: the slot named pre-power-limits, from step 1 of [bios/power-limits.md](bios/power-limits.md). It holds the BIOS as it was before the pass. How to load a slot: step 2 of [CMOS clear recovery](bios/power-limits.md#cmos-clear-recovery).
   - For the undervolt alone: [Step 7: Roll back to stock](bios/undervolt.md#step-7-roll-back-to-stock). It also names the menu line that loads a slot.
   - For the RAM alone: [Rollback to the kit profile](bios/ram.md#rollback-to-the-kit-profile).
   - For the power limits alone: [Roll back](bios/power-limits.md#roll-back).

When the PC does not start at all, clear the CMOS first. Each runbook has the section for it:

- [bios/power-limits.md, CMOS clear recovery](bios/power-limits.md#cmos-clear-recovery)
- [bios/undervolt.md, Recovery: clear CMOS](bios/undervolt.md#recovery-clear-cmos)
- [bios/ram.md, No-POST recovery and CMOS clear](bios/ram.md#no-post-recovery-and-cmos-clear)

After a CMOS clear, load the slot as above. If the slots are gone, the USB file of the RAM runbook is left. It holds the BIOS as it was before section 5, so the power limits and the undervolt are still in it.

Check the undo:

- `./pc-oc probe gpu` prints `gpu.boot_unit=disabled`, and each `gpu.offset_` line reads 0.
- `./pc-oc probe toolchain` prints `absent` for `toolchain.cargo`, `toolchain.fish` and `toolchain.makepkg`.
- `sudo /usr/local/lib/pc-oc/pc-oc probe cpu` prints the values of the stock record, step 4 of [bios/power-limits.md](bios/power-limits.md).

What stays after the undo: the installed scripts in `/usr/local/lib/pc-oc`, their sudo rules, the disabled boot unit, the built loads in `~/.cache/pc-oc`, and your results. None of them changes a setting by itself.
