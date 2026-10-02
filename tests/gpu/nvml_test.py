"""Contract for gpu/nvml.py (ticket #123 with Amendments 1 and 2, ADR 0003).

Run as: /usr/bin/python3 -I -B tests/gpu/nvml_test.py

The helper is loaded by path and driven through main(argv, nvml). argv is the
command line without the program name, for example ["set", "core", "120"].
nvml is a fake of the pynvml module: a fake library behind functions shaped
like the real ones. Nothing here initialises the real NVML; test_10 imports
pynvml and stops there.

PC_OC_NVML_HELPER points the tests at another helper file. It exists for the
red-twice proof of this contract only; nothing in the repo sets it.
"""

import contextlib
import ctypes
import errno
import hashlib
import importlib.util
import inspect
import io
import os
import signal
import string
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

REPO = Path(__file__).resolve().parents[2]
HELPER = Path(os.environ.get("PC_OC_NVML_HELPER") or REPO / "gpu" / "nvml.py").resolve()
PREFIX = "pc-oc: gpu: nvml: "

# Values copied from pynvml 13.615.71; test_10_fake_matches_installed_pynvml
# fails when the installed module disagrees.
CONSTANTS = {
    "NVML_SUCCESS": 0,
    "NVML_ERROR_UNINITIALIZED": 1,
    "NVML_ERROR_INVALID_ARGUMENT": 2,
    "NVML_ERROR_NOT_SUPPORTED": 3,
    "NVML_ERROR_NO_PERMISSION": 4,
    "NVML_ERROR_DRIVER_NOT_LOADED": 9,
    "NVML_ERROR_FUNCTION_NOT_FOUND": 13,
    "NVML_ERROR_GPU_IS_LOST": 15,
    "NVML_ERROR_ARGUMENT_VERSION_MISMATCH": 25,
    "NVML_ERROR_UNKNOWN": 999,
    "NVML_CLOCK_GRAPHICS": 0,
    "NVML_CLOCK_SM": 1,
    "NVML_CLOCK_MEM": 2,
    "NVML_CLOCK_VIDEO": 3,
    "NVML_CLOCK_COUNT": 4,
    "NVML_PSTATE_UNKNOWN": 32,
    "nvmlClockOffset_v1": 0x1000018,
}
CONSTANTS.update({"NVML_PSTATE_%d" % n: n for n in range(16)})

OK = CONSTANTS["NVML_SUCCESS"]
UNINITIALIZED = CONSTANTS["NVML_ERROR_UNINITIALIZED"]
INVALID_ARGUMENT = CONSTANTS["NVML_ERROR_INVALID_ARGUMENT"]
NOT_SUPPORTED = CONSTANTS["NVML_ERROR_NOT_SUPPORTED"]
DRIVER_NOT_LOADED = CONSTANTS["NVML_ERROR_DRIVER_NOT_LOADED"]
FUNCTION_NOT_FOUND = CONSTANTS["NVML_ERROR_FUNCTION_NOT_FOUND"]
VERSION_MISMATCH = CONSTANTS["NVML_ERROR_ARGUMENT_VERSION_MISMATCH"]
UNKNOWN = CONSTANTS["NVML_ERROR_UNKNOWN"]
CORE = CONSTANTS["NVML_CLOCK_GRAPHICS"]
MEM = CONSTANTS["NVML_CLOCK_MEM"]
P0, P1, P2, P5, P8 = 0, 1, 2, 5, 8


class c_nvmlClockOffset_t(ctypes.Structure):
    _fields_ = [
        ("version", ctypes.c_uint),
        ("type", ctypes.c_uint),
        ("pstate", ctypes.c_uint),
        ("clockOffsetMHz", ctypes.c_int),
        ("minClockOffsetMHz", ctypes.c_int),
        ("maxClockOffsetMHz", ctypes.c_int),
    ]


class NVMLError(Exception):
    """Same shape as pynvml.NVMLError: NVMLError(code) is an instance of the
    subclass for that code and carries the code in .value."""

    _valClassMapping = {}

    def __new__(typ, value):
        if typ is NVMLError:
            typ = NVMLError._valClassMapping.get(value, typ)
        obj = Exception.__new__(typ)
        obj.value = value
        return obj

    def __str__(self):
        return "NVML Error with code %d" % self.value

    def __eq__(self, other):
        return self.value == other.value


def _error_classes():
    classes = {}
    for const, code in CONSTANTS.items():
        if not const.startswith("NVML_ERROR_"):
            continue
        name = "NVMLError_" + string.capwords(const[len("NVML_ERROR_"):], "_").replace("_", "")

        def new(typ, *args, _code=code):
            return NVMLError.__new__(typ, _code)

        classes[name] = type(name, (NVMLError,), {"__new__": new})
        NVMLError._valClassMapping[code] = classes[name]
    return classes


ERROR_CLASSES = _error_classes()

