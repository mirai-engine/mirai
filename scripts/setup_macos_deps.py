#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.15"
# dependencies = []
# [tool.uv]
# required-version = ">=0.13"
# ///
"""Dependencies of Mirai on macOS that a package of the engine can carry, under
.deps/macos-arm64 (ignored by git):

  sdl3/lib/        the SDL3 of Homebrew with its id under @rpath: what links it
                   finds it next to itself, so the binaries of the engine and a
                   shipped game do not need /opt/homebrew
  spirv-tools/     spirv-val, spirv-opt and spirv-cross of Homebrew, side by
                   side with the libraries of SPIR-V they load

`mirai` prefers them to Homebrew's once they are there; `mirai package engine`
needs them. Needs Homebrew with sdl3, spirv-tools and spirv-cross, and the Xcode
Command Line Tools (install_name_tool, otool, codesign).
"""

import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEPS = ROOT / ".deps" / "macos-arm64"
SDL = "libSDL3.0.dylib"
TOOLS = ("spirv-val", "spirv-opt", "spirv-cross")
FORMULAS = ("sdl3", "spirv-tools", "spirv-cross")
# What macOS has in every machine: a dependency elsewhere travels with the tool.
SYSTEM = ("/usr/lib/", "/System/")


def fail(message: str):
    sys.exit(f"setup_macos_deps: {message}")


def run(*command) -> str:
    result = subprocess.run([str(part) for part in command], capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"{' '.join(str(part) for part in command)}: {result.stderr.strip()}")
    return result.stdout


def brew_prefix(formula: str) -> Path:
    result = subprocess.run(["brew", "--prefix", "--installed", formula], capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"Homebrew does not have {formula}: brew install {' '.join(FORMULAS)}")
    return Path(result.stdout.strip())


def load_commands(binary: Path) -> tuple[list[str], list[str]]:
    libraries, rpaths = [], []
    command = ""
    for line in run("otool", "-arch", "arm64", "-l", binary).splitlines():
        key, _, value = line.strip().partition(" ")
        if key == "cmd":
            command = value
        elif command == "LC_RPATH" and key == "path":
            rpaths.append(value.rsplit(" (offset ", 1)[0])
        elif key == "name" and command in (
            "LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_LAZY_LOAD_DYLIB",
            "LC_LOAD_UPWARD_DYLIB", "LC_REEXPORT_DYLIB",
        ):
            libraries.append(value.rsplit(" (offset ", 1)[0])
    return libraries, rpaths


def load_path(name: str, loader: Path, executable: Path) -> Path:
    prefix, _, relative = name.partition("/")
    if prefix == "@loader_path":
        return loader.parent / relative
    if prefix == "@executable_path":
        return executable.parent / relative
    return Path(name)


def resolve_library(name: str, loader: Path, executable: Path, rpaths: tuple[Path, ...]) -> Path:
    if name.startswith("@rpath/"):
        candidates = (path / name.removeprefix("@rpath/") for path in rpaths)
    else:
        candidates = (load_path(name, loader, executable),)
    for path in candidates:
        if path.is_file():
            return path.resolve()
    fail(f"{loader} loads {name}, which could not be found")


def place(source: Path, target: Path):
    target.unlink(missing_ok=True)
    shutil.copyfile(source.resolve(), target)
    target.chmod(0o755)


def sign(binary: Path):
    # Changing the load commands of an arm64 binary voids its signature.
    run("codesign", "--force", "--sign", "-", binary)


def sdl3():
    prefix = brew_prefix("sdl3")
    target = DEPS / "sdl3"
    lib = target / "lib"
    lib.mkdir(parents=True, exist_ok=True)
    library = lib / SDL
    place(prefix / "lib" / SDL, library)
    run("install_name_tool", "-id", f"@rpath/{SDL}", library)
    sign(library)
    link = lib / "libSDL3.dylib"
    link.unlink(missing_ok=True)
    link.symlink_to(SDL)
    for notice in ("LICENSE.txt", "share/licenses/SDL3/LICENSE.txt"):
        if (prefix / notice).is_file():
            shutil.copyfile(prefix / notice, target / "LICENSE.txt")
            break
    print(f"SDL3 of {prefix} in {lib}")


def spirv_tools():
    images: dict[str, tuple[Path, dict[str, str]]] = {}
    for tool in TOOLS:
        found = shutil.which(tool)
        if found is None:
            fail(f"{tool} is missing from PATH: brew install {' '.join(FORMULAS)}")
        executable = Path(found).resolve()
        seen = set()
        pending = [(executable, tool, ())]
        while pending:
            source, file, inherited = pending.pop()
            original, rewrites = images.setdefault(file, (source, {}))
            if original != source:
                fail(f"{file} resolves to both {original} and {source}")
            if file in seen:
                continue
            seen.add(file)
            names, run_paths = load_commands(source)
            rpaths = tuple(load_path(path, source, executable) for path in run_paths) + inherited
            for name in names:
                if name.startswith(SYSTEM):
                    continue
                library = Path(name).name
                if "spirv" not in library.lower():
                    fail(f"{source.name} loads {name}, which the SPIR-V bundle cannot carry")
                dependency = resolve_library(name, source, executable, rpaths)
                rewrites[name] = f"@loader_path/{library}"
                pending.append((dependency, library, rpaths))

    target = DEPS / "spirv-tools"
    shutil.rmtree(target, ignore_errors=True)
    target.mkdir(parents=True)
    for file, (source, rewrites) in images.items():
        binary = target / file
        place(source, binary)
        changes = [] if file in TOOLS else ["-id", f"@rpath/{file}"]
        for name, portable in rewrites.items():
            if name != portable:
                changes.extend(["-change", name, portable])
        if changes:
            run("install_name_tool", *changes, binary)
        sign(binary)
    for formula in ("spirv-tools", "spirv-cross"):
        notice = brew_prefix(formula) / "LICENSE"
        if notice.is_file():
            shutil.copyfile(notice, target / f"LICENSE-{formula}")
    bundled = sorted(images.keys() - set(TOOLS))
    print(f"{', '.join(TOOLS)} in {target}" + (f" with {', '.join(bundled)}" if bundled else ""))


def main():
    if sys.platform != "darwin":
        fail("this is for macOS; Linux has scripts/setup_linux_deps.py")
    for tool in ("brew", "otool", "install_name_tool", "codesign"):
        if shutil.which(tool) is None:
            fail(f"{tool} is missing from PATH")
    sdl3()
    spirv_tools()
    print(f"Dependencies ready in {DEPS}.")


if __name__ == "__main__":
    main()
