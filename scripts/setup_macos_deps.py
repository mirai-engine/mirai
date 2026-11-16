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


def dependencies(binary: Path) -> list[str]:
    """What a binary loads, as its load commands name it; a library's own id is not."""
    lines = run("otool", "-L", binary).splitlines()[1:]
    names = [line.strip().split(" (")[0] for line in lines if line.strip()]
    own = run("otool", "-D", binary).splitlines()[1:]
    return [name for name in names if name not in own]


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
    target = DEPS / "spirv-tools"
    shutil.rmtree(target, ignore_errors=True)
    target.mkdir(parents=True)
    pending = []
    for tool in TOOLS:
        found = shutil.which(tool)
        if found is None:
            fail(f"{tool} is missing from PATH: brew install {' '.join(FORMULAS)}")
        binary = target / tool
        place(Path(found), binary)
        run("install_name_tool", "-add_rpath", "@executable_path", binary)
        pending.append(binary)
    bundled = set()
    while pending:
        binary = pending.pop()
        for name in dependencies(binary):
            if name.startswith(SYSTEM) or name.startswith("@"):
                continue
            file = Path(name).name
            # mirai package engine carries, beside each tool, the libraries of SPIR-V of its folder.
            if "spirv" not in file.lower():
                fail(f"{binary.name} loads {name}, which is not a library of SPIR-V and a package would not carry")
            run("install_name_tool", "-change", name, f"@rpath/{file}", binary)
            if file not in bundled:
                bundled.add(file)
                library = target / file
                place(Path(name), library)
                run("install_name_tool", "-id", f"@rpath/{file}", library)
                run("install_name_tool", "-add_rpath", "@loader_path", library)
                pending.append(library)
        sign(binary)
    for formula in ("spirv-tools", "spirv-cross"):
        notice = brew_prefix(formula) / "LICENSE"
        if notice.is_file():
            shutil.copyfile(notice, target / f"LICENSE-{formula}")
    print(f"{', '.join(TOOLS)} in {target}" + (f" with {', '.join(sorted(bundled))}" if bundled else ""))


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
