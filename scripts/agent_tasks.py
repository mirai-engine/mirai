#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.15"
# dependencies = []
# [tool.uv]
# required-version = ">=0.13"
# ///
"""Measures how well a cold agent uses the editor API: each task of tests/agent_tasks runs on a
fresh copy of a new project, with a `claude -p` that has only the Mirai MCP tools, and is judged by
reading the final state through the API.

  uv run scripts/agent_tasks.py [--tasks a,b] [--models haiku,sonnet] [--runs N] [--out DIR]
                                [--timeout S] [--no-agent]

--out holds <task>/<model>/run<N>/ with result.json, the raw transcript.jsonl and the stderr of the
agent, and projects/<template>, the project the sessions copy. A run with its result.json is not
repeated, so the same command resumes; the default folder is named after the commit of the checkout.
--no-agent runs the setup and the checks alone, which proves a task file spends no tokens: every
check that needs the agent's work must fail and say why. Results go to stdout and that folder only.

A task file is a JSON object:

  prompt    what the agent is told, and nothing else
  project   template of `mirai new` the session copies
  scene     optional document of tests/agent_tasks/scenes/ written on the empty scene
  tools     optional built-in tools besides MCP; the agent then works in the copy of the project
  checks    list; each is one of the forms below and may carry `repeat: N`, which expands it for n
            from 1 to N: "{n}" in a text becomes n and a text "=<expression>" the value of it

  {"entity": "A/B", "position": [...], "scale": ..., "components": {...}}   fields of one entity
  {"gone": "A/B"}                                                           no entity at that path
  {"count": {"under": "A", "component": "C", "name": "L*"}, "equals": N}    entities of a filter
  {"each": {<filter>}, "components": {...}}                                 fields of all of them
  {"spread": ["A/B", ...], "axes": [0, 2], "points": [[x, z], ...]}         one entity on each point
  {"unchanged": {"except": ["A/B"], "except_component": "C"}}               the rest as it started
  {"play": [<conditions of the play check method>]}                         the running game
  {"camera": {"target": [...]}}                                             the viewport's camera
  {"file": "folder/a.png", "png": [width, height]}                          a file the agent wrote
  {"ui": "hud/a.ui", "nodes": {"name": {...}}, "document": {...}}           what ui.inspect gives
  {"scenario": {"steps": [...]}}                                            a play scenario passes

An entity is named by the names from its root joined by "/". An expected value is a number (within
`tolerance`, 0.01 by default), a text, a list or object of expected values, null for anything,
{"min": a, "max": b} or {"any": [values]}.

A `ui` check names a .ui by its path under assets. `nodes` expects nodes of its document by name,
wherever they nest: the keys of each as the document says them (a use has the name of its widget as
`kind` and its parameters as keys) and `parent`, the name of the node that holds it, "" for a root.
`document` expects the rest of it (tokens, styles, params). It also fails on each problem ui.check
finds in that file, so an interface that binds what the game lacks never passes.

A `scenario` check is a scenario of docs/game/testing/scenario.md, played from its first tick on the
scene that is open: a step presses a button by its name and a play.check reads what the game did.
"""

import argparse
import fnmatch
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TASKS = ROOT / "tests" / "agent_tasks"

# Every editor method the runner calls; a rename of the API changes only these.
INSPECT = "scene.inspect"
WRITE = "scene.write"
PLAY_CHECK = "play.check"
CAMERA = "camera.set"
UI_INSPECT = "ui.inspect"
UI_CHECK = "ui.check"
SCENARIO = "play.scenario.run"

RPC_TIMEOUT = 120
TOLERANCE = 0.01
MCP_PREFIX = "mcp__mirai__"
# What marks a process as a child of an agent, and what would tie its calls to another editor.
ENV_DROPPED = ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "MIRAI_API_PORT",
               "MIRAI_AI_TASK")


class Fatal(Exception):
    """The suite cannot go on: nothing about the agent is known. Rerunning resumes."""


def mirai(*arguments: str) -> str:
    shell = shutil.which("sh")
    if shell is None:
        raise Fatal("sh is not in PATH: run from bash (Git Bash on Windows)")
    done = subprocess.run([shell, (ROOT / "mirai").as_posix(), *arguments], cwd=ROOT, text=True,
                          encoding="utf-8", errors="replace", capture_output=True)
    if done.returncode != 0:
        raise Fatal(f"mirai {' '.join(arguments)} failed with code {done.returncode}\n"
                    f"{done.stderr[-2000:]}")
    return done.stdout


