# What a Linux machine needs before scripts/setup_linux_deps.py: uv, a C compiler,
# the headers SDL3 is built against, a Vulkan loader with a driver (lavapipe
# renders on the CPU, with ray queries) and the validation layer with the
# SPIR-V tools. Odin is not packaged: mount or install it and put it in PATH.
#   docker build -t mirai-linux -f scripts/linux.Dockerfile scripts
FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive
# uv runs the scripts of scripts/ and downloads the Python they ask for.
COPY --from=ghcr.io/astral-sh/uv:0.13.1 /uv /uvx /usr/local/bin/
RUN apt-get update && apt-get install -y --no-install-recommends \
    clang make cmake ninja-build pkg-config git curl ca-certificates xz-utils \
    libvulkan1 mesa-vulkan-drivers vulkan-tools vulkan-validationlayers spirv-tools spirv-cross \
    libx11-dev libxext-dev libxcursor-dev libxi-dev libxrandr-dev libxfixes-dev libxss-dev libxtst-dev libxkbcommon-dev \
    libasound2-dev libpulse-dev libudev-dev libdbus-1-dev \
    && rm -rf /var/lib/apt/lists/*
# A display for what opens a real window: xvfb-run -a ./mirai test editor ...
RUN apt-get update && apt-get install -y --no-install-recommends xvfb xauth && rm -rf /var/lib/apt/lists/*
