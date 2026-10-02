"""Read, set and zero the GPU clock offsets through NVML (ADR 0003, #123).

Run as: /usr/bin/python3 -I gpu/nvml.py get | set core|mem <mhz> | zero

The one non-Bash file in the repo. It fails closed: once it has written, it
exits 0 only when every write read back, stdout took every line and
nvmlShutdown returned. On any other path (an NVML error, a read-back that
differs, a stream that cannot be written, Ctrl-C, SIGTERM, SIGHUP) it first
writes 0 to every offset, then says why, and exits 1 (#123 Amendment 2).
"""

import ctypes
import os
import re
import signal
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


def emit(stream, lines):
    """Write the lines and flush. False when the stream did not take them; nothing is
    raised, whatever the stream does: a closed pipe raises BrokenPipeError and a closed
    stream ValueError, from write or from flush."""
    try:
        for text in lines:
            stream.write(text + "\n")
        stream.flush()
    except BaseException:
        return False
    return True


def say(messages):
    """One prefixed line on stderr per message. A stderr that cannot be written changes
    nothing: the exit code is already decided when this is called."""
    emit(sys.stderr, [PREFIX + " ".join(str(message).split()) for message in messages])


def why(err, doing=""):
    """One line about an exception. A Fail says what it was doing itself. Never raises:
    it is called between two writes of 0."""
    try:
        if isinstance(err, Fail):
            return str(err)
        text = ("%s: %s" % (type(err).__name__, err)).rstrip(": ")
    except Exception:
        text = type(err).__name__
    return "%s: %s" % (doing, text) if doing else text


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


class Watch:
    """SIGINT, SIGTERM and SIGHUP while the helper runs. The handler only notes the
    signal, so nothing is raised in the middle of a call and no write of 0 is skipped;
    check() turns a noted signal into a Fail between two calls. A signal that was
    ignored when the helper started (nohup) stays ignored."""

    SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)

    def __init__(self):
        self.seen = []
        self.told = 0
        self.previous = {}

    def note(self, signum, frame):
        self.seen.append(signum)

    def start(self):
        for signum in self.SIGNALS:
            if signal.getsignal(signum) is not signal.SIG_IGN:
                self.previous[signum] = signal.signal(signum, self.note)

    def stop(self):
        """Put back the handlers start() replaced."""
        while self.previous:
            signum, handler = self.previous.popitem()
            if handler is not None:  # None: not set from Python, and nothing can restore it
                signal.signal(signum, handler)

    def check(self):
        """Raise Fail for the signals noted since the last check."""
        new = self.seen[self.told:]
        self.told += len(new)
        if new:
            raise Fail("stopped by %s" % ", ".join(signal.Signals(signum).name for signum in new))


class Card:
    """GPU 0 and the two library calls, each return code checked."""

    def __init__(self, nvml):
        self.nvml = nvml
        self.written = set()
        self.zeroed = False  # zero() has attempted every write of 0

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


def set_offset(card, clock, mhz, watch):
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
        watch.check()  # a signal stops the run between two writes, not inside one
        card.write(pstate, clock, mhz)
    for pstate in supported:
        readings[pstate] = card.read(pstate, clock)
        if readings[pstate] is None or readings[pstate][0] != mhz:
            raise Fail("%s after writing %d" % (line(pstate, clock, readings[pstate]), mhz))
    return [line(pstate, clock, readings[pstate]) for pstate in PSTATES]


def zero(card):
    """Write 0 on every pstate and clock, then read each back. One that NVML calls
    unsupported is skipped, unless this run wrote to it. Nothing stops it early: a call
    that raises, Ctrl-C included, is noted and the next call is made. Returns what went
    wrong; [] means every write returned and every read was 0."""
    problems, targets = [], []
    for pstate in PSTATES:
        for clock in CLOCKS:
            try:
                if card.read(pstate, clock) is None and (pstate, clock) not in card.written:
                    continue
            except BaseException as err:  # state unknown: write 0 all the same
                problems.append(why(err, "read %s" % label(pstate, clock)))
            targets.append((pstate, clock))
            try:
                card.write(pstate, clock, 0)
            except BaseException as err:  # it may have landed; the read below tells
                problems.append(why(err, "write 0 to %s" % label(pstate, clock)))
    card.zeroed = True
    if not targets:
        problems.append("no pstate of P0, P1, P2 takes an offset")
    for pstate, clock in targets:
        try:
            reading = card.read(pstate, clock)
        except BaseException as err:
            problems.append(why(err, "read %s" % label(pstate, clock)))
            continue
        if reading is None or reading[0] != 0:
            problems.append("%s after writing 0" % line(pstate, clock, reading))
    return problems