# The card of the fixtures: P0 and P2 take offsets, P1 does not, P5 and P8 are
# idle pstates the helper must leave alone. Ranges differ per pstate so a
# helper that reads one pstate for all of them is caught.
CARD_RANGES = {
    (P0, CORE): (-1000, 1000),
    (P0, MEM): (-2000, 6000),
    (P2, CORE): (-1000, 900),
    (P2, MEM): (-2000, 5000),
    (P5, CORE): (-1000, 1000),
    (P5, MEM): (-2000, 6000),
    (P8, CORE): (-1000, 1000),
    (P8, MEM): (-2000, 6000),
}
CARD_OFFSETS = {
    (P0, CORE): 15,
    (P0, MEM): 100,
    (P2, CORE): 0,
    (P2, MEM): 200,
    (P5, CORE): 0,
    (P5, MEM): 0,
    (P8, CORE): 0,
    (P8, MEM): 0,
}


class FakeNvml:
    """A fake driver and library, and the pynvml-shaped names in front of it.

    The helper is handed `.module`; everything it asks of it is recorded in
    `.names`, every call in `.calls`. The clock-offset state is per pstate and
    per clock in `.offsets`.

    ranges:           {(pstate, clock): (min, max)} overrides for the card
    drop:             pstates the driver answers "not supported" for
    clamp:            {((pstate, clock), asked): stored} for a write that lands elsewhere
    stuck:            (pstate, clock) keys whose write succeeds and changes nothing
    set_codes:        {n: code} the n-th Set call (1-based) returns code, writes nothing
    get_codes_after_set: {(pstate, clock): code} Get returns code once any Set was called
    get_codes_after_write: {(pstate, clock): code} Get returns code once that offset was written
    set_interrupts:   {n: what} the n-th Set call lands, then what arrives as the call
                      returns: KeyboardInterrupt is raised, a signal number is sent to this
                      process with signal.raise_signal
    shutdown_raises:  nvmlShutdown raises this exception class and shuts nothing down
    count:            what nvmlDeviceGetCount returns
    init_error:       nvmlInit raises NVMLError(init_error)
    missing:          names the module does not have
    """

    def __init__(self, ranges=None, drop=(), clamp=None, stuck=(), set_codes=None,
                 get_codes_after_set=None, get_codes_after_write=None, set_interrupts=None,
                 shutdown_raises=None, count=1, init_error=None, missing=()):
        self.ranges = dict(CARD_RANGES)
        self.ranges.update(ranges or {})
        for key in [k for k in self.ranges if k[0] in drop]:
            del self.ranges[key]
        self.offsets = {key: CARD_OFFSETS[key] for key in self.ranges}
        self.clamp = dict(clamp or {})
        self.stuck = set(stuck)
        self.set_codes = dict(set_codes or {})
        self.get_codes_after_set = dict(get_codes_after_set or {})
        self.get_codes_after_write = dict(get_codes_after_write or {})
        self.set_interrupts = dict(set_interrupts or {})
        self.shutdown_raises = shutdown_raises
        self.count = count
        self.init_error = init_error
        self.missing = set(missing)
        self.initialised = False
        self.handles = [ctypes.c_void_p(0x1000 + n) for n in range(count)]
        self.calls = []
        self.names = set()
        self.misuse = []
        self.surface = dict(CONSTANTS)
        self.surface.update(ERROR_CLASSES)
        self.surface.update({
            "NVMLError": NVMLError,
            "c_nvmlClockOffset_t": c_nvmlClockOffset_t,
            "nvmlInit": self._init,
            "nvmlShutdown": self._shutdown,
            "nvmlDeviceGetCount": self._device_get_count,
            "nvmlDeviceGetHandleByIndex": self._device_get_handle_by_index,
            "nvmlDeviceGetClockOffsets": self._wrapper_get,
            "nvmlDeviceSetClockOffsets": self._wrapper_set,
            "_nvmlGetFunctionPointer": self._get_function_pointer,
            "_nvmlCheckReturn": self._check_return,
        })
        self.module = _Module(self)

    # what the tests read

    def count_of(self, name):
        return sum(1 for call in self.calls if call[0] == name)

    @property
    def sets(self):
        """Every Set that reached the library: (clock, pstate, mhz, code)."""
        return [call[1:] for call in self.calls if call[0] == "lib.set"]

    @property
    def gets(self):
        return [call[1:] for call in self.calls if call[0] == "lib.get"]

    @property
    def written(self):
        """Every (pstate, clock) a Set reached the library for."""
        return {(pstate, clock) for clock, pstate, *_ in self.sets}

    @property
    def zeroed(self):
        """Every (pstate, clock) a Set of 0 reached the library for."""
        return {(pstate, clock) for clock, pstate, mhz, _ in self.sets if mhz == 0}

    @property
    def signals(self):
        return [what for what in self.set_interrupts.values() if isinstance(what, int)]

    # pynvml-shaped functions

    def _init(self):
        self.calls.append(("nvmlInit",))
        if self.init_error is not None:
            self.calls.append(("nvmlInit.failed", self.init_error))
            raise NVMLError(self.init_error)
        self.initialised = True

    def _shutdown(self):
        self.calls.append(("nvmlShutdown",))
        if self.shutdown_raises is not None:
            self.calls.append(("nvmlShutdown.failed", self.shutdown_raises.__name__))
            raise self.shutdown_raises("nvmlShutdown: raised by the fake")
        if not self.initialised:
            raise NVMLError(UNINITIALIZED)
        self.initialised = False

    def _device_get_count(self):
        self.calls.append(("nvmlDeviceGetCount",))
        self._need_init("nvmlDeviceGetCount")
        return self.count

    def _device_get_handle_by_index(self, index):
        self.calls.append(("nvmlDeviceGetHandleByIndex", index))
        self._need_init("nvmlDeviceGetHandleByIndex")
        if not isinstance(index, int) or not 0 <= index < self.count:
            raise NVMLError(INVALID_ARGUMENT)
        return self.handles[index]

    def _get_function_pointer(self, name):
        self.calls.append(("_nvmlGetFunctionPointer", name))
        self._need_init("_nvmlGetFunctionPointer")
        return self._pointer(name)

    def _check_return(self, ret):
        self.calls.append(("_nvmlCheckReturn", ret))
        if ret != OK:
            raise NVMLError(ret)
        return ret

    # the two wrappers, as broken as the real ones: the code is dropped

    def _wrapper_get(self, device, info):
        self.calls.append(("wrapper", "nvmlDeviceGetClockOffsets"))
        self._need_init("nvmlDeviceGetClockOffsets")
        fn = self._pointer("nvmlDeviceGetClockOffsets")
        ret = fn(device, info)  # dropped, as in pynvml 13.615.71
        return OK

    def _wrapper_set(self, device, info):
        self.calls.append(("wrapper", "nvmlDeviceSetClockOffsets"))
        self._need_init("nvmlDeviceSetClockOffsets")
        fn = self._pointer("nvmlDeviceSetClockOffsets")
        ret = fn(device, info)  # dropped, as in pynvml 13.615.71
        return OK

    # the library

    def _need_init(self, what):
        if not self.initialised:
            self.misuse.append("%s while NVML is not initialised" % what)
            raise NVMLError(UNINITIALIZED)

    def _pointer(self, name):
        if name == "nvmlDeviceGetClockOffsets":
            return self._lib_get
        if name == "nvmlDeviceSetClockOffsets":
            return self._lib_set
        raise NVMLError(FUNCTION_NOT_FOUND)

    def _struct(self, info, what):
        struct = getattr(info, "_obj", None)  # ctypes.byref(struct)
        if struct is None and isinstance(info, ctypes._Pointer):
            struct = info.contents
        if not isinstance(struct, c_nvmlClockOffset_t):
            self.misuse.append("%s wants ctypes.byref(nvml.c_nvmlClockOffset_t()), got %r"
                               % (what, info))
            raise TypeError(self.misuse[-1])
        return struct

    def _precheck(self, device, struct, what):
        if not self.initialised:
            self.misuse.append("%s while NVML is not initialised" % what)
            return UNINITIALIZED
        if not any(device is handle for handle in self.handles):
            self.misuse.append("%s with a device that is not a handle" % what)
            return INVALID_ARGUMENT
        if struct.version != CONSTANTS["nvmlClockOffset_v1"]:
            self.misuse.append("%s with version %#x" % (what, struct.version))
            return VERSION_MISMATCH
        if (struct.pstate, struct.type) not in self.ranges:
            return NOT_SUPPORTED
        return OK

    def _lib_get(self, device, info):
        struct = self._struct(info, "nvmlDeviceGetClockOffsets")
        key = (struct.pstate, struct.type)
        ret = self._precheck(device, struct, "nvmlDeviceGetClockOffsets")
        if ret == OK and self.sets:
            ret = self.get_codes_after_set.get(key, OK)
        if ret == OK and key in self.written:
            ret = self.get_codes_after_write.get(key, OK)
        if ret == OK:
            struct.clockOffsetMHz = self.offsets[key]
            struct.minClockOffsetMHz, struct.maxClockOffsetMHz = self.ranges[key]
        self.calls.append(("lib.get", struct.type, struct.pstate, ret))
        return ret

    def _lib_set(self, device, info):
        struct = self._struct(info, "nvmlDeviceSetClockOffsets")
        key = (struct.pstate, struct.type)
        mhz = struct.clockOffsetMHz
        ret = self._precheck(device, struct, "nvmlDeviceSetClockOffsets")
        if ret == OK:
            ret = self.set_codes.get(len(self.sets) + 1, OK)
        if ret == OK and not self.ranges[key][0] <= mhz <= self.ranges[key][1]:
            ret = INVALID_ARGUMENT
        if ret == OK and key not in self.stuck:
            self.offsets[key] = self.clamp.get((key, mhz), mhz)
        self.calls.append(("lib.set", struct.type, struct.pstate, mhz, ret))
        what = self.set_interrupts.get(len(self.sets))
        if what is not None:
            self.calls.append(("interrupt", len(self.sets), what))
            if isinstance(what, int):
                signal.raise_signal(what)
            else:
                raise what()
        return ret