class Session:
    """A headless editor on a fresh copy of a project, which closing deletes."""

    def __init__(self, project: Path):
        printed = mirai("session", "start", project.as_posix(), "--copy")
        lines = [line for line in printed.splitlines() if line.startswith("{")]
        if not lines:
            raise Fatal(f"mirai session start printed no session: {printed[-2000:]}")
        self.project = Path(json.loads(lines[-1])["project"])

    def rpc(self, method: str, params: dict | None = None):
        """The port is read on every call: a build may restart the editor on another one."""
        port = json.loads((self.project / ".mirai" / "api.json").read_text("utf-8"))["port"]
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                           "params": params or {}}).encode()
        request = urllib.request.Request(f"http://127.0.0.1:{port}/rpc", data=body,
                                         headers={"Content-Type": "application/json"})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request, timeout=RPC_TIMEOUT) as response:
            answer = json.load(response)
        if answer.get("error"):
            raise RuntimeError(f"{method}: {answer['error'].get('message')}")
        return answer["result"]

    def stop(self):
        mirai("session", "stop", self.project.as_posix(), "--force")


class Scene:
    """The entities of the open scene, each named by its path of names."""

    def __init__(self, session: Session):
        self.entities: list[dict] = []
        while True:
            page = session.rpc(INSPECT, {"offset": len(self.entities), "limit": 4096, "components": True})
            self.entities += page["entities"]
            if not page["omitted"]:
                break
        by_id = {entity["id"]: entity for entity in self.entities}
        for entity in self.entities:
            names, walk = [], entity
            while walk is not None:
                names.append(walk["name"])
                walk = by_id.get(walk["parent"])
            entity["path"] = "/".join(reversed(names))

    def at(self, path: str) -> list[dict]:
        return [entity for entity in self.entities if entity["path"] == path]

    def select(self, where: dict) -> list[dict]:
        under = where.get("under")
        return [entity for entity in self.entities
                if (under is None or entity["path"].startswith(under + "/"))
                and ("component" not in where or where["component"] in entity["components"])
                and ("name" not in where or fnmatch.fnmatchcase(entity["name"], where["name"]))]


def matches(expected, found, tolerance: float) -> bool:
    if expected is None:
        return True
    if isinstance(expected, dict) and "any" in expected:
        return any(matches(option, found, tolerance) for option in expected["any"])
    if isinstance(expected, dict) and ("min" in expected or "max" in expected):
        return (isinstance(found, (int, float)) and expected.get("min", found) <= found
                <= expected.get("max", found))
    if isinstance(expected, dict):
        return isinstance(found, dict) and all(matches(value, found.get(key), tolerance)
                                               for key, value in expected.items())
    if isinstance(expected, list):
        return (isinstance(found, list) and len(found) == len(expected)
                and all(matches(a, b, tolerance) for a, b in zip(expected, found)))
    if isinstance(expected, (int, float)) and not isinstance(expected, bool):
        return (isinstance(found, (int, float)) and not isinstance(found, bool)
                and abs(found - expected) <= tolerance)
    return expected == found


def compared(entity: dict, check: dict, skipped: tuple) -> list[str]:
    """What differs between the fields a check names and those of an entity."""
    tolerance = check.get("tolerance", TOLERANCE)
    failures = []
    for field, expected in check.items():
        if field in skipped or field == "tolerance":
            continue
        found = entity.get(field)
        if not matches(expected, found, tolerance):
            failures.append(f"{entity['path']} {field}: expected {json.dumps(expected)}, "
                            f"found {json.dumps(found)}")
    return failures


def check_spread(check: dict, scene: Scene, session: Session) -> list[str]:
    axes = check["axes"]
    tolerance = check.get("tolerance", TOLERANCE)
    placed = []
    for path in check["spread"]:
        found = scene.at(path)
        if len(found) != 1:
            return [f"{path}: expected 1 entity, found {len(found)}"]
        placed.append((path, [found[0]["position"][axis] for axis in axes]))
    failures = []
    for point in check["points"]:
        taken = next((item for item in placed
                      if all(abs(a - b) <= tolerance for a, b in zip(item[1], point))), None)
        if taken is None:
            failures.append(f"{', '.join(check['spread'])}: expected one at {point} on axes "
                            f"{axes}, found {[item[1] for item in placed]}")
        else:
            placed.remove(taken)
    return failures


