# TODO

- Drop `native/crates/livi-video-player/src/wayland_relay.rs` (and its use in the projection
  `Player`) once Alpine ships GStreamer ≥ 1.30. It works around waylandsink keeping `next_buffer`
  when the compositor dies (leaks the CODA decoder's CMA), fixed upstream in 8cb22bbf
  ("wayland: Rework memory referencing and thread safety", MR !11157); 1.28 is still affected.
  Verify with `display_restart_tests.rs` against the new GStreamer before removing.
- livi-core with a new livi-helperd stops `livi-wifi-ap` to reinstall its unit (`--install-wifi-ap`), then
  logs "livi-wifi-ap.service not installed, the helper does not run as root" though the unit was
  written, and never starts the AP again (unit, 2026-11-11 04:52). The AP needs a manual
  `systemctl start livi-wifi-ap`; the install path should restart it whatever the check says.
- Road speed limit to LIVI: the camera's limit already arrives over micom (`0d8f018d 2d` byte 14, go-micomd decodes
  it) but micom-livi and livi-core-proto drop it; unit (mph/km/h) and a ~21 s sign timeout unverified. Layout, gap and
  in-car checks: `godot-shell/ref/notes/speed-limit.md` (local, vendor-derived).
- EV settings' writes (schedules, charge limits, AC current) are built but untried on the car; first writes per the in-car checklist in `godot-shell/docs/ev-settings.md`.
- EV schedule writes are blocked on checking stock's 0x8C55 read layout against a set timer. The car reports `f5 2c 35 0c 0c 00 00 00`, which is 12:00/12:00, no days and departure 1 off, i.e. nothing set. That has only ever been seen at defaults. Confirm whether a weekday departure is actually set; if not, set 07:30 Mon–Fri from the Kia app and expect `.. 67 0c 55 05 00` (go-micomd 03f8977c decodes it). A mismatch means the layout is wrong.
- Shell startup on the unit: the `[startup]` marks and checks in `godot-shell/docs/startup.md`, "On the unit" (VM only so far).
- Fake GPS for parked and VM tests (hippod GPX replay, livi-core ignoring simulated fixes for clock and timezone), stock map data in tcc803x-qemu (blocked on GLES 2): `godot-shell/docs/gnss-and-stock-nav.md`.
