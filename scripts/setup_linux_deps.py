#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.15"
# dependencies = []
# [tool.uv]
# required-version = ">=0.13"
# ///
"""Dependencies of Mirai on Linux, without sudo, under .deps/linux-amd64
(ignored by git):

  odin/        an Odin root for the installed compiler: its base, core and
               shared, and a copy of vendor/ with the stb libraries (image,
               truetype, vorbis) and cgltf compiled from their C sources
  sdl3/        SDL3 built from source as a shared library: X11 (and Wayland
               when its headers are installed), Vulkan, audio and gamepads
  vulkan-sdk/  the validation layer and the SPIR-V tools of the LunarG SDK,
               when the system has none or VULKAN_SDK_VERSION names one

`mirai` finds all of it by itself: after this script the commands are the
ones of every platform.

Needs odin (in PATH or MIRAI_ODIN), cc, ar, cmake, ninja or make and the
development headers of X11, of ALSA, PulseAudio or PipeWire, and of udev.
scripts/linux.Dockerfile lists the packages of Ubuntu.
"""

import fnmatch
import hashlib
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEPS = ROOT / ".deps" / "linux-amd64"
SDL_VERSION = os.environ.get("SDL3_VERSION") or "3.4.2"
SDL_SHA256 = "ef39a2e3f9a8a78296c40da701967dd1b0d0d6e267e483863ce70f8a03b4050c"
VULKAN_SDK_VERSION = os.environ.get("VULKAN_SDK_VERSION") or "1.4.363.0"
VULKAN_SDK_FILES = (
    "*/x86_64/bin/spirv-val", "*/x86_64/bin/spirv-opt", "*/x86_64/bin/spirv-cross",
    "*/x86_64/lib/libVkLayer_khronos_validation.so",
    "*/x86_64/share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json",
)


def fail(message: str):
    sys.exit(f"setup_linux_deps: {message}")


def need(*tools: str):
    for tool in tools:
        if shutil.which(tool) is None:
            fail(f"{tool} is missing from PATH")


def marker(path: Path) -> str | None:
    try:
        return path.read_text().strip()
    except OSError:
        return None


def download(url: str, path: Path):
    # sdk.lunarg.com answers 403 to the User-Agent of urllib.
    request = urllib.request.Request(url, headers={"User-Agent": "mirai-setup"})
    with urllib.request.urlopen(request) as response, open(path, "wb") as file:
        shutil.copyfileobj(response, file)


def run_logged(command: list, log: Path, message: str):
    with open(log, "w") as output:
        if subprocess.run(command, stdout=output, stderr=subprocess.STDOUT).returncode != 0:
            fail(f"{message}: {log}")


def odin_root(odin: str):
    """The copy belongs to one compiler: another version or installation replaces it."""
    environment = {k: v for k, v in os.environ.items() if k != "ODIN_ROOT"}
    install = Path(subprocess.run([odin, "root"], env=environment, capture_output=True, text=True, check=True).stdout.strip())
    if not (install / "vendor" / "stb" / "src").is_dir():
        fail(f"{install} is not the root of an Odin installation")
    version = subprocess.run([odin, "version"], capture_output=True, text=True, check=True).stdout.strip()
    identity = f"{version} {install}"
    target = DEPS / "odin"
    vendor = target / "vendor"
    if (vendor / "stb" / "lib" / "stb_vorbis.a").is_file() and (vendor / "cgltf" / "lib" / "cgltf.a").is_file() \
            and marker(target / ".compiler") == identity:
        return
    print(f"Odin: stb and cgltf in {target}")
    shutil.rmtree(target, ignore_errors=True)
    target.mkdir(parents=True)
    for part in ("base", "core", "shared"):
        (target / part).symlink_to(install / part)
    shutil.copytree(install / "vendor", vendor, symlinks=True)
    environment = {**os.environ, "ODIN_ROOT": str(target)}
    for library in ("stb", "cgltf"):
        subprocess.run(["sh", str(vendor / library / "src" / f"build_{library}.sh"), "unix"], env=environment, check=True)
    (target / ".compiler").write_text(identity + "\n")