def check_entity(check: dict, scene: Scene, session: Session) -> list[str]:
    found = scene.at(check["entity"])
    if len(found) != 1:
        return [f"{check['entity']}: expected 1 entity, found {len(found)}"]
    return compared(found[0], check, ("entity",))


def check_gone(check: dict, scene: Scene, session: Session) -> list[str]:
    found = scene.at(check["gone"])
    return [f"{check['gone']}: expected no entity, found {len(found)}"] if found else []


def check_count(check: dict, scene: Scene, session: Session) -> list[str]:
    found = len(scene.select(check["count"]))
    if found == check["equals"]:
        return []
    return [f"count of {json.dumps(check['count'])}: expected {check['equals']}, found {found}"]


def check_each(check: dict, scene: Scene, session: Session) -> list[str]:
    selected = scene.select(check["each"])
    if not selected:
        return [f"each of {json.dumps(check['each'])}: expected some entity, found none"]
    return [failure for entity in selected for failure in compared(entity, check, ("each",))]


def check_unchanged(check: dict, scene: Scene, session: Session, start: Scene) -> list[str]:
    spec = check["unchanged"]
    excepted = spec.get("except", [])
    failures = []
    for before in start.entities:
        path = before["path"]
        if (any(path == e or path.startswith(e + "/") for e in excepted)
                or spec.get("except_component") in before["components"]):
            continue
        found = scene.at(path)
        if len(found) != 1:
            failures.append(f"{path}: expected it left as it was, found {len(found)} entities")
            continue
        wanted = {k: before[k] for k in ("position", "rotation_deg", "scale", "components")}
        failures += compared(found[0], wanted, ())
        if found[0]["components"].keys() != before["components"].keys():
            failures.append(f"{path} components: expected {list(before['components'])}, "
                            f"found {list(found[0]['components'])}")
    return failures


def check_play(check: dict, scene: Scene, session: Session) -> list[str]:
    try:
        answer = session.rpc(PLAY_CHECK, {"conditions": check["play"]})
    except (RuntimeError, urllib.error.URLError) as error:
        return [f"the game: expected it running, found {error}"]
    if answer["passed"]:
        return []
    return [f"the game: expected {json.dumps(condition)}, found {json.dumps(result['value'])}"
            for condition, result in zip(check["play"], answer["results"]) if not result["passed"]]


def check_camera(check: dict, scene: Scene, session: Session) -> list[str]:
    tolerance = check.get("tolerance", TOLERANCE)
    camera = session.rpc(CAMERA, {})
    return [f"viewport camera {field}: expected {json.dumps(expected)}, "
            f"found {json.dumps(camera.get(field))}"
            for field, expected in check["camera"].items()
            if not matches(expected, camera.get(field), tolerance)]


def check_file(check: dict, scene: Scene, session: Session) -> list[str]:
    path = session.project / check["file"]
    if not path.is_file():
        return [f"{check['file']}: expected a file, found none"]
    if "png" not in check:
        return []
    head = path.read_bytes()[:24]
    if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n":
        return [f"{check['file']}: expected a PNG, found another kind of file"]
    size = list(struct.unpack(">II", head[16:24]))
    if size != check["png"]:
        return [f"{check['file']}: expected {check['png']}, found {size}"]
    return []


