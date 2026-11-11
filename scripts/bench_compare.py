#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.15"
# dependencies = ["psutil>=7,<8"]
# [tool.uv]
# required-version = ">=0.13"
# ///
"""Measures one run of an editor build through its JSON-RPC API and appends the
result as one JSON line; the scenario report turns those lines into tables.
The steps run on the editor of the --release binaries of a checkout
(.mirai/engine/release/mirai-editor), this one or --engine-root, so that the
numbers of two checkouts compare.

  demo          start-up, memory, idle view, an entity moved every frame, a selection, Play
  scale         a grid of --cubes cubes: load, idle view, an entity moved every frame
  playgpu       the GPU by pass in the view of the editor and in Play
  batch         scene.write of 64 cubes as the scene grows to --cubes
  simulation    floor, collider-only wall and dynamic box
  physics       native CCD or destruction wall benchmark without editor or GPU
  netpublish    entity state publication without solver, GPU or connected clients
  fade          one Material_Values.color alpha changed in a grid of --cubes cubes
  particles     four emitters of 25 000 particles a second, additive and unlit, then blended and lit
  particlelights  four emitters of 256 particle lights each, casting shadows and then not
  terrain       hover and held sculpt on a terrain fixture supplied by --scene
  presentation  samples an already running windowed editor, without changing it
  probe         lists the entities and what a click at the center selects
  report        tables of the medians of every run in --out, one column per --variant
"""

import argparse
import json
import math
import os
import re
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

import psutil

WINDOWS = sys.platform == "win32"
EXE = ".exe" if WINDOWS else ""
MB = 1024 * 1024
MATERIALS = [
    ("Tiles", "e3ff821135c2ceb379654a44d06379dd"),
    ("Bricks", "23a7463a595b0a31475362822eb57023"),
    ("Planks", "5cea425e5034e377b537680bec953e05"),
    ("Marble", "3b4cb4195321a2f7fe61aa57ece0c255"),
]
GRID_SPACING = 1.5
RUN_FRAMES = 120
RUNS = 4
CENTER = [720, 470]
CLICK = {"events": [{"mouse_position": CENTER}, {"mouse_position": CENTER, "mouse_buttons": ["left"], "clicks": 1},
                    {"mouse_position": CENTER}, {}]}


class BenchError(Exception):
    pass


if WINDOWS:
    import ctypes
    import winreg
    from ctypes import wintypes

    _kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _kernel32.OpenProcess.restype = wintypes.HANDLE
    _kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    _kernel32.OpenThread.restype = wintypes.HANDLE
    _kernel32.OpenThread.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    _kernel32.QueryThreadCycleTime.argtypes = [wintypes.HANDLE, ctypes.POINTER(ctypes.c_ulonglong)]
    _kernel32.QueryProcessCycleTime.argtypes = [wintypes.HANDLE, ctypes.POINTER(ctypes.c_ulonglong)]
    _kernel32.GetThreadTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
    _kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    THREAD_QUERY_LIMITED_INFORMATION = 0x0800


class CpuClock:
    """Milliseconds of processor of the main thread and of the whole process so far.

    On Windows they are cycles, exact where the processor times of the system
    advance in steps of 15.6 ms; on Linux the main thread is the run time of
    its scheduler, in nanoseconds.
    """

    def __init__(self, pid: int):
        self.pid = pid
        if not WINDOWS:
            return
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"HARDWARE\DESCRIPTION\System\CentralProcessor\0") as key:
            self.cycles_per_ms = float(winreg.QueryValueEx(key, "~MHz")[0]) * 1000
        self.process = _kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        # The thread that started first is the one that runs the frames.
        self.thread, first = None, None
        for thread in psutil.Process(pid).threads():
            handle = _kernel32.OpenThread(THREAD_QUERY_LIMITED_INFORMATION, False, thread.id)
            if not handle:
                continue
            times = [wintypes.FILETIME() for _ in range(4)]
            _kernel32.GetThreadTimes(handle, *(ctypes.byref(t) for t in times))
            created = times[0].dwHighDateTime << 32 | times[0].dwLowDateTime
            if first is None or created < first:
                if self.thread:
                    _kernel32.CloseHandle(self.thread)
                self.thread, first = handle, created
            else:
                _kernel32.CloseHandle(handle)
        if not self.process or not self.thread:
            raise BenchError("could not open the process and the main thread of the engine")

    def now(self) -> tuple[float, float]:
        if WINDOWS:
            thread, process = ctypes.c_ulonglong(), ctypes.c_ulonglong()
            _kernel32.QueryThreadCycleTime(self.thread, ctypes.byref(thread))
            _kernel32.QueryProcessCycleTime(self.process, ctypes.byref(process))
            return thread.value / self.cycles_per_ms, process.value / self.cycles_per_ms
        process = psutil.Process(self.pid)
        times = process.cpu_times()
        total = (times.user + times.system) * 1000
        if sys.platform == "linux":
            with open(f"/proc/{self.pid}/task/{self.pid}/schedstat") as stat:
                return int(stat.read().split()[0]) / 1e6, total
        main = process.threads()[0]
        return (main.user_time + main.system_time) * 1000, total

    def close(self):
        if WINDOWS:
            _kernel32.CloseHandle(self.thread)
            _kernel32.CloseHandle(self.process)


@dataclass
class Bench:
    args: argparse.Namespace
    root: Path
    variant: str
    preset: str
    process: subprocess.Popen | None = None
    clock: CpuClock | None = None


def rounded(value: float, digits: int) -> float:
    """Half to even on the scaled value."""
    scale = 10**digits
    return round(value * scale) / scale


def num(value) -> str:
    text = f"{float(value):.6f}".rstrip("0").rstrip(".")
    return "0" if text == "-0" else text


def number(value) -> float:
    return 0.0 if value is None else float(value)


