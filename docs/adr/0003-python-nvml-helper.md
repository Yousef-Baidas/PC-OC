# 0003: one Python file writes the GPU clock offsets

Date: 2026-10-02. Status: accepted (lead, on the human's ruling that the research finding decides; #69, #111).

## Context

GPU clock offsets on Wayland can only be set through NVML (`nvmlDeviceSetClockOffsets`); `nvidia-smi` cannot, and the X11 route needs an X server. CONVENTIONS.md says Bash only. NVML has no shell front end. NVIDIA's own Python bindings (`python-nvidia-ml-py`, official `extra` repo) are already installed on the PC, so they are not a new dependency. A C helper would add a compiler step to the root installer.

## Decision

- `gpu/nvml.py` is the one non-Bash file in the repo. It only reads and writes clock offsets; everything else stays Bash and calls it.
- It runs as `/usr/bin/python3 -I` (isolated mode: no `PYTHONPATH`, no user site directory), so root never imports from a path a user can write.
- It carries its own hard caps and reads every write back. On a mismatch or an NVML error it sets every offset to 0 and exits non-zero.
- Its gate is a unittest file under `tests/gpu/` that drives it against a fake NVML module, run from a bats case so `checks/gates.sh` covers it without a new tool.

## Consequences

- shellcheck and shfmt do not see this file; the unittest and the verifier's read are its only checks.
- A driver update that changes the NVML clock-offset call breaks the helper at run time. It fails closed (offsets 0), and the probe shows it.
- A second Python file needs a new ADR.
