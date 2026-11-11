#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.15"
# dependencies = ["psutil>=6"]
# [tool.uv]
# required-version = ">=0.13"
# ///
"""Build times of two checkouts of the engine, measured in alternated pairs:
each step runs on one checkout and then on the other, and the next round
starts with the other one. For each run it keeps the wall time, the
processor time of every process the run started (user and system: the
compiler, the linker, slangc, the mirai tool), the mean load of the machine
while it ran and what mirai printed. The phases steps run the compiler
directly with -show-more-timings and keep its phases.

Steps (--steps, comma separated; all of them by default):
  shaders_cold        the engine's shaders without output, stamp or caches
  shaders_cached      the same with the caches a new checkout gets
  engine_fast_force   mirai build engine --force
  engine_speed_force  mirai build engine --release --force
  editor_fast         a comment appended to editor/editor.odin, then mirai build engine
  editor_speed        the same with --release
  demo_shaders_cold   the first shader generation of the demo
  demo_speed          the library of the demo at -o:speed, its stamp removed
  noop_turn_held      mirai build editor demo --release without changes while this script holds
                      the build turn for --hold seconds
  phases_demo         the compiler on the library of the demo at -o:speed, by phases
  phases_runtime      the compiler on the mirai-engine library at -o:speed from its stage, by phases

shaders_cold removes the shared shader cache of the repository
(<main>/.mirai/cache/shaders): run it when no other checkout depends on it.

Usage: uv run scripts/bench_build.py --before <checkout> --after <checkout>
       [--rounds 2] [--steps a,b] [--hold 25] [--out bin/bench-build]
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import psutil

WINDOWS = sys.platform == "win32"
EXE = ".exe" if WINDOWS else ""
STEPS = ("shaders_cold", "shaders_cached", "engine_fast_force", "engine_speed_force", "editor_fast",
         "editor_speed", "demo_shaders_cold", "demo_speed", "noop_turn_held", "phases_demo", "phases_runtime")

if WINDOWS:
    import ctypes
    from ctypes import wintypes

    class JOB_ACCOUNTING(ctypes.Structure):
        _fields_ = [("TotalUserTime", ctypes.c_int64), ("TotalKernelTime", ctypes.c_int64),
                    ("ThisPeriodTotalUserTime", ctypes.c_int64), ("ThisPeriodTotalKernelTime", ctypes.c_int64),
                    ("TotalPageFaultCount", wintypes.DWORD), ("TotalProcesses", wintypes.DWORD),
                    ("ActiveProcesses", wintypes.DWORD), ("TotalTerminatedProcesses", wintypes.DWORD)]

    _kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _kernel32.CreateJobObjectW.restype = wintypes.HANDLE
    _kernel32.CreateJobObjectW.argtypes = [wintypes.LPVOID, wintypes.LPCWSTR]
    _kernel32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    _kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    _kernel32.QueryInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID, wintypes.DWORD, wintypes.LPVOID]
else:
    import fcntl
    import resource


class Processor:
    """Processor seconds of every process this one started, whether it
    ended or not: a job object on Windows, which the children join when they
    start; on other systems, what the waited children used."""

    def __init__(self):
        self.job = None
        if WINDOWS:
            self.job = _kernel32.CreateJobObjectW(None, None)
            if not self.job or not _kernel32.AssignProcessToJobObject(self.job, _kernel32.GetCurrentProcess()):
                raise SystemExit("bench_build: this process could not join a job object to count its children")

    def seconds(self) -> float:
        if WINDOWS:
            info = JOB_ACCOUNTING()
            if not _kernel32.QueryInformationJobObject(self.job, 1, ctypes.byref(info), ctypes.sizeof(info), None):
                raise SystemExit("bench_build: the job object could not be read")
            own = psutil.Process().cpu_times()
            return (info.TotalUserTime + info.TotalKernelTime) / 1e7 - own.user - own.system
        usage = resource.getrusage(resource.RUSAGE_CHILDREN)
        return usage.ru_utime + usage.ru_stime


class Load:
    """The mean load of the machine while it runs, in percent."""

    def __init__(self):
        self.samples: list[float] = []
        self.done = threading.Event()
        psutil.cpu_percent(None)
        self.thread = threading.Thread(target=self.sample, daemon=True)
        self.thread.start()

    def sample(self):
        while not self.done.wait(0.5):
            self.samples.append(psutil.cpu_percent(None))

    def stop(self) -> float:
        self.done.set()
        self.thread.join()
        return sum(self.samples) / len(self.samples) if self.samples else psutil.cpu_percent(None)


def main_checkout(checkout: Path) -> Path:
    common = subprocess.run(["git", "-C", str(checkout), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True, check=True).stdout.strip()
    return Path(common).parent


def compiler(checkout: Path) -> Path:
    if os.environ.get("MIRAI_ODIN"):
        return Path(os.environ["MIRAI_ODIN"])
    for deps in (checkout / ".deps", main_checkout(checkout) / ".deps"):
        for folder in ("odin/dist", "linux-amd64/odin", "odin"):
            if (found := deps / folder / f"odin{EXE}").is_file():
                return found
    return Path(shutil.which("odin") or "odin")


def attributes(checkout: Path) -> str:
    text = (checkout / "cook/build/world.odin").read_text(encoding="utf-8")
    return re.search(r'CUSTOM_ATTRIBUTES :: "([^"]+)"', text).group(1)


def remove(*paths: Path):
    for path in paths:
        if path.is_dir():
            shutil.rmtree(path, ignore_errors=True)
        elif path.exists():
            path.unlink()


class Bench:
    def __init__(self, args):
        self.args = args
        self.processor = Processor()
        self.runs: list[dict] = []
        self.bash = shutil.which("bash") or shutil.which("sh") or "sh"
        self.checkouts = {"before": args.before.resolve(), "after": args.after.resolve()}
        self.report = args.out / time.strftime("build-%Y%m%d-%H%M%S.json")

    def save(self):
        """The report as it is, after every run: an interrupted bench keeps what it measured."""
        self.args.out.mkdir(parents=True, exist_ok=True)
        self.report.write_text(json.dumps({"checkouts": {side: str(path) for side, path in self.checkouts.items()},
                                           "runs": self.runs}, indent=1, ensure_ascii=False), encoding="utf-8")

    def mirai(self, checkout: Path, *arguments: str) -> str:
        done = subprocess.run([self.bash, str(checkout / "mirai"), *arguments], cwd=checkout,
                              capture_output=True, text=True, encoding="utf-8", errors="replace")
        return (done.stdout + done.stderr).strip()

    def measure(self, step: str, side: str, run, *, prepare=None, after=None) -> dict:
        if prepare:
            prepare()
        load = Load()
        processor = self.processor.seconds()
        started = time.perf_counter()
        output, phases = run()
        wall = time.perf_counter() - started
        cpu = self.processor.seconds() - processor
        record = {"step": step, "side": side, "wall_s": round(wall, 1), "cpu_s": round(cpu, 1),
                  "load_pct": round(load.stop()), "output": output, "phases": phases}
        if after:
            after()
        self.runs.append(record)
        self.save()
        shown = " ".join(f"{name} {seconds:.1f}" for name, seconds in phases.items())
        print(f"{step:20} {side:6} wall {record['wall_s']:7.1f} s  cpu {record['cpu_s']:7.1f} s  "
              f"load {record['load_pct']:3d} %  {shown or reported(output)}", flush=True)
        return record

    def step(self, step: str, side: str, checkout: Path):
        root = main_checkout(checkout)
        demo = checkout / "demo"
        tables = (checkout / "shaders/build", checkout / "render/shaders_gen.odin", checkout / "rhi/shaders_gen_test.odin")
        mirai = lambda *a: (lambda: (self.mirai(checkout, *a), {}))
        match step:
            case "shaders_cold":
                self.measure(step, side, mirai("shaders"),
                             prepare=lambda: remove(*tables, checkout / ".mirai/shader-cache", root / ".mirai/cache/shaders"))
            case "shaders_cached":
                # What a new checkout has: a copy of the cache of its origin, or the shared
                # one, which a cold run of the other checkout may have emptied.
                self.measure(step, side, mirai("shaders"),
                             prepare=lambda: (self.mirai(checkout, "shaders"),
                                              remove(*tables, checkout / ".mirai/shader-cache/generation.json")))
            case "engine_fast_force" | "engine_speed_force":
                self.measure(step, side, mirai("build", "engine", "--" + step.split("_")[1], "--force"))
            case "editor_fast" | "editor_speed":
                mode = "--" + step.split("_")[1]
                source = checkout / "editor/editor.odin"
                text = source.read_bytes()

                def touch():
                    self.mirai(checkout, "build", "engine", mode)
                    source.write_bytes(text + f"\n// bench_build {time.time_ns()}\n".encode())

                def restore():
                    source.write_bytes(text)
                    self.mirai(checkout, "build", "engine", mode)
                self.measure(step, side, mirai("build", "engine", mode), prepare=touch, after=restore)
            case "demo_shaders_cold":
                self.measure(step, side, mirai("build", "editor", "demo", "--release"),
                             prepare=lambda: (self.mirai(checkout, "build", "engine", "--release"),
                                              remove(demo / ".mirai/shaders", demo / ".mirai/shader-cache", root / ".mirai/cache/shaders")))
            case "demo_speed":
                self.measure(step, side, mirai("build", "editor", "demo", "--release"),
                             prepare=lambda: (self.mirai(checkout, "build", "editor", "demo", "--release"),
                                              remove(demo / ".mirai/build/editor.stamp")))
            case "noop_turn_held":
                self.mirai(checkout, "build", "editor", "demo", "--release")
                release = self.hold(root)
                self.measure(step, side, mirai("build", "editor", "demo", "--release"), after=release.join)
            case "phases_demo" | "phases_runtime":
                self.mirai(checkout, "build", "editor", "demo", "--release")
                self.measure(step, side, lambda: self.phases(checkout, step == "phases_demo"))

    def hold(self, root: Path) -> threading.Timer:
        """Takes the turn of the builds for --hold seconds; the timer gives it back."""
        lock = root / ".mirai/cache/locks/build.lock"
        lock.parent.mkdir(parents=True, exist_ok=True)
        # Another build may have it open: wait for it, as mirai does.
        while True:
            try:
                holder = open(lock, "a+b")
                break
            except PermissionError:
                time.sleep(0.25)
        if not WINDOWS:
            fcntl.lockf(holder, fcntl.LOCK_EX)
        lock.with_name("build.lock.owner").write_text("bench_build: holding the turn to time a build without changes")
        release = threading.Timer(self.args.hold, holder.close)
        release.start()
        return release

    def phases(self, checkout: Path, demo: bool) -> tuple[str, dict]:
        """The compiler run alone, as mirai runs it, with -show-more-timings."""
        release = checkout / ".mirai" / "engine" / "release"
        attribute = f"-custom-attribute:{attributes(checkout)}"
        with tempfile.TemporaryDirectory(prefix="bench-build-") as folder:
            timings = Path(folder) / "timings.json"
            if demo:
                project = checkout / "demo"
                command = [str(compiler(checkout)), "build", str(project / ".mirai/gen/editor"), "-build-mode:dll",
                           "-o:speed", f"-collection:mirai={release / 'decl'}",
                           f"-collection:project={project}", f"-collection:plugins={checkout / 'plugins'}",
                           f"-collection:generated={project / '.mirai/gen'}", attribute]
            else:
                stage = release / "stage-engine"
                command = [str(compiler(checkout)), "build", str(stage / "__mirai_engine"), "-build-mode:dll",
                           f"-collection:mirai={stage}", "-o:speed", "-debug", attribute]
            command += [f"-out:{Path(folder) / ('editor' if demo else 'mirai-engine')}.dll", "-show-more-timings",
                        "-export-timings:json", f"-export-timings-file:{timings}"]
            done = subprocess.run(command, cwd=checkout, capture_output=True, text=True, encoding="utf-8", errors="replace")
            if done.returncode != 0:
                return (done.stdout + done.stderr).strip()[-2000:], {}
            millis = {name: float(value) / 1000 for name, value in
                      re.findall(r'"name": "([^"]*)", "millis": ([0-9.]+)', timings.read_text(encoding="utf-8", errors="replace"))}
        objects = sum(seconds for name, seconds in millis.items() if name.startswith("LLVM Object Generation"))
        objects += sum(seconds for name, seconds in millis.items() if name.startswith("LLVM Generate Object"))
        link = sum(seconds for name, seconds in millis.items() if name.endswith("-link"))
        phases = {"total": millis.get("Total Time", 0),
                  "front": millis.get("initialization", 0) + millis.get("parse files", 0) + millis.get("type check", 0),
                  "procedures": millis.get("LLVM Procedure Generation", 0),
                  "module_passes": millis.get("LLVM Module Pass and Verification", 0),
                  "objects": objects, "link": link}
        return "", {name: round(seconds, 1) for name, seconds in phases.items()}


def reported(output: str) -> str:
    """What mirai said a build took, or the counts of a shader generation."""
    return "; ".join(re.findall(r"ready \([^)]*\)|\(\d+ compiled, \d+ reused\)|unchanged|copied from the shared cache", output))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--steps", default=",".join(STEPS))
    parser.add_argument("--hold", type=float, default=25)
    parser.add_argument("--out", type=Path, default=Path("bin/bench-build"))
    args = parser.parse_args()
    steps = [step for step in args.steps.split(",") if step]
    unknown = [step for step in steps if step not in STEPS]
    if unknown:
        parser.error(f"unknown steps: {', '.join(unknown)}")
    bench = Bench(args)
    checkouts = bench.checkouts
    for side, checkout in checkouts.items():
        print(f"preparing {side}: {checkout}", flush=True)
        for arguments in (("help",), ("deps",), ("build", "engine"), ("build", "engine", "--release"),
                          ("build", "editor", "demo", "--release")):
            bench.mirai(checkout, *arguments)
    for step in steps:
        for round in range(args.rounds):
            order = ("before", "after") if round % 2 == 0 else ("after", "before")
            for side in order:
                bench.step(step, side, checkouts[side])
    bench.save()
    print(f"\n{bench.report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
