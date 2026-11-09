# Godot shell: an alternative UI on LIVI's backend

A Godot 4 app as the head unit's whole UI. It embeds a Wayland compositor, so
LIVI's projection video, hosted apps (godot-maps, even LIVI's own Slint UI) and
our own pages are textures in one GPU scene. `livi-core` stays the backend,
unchanged.

Target: the Mobis G5W in a 2024 Kia EV6. That is armv7 with musl, postmarketOS
with GNOME, a Mali-G51 on panfrost (GLES 3, no Vulkan), and a 1920×720 panel.
Development happens in an arm64 postmarketOS VM on the Mac (see "Dev
environment").

## Why

- Slint (LIVI's UI) is good for system pages but weak for rich, animated, map-
  and 3D-heavy UI. Godot is strong there, and godot-maps already runs on it.
- No toolkit can embed other processes' windows by itself. A compositor has to
  sit under or inside the UI. Simula shows a Godot app can be that compositor.
- LIVI is already split into a backend and a UI process, so a second UI is a
  client, not a fork of the backend.

## How LIVI fits (verified in this tree)

- **Backend/UI split.** `livi-core` is the backend. `livi-ui` (Slint) is a client
  over `livi-core-proto`; the Rust client is `livi-core-client`. Our car work
  lives in the core: telemetry, the energy model, preconditioning
  (`livi-core/src/precondition.rs`), the charging stop, night mode.
- **Projection video is a plain Wayland client.**
  - `livi-core` starts `livi-gst-host` with `WAYLAND_DISPLAY` set to the UI's
    compositor (`livi-core/src/services.rs:115-118`).
  - Video goes out through `waylandsink` with dmabuf, with the V4L2 decoders
    ranked first (`livi-video-player/src/lib.rs:58`). Each stream is its own
    toplevel.
- **The compositor control protocol** is what our compositor must implement
  to stand in for `livi-compositor`.
  - `livi-compositor` learns a video surface's **tag** on its control socket
    before the window maps (`livi-compositor/src/ctrl.rs:244-256`,
    `pending_video_tags`), and matches it to the next toplevel
    (`shell.rs:126`).
  - Placement comes from `VideoCfg`: screen, crop, visible area and tier
    (`state.rs:36-46`), applied by `layout.rs:17-60`.
- **Touch to the phone goes through the core.** A UI sends
  `Message::Input { input: Input::Pointer { screen, points } }`
  (`livi-core-proto/src/message.rs:17`), with points normalised 0–1 over the
  projection area. The core turns them into phone touches
  (`livi-core/src/projection/input.rs`). Keys are `Input::Key`. No core change
  is needed.
- **`livi-compositor`** is smithay-based. It serves `xdg_shell`,
  `linux-dmabuf`, `drm_syncobj`, `wl_seat`, `viewporter`, `cursor_shape` and
  `data_device`. It has no `text_input`, popups or XWayland. Its client, dmabuf
  and seat code is the base to reuse in Rust.
- **Android Auto margins.** `projectionViewAreaRight` and the content insets
  (`livi-aa-stack/src/discovery.rs`) let Android Auto use part of the screen,
  for a split layout with a side panel. Whether the phone honours them is
  unverified.

## Precedent: Simula (SimulaVR/Simula, MIT)

- Simula is a Godot 3 fork (`3.x-simula`) with an engine module, `gdwlroots`
  (C++, SimulaVR/gdwlroots), that embeds wlroots. Godot runs the Wayland
  server; `WlrBackend`, `WlrCompositor`, `WlrXdgShell`, `WlrSeat` and
  `WlrXWayland` are nodes.
- It implements wlroots' renderer on Godot's GLES3 rasterizer
  (`gles3_renderer.cpp`), so client buffers become `WlrGLES3Texture`
  (`WlrSurface.get_texture()`). It uses dmabuf when the EGL Wayland bind
  works, tracks damage, and paces clients with `send_frame_done()`.
- Input goes through `WlrSeat`/`WlrKeyboard` with a keycode map. XWayland is
  supported.
- It runs on the GLES3 path, the same as our Mali. It's a daily-driver window
  manager.

## Architecture

```
godot-shell (Godot 4, GLES3 compatibility renderer)
├── gdext extension (Rust, godot-rust/gdext)
│   ├── compositor: smithay, from livi-compositor's code
│   │     clients' dmabuf/shm -> EGLImage -> GL texture
│   │     -> RenderingServer.texture_create_from_native_handle
│   ├── livi-compositor control protocol (video tags, VideoCfg)
│   └── core client: livi-core-client (state, actions, Input::Pointer/Key)
├── scenes: home, projection view (full or split), side panel, maps, stats,
│   car pages
└── hosted apps as textures: godot-maps, LIVI's Slint UI (settings and media at
    first), anything else that speaks Wayland
livi-core (unchanged), started with WAYLAND_DISPLAY = the shell's socket
livi-gst-host (unchanged) -> waylandsink -> the shell's compositor
```

Hosting LIVI's own Slint UI as a window lets the shell start small: it does
home, maps, the dashboard and projection layout, and shows LIVI's settings and
media pages until (if ever) they are rewritten.

## Milestones

1. **Toolchain.**
   - Build gdext for the arm64 VM and for armv7-musl (cross, as livi-headunit
     does).
   - Load it in Alpine's Godot 4.7 (`godot` and `godot-templates`).
   - Check that `livi-core-client` links from the extension.
2. **Compositor in Godot.**
   - A minimal smithay server in the extension, with `xdg_shell` and shm.
     Show `weston-terminal` as a `TextureRect`.
   - Then dmabuf, through EGLImage and a native GL texture.
   - Then input: pointer, touch and keyboard, through `wl_seat`.
3. **LIVI's video.**
   - Implement `livi-compositor`'s control protocol (the tags and `VideoCfg`).
   - Start `livi-core` against the shell's socket.
   - Show Android Auto as a texture; send touches as `Input::Pointer`.
4. **Layout.** Full-screen projection, a split with a side panel (the
   `projectionViewAreaRight` margin), and switching.
5. **Hosting.** godot-maps, then LIVI's Slint UI, as windows in a region.
6. **Pages.** Home, side panel (drive stats, the preconditioning toggle from
   the core's `PreconditionBattery` and status), stats and graphs (from the
   core's telemetry), the launcher (desktop entries and icon themes).
7. **On the unit.**
   - armv7 build and package.
   - Measure Android Auto decode plus Godot compositing on the Mali-G51
     (frame rate and latency), idle CPU and GPU with low-processor mode, and
     memory.

Go or no-go after 7: if the Mali can't composite the projection and Godot at a
usable rate, stop; the work up to 6 is still usable as hosted pages under
`livi-compositor`.

## Open questions

- gst-host's toplevels: what `app_id` and title they carry, and how the control
  socket's tag handshake runs end to end. Read `livi-compositor/src/ctrl.rs`
  in full.
- Whether `livi-ui` also drives the compositor's control socket, or only the
  core does. That decides what the shell must answer.
- Godot 4 interop: `texture_create_from_native_handle` with GL textures made
  from EGLImages on panfrost, and the sync with Godot's render thread.
- Text input and an on-screen keyboard for hosted apps (no `text_input` yet).
  Godot's own controls need their own keyboard.
- Running directly on DRM/KMS without GNOME later: smithay can, Godot would
  need to run on our compositor's output. That's out of scope until the above
  works.

## Dev environment

An arm64 postmarketOS GNOME VM on the Mac, running in QEMU with HVF, Mesa
llvmpipe and ssh. Scripts and image are in nura-G5W-Android `vm/qemu-aarch64/`;
see its README. The shell runs nested inside the VM's GNOME. The VM is for
functional work only; performance is measured on the unit.

## References

- Simula: https://github.com/SimulaVR/Simula, https://github.com/SimulaVR/gdwlroots
- godot-rust gdext: https://github.com/godot-rust/gdext
- smithay: https://github.com/Smithay/smithay (livi-compositor's base)
- Godot `RenderingServer.texture_create_from_native_handle`
- LibGodot (experimental since 4.6): Godot as a library, if the shell should
  embed Godot rather than be a Godot app
- godot-maps: ../godot-maps, branch `armv7`
