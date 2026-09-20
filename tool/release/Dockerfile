FROM debian:trixie-slim@sha256:7792b1f7702a86946cd518db72b6a407302c3e9bc1635634368b878189e8221c
# All package downloads are checked by Debian's signed Release/Packages metadata.
# Snapshot date is fixed; package installation happens only in this builder.
RUN printf 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20260920T000000Z trixie main\n' > /etc/apt/sources.list && \
    rm /etc/apt/sources.list.d/debian.sources && \
    apt-get -o Acquire::Check-Valid-Until=false update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl git xz-utils unzip python3 build-essential clang cmake ninja-build \
      pkg-config patchelf dpkg-dev libgtk-3-dev liblzma-dev libudev-dev libdbus-1-dev \
      libgbm-dev libegl-dev libgles-dev libvulkan-dev libwayland-dev wayland-protocols \
      libxkbcommon-dev libsystemd-dev libdrm-dev libpugixml-dev libgstreamer1.0-dev \
      libgstreamer-plugins-base1.0-dev libssl-dev libusb-1.0-0-dev \
      gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-libav
WORKDIR /workspace
ENTRYPOINT ["python3", "/source/tool/release/build-standard.py", "--source", "/source", "--work", "/workspace/build"]
