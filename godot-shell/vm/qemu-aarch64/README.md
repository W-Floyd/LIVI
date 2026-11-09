# postmarketOS arm64 VM (QEMU + HVF)

A Linux dev VM on the Mac for the Godot shell: postmarketOS edge
(`qemu-aarch64`, `linux-postmarketos-stable`), GNOME on Wayland, Mesa llvmpipe,
Rust, clang, Godot 4 and weston. The pmaports tree is nura's fork, so the OS
calls itself "Nura edge".

## Use

```sh
./run.sh                      # cocoa window, foreground; quit the window or --stop
./run.sh --headless           # no window, daemonized (pid in qemu.pid)
./run.sh --headless --vnc 1   # headless, plus VNC on 127.0.0.1:5901
./run.sh --stop               # clean shutdown
ssh -p 2222 user@localhost    # key from SSH_PUBKEY at build; password nura (sudo too)
```

`CPUS` (6) and `MEM` (8G) override the defaults, and arguments after the
options go to qemu.

GNOME logs `user` in automatically, and lock, blanking, dimming and suspend on
idle are off, so a session is always up, even headless. From ssh, use it with:

```sh
export XDG_RUNTIME_DIR=/run/user/10000 WAYLAND_DISPLAY=wayland-0
weston --backend=wayland --socket=wayland-nested &   # nested compositor
eglinfo -B                                           # llvmpipe
```

For X11 clients add `DISPLAY=:0 XAUTHORITY=$(ls /run/user/10000/.mutter-Xwaylandauth.*)`.

Screenshot, any mode: `echo "screendump $PWD/s.ppm" | nc -U monitor.sock`.

## Inside

- `pmos.qcow2`: 20 GB virtual, about 3 GB on disk. The initramfs grows the root
  partition to fill the disk on first boot.
- Boot: edk2 UEFI (Homebrew's `edk2-aarch64-code.fd`, variables in
  `efi-vars.fd`) loads systemd-boot from the image's FAT boot partition. No
  `-kernel`/`-initrd`. This is the same path `pmbootstrap qemu` takes.
- Devices: `virt,highmem=on`, HVF with `-cpu host`, virtio-blk, virtio-net (user
  mode networking, host 127.0.0.1:2222 to guest 22), virtio-gpu-pci (no virgl, so
  GL is llvmpipe), virtio keyboard and tablet, and a virtio-serial port for
  `qemu-guest-agent`.
- Control sockets in this folder: `qmp.sock` (QMP), `monitor.sock` (HMP),
  `qga.sock` (guest agent). Serial console goes to `serial.log`.
- Extra packages: see `pmbootstrap.cfg`. The GNOME UI also brings its
  recommended apps (Firefox and the GNOME apps).
- `overlay/` goes into the rootfs at build time: gdm autologin, the gschema
  override (no idle, lock, suspend or welcome tour, and a power button that
  does nothing) and the guest agent unit.

## Quirks

- `--stop` shuts down through the guest agent. GNOME holds logind's
  power-key inhibitor, so ACPI `system_powerdown` is ignored while the
  session is up. The ACPI powerdown and QMP `quit` are fallbacks.
- The window: the tablet is an absolute pointer, so no grab is needed. If
  the keyboard does get grabbed, Ctrl+Option+G releases it.
- sshd can refuse the password for a few seconds right after boot. Retry it.
  If ssh offers many agent keys first, the server cuts the login off; use
  `-o PubkeyAuthentication=no` or `ssh-copy-id -p 2222 user@localhost`.
- If you add a PCI device: the disk has `bootindex=0` because the boot
  entries in `efi-vars.fd` record PCI slots. Without it edk2 drops to its shell.
  If the VM ever boots to `Shell>`, delete `efi-vars.fd`.

## Rebuild

```sh
./build.sh      # about 1 min with a warm cache; refuses if pmos.qcow2 exists
```

The image is built with pmbootstrap in nura's builder container
(`NURA_DIR`, default `/Users/william/Documents/Personal/git/nura-G5W-Android`).
It uses its own config (`pmbootstrap.cfg`, copied into the container as
`~/.config/pmbootstrap-qemu-aarch64.cfg`) and its own rootfs
(`chroot_rootfs_qemu-aarch64`). The head unit's config, rootfs and packages
are not touched. The work dir and package caches are shared.

The steps:

1. `pmbootstrap install --no-image` builds the rootfs.
2. `overlay/` is untarred into it, and `glib-compile-schemas` runs. The Mac's
   `SSH_PUBKEY` (default `~/.ssh/id_ed25519.pub`) becomes `user`'s
   `authorized_keys`.
3. `pmbootstrap install --no-split` writes the image.
4. The raw image is streamed to the Mac, converted to qcow2 and grown to `SIZE`
   (20G).

The build stops if the Mac's free space drops below 15 GB.

The rootfs is reused between builds. A file removed from `overlay/` stays in
it until it is deleted from `chroot_rootfs_qemu-aarch64` in the container.

`pmbootstrap shutdown` runs before and after the build, because stale
`/dev/installp*` nodes from an earlier install make mkfs fail. It also
unregisters pmbootstrap's own `qemu-arm` binfmt handler. pmbootstrap registers
it again on its next armv7 build, and Docker's `arm` handler stays.
