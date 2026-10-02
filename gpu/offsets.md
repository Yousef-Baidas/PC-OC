# Runbook: GPU clock offsets

Why: `pc-oc search gpu` finds the highest core and memory clock offsets this card holds under load. It runs unattended, sets nothing for good and ends with every offset at 0. The two numbers it proves are written to a file; nothing is applied by the search.

Note: `pc-oc` below is the installed `/usr/local/lib/pc-oc/pc-oc`; type that path where your shell does not find `pc-oc`. Run every command from the root of this checkout.

## Before

1. Install the memory load: `sudo pacman -S memtest_vulkan`.
   - Revert: `sudo pacman -R memtest_vulkan`.
2. Build the core load as your own user, not as root: `gpu/burn-build.sh`.
   - Revert: remove `~/.cache/pc-oc/gpu-burn`.
3. Install the reviewed scripts: `sudo os/install.sh`.
   - Revert: none; the installer replaces `/usr/local/lib/pc-oc` and `/etc/sudoers.d/pc-oc` and the boot unit.
4. Set the power limit: `sudo pc-oc apply gpu`. The search refuses to start without it.
   - Revert: `sudo pc-oc revert gpu`.
5. Close games and every other GPU work (browsers with video, encoders, anything that renders). The loads need the whole card, and a step that fails can take such a program down with it.

## Search

6. Start the search: `sudo pc-oc search gpu`.
   - It takes about 70 minutes in the worst case. It prints one line per step and needs no input.
   - The card drives the display, so the screen can freeze on a failing step. Save your work first.
   - Ctrl+C ends it cleanly: the load is stopped and the offsets go back to 0.
7. When it ends with a message instead of a result, read the message and run the same command again: `sudo pc-oc search gpu`. It goes on after the step it stopped at and counts that step as failed. Reboot first when the message names an Xid.
8. After a freeze: reboot (hold the power button if nothing else answers), log in, and start the same command again: `sudo pc-oc search gpu`. The step that froze is counted as failed and the search goes on below it.
9. When the desktop does not come up after a reboot: at the boot menu, add `systemd.mask=pc-oc-gpu.service` to the kernel command line. That boot skips the unit that sets the GPU values. Then run `sudo pc-oc revert gpu`.
10. When the search prints `ZERO FAILED` in capitals: an offset may still be set. Run `sudo reboot`.

## Result

11. The search ends with the two proven numbers on the screen. They are in `/var/lib/pc-oc/gpu/search/result`:
    - `core_offset_mhz=<MHz>`, `mem_offset_mhz=<MHz>`, `finished=<UTC time>`.
    - A value of 0 means no offset of that clock passed its steps and its soak.
    - Report: the `result` file and the `log` file of `/var/lib/pc-oc/gpu/search/`, both whole, and every message the search printed that is not a step line.
12. Nothing is applied yet. The two numbers go into `gpu/values` (`core_offset_mhz`, `mem_offset_mhz`) in a reviewed change; after that, `sudo os/install.sh` and `sudo pc-oc apply gpu` set them, and the boot unit sets them at every boot.
13. To search again from the start (after a driver update, for one): `sudo rm -r /var/lib/pc-oc/gpu/search`, then step 6. A start that finds a `result` file only prints it.

## What the first run measures

Four facts could not be checked without a load (#121). The first run measures them and stops with the offsets at 0, naming the fact, when one is not as assumed:

- Which performance state each load reaches. Both loads at stock clocks must reach pstate 0, 1 or 2, the three the offsets are set on.
- The unit of the NVML memory offset. At the first memory step the memory clock must move by the offset that was set, within 5 MHz. If it moves by another amount, the message gives both numbers; report them and do not go on.
- The device index of memtest_vulkan (`mem_device_index` in `gpu/search.values`). A wrong index shows as a memory load at stock clocks that fails or reaches no working pstate.
- That a reboot clears the offsets. This one is only measured if a step crashes: the next start then reads the offsets before it sets anything, and says so if they outlived the reboot.

Report: for each of the four, what the `log` file and the messages show, or "not measured" for the reboot fact when no step crashed.

## The boot unit and its start counter

`pc-oc-gpu.service` carries `StartLimitIntervalSec=infinity`, so every start in one boot counts, manual and successful ones too. After five manual `systemctl restart pc-oc-gpu.service` in one boot the unit refuses the next start; `systemctl reset-failed pc-oc-gpu.service` clears the counter. The search does not start the unit.

## What the search trusts

The search runs the loads as your own user and trusts that account: a process of yours that rewrites the load binary in `~/.cache/pc-oc` can make a step look passed; the damage is bounded by the hard caps of the helper (300 MHz core, 2000 MHz memory) and by the final Cyberpunk check you run yourself.