def check_ui(check: dict, scene: Scene, session: Session) -> list[str]:
    name = check["ui"]
    tolerance = check.get("tolerance", TOLERANCE)
    try:
        document = session.rpc(UI_INSPECT, {"asset": name})["document"]
        problems = session.rpc(UI_CHECK, {})["problems"]
    except (RuntimeError, urllib.error.URLError) as error:
        return [f"{name}: expected a .ui that reads, found {error}"]
    # ui.check names a file as the editor shows it: without folder or extension.
    failures = [f"{name}: expected no problem, found {problem['message']}"
                for problem in problems if problem["asset"] == Path(name).stem]
    nodes = {}

    def walk(listed: list[dict], holder: str):
        for node in listed:
            nodes[node.get("name", "")] = {**node, "parent": holder}
            walk(node.get("children", []), node.get("name", ""))

    walk(document.get("nodes", []), "")
    for node, expected in check.get("nodes", {}).items():
        if node not in nodes:
            failures.append(f"{name}: expected a node {node}, found {sorted(nodes)}")
            continue
        found = {key: value for key, value in nodes[node].items() if key != "children"}
        if not matches(expected, found, tolerance):
            failures.append(f"{name} node {node}: expected {json.dumps(expected)}, "
                            f"found {json.dumps(found)}")
    for key, expected in check.get("document", {}).items():
        if not matches(expected, document.get(key), tolerance):
            failures.append(f"{name} {key}: expected {json.dumps(expected)}, "
                            f"found {json.dumps(document.get(key))}")
    return failures


def check_scenario(check: dict, scene: Scene, session: Session) -> list[str]:
    path = session.project / ".mirai" / "tmp" / "task_scenario.mirai"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(check["scenario"]), "utf-8")
    try:
        answer = session.rpc(SCENARIO, {"path": path.as_posix()})
    except (RuntimeError, urllib.error.URLError) as error:
        return [f"the scenario: expected it to play, found {error}"]
    return [f"the scenario: expected every step to pass, found {report['failure']}"
            for report in answer["scenarios"] if not report["passed"]]


CHECKS = {"entity": check_entity, "gone": check_gone, "count": check_count, "each": check_each,
          "spread": check_spread, "play": check_play, "camera": check_camera, "file": check_file,
          "ui": check_ui, "scenario": check_scenario}


def substituted(value, n: int):
    if isinstance(value, str):
        return eval(value[1:], {"n": n}) if value.startswith("=") else value.replace("{n}", str(n))
    if isinstance(value, list):
        return [substituted(item, n) for item in value]
    if isinstance(value, dict):
        return {key: substituted(item, n) for key, item in value.items()}
    return value


def expanded(checks: list[dict]) -> list[dict]:
    result = []
    for check in checks:
        if "repeat" in check:
            body = {k: v for k, v in check.items() if k != "repeat"}
            result += [substituted(body, n) for n in range(1, check["repeat"] + 1)]
        else:
            result.append(check)
    return result


def form_of(task: dict, check: dict) -> str:
    """The form of a check, by the one key of it that names a form."""
    kinds = [kind for kind in (*CHECKS, "unchanged") if kind in check]
    if len(kinds) != 1:
        raise Fatal(f"{task['name']}: a check needs one form of {[*CHECKS, 'unchanged']}: {check}")
    return kinds[0]


def evaluate(task: dict, session: Session, start: Scene) -> list[str]:
    scene = Scene(session)
    failures = []
    for check in expanded(task["checks"]):
        form = form_of(task, check)
        if form == "unchanged":
            failures += check_unchanged(check, scene, session, start)
        else:
            failures += CHECKS[form](check, scene, session)
    return failures


def method_of(call: dict) -> str:
    """The method a tool call ran: `call` names it in its input."""
    name = call["name"].removeprefix(MCP_PREFIX)
    return str(call["input"].get("method", name)) if name == "call" else name


def agent_command(task: dict, model: str, config: Path) -> list[str]:
    claude = shutil.which("claude")
    if claude is None:
        raise Fatal("claude is not in PATH")
    tools = task.get("tools", [])
    return [claude, "-p", "--model", model, "--output-format", "stream-json", "--verbose",
            "--strict-mcp-config", "--mcp-config", str(config), "--setting-sources", "",
            "--tools", ",".join(tools), "--allowedTools", ",".join(["mcp__mirai", *tools]),
            "--permission-mode", "dontAsk", "--no-session-persistence",
            "--disable-slash-commands"]