class _Module:
    """What main() receives as `nvml`: the fake's pynvml names, nothing else."""

    def __init__(self, fake):
        object.__setattr__(self, "_fake", fake)

    def __getattribute__(self, name):
        if name.startswith("__") and name.endswith("__"):
            return object.__getattribute__(self, name)
        fake = object.__getattribute__(self, "_fake")
        fake.names.add(name)
        if name in fake.missing or name not in fake.surface:
            raise AttributeError("module 'pynvml' has no attribute %r" % name)
        return fake.surface[name]


# name: (argv, fake settings, numbered case of the ticket or None)
SCENARIOS = {
    "get": (["get"], {}, 1),
    "set_core_120": (["set", "core", "120"], {}, 2),
    "set_core_300": (["set", "core", "300"], {}, None),
    "set_mem_2000": (["set", "mem", "2000"], {}, None),
    "zero": (["zero"], {}, None),
    "refuse_core_301": (["set", "core", "301"], {}, 3),
    "refuse_mem_2001": (["set", "mem", "2001"], {}, 3),
    "refuse_core_minus_15": (["set", "core", "-15"], {}, 3),
    "refuse_core_plus_120": (["set", "core", "+120"], {}, 3),
    "refuse_core_0120": (["set", "core", "0120"], {}, 3),
    "refuse_core_12_5": (["set", "core", "12.5"], {}, 3),
    "refuse_core_no_value": (["set", "core"], {}, 3),
    "refuse_gfx_100": (["set", "gfx", "100"], {}, 3),
    "refuse_core_100_extra": (["set", "core", "100", "extra"], {}, 3),
    "above_p2_max": (["set", "core", "120"], {"ranges": {(P2, CORE): (-1000, 100)}}, 4),
    "readback_105": (["set", "core", "120"], {"clamp": {((P2, CORE), 120): 105}}, 5),
    "second_write_fails": (["set", "core", "120"], {"set_codes": {2: UNKNOWN}}, 6),
    "zero_stuck": (["zero"], {"stuck": {(P0, CORE)}}, 7),
    "count_0_get": (["get"], {"count": 0}, 8),
    "count_0_set": (["set", "core", "120"], {"count": 0}, 8),
    "count_0_zero": (["zero"], {"count": 0}, 8),
    "count_2_get": (["get"], {"count": 2}, 8),
    "count_2_set": (["set", "core", "120"], {"count": 2}, 8),
    "count_2_zero": (["zero"], {"count": 2}, 8),
    "zero_readback_get_fails": (["zero"], {"get_codes_after_set": {(P0, CORE): UNKNOWN}}, 12),
    "no_check_return": (["set", "core", "120"], {"missing": {"_nvmlCheckReturn"}}, 13),
    "no_function_pointer": (["set", "core", "120"], {"missing": {"_nvmlGetFunctionPointer"}}, 13),
    "init_fails": (["set", "core", "120"], {"init_error": DRIVER_NOT_LOADED}, None),
    "nothing_supported": (["set", "core", "120"], {"drop": {P0, P1, P2}}, None),
    # Amendment 2. A write of 120 on P0 and on P2 comes first in each `set`, so
    # the third Set call is the first write of the roll-back.
    "readback_105_stderr_broken": (["set", "core", "120"], {"clamp": {((P2, CORE), 120): 105}}, 14),
    "readback_105_stderr_closed": (["set", "core", "120"], {"clamp": {((P2, CORE), 120): 105}}, 14),
    "set_core_120_streams_broken": (["set", "core", "120"], {}, 15),
    "set_core_120_streams_closed": (["set", "core", "120"], {}, 15),
    "roll_back_interrupted": (["set", "core", "120"], {"clamp": {((P2, CORE), 120): 105},
                                                       "set_interrupts": {3: KeyboardInterrupt}}, 16),
    "zero_interrupted": (["zero"], {"set_interrupts": {1: KeyboardInterrupt}}, 17),
    "shutdown_raises": (["set", "core", "120"], {"shutdown_raises": RuntimeError}, 18),
    "readback_unsupported": (["set", "core", "120"],
                             {"get_codes_after_write": {(P2, CORE): NOT_SUPPORTED}}, 19),
    "sigterm_in_second_write": (["set", "core", "120"], {"set_interrupts": {2: signal.SIGTERM}}, 20),
    "sighup_in_second_write": (["set", "core", "120"], {"set_interrupts": {2: signal.SIGHUP}}, 20),
    "roll_back_write_fails": (["set", "core", "120"], {"clamp": {((P2, CORE), 120): 105},
                                                       "set_codes": {3: UNKNOWN}}, None),
    "zero_write_fails": (["zero"], {"set_codes": {1: UNKNOWN}}, None),
}
# Refusals that may come before or after nvmlInit; every other scenario of
# cases 1 to 8 cannot be answered without it.
INIT_OPTIONAL = {name for name, (_, _, case) in SCENARIOS.items() if case == 3}