def roll_back(card):
    """Write 0 everywhere if this run wrote and zero() has not run yet. Returns the
    lines for stderr and writes none of them."""
    if not card.written or card.zeroed:
        return []
    problems = zero(card)
    return ["roll back: %s" % problem for problem in problems] + [
        "roll back: offsets are NOT confirmed 0" if problems else "roll back: every offset reads 0"]


def run(card, command, clock, mhz, watch):
    card.open()
    if command == "get":
        lines = [line(pstate, clock, card.read(pstate, clock))
                 for pstate in PSTATES for clock in CLOCKS]
    elif command == "set":
        lines = set_offset(card, clock, mhz, watch)
    else:
        lines = []
        problems = zero(card)
        if problems:
            raise Fail("zero: " + "; ".join(problems))
    watch.check()
    # written in here so that a stdout that fails is rolled back like any other failure
    if lines and not emit(sys.stdout, lines):
        raise Fail("cannot write to stdout")


def serve(argv, nvml, watch, notes):
    """Run the command and return the exit code; the lines for stderr go to `notes`."""
    try:
        command, clock, mhz = parse(argv)
        missing = [name for name in NAMES if not hasattr(nvml, name)]
        if missing:
            raise Fail("pynvml has no %s" % ", ".join(missing))
    except Fail as err:
        notes.append(str(err))
        return err.status
    watch.start()  # before nvmlInit, so before any write
    try:
        nvml.nvmlInit()
    except nvml.NVMLError as err:
        notes.append("nvmlInit failed: %s" % err)
        return 1
    card = Card(nvml)
    status = 0

    def failed(err, doing=""):
        undone = roll_back(card)  # first: no message is put together or written before it
        notes.append(why(err, doing))
        notes.extend(undone)
        return 1

    try:
        run(card, command, clock, mhz, watch)
        watch.check()
    except BaseException as err:  # Ctrl-C and SystemExit too: no offset is left half applied
        status = failed(err)
    try:
        nvml.nvmlShutdown()
        watch.check()
    except BaseException as err:  # the roll-back is tried even though NVML may be shut down
        status = failed(err, "nvmlShutdown")
    return status


def main(argv, nvml):
    """Run one command against the pynvml module `nvml`. Returns the exit code and never
    raises. stderr is written after any roll-back and after nvmlShutdown; the signal
    handlers found on entry are back when it returns."""
    notes = []
    watch = Watch()
    try:
        status = serve(list(argv), nvml, watch, notes)
    except BaseException as err:  # what serve() did not foresee; it catches around every write
        status = 1
        notes.append(why(err))
    if notes:
        say(notes)
    try:
        watch.stop()
    except BaseException as err:
        say([why(err, "restore the signal handlers")])
        status = status or 1
    return status


def leave(status):
    """sys.exit(status) with the code kept. Python's own flush on the way out turns the
    code into 120 over a stdout or stderr that is gone, so such a stream is pointed at
    /dev/null first; emit() has already tried to write all there is."""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.flush()
        except Exception:
            try:
                os.dup2(os.open(os.devnull, os.O_WRONLY), stream.fileno())
            except Exception:
                pass  # no stream, or no file descriptor behind it: nothing is left to flush
    sys.exit(status)


if __name__ == "__main__":
    try:
        parse(sys.argv[1:])
    except Fail as err:
        say([err])
        leave(err.status)
    sys.dont_write_bytecode = True  # the helper writes no file, bytecode included
    try:
        import pynvml
    except ImportError as err:
        say(["cannot import pynvml: %s" % err])
        leave(1)
    leave(main(sys.argv[1:], pynvml))
