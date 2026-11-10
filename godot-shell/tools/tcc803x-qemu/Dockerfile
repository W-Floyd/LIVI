FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git ca-certificates python3 python3-venv python3-pip ninja-build pkg-config \
    libglib2.0-dev libpixman-1-dev libfdt-dev flex bison device-tree-compiler \
    gdb-multiarch xz-utils file gdisk python3-capstone && rm -rf /var/lib/apt/lists/*
WORKDIR /work