def run_agent(task: dict, model: str, session: Session, folder: Path, timeout: float) -> dict:
    """Runs the agent and reads its transcript. A task without file tools works in an empty folder
    outside every repository, so that it finds no project context."""
    config = folder / "mcp.json"
    executable = (ROOT / "bin" / "mirai").with_suffix(".exe" if os.name == "nt" else "")
    config.write_text(json.dumps({"mcpServers": {"mirai": {
        "command": executable.as_posix(),
        "args": ["mcp", "--project", session.project.as_posix()]}}}), "utf-8")
    environment = {k: v for k, v in os.environ.items() if k not in ENV_DROPPED}
    environment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
    environment["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] = "1"
    transcript = folder / "transcript.jsonl"
    scratch = tempfile.mkdtemp(prefix="mirai-agent-task-")
    began = time.monotonic()
    timed_out = False
    try:
        with open(transcript, "wb") as out, open(folder / "stderr.log", "wb") as err:
            subprocess.run(agent_command(task, model, config), input=task["prompt"].encode(),
                           cwd=session.project if task.get("tools") else scratch, env=environment,
                           stdout=out, stderr=err, timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    stats = read_transcript(transcript)
    stats["seconds"] = round(time.monotonic() - began, 1)
    stats["timed_out"] = timed_out
    return stats


def read_transcript(path: Path) -> dict:
    calls, failed, usage, final, connected = {}, Counter(), {}, None, False
    for line in path.read_text("utf-8", errors="replace").splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = event.get("type")
        if kind == "system" and event.get("subtype") == "init":
            connected = any(server.get("name") == "mirai" and server.get("status") == "connected"
                            for server in event.get("mcp_servers", []))
        elif kind == "assistant":
            for block in event["message"]["content"]:
                if block.get("type") == "tool_use":
                    calls[block["id"]] = block
        elif kind == "user" and isinstance(event["message"]["content"], list):
            for block in event["message"]["content"]:
                if block.get("type") == "tool_result" and block.get("is_error"):
                    call = calls.get(block["tool_use_id"])
                    failed[method_of(call) if call else "?"] += 1
        elif kind == "result":
            final, usage = event, event.get("usage", {})
    return {
        "connected": connected,
        "agent_error": None if final is None or not final.get("is_error")
        else str(final.get("result") or final.get("subtype")),
        "finished": final is not None,
        "tool_calls": len(calls),
        "tool_errors": sum(failed.values()),
        "failed_methods": dict(failed),
        "input_tokens": usage.get("input_tokens", 0) + usage.get("cache_creation_input_tokens", 0)
        + usage.get("cache_read_input_tokens", 0),
        "output_tokens": usage.get("output_tokens", 0),
    }


def set_up_scene(task: dict, session: Session):
    if "scene" not in task:
        return
    document = json.loads((TASKS / "scenes" / f"{task['scene']}.json").read_text("utf-8"))
    session.rpc(WRITE, {"entities": document["entities"]})


def base_project(template: str, out: Path, built: set[str]) -> Path:
    """The project every session of a template copies, built once per run of the suite so that the
    copies start from its caches."""
    project = out / "projects" / template
    if template not in built:
        if not (project / "project.mirai").exists():
            mirai("new", project.as_posix(), "--template", template)
        mirai("build", "editor", project.as_posix())
        built.add(template)
    return project


def run_task(task: dict, model: str, run: int, out: Path, timeout: float, built: set[str],
             no_agent: bool) -> dict:
    folder = out / task["name"] / model / f"run{run}"
    done = folder / "result.json"
    if done.exists() and not no_agent:
        return json.loads(done.read_text("utf-8"))
    folder.mkdir(parents=True, exist_ok=True)
    session = Session(base_project(task["project"], out, built))
    try:
        set_up_scene(task, session)
        start = Scene(session)
        stats = None if no_agent else run_agent(task, model, session, folder, timeout)
        failures = evaluate(task, session, start)
    finally:
        session.stop()
    if no_agent:
        return {"task": task["name"], "model": model, "run": run, "failures": failures}
    if not stats["finished"] and not stats["timed_out"]:
        raise Fatal(f"{task['name']} {model}: the agent ended without a result; see {folder}")
    if stats["finished"] and not stats["connected"]:
        raise Fatal(f"{task['name']} {model}: the Mirai MCP server did not connect; see {folder}")
    if stats["agent_error"]:
        raise Fatal(f"{task['name']} {model}: the agent failed: {stats['agent_error']}")
    result = {"task": task["name"], "model": model, "run": run, "passed": not failures,
              "failures": failures, **stats}
    done.write_text(json.dumps(result, indent=1), "utf-8")
    return result


def load_tasks(names: list[str] | None) -> list[dict]:
    tasks = []
    for path in sorted(TASKS.glob("*.json")):
        task = json.loads(path.read_text("utf-8"))
        task["name"] = path.stem
        # A file no session could judge fails here, before any agent runs.
        for key in ("prompt", "project", "checks"):
            if key not in task:
                raise Fatal(f"{task['name']}: a task needs {key}")
        for check in expanded(task["checks"]):
            form_of(task, check)
        tasks.append(task)
    known = [task["name"] for task in tasks]
    for name in names or []:
        if name not in known:
            raise Fatal(f"there is no task {name}; the tasks are {known}")
    return [task for task in tasks if not names or task["name"] in names]


def table(headers: list[str], rows: list[list]) -> str:
    cells = [headers, *[[str(cell) for cell in row] for row in rows]]
    widths = [max(len(row[i]) for row in cells) for i in range(len(headers))]
    return "\n".join("  ".join(cell.ljust(width) for cell, width in zip(row, widths)).rstrip()
                     for row in cells)


def row_of(label: list[str], results: list[dict], per_run: bool) -> list:
    runs = len(results)
    scale = 1 / runs if per_run else 1
    total = lambda field: sum(result[field] for result in results) * scale
    failed = Counter()
    for result in results:
        failed.update(result["failed_methods"])
    names = " ".join(f"{name}x{count}" for name, count in failed.most_common()) or "-"
    return [*label, f"{sum(result['passed'] for result in results)}/{runs}",
            f"{total('tool_calls'):.1f}", sum(result["tool_errors"] for result in results), names,
            f"{total('input_tokens'):.0f}", f"{total('output_tokens'):.0f}",
            f"{total('seconds'):.1f}"]


def report(results: list[dict], models: list[str], names: list[str]):
    measures = ["pass", "tool calls", "errors", "failed methods", "input", "output", "seconds"]
    rows = []
    for name in names:
        for model in models:
            subset = [r for r in results if r["task"] == name and r["model"] == model]
            if subset:
                rows.append(row_of([name, model], subset, True))
    print("\nPer task and model (tool calls, tokens and seconds are means per run; errors a sum):")
    print(table(["task", "model", *measures], rows))
    totals = [row_of([model], [r for r in results if r["model"] == model], False)
              for model in models if any(r["model"] == model for r in results)]
    print("\nTotals per model:")
    print(table(["model", *measures], totals))


def default_out() -> Path:
    head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, text=True,
                          capture_output=True).stdout.strip()
    return ROOT / "bin" / "agent_tasks" / (head or "local")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--tasks", help="names of tasks, comma-separated; all by default")
    parser.add_argument("--models", default="haiku,sonnet", help="models, comma-separated")
    parser.add_argument("--runs", type=int, default=3, help="runs per task and model")
    parser.add_argument("--out", type=Path, default=None, help="output folder, under bin/")
    parser.add_argument("--timeout", type=float, default=600, help="seconds an agent may take")
    parser.add_argument("--no-agent", action="store_true", help="only the setup and the checks")
    args = parser.parse_args()
    out = (args.out or default_out()).resolve()
    models = [model for model in args.models.split(",") if model]
    built: set[str] = set()
    results = []
    try:
        tasks = load_tasks(args.tasks.split(",") if args.tasks else None)
        for task in tasks:
            for model in models[:1] if args.no_agent else models:
                for run in range(1, 2 if args.no_agent else args.runs + 1):
                    result = run_task(task, model, run, out, args.timeout, built, args.no_agent)
                    if args.no_agent:
                        print(f"{task['name']}: {len(result['failures'])} checks fail")
                    else:
                        results.append(result)
                        print(f"{task['name']} {model} run{run}: "
                              f"{'pass' if result['passed'] else 'FAIL'}, "
                              f"{result['tool_calls']} calls, {result['tool_errors']} errors, "
                              f"{result['seconds']} s"
                              f"{', timed out' if result['timed_out'] else ''}", flush=True)
                    for failure in result["failures"]:
                        print(f"  {failure}", flush=True)
    except Fatal as error:
        print(f"agent_tasks: {error}", file=sys.stderr)
        return 2
    if results:
        report(results, models, [task["name"] for task in tasks])
    print(f"\nOutput: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
