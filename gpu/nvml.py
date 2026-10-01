"""Read, set and zero the GPU clock offsets through NVML (ADR 0003, #123).

Run as: /usr/bin/python3 -I gpu/nvml.py get | set core|mem <mhz> | zero

The one non-Bash file in the repo. It fails closed: once it has written, an
NVML error or a read-back that differs puts every offset back to 0, and the
exit code is not 0.
"""

import ctypes
import re
import sys

PREFIX = "pc-oc: gpu: nvml: "
USAGE = "usage: nvml.py get | set core|mem <mhz> | zero"

# Ceilings whatever the caller asks, on top of the range the card reports. They
# bound a search whose checks missed a problem; they are not targets (#121).
CORE_CAP_MHZ = 300  # src: nvml-offset-t (inside the card's -1000..1000, #111); the bound is #121's
MEM_CAP_MHZ = 2000  # src: nvml-offset-t (inside the card's -2000..6000, #111); the bound is #121's
CAPS = {"core": CORE_CAP_MHZ, "mem": MEM_CAP_MHZ}
MHZ = re.compile(r"0|[1-9][0-9]{0,3}")

# The pstates a load reaches; an idle pstate is never read or written (#121).
PSTATES = (0, 1, 2)
CLOCKS = {"core": "NVML_CLOCK_GRAPHICS", "mem": "NVML_CLOCK_MEM"}

# Everything asked of pynvml, checked before nvmlInit so a missing name is a
# refusal, not an AttributeError halfway through a write. The clock-offset
# wrappers nvmlDevice{Get,Set}ClockOffsets are not here: in 13.615.71 they drop
# the driver's return code, so the library is called through the two private
# names and the code is checked (#123 Amendment 1).
NAMES = (
    "nvmlInit", "nvmlShutdown", "nvmlDeviceGetCount", "nvmlDeviceGetHandleByIndex",
    "_nvmlGetFunctionPointer", "_nvmlCheckReturn", "c_nvmlClockOffset_t", "nvmlClockOffset_v1",
    "NVMLError", "NVML_ERROR_NOT_SUPPORTED",
    *CLOCKS.values(), *("NVML_PSTATE_%d" % pstate for pstate in PSTATES),
)


class Fail(Exception):
    """A refusal or a failure: the message for stderr and the exit code."""

    status = 1


class Usage(Fail):
    status = 2


def say(message):
    print(PREFIX + " ".join(str(message).split()), file=sys.stderr)


def why(err):
    return str(err) if isinstance(err, Fail) else "%s: %s" % (type(err).__name__, err)


def label(pstate, clock):
    return "p%d.%s" % (pstate, clock)


def parse(argv):
    """Return (command, clock, mhz); clock and mhz are None unless the command is set."""
    if argv in (["get"], ["zero"]):
        return argv[0], None, None
    if len(argv) != 3 or argv[0] != "set" or argv[1] not in CAPS:
        raise Usage(USAGE)
    clock, text = argv[1], argv[2]
    if not MHZ.fullmatch(text):
        raise Fail("%s offset %r is not a whole number of MHz, 0 or more, without sign or"
                   " leading zero" % (clock, text))
    if int(text) > CAPS[clock]:
        raise Fail("%s offset %s is above the hard cap of %d MHz" % (clock, text, CAPS[clock]))
    return "set", clock, int(text)


class Card:
    """GPU 0 and the two library calls, each return code checked."""

    def __init__(self, nvml):
        self.nvml = nvml
        self.written = set()

    def open(self):
        nvml = self.nvml
        try:
            count = nvml.nvmlDeviceGetCount()
            if count != 1:
                raise Fail("NVML reports %d GPUs, this helper handles exactly 1" % count)
            self.device = nvml.nvmlDeviceGetHandleByIndex(0)
            self.get = nvml._nvmlGetFunctionPointer("nvmlDeviceGetClockOffsets")
            self.set = nvml._nvmlGetFunctionPointer("nvmlDeviceSetClockOffsets")
        except nvml.NVMLError as err:
            raise Fail("cannot open GPU 0: %s" % err) from None

    def call(self, fn, what, pstate, clock, mhz):
        """The struct after fn took it, or None when NVML answers "not supported"."""
        nvml = self.nvml
        info = nvml.c_nvmlClockOffset_t()
        info.version = nvml.nvmlClockOffset_v1
        info.type = getattr(nvml, CLOCKS[clock])
        info.pstate = getattr(nvml, "NVML_PSTATE_%d" % pstate)
        info.clockOffsetMHz = mhz
        try:
            nvml._nvmlCheckReturn(fn(self.device, ctypes.byref(info)))
        except nvml.NVMLError as err:
            if err.value == nvml.NVML_ERROR_NOT_SUPPORTED:
                return None
            raise Fail("%s %s: %s" % (what, label(pstate, clock), err)) from None
        return info

    def read(self, pstate, clock):
        """(offset, min, max) in MHz, or None when NVML answers "not supported"."""
        info = self.call(self.get, "read", pstate, clock, 0)
        if info is None:
            return None
        return info.clockOffsetMHz, info.minClockOffsetMHz, info.maxClockOffsetMHz

    def write(self, pstate, clock, mhz):
        self.written.add((pstate, clock))  # before the call: a failed write may have landed
        if self.call(self.set, "write %d to" % mhz, pstate, clock, mhz) is None:
            raise Fail("write %d to %s: not supported" % (mhz, label(pstate, clock)))