def cpu_field(status: dict, name: str) -> float:
    return number((status.get("cpu") or {}).get(name))


def median(values) -> float:
    return statistics.median(values) if values else 0.0


def mean(values) -> float:
    return statistics.fmean(values) if values else 0.0


def rpc(b: Bench, method: str, params=None, timeout: float = 600):
    """One request per connection, sent in a single write without Nagle: the
    time of a call is the one of the editor, not of a delayed acknowledgement."""
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": {} if params is None else params}).encode()
    head = (f"POST /rpc HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode()
    data, end, length = bytearray(), -1, -1
    try:
        with socket.create_connection(("127.0.0.1", b.args.port), timeout=timeout) as connection:
            connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            connection.sendall(head + body)
            while chunk := connection.recv(65536):
                data += chunk
                if end < 0 and (at := data.find(b"\r\n\r\n")) >= 0:
                    end = at + 4
                    if match := re.search(rb"(?i)content-length:\s*(\d+)", data[:at]):
                        length = int(match[1])
                if end >= 0 and length >= 0 and len(data) >= end + length:
                    break
    except OSError as error:
        raise BenchError(f"{method}: no answer ({error})") from error
    if end < 0:
        raise BenchError(f"{method}: no answer")
    answer = json.loads(data[end:end + length] if length >= 0 else data[end:])
    if answer.get("error"):
        raise BenchError(f"{method}: {answer['error'].get('message')}")
    return answer.get("result")


def port_open(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.025):
            return True
    except OSError:
        return False


def step(b: Bench, frames: int):
    rpc(b, "engine.step", {"frames": frames, "dt": 0.016666668})


def engine_start(b: Bench, extra=()) -> dict:
    args = b.args
    if port_open(args.port):
        raise BenchError(f"port {args.port} is in use")
    # The binaries of --release: those of dev (-o:minimal) measure the compiler, not the engine.
    folder = b.root / ".mirai" / "engine" / "release"
    if not args.exe and not (folder / "engine.stamp").is_file():
        raise BenchError(f"the engine of {b.root} has no --release binaries: run mirai build engine --release before measuring")
    window = ["--headless", "--api-port", str(args.port), "--width", "1440", "--height", "900"]
    exe = Path(args.exe) if args.exe else folder / f"mirai-editor{EXE}"
    arguments = ["--project", "demo", *window]
    environment = dict(os.environ)
    environment["VK_LAYER_PATH"] = ""
    environment.pop("VK_INSTANCE_LAYERS", None)
    started = time.perf_counter()
    b.process = subprocess.Popen([str(exe), *arguments, *extra], cwd=b.root, env=environment)
    try:
        while not port_open(args.port):
            if b.process.poll() is not None:
                raise BenchError(f"the engine ended with code {b.process.returncode}")
            if time.perf_counter() - started > 180:
                raise BenchError("the engine did not open its API")
            time.sleep(0.005)
        ready = (time.perf_counter() - started) * 1000
        step(b, 1)
        first = (time.perf_counter() - started) * 1000
        b.clock = CpuClock(b.process.pid)
    except BaseException:
        b.process.kill()
        b.process.wait()
        raise
    return {"ready_ms": ready, "first_frame_ms": first}


def engine_stop(b: Bench):
    if b.clock:
        b.clock.close()
        b.clock = None
    try:
        rpc(b, "engine.shutdown", {"discard": True}, 20)
    except BenchError:
        pass
    try:
        b.process.wait(20)
    except subprocess.TimeoutExpired:
        b.process.kill()
        b.process.wait()


def passes_add(table: dict, status: dict):
    for timing in status.get("gpu_timings") or []:
        if timing.get("name"):
            table.setdefault(timing["name"], []).append(number(timing.get("ms")))


def parts_add(table: dict, status: dict):
    for name, value in (status.get("cpu") or {}).items():
        table.setdefault(name, []).append(number(value))


def functions_add(table: dict, status: dict):
    for entry in status.get("functions") or []:
        if entry.get("name"):
            table.setdefault(entry["name"], []).append(number(entry.get("ms")))


def medians(table: dict) -> dict:
    return {key: rounded(median(values), 4) for key, values in table.items()}


def means(table: dict) -> dict:
    return {key: rounded(mean(values), 4) for key, values in table.items()}


def frames_alone(b: Bench, table: dict) -> tuple[list[float], dict]:
    """Frames alone after a pause, which never wait for the GPU: their app_ms is
    the time the main thread worked, by part."""
    alone, status = [], {}
    for _ in range(30):
        time.sleep(0.04)
        step(b, 1)
        status = rpc(b, "engine.status")
        alone.append(cpu_field(status, "app_ms"))
        parts_add(table, status)
    return alone, status


def measure_view(b: Bench, prefix: str, metrics: dict, passes: dict, parts: dict):
    """Frames one after another: the pace of the editor without a frame limit, the
    GPU at its working clock, and the processor the main thread and the process
    used for each. Then frames alone."""
    walls = []
    cpu = b.clock.now()
    for _ in range(RUNS):
        started = time.perf_counter()
        step(b, RUN_FRAMES)
        walls.append((time.perf_counter() - started) * 1000 / RUN_FRAMES)
    used = b.clock.now()
    frames = RUNS * RUN_FRAMES
    gpu, table = [], {}
    for _ in range(8):
        step(b, 30)
        status = rpc(b, "engine.status")
        gpu.append(number(status.get("gpu_ms")))
        passes_add(table, status)
    cpu_table = {}
    alone, status = frames_alone(b, cpu_table)
    metrics[f"{prefix}_wall_ms"] = rounded(median(walls), 3)
    metrics[f"{prefix}_main_thread_ms"] = rounded((used[0] - cpu[0]) / frames, 3)
    metrics[f"{prefix}_process_ms"] = rounded((used[1] - cpu[1]) / frames, 3)
    metrics[f"{prefix}_gpu_ms"] = rounded(median(gpu), 3)
    metrics[f"{prefix}_frame_alone_ms"] = rounded(median(alone), 3)
    metrics[f"{prefix}_frame_alone_mean_ms"] = rounded(mean(alone), 3)
    passes[prefix] = medians(table)
    parts[prefix] = medians(cpu_table)
    parts[f"{prefix}_mean"] = means(cpu_table)
    metrics[f"{prefix}_instances"] = int(status.get("instances") or 0)
    metrics[f"{prefix}_visible_instances"] = int(status.get("visible_instances") or 0)


def merge(*entities: dict) -> dict:
    """The params of a scene.write that adds or changes these entities and leaves the rest."""
    return {"merge": True, "entities": list(entities)}


def move_params(entity, position, offset: float) -> dict:
    return merge({"id": entity, "position": [position[0] + offset, position[1], position[2]]})


def measure_move(b: Bench, prefix: str, entity, position, metrics: dict, passes: dict, parts: dict):
    alone, edits, cpu_table = [], [], {}
    for i in range(1, 41):
        time.sleep(0.04)
        started = time.perf_counter()
        rpc(b, "scene.write", move_params(entity, position, 0.01 * i))
        edits.append((time.perf_counter() - started) * 1000)
        step(b, 1)
        status = rpc(b, "engine.status")
        alone.append(cpu_field(status, "app_ms"))
        parts_add(cpu_table, status)
    gpu, table = [], {}
    frames = 240
    cpu = b.clock.now()
    started = time.perf_counter()
    for i in range(1, frames + 1):
        rpc(b, "scene.write", move_params(entity, position, 0.4 - 0.002 * i))
        step(b, 1)
        if i % 30 == 0:
            status = rpc(b, "engine.status")
            gpu.append(number(status.get("gpu_ms")))
            passes_add(table, status)
    wall = (time.perf_counter() - started) * 1000
    used = b.clock.now()
    metrics[f"{prefix}_wall_ms"] = rounded(wall / frames, 3)
    metrics[f"{prefix}_main_thread_ms"] = rounded((used[0] - cpu[0]) / frames, 3)
    metrics[f"{prefix}_process_ms"] = rounded((used[1] - cpu[1]) / frames, 3)
    metrics[f"{prefix}_gpu_ms"] = rounded(median(gpu), 3)
    metrics[f"{prefix}_frame_alone_ms"] = rounded(median(alone), 3)
    metrics[f"{prefix}_frame_alone_mean_ms"] = rounded(mean(alone), 3)
    metrics[f"{prefix}_edit_call_ms"] = rounded(median(edits), 3)
    passes[prefix] = medians(table)
    parts[prefix] = medians(cpu_table)
    parts[f"{prefix}_mean"] = means(cpu_table)


def private_mb(process: psutil.Process) -> float:
    private = process.memory_info().private if WINDOWS else process.memory_full_info().uss
    return rounded(private / MB, 1)


def memory_add(b: Bench, prefix: str, metrics: dict):
    process = psutil.Process(b.process.pid)
    metrics[f"{prefix}_working_set_mb"] = rounded(process.memory_info().rss / MB, 1)
    metrics[f"{prefix}_private_mb"] = private_mb(process)


def configure(b: Bench):
    rpc(b, "settings.set", {"graphics_preset": b.preset.capitalize(),
                            "settings": {"Graphics_Settings": {"frame_limit": 0, "vsync": False}}})


def moved_entity(b: Bench):
    """The entity the demo moves: the first one named --moved."""
    for entity in rpc(b, "scene.inspect", {"limit": 4096})["entities"]:
        if str(entity.get("name", "")).casefold() == b.args.moved.casefold():
            return entity["id"], entity["position"]
    raise BenchError(f"no entity named {b.args.moved}")


def scene_extra(b: Bench) -> list[str]:
    return ["--scene", b.args.scene] if b.args.scene else []


def result_write(b: Bench, metrics: dict, passes: dict, parts: dict):
    args = b.args
    line = {"scenario": args.scenario, "variant": b.variant, "preset": b.preset,
            "cubes": args.cubes, "scene": args.scene, "terrain_target": args.terrain_target,
            "metrics": metrics, "passes": passes, "cpu": parts}
    with open(args.out, "a", encoding="utf-8", newline="\n") as out:
        out.write(json.dumps(line, separators=(",", ":")) + "\n")
    for key in sorted(metrics, key=str.casefold):
        print(f"{key:<34} {num(metrics[key])}")


def scenario_playgpu(b: Bench):
    """GPU by pass in the editor view and in Play, with frames one after another."""
    metrics, passes, parts = {}, {}, {}
    engine_start(b, scene_extra(b))
    try:
        configure(b)
        step(b, 300)
        for state in ("edit", "play"):
            if state == "play":
                rpc(b, "play.start")
                step(b, 300)
            table, gpu, cpu_table, status = {}, [], {}, {}
            for _ in range(8):
                step(b, 30)
                status = rpc(b, "engine.status")
                gpu.append(number(status.get("gpu_ms")))
                passes_add(table, status)
                parts_add(cpu_table, status)
            metrics[f"{state}_gpu_ms"] = rounded(median(gpu), 3)
            metrics[f"{state}_instances"] = int(status.get("instances") or 0)
            metrics[f"{state}_visible_instances"] = int(status.get("visible_instances") or 0)
            metrics[f"{state}_lights"] = int(status.get("lights") or 0)
            passes[state] = medians(table)
            parts[state] = medians(cpu_table)
        result_write(b, metrics, passes, parts)
    finally:
        engine_stop(b)


PARTICLE_VARIANTS = {
    "additive": {"blend": "Additive", "lit": False},
    "lit": {"blend": "Alpha", "lit": True},
}


def scenario_particles(b: Bench):
    """Four emitters of 25 000 particles a second with a life of one second
    (100 000 alive), spheres of 0.5 m and sprites of 5 to 8 cm, from the camera
    of the measurements of particles: the GPU of the simulation and of the
    sprites by pass, over 300 frames after 120 to settle."""
    metrics, passes, parts = {}, {}, {}
    engine_start(b, scene_extra(b))
    try:
        configure(b)
        rpc(b, "camera.set", {"position": [0, 2.2, 8.5], "target": [0, 1.1, 0]})
        emitters = []
        for index in range(4):
            added = rpc(b, "scene.write", merge({"preset": "particles", "name": f"Bench particles {index}",
                                                 "position": [index * 1.5 - 2.25, 1.1, 0]}))
            emitters.append(added["id"])
        for variant, look in PARTICLE_VARIANTS.items():
            for entity in emitters:
                rpc(b, "particle.instance.set", {"id": entity, "values": {
                    "rate": 25000, "lifetime": [1, 1], "shape": "Sphere", "shape_size": [0.5, 0.5, 0.5],
                    "shell": 0, "speed": [0, 0], "size": [0.05, 0.08], "gravity": 0, **look}})
            step(b, 120)
            summary = rpc(b, "profile.capture", {"frames": 300, "advance": True, "top": 64}, 1200)
            frame = summary.get("frame") or {}
            metrics[f"{variant}_gpu_ms"] = rounded(number(frame.get("gpu_ms")), 3)
            metrics[f"{variant}_frame_ms"] = rounded(number(frame.get("p50_ms")), 3)
            metrics[f"{variant}_cpu_ms"] = rounded(number(frame.get("cpu_ms")), 3)
            passes[variant] = {entry["name"]: rounded(number(entry.get("mean_ms")), 4)
                               for entry in summary.get("gpu") or [] if entry.get("name")}
            parts[variant] = {entry["name"]: rounded(number(entry.get("self_ms")), 4)
                              for entry in summary.get("zones") or [] if entry.get("name")}
            status = rpc(b, "engine.status")
            alive = status.get("particles")
            for counter in status.get("counters") or []:
                if counter.get("name") == "particles":
                    alive = (counter.get("values") or [0])[0]
            metrics[f"{variant}_particles"] = int(alive or 0)
        result_write(b, metrics, passes, parts)
    finally:
        engine_stop(b)


PARTICLE_LIGHT_VARIANTS = {"shadows": True, "shadowless": False}


def scenario_particlelights(b: Bench):
    """Four emitters of 256 particle lights each (1024: the room of a part of
    the GPU lights), 4 m of range over what stands around them, from the
    camera of the measurements of particles: the GPU by pass (shadow trace,
    shadow filter, the direct light and the particles) with their lights
    casting shadows (light_shadows) and without, over 300 frames after 120
    to settle."""
    metrics, passes, parts = {}, {}, {}
    engine_start(b, scene_extra(b))
    try:
        configure(b)
        rpc(b, "camera.set", {"position": [0, 2.2, 8.5], "target": [0, 1.1, 0]})
        emitters = []
        for index in range(4):
            added = rpc(b, "scene.write", merge({"preset": "particles", "name": f"Bench particle lights {index}",
                                                 "position": [index * 1.5 - 2.25, 0.8, 0]}))
            emitters.append(added["id"])
        for variant, shadows in PARTICLE_LIGHT_VARIANTS.items():
            for entity in emitters:
                rpc(b, "particle.instance.set", {"id": entity, "values": {
                    "rate": 512, "lifetime": [1, 1], "shape": "Sphere", "shape_size": [0.7, 0.7, 0.7],
                    "shell": 0, "speed": [0, 0], "size": [0.04, 0.06], "gravity": 0, "blend": "Additive", "lit": False,
                    "lights": 256, "light_intensity": 30, "light_range": 4, "light_shadows": shadows}})
            step(b, 120)
            summary = rpc(b, "profile.capture", {"frames": 300, "advance": True, "top": 64}, 1200)
            frame = summary.get("frame") or {}
            metrics[f"{variant}_gpu_ms"] = rounded(number(frame.get("gpu_ms")), 3)
            metrics[f"{variant}_frame_ms"] = rounded(number(frame.get("p50_ms")), 3)
            metrics[f"{variant}_cpu_ms"] = rounded(number(frame.get("cpu_ms")), 3)
            passes[variant] = {entry["name"]: rounded(number(entry.get("mean_ms")), 4)
                               for entry in summary.get("gpu") or [] if entry.get("name")}
            parts[variant] = {entry["name"]: rounded(number(entry.get("self_ms")), 4)
                              for entry in summary.get("zones") or [] if entry.get("name")}
            status = rpc(b, "engine.status")
            alive = 0
            for counter in status.get("counters") or []:
                if counter.get("name") == "particles":
                    alive = (counter.get("values") or [0])[0]
            metrics[f"{variant}_particles"] = int(alive or 0)
            metrics[f"{variant}_validation_errors"] = int(status.get("validation_errors") or 0)
        result_write(b, metrics, passes, parts)
    finally:
        engine_stop(b)


def grid_side(b: Bench) -> int:
    return math.ceil(math.sqrt(b.args.cubes))


def grid_position(b: Bench, index: int) -> list[float]:
    side = grid_side(b)
    x = (index % side - (side - 1) / 2) * GRID_SPACING
    z = (index // side - (side - 1) / 2) * GRID_SPACING
    return [x, 0.5, z]


def grid_cubes(b: Bench, first: int) -> list[dict]:
    return [{
        "preset": "cube", "name": f"Cube {i + 1}", "position": grid_position(b, i),
        "components": {"Mesh_Renderer": {"materials": [MATERIALS[i % 4][1]]}, "Material_Values": {"color": [0.7, 0.7, 0.7, 1]}},
    } for i in range(first, min(first + 64, b.args.cubes))]


def delete_roots(b: Bench):
    rpc(b, "scene.write", {"entities": []})


def grid_new(b: Bench, path: Path):
    """The scene of this engine, built through its API and saved with scene.save."""
    delete_roots(b)
    for first in range(0, b.args.cubes, 64):
        rpc(b, "scene.write", merge(*grid_cubes(b, first)))
    rpc(b, "scene.write", merge({"preset": "sun", "name": "Daylight", "position": [0, 10, 0]}))
    rpc(b, "scene.save", {"path": path.as_posix()})


def scenario_batch(b: Bench):
    """Time of a scene.write of 64 cubes as the scene grows."""
    metrics, passes, parts = {}, {}, {}
    engine_start(b, ["--no-gpu"])
    try:
        delete_roots(b)
        for first in range(0, b.args.cubes, 64):
            cubes = grid_cubes(b, first)
            started = time.perf_counter()
            rpc(b, "scene.write", merge(*cubes))
            ms = (time.perf_counter() - started) * 1000
            count = first + len(cubes)
            if count in (64, 512, 1024, 2048, 4096, 8192):
                metrics[f"batch_at_{count}_ms"] = rounded(ms, 1)
        metrics["private_mb"] = private_mb(psutil.Process(b.process.pid))
        result_write(b, metrics, passes, parts)
    finally:
        engine_stop(b)


def scenario_probe(b: Bench):
    engine_start(b, scene_extra(b))
    try:
        for entity in rpc(b, "scene.inspect", {"limit": 4096})["entities"]:
            print(entity["id"], entity.get("name"), ",".join(num(v) for v in entity.get("position") or []))
        rpc(b, "editor.input", CLICK)
        print("selected: " + json.dumps(rpc(b, "editor.inspect").get("selection"), separators=(",", ":")))
        status = rpc(b, "engine.status")
        print(f"instances {status.get('instances')}, visible {status.get('visible_instances')}")
    finally:
        engine_stop(b)


def scenario_terrain(b: Bench):
    args = b.args
    if not args.scene:
        raise BenchError("terrain requires an isolated terrain fixture in --scene")
    if len(args.terrain_target) != 3:
        raise BenchError("--terrain-target requires three coordinates")
    metrics, passes, parts = {}, {}, {}
    target = args.terrain_target
    engine_start(b, ["--scene", args.scene])
    try:
        configure(b)
        rpc(b, "camera.set", {"position": [target[0] + 12, target[1] + 15, target[2] + 18], "target": target})
        step(b, 120)
        rpc(b, "editor.input", {"events": [{"keys": ["T"], "mouse_position": CENTER}, {"mouse_position": CENTER}]})
        measure_view(b, "hover", metrics, passes, parts)
        rpc(b, "editor.input", {"events": [{"mouse_position": CENTER, "mouse_buttons": ["left"]}]})
        walls, gpu, table = [], [], {}
        step(b, 10)
        cpu = b.clock.now()
        for _ in range(RUNS):
            started = time.perf_counter()
            step(b, 30)
            walls.append((time.perf_counter() - started) * 1000 / 30)
            status = rpc(b, "engine.status")
            gpu.append(number(status.get("gpu_ms")))
            passes_add(table, status)
        used = b.clock.now()
        cpu_table = {}
        alone, _ = frames_alone(b, cpu_table)
        metrics["sculpt_wall_ms"] = rounded(median(walls), 3)
        metrics["sculpt_main_thread_ms"] = rounded((used[0] - cpu[0]) / (RUNS * 30), 3)
        metrics["sculpt_process_ms"] = rounded((used[1] - cpu[1]) / (RUNS * 30), 3)
        metrics["sculpt_gpu_ms"] = rounded(median(gpu), 3)
        metrics["sculpt_frame_alone_ms"] = rounded(median(alone), 3)
        metrics["sculpt_frame_alone_mean_ms"] = rounded(mean(alone), 3)
        passes["sculpt"] = medians(table)
        parts["sculpt"] = medians(cpu_table)
        parts["sculpt_mean"] = means(cpu_table)
        memory_add(b, "sculpt", metrics)
        rpc(b, "editor.input", {"events": [{"keys": ["Escape"], "mouse_buttons": ["left"], "mouse_position": CENTER}, {}]})
        result_write(b, metrics, passes, parts)
    finally:
        engine_stop(b)


def scenario_presentation(b: Bench):
    args = b.args
    if args.samples < 2 or args.sample_interval_ms < 100:
        raise BenchError("presentation needs at least two samples and a 100 ms interval")
    status = rpc(b, "engine.status")
    if status.get("headless") or status.get("manual"):
        raise BenchError("presentation needs a windowed editor")
    window = rpc(b, "editor.inspect")["window"]
    if not window.get("present") or window.get("minimized") or window.get("fullscreen"):
        raise BenchError("presentation needs a visible window outside fullscreen")
    graphics = rpc(b, "graphics.status")
    if graphics.get("vsync") or graphics.get("frame_limit") != 0:
        raise BenchError("turn VSync and Frame limit off before measuring presentation")
    b.preset = str(graphics.get("preset")).lower()
    values, parts = {}, {}
    for _ in range(args.samples):
        time.sleep(args.sample_interval_ms / 1000)
        status = rpc(b, "engine.status")
        for key in ("fps", "gpu_ms", "render_width", "render_height"):
            values.setdefault(key, []).append(number(status.get(key)))
        parts_add(parts, status)
    current = rpc(b, "editor.inspect")["window"]
    if current.get("fullscreen") or current.get("minimized") or current.get("size") != window.get("size"):
        raise BenchError("the window changed during presentation measurement")
    values["window_width"] = [number(window["size"][0])]
    values["window_height"] = [number(window["size"][1])]
    result_write(b, medians(values), {}, {"window": medians(parts)})


def scenario_demo(b: Bench):
    metrics, passes, parts = {}, {}, {}
    started = engine_start(b, scene_extra(b))
    try:
        metrics["start_ready_ms"] = rounded(started["ready_ms"], 1)
        metrics["start_first_frame_ms"] = rounded(started["first_frame_ms"], 1)
        memory_add(b, "loaded", metrics)
        configure(b)
        step(b, 300)
        measure_view(b, "idle", metrics, passes, parts)
        memory_add(b, "idle", metrics)
        entity, position = moved_entity(b)
        measure_move(b, "move", entity, position, metrics, passes, parts)
        rpc(b, "editor.input", CLICK)
        metrics["selected"] = len(rpc(b, "editor.inspect").get("selection") or [])
        step(b, 60)
        measure_view(b, "selected", metrics, passes, parts)
        watch = time.perf_counter()
        rpc(b, "play.start")
        metrics["play_start_ms"] = rounded((time.perf_counter() - watch) * 1000, 1)
        cpu = b.clock.now()
        watch = time.perf_counter()
        step(b, 60)
        metrics["play_first_second_wall_ms"] = rounded((time.perf_counter() - watch) * 1000, 1)
        used = b.clock.now()
        metrics["play_first_second_main_thread_ms"] = rounded(used[0] - cpu[0], 1)
        metrics["play_first_second_process_ms"] = rounded(used[1] - cpu[1], 1)
        step(b, 120)
        walls = []
        cpu = b.clock.now()
        for _ in range(RUNS):
            watch = time.perf_counter()
            step(b, RUN_FRAMES)
            walls.append((time.perf_counter() - watch) * 1000 / RUN_FRAMES)
        used = b.clock.now()
        metrics["play_wall_ms"] = rounded(median(walls), 3)
        metrics["play_main_thread_ms"] = rounded((used[0] - cpu[0]) / (RUNS * RUN_FRAMES), 3)
        metrics["play_process_ms"] = rounded((used[1] - cpu[1]) / (RUNS * RUN_FRAMES), 3)
        cpu_table = {}
        alone, status = frames_alone(b, cpu_table)
        metrics["play_frame_alone_ms"] = rounded(median(alone), 3)
        metrics["play_frame_alone_mean_ms"] = rounded(mean(alone), 3)
        metrics["play_gpu_ms"] = rounded(number(status.get("gpu_ms")), 3)
        parts["play"] = medians(cpu_table)
        parts["play_mean"] = means(cpu_table)
        watch = time.perf_counter()
        rpc(b, "play.stop")
        metrics["play_stop_ms"] = rounded((time.perf_counter() - watch) * 1000, 1)
        result_write(b, metrics, passes, parts)
    finally:
        engine_stop(b)


def grid_camera(b: Bench) -> dict:
    return {"target": [0, 0, 0], "yaw": 0.25, "pitch": 0.85, "distance": grid_side(b) * GRID_SPACING * 1.1}


def scenario_scale(b: Bench):
    metrics, passes, parts = {}, {}, {}
    path = Path(b.args.scratch) / f"grid_{b.variant}_{b.args.cubes}.scene"
    if not path.exists():
        engine_start(b, ["--no-gpu"])
        try:
            grid_new(b, path)
        finally:
            engine_stop(b)
    started = engine_start(b, ["--scene", str(path)])
    try:
        metrics["start_first_frame_ms"] = rounded(started["first_frame_ms"], 1)
        entity = rpc(b, "scene.inspect", {"limit": 1})["entities"][0]["id"]
        rpc(b, "camera.set", grid_camera(b))
        configure(b)
        memory_add(b, "loaded", metrics)
        step(b, 240)
        measure_view(b, "idle", metrics, passes, parts)
        measure_move(b, "move", entity, grid_position(b, 0), metrics, passes, parts)
        memory_add(b, "end", metrics)
        result_write(b, metrics, passes, parts)
    finally:
        engine_stop(b)


def spread(values: list[float]) -> str:
    ordered = sorted(values)
    return f"{num(rounded(median(ordered), 3))} ({num(rounded(ordered[0], 3))} to {num(rounded(ordered[-1], 3))})"


def report_table(title: str, variants: list[str], columns: dict, field: str):
    """One row per name of `field`, one column per variant; the last column is the
    median of the last variant over the one of the first."""
    names = []
    for variant in variants:
        for run in columns[variant]:
            for name in run.get(field) or {}:
                if name not in names:
                    names.append(name)
    if not names:
        return
    print()
    print(f"### {title}")
    print()
    print(f"| Measure | {' | '.join(variants)} | {variants[-1]}/{variants[0]} |")
    print("| --- |" + " ---: |" * (len(variants) + 1))
    for name in sorted(names, key=str.casefold):
        cells, results = [], []
        for variant in variants:
            values = [number(run[field][name]) for run in columns[variant]
                      if run.get(field) is not None and run[field].get(name) is not None]
            cells.append(spread(values) if values else "-")
            results.append(median(values) if values else None)
        ratio = "-"
        if results[0] is not None and results[-1] is not None and results[0] > 0:
            ratio = num(rounded(results[-1] / results[0], 2))
        print(f"| {name} | {' | '.join(cells)} | {ratio} |")


def scenario_report(b: Bench):
    groups: dict[str, list[dict]] = {}
    with open(b.args.out, encoding="utf-8-sig") as lines:
        for line in lines:
            if line.strip():
                run = json.loads(line)
                groups.setdefault(f"{run['scenario']} {run['preset']} {run['cubes']} {run['scene']}", []).append(run)
    for runs in groups.values():
        first = runs[0]
        title = f"{first['scenario']} {first['scene']}, preset {first['preset']}"
        if first["scenario"] == "scale":
            title = f"{first['cubes']} cubes, preset {first['preset']}"
        columns: dict[str, list[dict]] = {}
        for run in runs:
            columns.setdefault(run["variant"], []).append(run)
        variants = list(columns)
        print()
        print(f"## {title} ({', '.join(f'{v} {len(columns[v])}' for v in variants)} runs)")
        report_table("Measures", variants, columns, "metrics")
        states = []
        for field in ("passes", "cpu"):
            for run in runs:
                for state in run.get(field) or {}:
                    if state not in states:
                        states.append(state)
        for state in states:
            by_state = {variant: [{"passes": (run.get("passes") or {}).get(state), "cpu": (run.get("cpu") or {}).get(state)}
                                  for run in columns[variant]] for variant in variants}
            report_table(f"GPU by pass, {state} (ms)", variants, by_state, "passes")
            report_table(f"CPU of the main thread by part, {state} (ms)", variants, by_state, "cpu")


def scenario_simulation(b: Bench):
    metrics, passes, parts = {}, {}, {}
    engine_start(b, [] if b.args.simulation_gpu else ["--no-gpu"])
    try:
        box = {"Collider": {"kind": "Box", "size": [1, 1, 1]}}
        rpc(b, "scene.new", {"discard": True})
        rpc(b, "scene.write", merge({"preset": "cube", "name": "Floor", "position": [0, -0.5, 0], "scale": [10, 0.5, 10], "components": box}))
        wall = rpc(b, "scene.write", merge({"preset": "cube", "name": "Wall", "position": [-2, 1, 0], "scale": [0.25, 1, 2], "components": box}))
        rpc(b, "scene.write", merge({"preset": "cube", "name": "Box", "position": [0, 0.51, 0], "scale": [0.5, 0.5, 0.5], "components": {
            "Rigid_Body": {"type": "Dynamic", "mass": 1, "gravity_scale": 1}, **box}}))
        rpc(b, "play.start", {"simulate": True})
        rpc(b, "play.step", {"for": 90})
        for phase in ("resting", "moving"):
            frames, game, gpu, record, wait, table = [], [], [], [], [], {}
            for i in range(1, 91):
                if phase == "moving":
                    rpc(b, "simulation.move", {"id": wall["id"], "position": [-2 + i / 30, 1, 0]})
                rpc(b, "play.step", {"for": 1})
                status = rpc(b, "engine.status")
                frames.append(cpu_field(status, "app_ms"))
                game.append(cpu_field(status, "game_ms"))
                gpu.append(number(status.get("gpu_ms")))
                record.append(cpu_field(status, "render_record_ms"))
                wait.append(cpu_field(status, "render_begin_ms"))
                functions_add(table, status)
            metrics[f"{phase}_frame_ms"] = median(frames)
            metrics[f"{phase}_game_ms"] = median(game)
            metrics[f"{phase}_gpu_ms"] = median(gpu)
            metrics[f"{phase}_record_ms"] = median(record)
            metrics[f"{phase}_gpu_wait_ms"] = median(wait)
            metrics[f"{phase}_max_frame_ms"] = max(frames)
            parts[phase] = medians(table)
        result_write(b, metrics, passes, parts)
    finally:
        engine_stop(b)


def mirai(b: Bench, *args: str) -> list[str]:
    """Runs mirai of the measured checkout and returns what it printed, after printing it."""
    shell = shutil.which("sh")
    if shell is None:
        raise BenchError("sh is not in PATH: run from bash (Git Bash on Windows)")
    result = subprocess.run([shell, (b.root / "mirai").as_posix(), *args], cwd=b.root,
                            stdout=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
    lines = result.stdout.splitlines()
    for line in lines:
        print(line)
    if result.returncode != 0:
        raise BenchError(f"mirai {' '.join(args)} failed with code {result.returncode}")
    return lines


CCD_LINE = re.compile(r"CCD_BENCH scene=(\w+) workers=(\d+) median_ms=([\d.]+) best_ms=([\d.]+) mean_ms=([\d.]+) begin_events=(\d+)")
WALL_LINE = re.compile(
    r"BENCH wall of (\d+) pieces and (\d+) connections: build ([\d.]+) ms, intact step ([\d.]+) ms, step that breaks it "
    r"([\d.]+) ms; 120 steps after: median ([\d.]+) ms, mean ([\d.]+), worst ([\d.]+), median stages narrow ([\d.]+) "
    r"prepare ([\d.]+) solve ([\d.]+); (\d+) events, (\d+) pieces loose \((\d+) debris\), at most (\d+) contacts")
WALL_FIELDS = ("pieces", "connections", "build_ms", "intact_step_ms", "breaking_step_ms", "after_median_ms", "after_mean_ms",
               "after_worst_ms", "narrow_ms", "prepare_ms", "solve_ms", "events", "loose_pieces", "debris", "contacts")
PUBLISH_LINE = re.compile(r"NET_PUBLISH_BENCH scene=(\w+) objects=(\d+) update_hz=(\d+) median_ms=([\d.]+) best_ms=([\d.]+) mean_ms=([\d.]+)")


def scenario_physics(b: Bench):
    metrics = {}
    test = b.args.physics_test
    for line in mirai(b, "test", "plugins/physics/runtime/sim", test, "--release", "-define:PHYSICS_BENCH=true"):
        if match := CCD_LINE.search(line):
            prefix = f"{match[1]}_{match[2]}w"
            metrics[f"{prefix}_median_ms"] = float(match[3])
            metrics[f"{prefix}_best_ms"] = float(match[4])
            metrics[f"{prefix}_mean_ms"] = float(match[5])
            metrics[f"{prefix}_begin_events"] = int(match[6])
        elif match := WALL_LINE.search(line):
            for index, name in enumerate(WALL_FIELDS, 1):
                metrics[f"wall_{name}"] = float(match[index])
    if len(metrics) != (15 if test == "bench_wall" else 24):
        raise BenchError(f"physics benchmark {test} did not emit all expected measurements")
    result_write(b, metrics, {}, {})


def scenario_netpublish(b: Bench):
    metrics = {}
    for line in mirai(b, "test", "plugins/multiplayer/runtime", "bench_publish", "--release", "-define:NET_PUBLISH_BENCH=true"):
        if match := PUBLISH_LINE.search(line):
            prefix = f"{match[1]}_{match[3]}hz"
            metrics[f"{prefix}_objects"] = int(match[2])
            metrics[f"{prefix}_median_ms"] = float(match[4])
            metrics[f"{prefix}_best_ms"] = float(match[5])
            metrics[f"{prefix}_mean_ms"] = float(match[6])
    if len(metrics) != 16:
        raise BenchError("state publication benchmark did not emit all expected measurements")
    result_write(b, metrics, {}, {})


def scenario_fade(b: Bench):
    args = b.args
    metrics, passes, parts = {}, {}, {}
    engine_start(b)
    try:
        rpc(b, "scene.new", {"discard": True})
        grid_new(b, Path(args.scratch) / f"fade_{b.variant}_{args.cubes}.scene")
        entity = rpc(b, "scene.inspect", {"limit": 1})["entities"][0]["id"]
        rpc(b, "camera.set", grid_camera(b))
        configure(b)
        step(b, 120)
        for phase in ("idle", "fade"):
            frames, game, gpu, sync, functions, cpu, timings, status = [], [], [], [], {}, {}, {}, {}
            rpc(b, "engine.status")
            for i in range(args.samples + 16):
                if phase == "fade":
                    alpha = 0.25 if i % 2 == 0 else 0.75
                    rpc(b, "scene.write", merge({"id": entity, "components": {"Material_Values": {"color": [0.7, 0.7, 0.7, alpha]}}}))
                step(b, 1)
                status = rpc(b, "engine.status")
                if i < 16:
                    continue
                frames.append(cpu_field(status, "app_ms"))
                game.append(cpu_field(status, "game_ms"))
                gpu.append(number(status.get("gpu_ms")))
                parts_add(cpu, status)
                passes_add(timings, status)
                functions_add(functions, status)
                sync += [number(e.get("ms")) for e in status.get("functions") or [] if e.get("name") == "render_sync"]
            if len(sync) != args.samples:
                raise BenchError(f"render_sync missing from {phase} samples")
            metrics[f"{phase}_frame_ms"] = median(frames)
            metrics[f"{phase}_game_ms"] = median(game)
            metrics[f"{phase}_gpu_ms"] = median(gpu)
            metrics[f"{phase}_render_sync_ms"] = median(sync)
            metrics[f"{phase}_max_render_sync_ms"] = max(sync)
            metrics[f"{phase}_instances"] = int(status.get("instances") or 0)
            metrics[f"{phase}_validation_errors"] = int(status.get("validation_errors") or 0)
            parts[phase] = medians(cpu)
            parts[f"{phase}_functions"] = medians(functions)
            passes[phase] = medians(timings)
        result_write(b, metrics, passes, parts)
    finally:
        engine_stop(b)


SCENARIOS = {
    "demo": scenario_demo, "scale": scenario_scale, "playgpu": scenario_playgpu, "batch": scenario_batch,
    "simulation": scenario_simulation, "physics": scenario_physics, "netpublish": scenario_netpublish,
    "fade": scenario_fade, "terrain": scenario_terrain, "presentation": scenario_presentation,
    "probe": scenario_probe, "report": scenario_report, "particles": scenario_particles,
    "particlelights": scenario_particlelights,
}


def coordinates(text: str) -> list[float]:
    return [float(part) for part in text.split(",")]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("scenario", choices=SCENARIOS)
    parser.add_argument("--engine-root", help="the checkout whose editor runs; this one when omitted")
    parser.add_argument("--exe", help="the editor executable; the one of the build of the engine when omitted")
    parser.add_argument("--scene", default="", help="the scene the demo opens; the start scene of the project when omitted")
    parser.add_argument("--terrain-target", type=coordinates, default=[0.0, 0.0, 0.0], metavar="X,Y,Z")
    parser.add_argument("--moved", default="Wood box", help="the name of the entity the demo moves")
    parser.add_argument("--variant", help="the column of the report this run belongs to; the folder of the checkout when omitted")
    parser.add_argument("--preset", default="high")
    parser.add_argument("--port", type=int, default=7961)
    parser.add_argument("--cubes", type=int, default=2000)
    parser.add_argument("--samples", type=int, default=24)
    parser.add_argument("--sample-interval-ms", type=int, default=500)
    parser.add_argument("--physics-test", choices=("bench_ccd", "bench_wall"), default="bench_ccd")
    parser.add_argument("--simulation-gpu", action="store_true", help="headless GPU rendering in the simulation scenario")
    parser.add_argument("--out", default="bench.jsonl")
    parser.add_argument("--scratch", default=tempfile.gettempdir())
    args = parser.parse_args()
    root = Path(args.engine_root).resolve() if args.engine_root else Path(__file__).resolve().parent.parent
    b = Bench(args=args, root=root, variant=args.variant or root.name, preset=args.preset)
    # configure keeps its graphics in the settings of the demo through
    # settings.set: they go back to what they were however the run ends.
    settings = root / "demo" / "settings.mirai"
    before = settings.read_bytes() if settings.is_file() else None
    try:
        SCENARIOS[args.scenario](b)
    except BenchError as error:
        sys.exit(f"bench_compare: {error}")
    finally:
        if before is not None:
            settings.write_bytes(before)
        elif settings.is_file():
            settings.unlink()


if __name__ == "__main__":
    main()
