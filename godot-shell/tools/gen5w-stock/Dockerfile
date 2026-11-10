FROM ubuntu:20.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    gcc-arm-linux-gnueabihf make bc bison flex libssl-dev libelf-dev xz-utils cpio gzip \
    e2fsprogs gdisk qemu-utils python3 ca-certificates patch rsync file \
    gcc libc6-dev lz4 > /dev/null && rm -rf /var/lib/apt/lists/*