# Scenarios in which the helper cannot write its messages:
# name: (streams that raise on write, exception class, its arguments).
BROKEN = (BrokenPipeError, (errno.EPIPE, "Broken pipe"))
CLOSED = (ValueError, ("I/O operation on closed file.",))
DEAD_STREAMS = {
    "readback_105_stderr_broken": (("stderr",), *BROKEN),
    "readback_105_stderr_closed": (("stderr",), *CLOSED),
    "set_core_120_streams_broken": (("stdout", "stderr"), *BROKEN),
    "set_core_120_streams_closed": (("stdout", "stderr"), *CLOSED),
}
# The handlers a helper may replace; Run puts back what it found.
SIGNALS = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)


class DeadStream:
    """A stdout or stderr that cannot be written: write and flush raise. `seen`
    holds what state() returned at each attempt to write."""

    def __init__(self, kind, args, state):
        self.kind, self.args, self.state = kind, args, state
        self.closed = kind is ValueError
        self.seen = []

    def write(self, text):
        self.seen.append(self.state())
        raise self.kind(*self.args)

    def flush(self):
        raise self.kind(*self.args)


def load_helper():
    if not HELPER.is_file():
        raise AssertionError("helper not found: %s" % HELPER)
    spec = importlib.util.spec_from_file_location("pc_oc_gpu_nvml", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Run:
    """One call of main(). `out` and `err` are None for a stream that could not
    be written, and `err_seen` then holds the offsets at each attempt to write
    to stderr. In a scenario of Amendment 2 (cases 14 and up) an exception out
    of main() is kept in `raised`. A signal the scenario sends lands in
    `unhandled` when the helper has no handler for it; the handlers found
    before the call are back in place after it, whatever the helper installed."""

    def __init__(self, name):
        argv, settings, case = SCENARIOS[name]
        self.name = name
        self.fake = FakeNvml(**settings)
        self.raised = None
        self.unhandled = []
        helper = load_helper()
        dead, kind, args = DEAD_STREAMS.get(name, ((), None, None))
        out, err = (DeadStream(kind, args, lambda: dict(self.fake.offsets)) if stream in dead
                    else io.StringIO() for stream in ("stdout", "stderr"))
        handlers = {sig: signal.getsignal(sig) for sig in SIGNALS}
        try:
            for sig in self.fake.signals:  # without this the default action ends the test run
                signal.signal(sig, lambda signum, frame: self.unhandled.append(signum))
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    self.status = helper.main(list(argv), self.fake.module)
                except SystemExit as exit_:
                    raise AssertionError("main(%r) raised SystemExit(%r); it must return its exit"
                                         " code" % (argv, exit_.code)) from None
                except BaseException as raised:
                    if case is None or case < 14:
                        raise
                    if isinstance(raised, KeyboardInterrupt) and not self.fake.count_of("interrupt"):
                        raise  # a real Ctrl-C, not the fake's
                    self.status, self.raised = None, raised
        finally:
            for sig, handler in handlers.items():
                if handler is not None:
                    signal.signal(sig, handler)
        self.out = None if "stdout" in dead else out.getvalue()
        self.err = None if "stderr" in dead else err.getvalue()
        self.err_seen = err.seen if "stderr" in dead else None


class Contract(unittest.TestCase):
    maxDiff = None

    def run_scenario(self, name):
        """Run one scenario and apply the rules that hold for every command."""
        run = Run(name)
        self.assert_rules(run)
        return run

    def assert_rules(self, run):
        fake = run.fake
        self.assertIs(type(run.status), int, "main() returns an int")
        self.assertEqual(fake.misuse, [], "the fake library was called in a way the real one rejects")
        self.assertLessEqual({pstate for _, pstate, *_ in fake.gets + fake.sets}, {P0, P1, P2},
                             "only P0, P1 and P2 are ever read or written")
        self.assertLessEqual({clock for clock, *_ in fake.gets + fake.sets}, {CORE, MEM},
                             "only the graphics and memory clocks are ever read or written")
        inits = fake.count_of("nvmlInit") - fake.count_of("nvmlInit.failed")
        self.assertLessEqual(fake.count_of("nvmlInit"), 1, "nvmlInit is called at most once")
        if inits and fake.shutdown_raises is None:  # a shutdown that raised may be tried again
            self.assertEqual(fake.count_of("nvmlShutdown"), 1,
                             "nvmlShutdown is called exactly once when nvmlInit succeeded")
        if run.status == 0:
            self.assertEqual(run.err, "", "nothing on stderr on success")
        elif run.err is not None:  # None: this stderr could not be written
            self.assertNotEqual(run.err, "", "a failure says why on stderr")
            for line in run.err.splitlines():
                self.assertTrue(line.startswith(PREFIX), "stderr line %r starts %r" % (line, PREFIX))

    def assert_rolled_back(self, run):
        """The rule of Amendment 2: after the first write, any path but a clean
        one ends with every offset the helper wrote at 0, and exit 1."""
        fake = run.fake
        written = sorted(fake.written)
        self.assertNotEqual(written, [], "the fixture's writes happened")
        self.assertEqual({key: fake.offsets[key] for key in written}, dict.fromkeys(written, 0),
                         "every offset the helper wrote is 0 at the end")
        self.assertIsNone(run.raised, "main() returns its exit code; nothing is raised out of it")
        self.assertEqual(run.status, 1)
        self.assert_rules(run)

    def assert_roll_back_came_first(self, run):
        written = sorted(run.fake.written)
        self.assertNotEqual(run.err_seen, [], "a failure tries to say why on stderr")
        self.assertEqual({key: run.err_seen[0][key] for key in written}, dict.fromkeys(written, 0),
                         "the roll-back runs before any message is written; these are the offsets"
                         " at the first write to stderr")

    def assert_refused(self, run, statuses=(1,)):
        self.assertIn(run.status, statuses)
        self.assertEqual(run.fake.sets, [], "zero writes")
        self.assertEqual(run.out, "", "a refusal prints nothing on stdout")

    def assert_all_zero(self, fake):
        self.assertEqual({key: fake.offsets[key] for key in fake.offsets if key[0] in (P0, P1, P2)},
                         {(P0, CORE): 0, (P0, MEM): 0, (P2, CORE): 0, (P2, MEM): 0})

    # 1

    def test_01_get_prints_six_lines_with_p1_unsupported(self):
        run = self.run_scenario("get")
        self.assertEqual(run.out, "p0.core offset=15 min=-1000 max=1000\n"
                                  "p0.mem offset=100 min=-2000 max=6000\n"
                                  "p1.core unsupported\n"
                                  "p1.mem unsupported\n"
                                  "p2.core offset=0 min=-1000 max=900\n"
                                  "p2.mem offset=200 min=-2000 max=5000\n")
        self.assertEqual(run.status, 0)
        self.assertEqual(run.fake.sets, [], "get writes nothing")

    # 2

    def test_02_set_core_120_writes_core_on_p0_and_p2_only(self):
        run = self.run_scenario("set_core_120")
        self.assertEqual(sorted(run.fake.sets), [(CORE, P0, 120, OK), (CORE, P2, 120, OK)])
        self.assertEqual(run.fake.offsets[(P0, MEM)], 100, "mem untouched")
        self.assertEqual(run.fake.offsets[(P2, MEM)], 200, "mem untouched")
        self.assertEqual(run.out, "p0.core offset=120 min=-1000 max=1000\n"
                                  "p1.core unsupported\n"
                                  "p2.core offset=120 min=-1000 max=900\n")
        self.assertEqual(run.status, 0)

    # 3

    def test_03_refuses_set_core_301(self):
        self.assert_refused(self.run_scenario("refuse_core_301"), (1, 2))

    def test_03_refuses_set_mem_2001(self):
        self.assert_refused(self.run_scenario("refuse_mem_2001"), (1, 2))

    def test_03_refuses_set_core_minus_15(self):
        self.assert_refused(self.run_scenario("refuse_core_minus_15"), (1, 2))

    def test_03_refuses_set_core_plus_120(self):
        self.assert_refused(self.run_scenario("refuse_core_plus_120"), (1, 2))

    def test_03_refuses_set_core_0120(self):
        self.assert_refused(self.run_scenario("refuse_core_0120"), (1, 2))

    def test_03_refuses_set_core_12_5(self):
        self.assert_refused(self.run_scenario("refuse_core_12_5"), (1, 2))

    def test_03_refuses_set_core_without_value(self):
        self.assert_refused(self.run_scenario("refuse_core_no_value"), (1, 2))

    def test_03_refuses_set_gfx_100(self):
        self.assert_refused(self.run_scenario("refuse_gfx_100"), (1, 2))

    def test_03_refuses_set_core_100_extra(self):
        self.assert_refused(self.run_scenario("refuse_core_100_extra"), (1, 2))

    # 4

    def test_04_above_card_max_on_p2_only_writes_nothing(self):
        run = self.run_scenario("above_p2_max")
        self.assert_refused(run)
        self.assertEqual(run.fake.offsets[(P0, CORE)], 15, "P0 is not written first")

    # 5

    def test_05_readback_105_after_writing_120_zeroes_everything(self):
        run = self.run_scenario("readback_105")
        self.assertIn((CORE, P2, 120, OK), run.fake.sets, "the fixture's write of 120 on P2 happened")
        self.assert_all_zero(run.fake)
        self.assertEqual(run.status, 1)

    # 6

    def test_06_error_code_on_second_write_zeroes_everything(self):
        run = self.run_scenario("second_write_fails")
        self.assertEqual([code for *_, code in run.fake.sets[:2]], [OK, UNKNOWN],
                         "the fixture's second write failed")
        self.assert_all_zero(run.fake)
        self.assertEqual(run.status, 1)

    # 7

    def test_07_zero_exits_1_when_a_value_stays_nonzero(self):
        run = self.run_scenario("zero_stuck")
        self.assertEqual(run.fake.offsets, {**CARD_OFFSETS, (P0, MEM): 0, (P2, MEM): 0},
                         "P0 core kept 15, every other handled offset is 0")
        self.assertEqual(run.status, 1)

    # 8

    def test_08_gpu_count_0_is_refused(self):
        for name in ("count_0_get", "count_0_set", "count_0_zero"):
            with self.subTest(name):
                self.assert_refused(self.run_scenario(name))

    def test_08_gpu_count_2_is_refused(self):
        for name in ("count_2_get", "count_2_set", "count_2_zero"):
            with self.subTest(name):
                self.assert_refused(self.run_scenario(name))

    # 9

    def test_09_shutdown_exactly_once_in_cases_1_to_8(self):
        for name, (_, _, case) in SCENARIOS.items():
            if case is None or case > 8:
                continue
            with self.subTest(name):
                fake = self.run_scenario(name).fake
                if name not in INIT_OPTIONAL:
                    self.assertEqual(fake.count_of("nvmlInit"), 1)
                    self.assertEqual(fake.count_of("nvmlShutdown"), 1)
                    self.assertEqual(fake.calls[-1], ("nvmlShutdown",), "shutdown is the last call")

    # 10

    def test_10_installed_pynvml_has_every_name_the_helper_uses(self):
        names = set()
        for name in SCENARIOS:
            names |= Run(name).fake.names
        self.assertLessEqual({"_nvmlGetFunctionPointer", "_nvmlCheckReturn"}, names,
                             "the helper reaches the library through the two private names")
        import pynvml
        self.assertIsNone(pynvml.nvmlLib, "the real NVML library is never loaded here")
        self.assertEqual(sorted(n for n in names if not hasattr(pynvml, n)), [],
                         "names the helper uses that %s lacks" % pynvml.__file__)

    def test_10_fake_matches_installed_pynvml(self):
        import pynvml
        fake = FakeNvml()
        for name, mine in sorted(fake.surface.items()):
            with self.subTest(name):
                self.assertTrue(hasattr(pynvml, name), "pynvml has no %s" % name)
                real = getattr(pynvml, name)
                if isinstance(mine, int):
                    self.assertEqual(real, mine)
                elif name == "c_nvmlClockOffset_t":
                    self.assertEqual([(field, kind._type_) for field, kind in real._fields_],
                                     [(field, kind._type_) for field, kind in mine._fields_])
                    self.assertEqual(ctypes.sizeof(real), ctypes.sizeof(mine))
                    self.assertEqual(ctypes.sizeof(real) | 1 << 24, pynvml.nvmlClockOffset_v1)
                elif isinstance(mine, type):
                    self.assertTrue(issubclass(real, pynvml.NVMLError))
                else:
                    self.assertEqual(list(inspect.signature(real).parameters),
                                     list(inspect.signature(mine).parameters))
        for code in sorted(NVMLError._valClassMapping):
            with self.subTest(code=code):
                self.assertEqual(type(pynvml.NVMLError(code)).__name__, type(NVMLError(code)).__name__)
                self.assertEqual(pynvml.NVMLError(code).value, code)
        self.assertIsNone(pynvml.nvmlLib, "the real NVML library is never loaded here")

    # 12 (Amendment 1)

    def test_12_zero_exits_1_when_a_readback_get_fails(self):
        run = self.run_scenario("zero_readback_get_fails")
        self.assertIn((CORE, P0, UNKNOWN), run.fake.gets, "the fixture's failing read-back happened")
        self.assertEqual(run.status, 1)

    # 13 (Amendment 1)

    def test_13_module_without_check_return_is_refused(self):
        run = self.run_scenario("no_check_return")
        self.assert_refused(run)
        self.assertIn("_nvmlCheckReturn", run.err, "the message names the missing name")

    def test_13_module_without_function_pointer_is_refused(self):
        run = self.run_scenario("no_function_pointer")
        self.assert_refused(run)
        self.assertIn("_nvmlGetFunctionPointer", run.err, "the message names the missing name")

    # 14 (Amendment 2)

    def test_14_dead_stderr_does_not_stop_the_roll_back(self):
        for name in ("readback_105_stderr_broken", "readback_105_stderr_closed"):
            with self.subTest(name):
                run = Run(name)
                self.assertIn((CORE, P2, 120, OK), run.fake.sets,
                              "the fixture's write of 120 on P2 happened")
                self.assert_rolled_back(run)
                self.assert_roll_back_came_first(run)

    # 15 (Amendment 2)

    def test_15_dead_stdout_and_stderr_roll_back_a_good_set(self):
        for name in ("set_core_120_streams_broken", "set_core_120_streams_closed"):
            with self.subTest(name):
                run = Run(name)
                self.assertEqual(sorted(run.fake.sets[:2]), [(CORE, P0, 120, OK), (CORE, P2, 120, OK)],
                                 "the fixture's two writes of 120 happened")
                self.assert_rolled_back(run)
                self.assert_roll_back_came_first(run)

    # 16 (Amendment 2)

    def test_16_keyboard_interrupt_in_the_first_roll_back_write_does_not_skip_the_rest(self):
        uninterrupted = Run("readback_105").fake.zeroed
        run = Run("roll_back_interrupted")
        self.assertEqual([mhz for _, _, mhz, _ in run.fake.sets[2:3]], [0],
                         "the third Set call is the first write of the roll-back")
        self.assertEqual(run.fake.count_of("interrupt"), 1, "the fixture's KeyboardInterrupt was raised")
        self.assertEqual(run.fake.zeroed, uninterrupted,
                         "the roll-back writes 0 where it does when nothing interrupts it")
        self.assert_rolled_back(run)

    # 17 (Amendment 2)

    def test_17_keyboard_interrupt_in_the_first_write_of_zero_does_not_skip_the_rest(self):
        run = Run("zero_interrupted")
        self.assertEqual(run.fake.count_of("interrupt"), 1, "the fixture's KeyboardInterrupt was raised")
        self.assertEqual(run.fake.zeroed, {(P0, CORE), (P0, MEM), (P2, CORE), (P2, MEM)},
                         "zero writes 0 on both clocks of every supported pstate")
        self.assert_rolled_back(run)
        self.assert_all_zero(run.fake)

    # 18 (Amendment 2)

    def test_18_runtime_error_from_shutdown_rolls_back_a_good_set(self):
        run = Run("shutdown_raises")
        self.assertEqual(sorted(run.fake.sets[:2]), [(CORE, P0, 120, OK), (CORE, P2, 120, OK)],
                         "the fixture's two writes of 120 happened")
        self.assertIn(("nvmlShutdown.failed", "RuntimeError"), run.fake.calls,
                      "the fixture's nvmlShutdown raised")
        self.assert_rolled_back(run)

    # 19 (Amendment 2)

    def test_19_readback_not_supported_after_the_write_zeroes_p0_and_p2(self):
        run = Run("readback_unsupported")
        self.assertIn((CORE, P2, 120, OK), run.fake.sets, "the fixture's write of 120 on P2 happened")
        self.assertIn((CORE, P2, NOT_SUPPORTED), run.fake.gets,
                      "the fixture's read-back on P2 answered not supported")
        self.assertLessEqual({(P0, CORE), (P2, CORE)}, run.fake.zeroed, "0 is written on P0 and on P2")
        self.assert_rolled_back(run)

    # 20 (Amendment 2)

    def test_20_sigterm_and_sighup_in_the_second_write_roll_back(self):
        for name, sig in (("sigterm_in_second_write", signal.SIGTERM),
                          ("sighup_in_second_write", signal.SIGHUP)):
            with self.subTest(name):
                before = signal.getsignal(sig)
                run = Run(name)
                self.assertIs(signal.getsignal(sig), before, "the handler from before the run is back")
                self.assertIn(("interrupt", 2, sig), run.fake.calls,
                              "the fixture sent %s in the second write" % sig.name)
                self.assertEqual(run.unhandled, [], "main() has its own handler in place before the"
                                 " first write; this signal reached the test's")
                self.assert_rolled_back(run)

    # Rules of the ticket's Interface and of the amendments that have no numbered case.

    def test_amendment_2_zero_writes_go_on_after_one_fails(self):
        with self.subTest("roll_back_write_fails"):
            unfailed = Run("readback_105").fake.zeroed
            run = self.run_scenario("roll_back_write_fails")
            self.assertEqual([(mhz, code) for _, _, mhz, code in run.fake.sets[2:3]], [(0, UNKNOWN)],
                             "the fixture's first write of the roll-back failed")
            self.assertEqual(run.fake.zeroed, unfailed,
                             "the roll-back writes 0 where it does when no write fails")
            self.assertEqual(run.status, 1)
        with self.subTest("zero_write_fails"):
            run = self.run_scenario("zero_write_fails")
            self.assertEqual([(mhz, code) for _, _, mhz, code in run.fake.sets[:1]], [(0, UNKNOWN)],
                             "the fixture's first write failed")
            self.assertEqual(run.fake.zeroed, {(P0, CORE), (P0, MEM), (P2, CORE), (P2, MEM)},
                             "zero writes 0 on both clocks of every supported pstate")
            self.assertEqual(run.status, 1)

    def test_amendment_public_wrappers_are_never_called(self):
        for name in SCENARIOS:
            with self.subTest(name):
                self.assertEqual(Run(name).fake.count_of("wrapper"), 0,
                                 "nvmlDevice{Get,Set}ClockOffsets drop the return code")

    def test_interface_set_core_300_is_inside_the_cap(self):
        run = self.run_scenario("set_core_300")
        self.assertEqual(sorted(run.fake.sets), [(CORE, P0, 300, OK), (CORE, P2, 300, OK)])
        self.assertEqual(run.status, 0)

    def test_interface_set_mem_2000_is_inside_the_cap(self):
        run = self.run_scenario("set_mem_2000")
        self.assertEqual(sorted(run.fake.sets), [(MEM, P0, 2000, OK), (MEM, P2, 2000, OK)])
        self.assertEqual(run.fake.offsets[(P0, CORE)], 15, "core untouched")
        self.assertEqual(run.out, "p0.mem offset=2000 min=-2000 max=6000\n"
                                  "p1.mem unsupported\n"
                                  "p2.mem offset=2000 min=-2000 max=5000\n")
        self.assertEqual(run.status, 0)

    def test_interface_zero_writes_0_on_both_clocks_and_exits_0(self):
        run = self.run_scenario("zero")
        self.assertEqual(sorted(run.fake.sets), [(CORE, P0, 0, OK), (CORE, P2, 0, OK),
                                                 (MEM, P0, 0, OK), (MEM, P2, 0, OK)])
        self.assert_all_zero(run.fake)
        self.assertEqual(run.status, 0)

    def test_interface_init_failure_is_refused(self):
        self.assert_refused(self.run_scenario("init_fails"))

    def test_interface_no_supported_pstate_is_refused(self):
        self.assert_refused(self.run_scenario("nothing_supported"))


def main():
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Contract)
    if HELPER.is_file():
        data = HELPER.read_bytes()
        what = "sha256=%s bytes=%d" % (hashlib.sha256(data).hexdigest(), len(data))
    else:
        what = "missing"
    print("nvml_test: helper=%s %s tests=%d" % (HELPER, what, suite.countTestCases()), flush=True)
    result = unittest.TextTestRunner(stream=sys.stdout, verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