def line(pstate, clock, reading):
    if reading is None:
        return "%s unsupported" % label(pstate, clock)
    return "%s offset=%d min=%d max=%d" % (label(pstate, clock), *reading)


def set_offset(card, clock, mhz):
    readings = {pstate: card.read(pstate, clock) for pstate in PSTATES}
    supported = [pstate for pstate in PSTATES if readings[pstate] is not None]
    if not supported:
        raise Fail("no pstate of P0, P1, P2 takes a %s offset" % clock)
    for pstate in supported:
        _, low, high = readings[pstate]
        if not low <= mhz <= high:
            raise Fail("%s offset %d is outside the card's range %d..%d on %s"
                       % (clock, mhz, low, high, label(pstate, clock)))
    for pstate in supported:
        card.write(pstate, clock, mhz)
    for pstate in supported:
        readings[pstate] = card.read(pstate, clock)
        if readings[pstate] is None or readings[pstate][0] != mhz:
            raise Fail("%s after writing %d" % (line(pstate, clock, readings[pstate]), mhz))
    return [line(pstate, clock, readings[pstate]) for pstate in PSTATES]


def zero(card):
    """Write 0 on every pstate and clock, then read each back. One that NVML calls
    unsupported is skipped, unless this run wrote to it. Never stops early. Returns
    what went wrong; [] means every read was 0."""
    problems, targets = [], []
    for pstate in PSTATES:
        for clock in CLOCKS:
            try:
                if card.read(pstate, clock) is None and (pstate, clock) not in card.written:
                    continue
            except Exception as err:
                problems.append(why(err))  # state unknown: write 0 all the same
            targets.append((pstate, clock))
            try:
                card.write(pstate, clock, 0)
            except Exception as err:
                problems.append(why(err))
    if not targets:
        problems.append("no pstate of P0, P1, P2 takes an offset")
    for pstate, clock in targets:
        try:
            reading = card.read(pstate, clock)
        except Exception as err:
            problems.append(why(err))
            continue
        if reading is None or reading[0] != 0:
            problems.append("%s after writing 0" % line(pstate, clock, reading))
    return problems


def roll_back(card):
    problems = zero(card)
    for problem in problems:
        say("roll back: %s" % problem)
    say("roll back: offsets are NOT confirmed 0" if problems else "roll back: every offset reads 0")


def run(card, command, clock, mhz):
    card.open()
    if command == "get":
        lines = [line(pstate, clock, card.read(pstate, clock))
                 for pstate in PSTATES for clock in CLOCKS]
    elif command == "set":
        lines = set_offset(card, clock, mhz)
    else:
        lines = []
        problems = zero(card)
        if problems:
            raise Fail("zero: " + "; ".join(problems))
    # printed in here so that a failing stdout is rolled back like any other failure
    for text in lines:
        print(text)
    sys.stdout.flush()


def main(argv, nvml):
    """Run one command against the pynvml module `nvml`; returns the exit code."""
    try:
        command, clock, mhz = parse(list(argv))
        missing = [name for name in NAMES if not hasattr(nvml, name)]
        if missing:
            raise Fail("pynvml has no %s" % ", ".join(missing))
        try:
            nvml.nvmlInit()
        except nvml.NVMLError as err:
            raise Fail("nvmlInit failed: %s" % err) from None
    except Fail as err:
        say(err)
        return err.status
    card = Card(nvml)
    status = 1
    try:
        run(card, command, clock, mhz)
        status = 0
    except (Exception, KeyboardInterrupt) as err:  # Ctrl-C too: no half-applied offset is left
        say(why(err))
        if card.written and command != "zero":
            roll_back(card)
    try:
        nvml.nvmlShutdown()
    except nvml.NVMLError as err:
        say("nvmlShutdown failed: %s" % err)
        if status == 0 and card.written and command != "zero":
            roll_back(card)
        status = 1
    return status


if __name__ == "__main__":
    try:
        parse(sys.argv[1:])
    except Fail as err:
        say(err)
        sys.exit(err.status)
    sys.dont_write_bytecode = True  # the helper writes no file, bytecode included
    try:
        import pynvml
    except ImportError as err:
        say("cannot import pynvml: %s" % err)
        sys.exit(1)
    sys.exit(main(sys.argv[1:], pynvml))
