#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.15"
# dependencies = []
# [tool.uv]
# required-version = ">=0.13"
# ///
"""The game without the editor: a player run headless for 1 and for N frames of
1/60 s, with and without GPU. The difference of the two runs is the cost of
N-1 frames; the run of 1 frame is the start-up. Up to three players: the one
of a checkout of the previous layout (previous: bin/mirai-player with the
modules of demo), the program of the binaries of this engine with the library
play of demo (current: mirai play builds it) and the shipped demo (ship:
mirai build game demo --out <folder>).
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

WINDOWS = sys.platform == "win32"
EXE = ".exe" if WINDOWS else ""
MB = 1024 * 1024
SCENES = ("gallery/main.scene", "control/control.scene", "destruction/destruction.scene")

if WINDOWS:
    import ctypes
    from ctypes import wintypes

    class PROCESS_MEMORY_COUNTERS(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD)] + [
            (name, ctypes.c_size_t) for name in ("PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage",
                                                 "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage",
                                                 "QuotaNonPagedPoolUsage", "PagefileUsage", "PeakPagefileUsage")]

    _kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _kernel32.OpenProcess.restype = wintypes.HANDLE
    _kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    _kernel32.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
    _kernel32.K32GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(PROCESS_MEMORY_COUNTERS), wintypes.DWORD]
    _kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    PROCESS_VM_READ = 0x0010


def rounded(value: float, digits: int) -> float:
    """Half to even on the scaled value."""
    scale = 10**digits
    return round(value * scale) / scale


def wait_measured(process: subprocess.Popen) -> tuple[int, float, float]:
    """Waits for the child and returns its exit code, the milliseconds of
    processor it used and the peak of its resident memory in bytes."""
    if WINDOWS:
        handle = _kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, False, process.pid)
        code = process.wait()
        times = [wintypes.FILETIME() for _ in range(4)]
        _kernel32.GetProcessTimes(handle, *(ctypes.byref(t) for t in times))
        counters = PROCESS_MEMORY_COUNTERS(cb=ctypes.sizeof(PROCESS_MEMORY_COUNTERS))
        _kernel32.K32GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb)
        _kernel32.CloseHandle(handle)
        hundreds = sum(t.dwHighDateTime << 32 | t.dwLowDateTime for t in times[2:])
        return code, hundreds / 10_000, counters.PeakWorkingSetSize
    _, status, usage = os.wait4(process.pid, 0)
    process.returncode = os.waitstatus_to_exitcode(status)
    # ru_maxrss is in kilobytes on Linux and in bytes on macOS.
    peak = usage.ru_maxrss if sys.platform == "darwin" else usage.ru_maxrss * 1024
    return process.returncode, (usage.ru_utime + usage.ru_stime) * 1000, peak


def player_run(args, engine: str, scene: str, gpu: bool, frames: int) -> dict:
    match engine:
        case "previous":
            exe, cwd, arguments = Path(args.previous_root) / "bin" / f"mirai-player{EXE}", args.previous_root, ["demo"]
        case "current":
            exe, cwd, arguments = Path(args.current_root) / ".mirai" / "engine" / "release" / f"mirai-player{EXE}", args.current_root, ["--project", "demo"]
        case _:
            exe, cwd, arguments = Path(args.ship_folder) / f"Demo{EXE}", args.ship_folder, []
    arguments += ["--scene", scene, "--headless", "--frames", str(frames)]
    if not gpu:
        arguments.append("--no-gpu")
    environment = dict(os.environ)
    environment["VK_LAYER_PATH"] = ""
    environment.pop("VK_INSTANCE_LAYERS", None)
    with tempfile.TemporaryFile() as output:
        started = time.perf_counter()
        process = subprocess.Popen([str(exe), *arguments], cwd=cwd, env=environment, stdout=output, stderr=output)
        code, cpu, peak = wait_measured(process)
        wall = (time.perf_counter() - started) * 1000
        if code != 0:
            output.seek(0)
            raise RuntimeError(f"{engine} {scene} exited {code}: {output.read().decode(errors='replace').strip()}")
    return {"wall": wall, "cpu": cpu, "peak_mb": rounded(peak / MB, 1)}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--previous-root", help="checkout of the previous layout; without it the previous player is skipped")
    parser.add_argument("--current-root", default=str(Path(__file__).resolve().parent.parent))
    parser.add_argument("--ship-folder", help="folder of mirai build game demo --out; without it the shipped demo is skipped")
    parser.add_argument("--frames", type=int, default=601)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    engines = [e for e, given in (("previous", args.previous_root), ("current", True), ("ship", args.ship_folder)) if given]
    for scene in SCENES:
        for gpu in (True, False):
            for _ in range(args.runs):
                for engine in engines:
                    try:
                        one = player_run(args, engine, scene, gpu, 1)
                        many = player_run(args, engine, scene, gpu, args.frames)
                        line = {"engine": engine, "scene": scene, "gpu": gpu, "frames": args.frames,
                                "start_wall_ms": rounded(one["wall"], 1), "start_cpu_ms": rounded(one["cpu"], 1),
                                "frame_wall_ms": rounded((many["wall"] - one["wall"]) / (args.frames - 1), 3),
                                "frame_cpu_ms": rounded((many["cpu"] - one["cpu"]) / (args.frames - 1), 3),
                                "peak_mb": many["peak_mb"]}
                    except (OSError, RuntimeError) as error:
                        line = {"engine": engine, "scene": scene, "gpu": gpu, "error": str(error)}
                    text = json.dumps(line, separators=(",", ":"))
                    with open(args.out, "a", encoding="utf-8", newline="\n") as out:
                        out.write(text + "\n")
                    print(text)


if __name__ == "__main__":
    main()