def sdl3():
    target = DEPS / "sdl3"
    if (target / "lib" / "libSDL3.so.0").is_file() and marker(target / ".version") == SDL_VERSION:
        return
    need("cmake")
    print(f"SDL3 {SDL_VERSION} in {target}")
    if shutil.which("ninja"):
        generator = ["-G", "Ninja"]
    else:
        need("make")
        generator = []
    source = DEPS / "src" / f"SDL3-{SDL_VERSION}"
    if not source.is_dir():
        archive = DEPS / "src" / f"SDL3-{SDL_VERSION}.tar.gz"
        download(f"https://github.com/libsdl-org/SDL/releases/download/release-{SDL_VERSION}/SDL3-{SDL_VERSION}.tar.gz", archive)
        if SDL_VERSION == "3.4.2" and hashlib.sha256(archive.read_bytes()).hexdigest() != SDL_SHA256:
            fail(f"the SHA-256 of {archive} is not the expected one")
        with tarfile.open(archive) as tar:
            tar.extractall(DEPS / "src", filter="data")
        archive.unlink()
    build = source / "build"
    shutil.rmtree(build, ignore_errors=True)
    shutil.rmtree(target, ignore_errors=True)
    run_logged(["cmake", "-S", source, "-B", build, *generator, "-DCMAKE_BUILD_TYPE=Release",
                f"-DCMAKE_INSTALL_PREFIX={target}", "-DCMAKE_INSTALL_LIBDIR=lib",
                "-DSDL_SHARED=ON", "-DSDL_STATIC=OFF", "-DSDL_TEST_LIBRARY=OFF", "-DSDL_TESTS=OFF", "-DSDL_EXAMPLES=OFF",
                "-DSDL_X11=ON", "-DSDL_VULKAN=ON", "-DSDL_AUDIO=ON", "-DSDL_JOYSTICK=ON", "-DSDL_HIDAPI=ON",
                "-DSDL_CAMERA=OFF", "-DSDL_GPU=OFF", "-DSDL_RENDER=OFF", "-DSDL_OPENGL=OFF", "-DSDL_OPENGLES=OFF"],
               DEPS / "src" / "sdl3-configure.log", "cmake could not configure SDL3")
    # SDL builds without what it does not find: a window, sound and gamepads are required here.
    config = next(build.rglob("SDL_build_config.h"), None)
    if config is None:
        fail(f"cmake did not generate SDL_build_config.h in {build}")
    text = config.read_text()
    for pattern, missing in (
        (r"SDL_VIDEO_DRIVER_X11", "X11: its headers are missing (libx11-dev, libxext-dev, libxcursor-dev, libxi-dev, libxrandr-dev)"),
        (r"SDL_AUDIO_DRIVER_(ALSA|PULSEAUDIO|PIPEWIRE)", "audio: the headers of ALSA, PulseAudio or PipeWire are missing (libasound2-dev, libpulse-dev)"),
        (r"SDL_JOYSTICK_LINUX", "gamepads"),
        (r"HAVE_LIBUDEV_H", "udev: gamepads would not be detected when connected (libudev-dev)"),
    ):
        if not re.search(rf"^#define {pattern} ", text, re.MULTILINE):
            fail(f"SDL3 was built without {missing}")
    run_logged(["cmake", "--build", build, f"-j{os.process_cpu_count()}"], DEPS / "src" / "sdl3-build.log", "SDL3 did not build")
    subprocess.run(["cmake", "--install", build], stdout=subprocess.DEVNULL, check=True)
    (target / ".version").write_text(SDL_VERSION + "\n")


def vulkan_sdk():
    data_home = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    layer = any((Path(folder) / "vulkan" / "explicit_layer.d" / "VkLayer_khronos_validation.json").is_file()
                for folder in ("/usr/share", "/usr/local/share", "/etc", data_home))
    tools = all(shutil.which(tool) for tool in ("spirv-val", "spirv-opt", "spirv-cross"))
    target = DEPS / "vulkan-sdk"
    wanted = bool(os.environ.get("VULKAN_SDK_VERSION")) or not layer or not tools
    if not wanted or marker(target / ".version") == VULKAN_SDK_VERSION:
        return
    if platform.machine() != "x86_64":
        fail("LunarG only publishes the Vulkan SDK for x86_64: install the validation layer and spirv-tools of the system")
    print(f"Vulkan SDK {VULKAN_SDK_VERSION}: validation layer and SPIR-V tools in {target}")
    archive = DEPS / "src" / "vulkan-sdk.tar.xz"
    download(f"https://sdk.lunarg.com/sdk/download/{VULKAN_SDK_VERSION}/linux/vulkansdk-linux-x86_64-{VULKAN_SDK_VERSION}.tar.xz", archive)
    shutil.rmtree(target, ignore_errors=True)
    target.mkdir(parents=True)
    with tarfile.open(archive) as tar:
        for member in tar:
            if any(fnmatch.fnmatchcase(member.name, pattern) for pattern in VULKAN_SDK_FILES):
                member.name = member.name.split("/", 2)[2]
                tar.extract(member, target, filter="data")
    archive.unlink()
    (target / ".version").write_text(VULKAN_SDK_VERSION + "\n")


def main():
    need("cc", "ar")
    odin = shutil.which(os.environ.get("MIRAI_ODIN") or "odin")
    if odin is None:
        fail("Odin is neither in PATH nor in MIRAI_ODIN")
    (DEPS / "src").mkdir(parents=True, exist_ok=True)
    odin_root(odin)
    sdl3()
    vulkan_sdk()
    subprocess.run([ROOT / "mirai", "deps"], check=True)
    print(f"Dependencies ready in {DEPS}.")


if __name__ == "__main__":
    main()
