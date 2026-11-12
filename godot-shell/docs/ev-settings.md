# EV settings: car integration

What the EV page's settings (`project/ui/ev_settings.gd`, paths in `project/ui/ev_settings_link.gd`)
need from the car, what is known, and how to settle the rest in the car. EV6 Gen5W, CAN DB generation 2.

All micom frames below are HEVService: tx `88 0c 01 0c` func 0x0Cxx, rx `0c 88 01 8c` func 0x8Cxx; item = 0x8C02
`[id][value]`; 0x8C01 = bulk answer to 0x0C01. "Pulse" = value, then the idle value 120 ms later (stock).

Sources:
- **S**: stock HEVService/HEVManager/TAppEV3 decompile (V015), `ref/notes/micom-survey.md` (local, gitignored).
- **G**: go-micomd `docs/spec/kia-ev6-gen5w.md`, `variants/kia-ev6-gen5w.yaml`.
- **C**: go-micomd frame captures 2026-11 (charging, driving, parked preconditioning); go-micomd sends almost no
  requests, so request-only answers (0x8C01, 0x8C4A..55 startup reads) are mostly absent.
- **M**: EV6 owner's manual, EV guide pp. 1-8 to 1-16. **A**: stock EV app strings (HKMC_TAppEV3).
- **E**: stock V015 under `tools/tcc803x-qemu` with go-micomd's `micom-fake`: the frames its EV settings send.

## State today

| Setting (page id) | Read | Write |
|---|---|---|
| Charge limit AC/DC (`charge_limit_ac/dc`) | ✓ `chargeLimitAc/DcPct` (micom-livi, items 0x21/0x22), never yet seen on the wire | none: row read-only |
| AC charging current (`ac_current`) | none | none |
| Departure 1/2 (`departure_1/2`) | ✓ `departure1/2` (micom-livi, 0x8C55 + 0x8C53 [0]) | ✓ `setEvSchedule` → micom-livi `ev-departures` (0x0C06), **only with `-ev-schedule-writes`**, parked |
| Off-peak window, off-peak mode (`off_peak`, `off_peak_mode`) | ✓ `offPeak`, `scheduledChargingMode` (0x8C53) | ✓ as above, `ev-off-peak` (0x0C05); mode code 1 never |
| Scheduled charging (`scheduled_charging`) | none (0x8C4A [3] not decoded) | none |
| Climate at departure, defog | ✓ `scheduledClimate`, `scheduledClimateDefrost` (0x8C53 [7], 0x8C54 [0]) | ✓ as departures |
| Climate temperature (`climate_temp`) | ✓ `scheduledClimateTempCode`, the raw code only | none: encoding unknown; sent back as read |
| Battery conditioning (`battery_conditioning`) | ✓ `batteryConditioningMode`, `batteryConditioning`, `batteryConditioningError` | ✓ LIVI's `preconditionBattery` action; micom-livi holds batt-cond-mode (0x0C62) on while it lasts, **only with `-precondition`** |
| Before a fast charger (LIVI's own) | ✓ `preconditionState/Why` | ✓ `batteryPreconditioning` config |
| Winter mode | none | none |
| V2L discharge limit | none | none |
| Utility mode | none | none |

A new read is: a TelemetrySnapshot field (`livi-core-proto`, it denies unknown fields), a micom-livi map line, and
the field name in `EvSettingsLink.SETTINGS[...].proposed` moved to `read`. A new write is a go-micomd variant tx
message, a micom-livi opt-in path, a core action, and `write = "core"` with a case in `_write_core`.

## Per setting

### Charge limit, AC and DC
- Write 0x0C18, 7 B: `00 00 [2] 00 [4] [5] [6]`. [0], [1], [3] always 0 (a fresh array, never written); [2] b7:6
  winter mode, 3 = unchanged (gen < 2: b1:0); [4] AC, [5] DC, [6] route target: pct / 0.5, 0xff = unchanged
  (`setTargetSOCext`). **S**
- Stock sends one limit per frame, the rest 0xff and winter 3, copying nothing from the readback: AC 90 %
  `00 00 c0 00 b4 ff ff`, DC 50 % `00 00 c0 00 ff 64 ff`; same frames whatever winter mode or other limit the car
  reports; nothing sent for the value already held; route target never set. **E** (10 % steps 50-100, both)
- Read items 0x21 (AC), 0x22 (DC), 0x31 (route); 0x8C01 [50], [51]; x0.5 %. **S, G**. Items not seen in **C**:
  item updates are on change only. Stock shows a readback of 75 % as 70 %. **E**
- Range at limit: items 0x1f/0x20, seen 406-414 km. **C**
- micomd's `-input` keeps the fields an input omits: LIVI must send the other limits and winter mode as `null`,
  or a DC write resends its last AC value. go-micomd `ev-charge-limits`. **G**
- Kia Connect (TMU, `HKMC_TAppService`) has the 6-byte `setTargetSOC` (AC and DC together, [2] = 0); no caller
  found. **S**
- Unknown: ack beyond the item echo; persistence across ignition (likely VCU-held); whether a value outside
  50-100 or off the 10 % steps is refused or clamped; whether the car really leaves winter mode on 3.
  Without micomd `-hev-status-request` the limits show only once they change.
- Risks: a target below the present SoC stops an AC charge (**M**); Kia Connect sets the same targets: the car's
  readback, not LIVI, is truth.

### AC charging current
- Write 0x0C5B [1 = 100 %, 2 = 90 %, 3 = 60 %], then 0 120-180 ms later. **S, E**. One value for portable and
  station: on this path `setOBCCurrent` sends only the ICCB value; the EV6 app shows one choice. **S, E**
- Path: HEVService flag 82 = 1, set at `onMicomReady` for CAN DB generation >= 1 (0x8C5F may change it); else
  0x0C13 [1, EVSE<<2 | ICCB, 0]. **S**. The app greys the setting until OBC or VCMS ready (0x8C4F [3] b1:0,
  01 on the EV6 unplugged too). **S, E, C**
- Read 0x8C50 [0] b3:2 OBC_CHGINCURRMODSTA, item 0x51: 2 → 90 %, 3 → 60 %, else 100 %. **S, E**
- go-micomd `ev-charging-current`. **G**
- Unknown: raw readback from the car; 0x8C50 is only answered to the 0x0C50 startup read (not in **C**).
- Risk: changing it mid-charge may stop the charge.

### Schedule edits (departures, off-peak, climate)
- Path: the page's `setEvSchedule` action (only the changed fields) → core `evSchedule.request` → GET
  /navigation `evScheduleRequest` → micom-livi rebuilds `ev-departures` / `ev-off-peak` from the car's readback
  with only those fields changed (the variant's `reflects:`), sends via micomd's `-input`, and reports
  `evScheduleWrite` confirmed once the readback matches, failed after 10 s. The core ends the request on that
  word, or after 30 s; the page shows the edit while it stands, then the car's values.
- Gates, all needed: micomd `-allow-dangerous` (both messages are `dangerous`), micom-livi `-input` and
  `-ev-schedule-writes` (off by default; LIVI shows the schedule read-only without it), parked (micom-livi:
  driving regulation known off and gear P or unknown; core: `drivingRegulation` not true and gear P or
  absent; the page: `Drive.moving`).
- Refused, never guessed: any reflected field not yet received (0x8C53 and 0x8C54 arrive only on change or a
  startup read, and micomd sends no startup read for them: on the car on 2026-11-12 only 0x8C55 was held, so
  every edit fails "nothing received yet" until they arrive), a 2-bit day reading 2 or 3, an hour of 31 (stock's
  none), mode code 1.
- The climate temperature (6-bit code, °F - 56 at unit 1 fits two stock points only) is never edited; each
  0x0C06 sends set 1's code back as read, and set 2's temperature and unit copied from it (stock does the same).

### Departures (1, 2) and climate at departure
- Write 0x0C06, 7 B: layout from stock under QEMU (go-micomd `ev-departures`); MSB-first; set 2's climate has
  no readback.
- Read 0x8C55: [3] set 1 hour b4:0 / minute b7:5, [4] set 2, [5] set 1 Mon-Thu (2 bits each), [6] set 1
  enable/Fri-Sun, [7] set 2 Mon-Thu; [0..2] vary per frame, unread. Seen 56814 times, [3], [4] = 0c (12:00,
  nothing set). **S, C**. 0x8C53 [0] set 2 enable/Fri-Sun; [7] b1:0 scheduled climate enable, b7:2 temperature;
  0x8C54 [0] b1:0 defrost, [3] b7:6 temperature unit. **S**
- 3-bit minute: tens of minutes (stock's 7:30 PM packed as minute bits 3).
- Climate is per departure in 0x0C06 but one enable/temperature in 0x8C53. **S**
- Unknown: temperature encoding (0x8C53 [7] = 0x50 → code 20 at default); how "once" (no day) is expressed;
  2-bit day values other than 0/1; whether the car applies a write it then reports.
- Risks: the car's scheduler acts on the HU clock 0x0C09 (micom-livi `-clock`; the variant templates weekday
  and hour, verify against a stock strace): a wrong clock charges or heats at the wrong time; climate runs only
  plugged in (**A**); two writers (LIVI, Kia Connect).

### Scheduled charging, off-peak hours
- Write 0x0C05, 5 B: 4 × (hour, minute; gen ≥ 2 hour << 3 | minute): off-peak start/end, weekday and weekend;
  [4] charge-control mode (gen ≥ 2 << 6). **S**
- Read 0x8C53 [1] start, [2] end (hour b4:0, minute b7:5), [5] b1:0 scheduled-charge mode; 0x8C4A [3] b7:6
  HCU_CHRGCTRLMODSTA; 0x8C4D [0], [1] off-peak start; 0x8C51 end; 0x8C52 / 0x8C54 [4..7] the scheduled window
  the car computed (7/31/63 = none). **S**. 0x8C53 seen 8 times: `00 14 10 02 00 40 00 50` = 20:00-16:00,
  mode 0, climate off. **C**
- Modes: off-peak prioritised (may run past the window) / off-peak only (may not reach 100 %). **M**
- Mode (0x8C53 [5], 0x0C05 [4] b7:6): 0 off, 2 prioritise off-peak, 3 off-peak only (stock under QEMU); 1
  unknown. Stock's EV app sends one window; the weekend bytes go 0 (only their low bits fit).
- Unknown: mode 1; how "scheduled charging off" (0x8C4A [3]) relates to mode 0.
- Risks: as departures (clock, Kia Connect); the 0x8C53 default seen may be the car's, not an empty schedule.

### Battery conditioning mode
- Write 0x0C62 [mode: 0 default, 1 off, 2 on], pulse to 0. go-micomd `batt-cond-mode`; micom-livi
  `-precondition` sends on while LIVI's request lasts. **S, G**
- Read item 0x63, 0x8C01 [141] (`batteryConditioningMode`); running from body 0x53 (`batteryConditioning`,
  captured 68 s after a request); failure item 0x79 / 0x8C01 [182] (1 range, 2 already warm, 3 heat
  management). **S, G, C**
- Stock's setting is persistent ("Battery Conditioning Mode" on/off); LIVI's is a timed request. **A**
- Unknown: whether mode "on" persists across ignition; whether "off" from LIVI's end overrides a driver's stock
  "on"; whether 0x0C62 needs READY.
- Risks: on-mode drains range (**M**); LIVI ending its request sends off, which may turn off a mode the car held.

### Winter mode
- Write 0x0C18 [2] (gen ≥ 2 << 6), the three limits 0xff. **S**. Read item 0x44 XEV_WINTERMODESTA, 0x8C1A [6]
  b2:1, 0x8C01 [94]. **S**
- The app shows it only where Battery Conditioning Mode is not offered; under **E** the EV6 shows battery
  conditioning, so no winter mode frame was captured. **S, E**
- Unknown: values (the app accepts 0-2 back); whether this EV6 has it.

### V2L discharge limit
- Write 0x0C5A [soc], pulse to 0xff. Read item 0x50 CHRG_V2XDISCHRGLIMSOCVAL_SYNC. **S**. Mode 0x0C57 / item 0x4e.
- Unknown: encoding (raw % or / 0.5), range (20-80 % assumed), whether it needs V2L connected.

### Utility mode
- Write 0x0C5D [mode], pulse to 0. Read items 0x58 VCU_UTILMODUSMSTA (seen 0/1 in **C**), 0x59 warning. **S**
- Needs READY and P; off only with the start button; cluster shows UTIL, EPB applies. **M**
- Unknown: the "on" value; the refusal signal (item 0x59?).
- Risk: highest of these: it changes the car's power state. Never send without the driver at the car.

## In-car checklist

Prerequisites: micomd `-record <file>` running throughout; note IGN / READY / plugged state for
each step; each write message added to the variant first, behind `-allow-inferred` and an explicit micom-livi
opt-in; one write per step, read back before the next. Writes are run by the user.

Reads (no writes):
- [ ] micomd `-hev-status-request` (0x0C01 bulk) with IGN on; decode [50], [51] against the limits stock showed;
      [94], [141], [182].
- [ ] Send the startup reads 0x0C4A, 4C, 4D, 4F, 50, 51, 52, 53, 54, 55, 5F; record each answer.
- [ ] 0x8C5F: confirm [0] = 1 (unified AC current path).
- [ ] With stock HU (or the Kia Connect app) set: departure 1 Mon-Fri 07:30, departure 2 Sat 09:10, off-peak
      22:00-06:00 prioritised, climate 21 °C defrost on, limits AC 80 / DC 90, current Reduced, V2L 30 %. Diff
      0x8C53/54/55/4A/4D/50/51/52 and items 0x21/22/3d/50/51 against the empty capture. Repeat with one field
      changed at a time to map bits (minute tens, days, temperature encoding, mode values).
- [ ] Do the same values survive ignition off/on and a 12 V sleep? (readback after wake, before any write)
- [ ] Does the car emit item 0x21/0x22 on change only, or also periodically?

Writes (one at a time; read back via the items above and the cluster):
- [ ] 0x0C62 on/off pulse, parked READY and IGN-only: item 0x63 follows? persists across ignition?
- [ ] 0x0C18 `00 00 c0 00 a0 ff ff` (AC 80 %, stock's frame): item 0x21 → 0xa0? DC (0x22) and winter (0x44)
      untouched?
- [ ] 0x0C18 `00 00 c0 00 ff b4 ff` (DC 90 %); then AC `.. 64 ff ff` (50 %) below SoC while AC charging: does the
      charge stop as **M** says?
- [ ] 0x0C18 off-step or out of range (AC 0x96 = 75 %, 0x5a = 45 %): refused or clamped?
- [ ] 0x0C5B 02 then 00 (90 %), AC plugged, not charging; then 01; then while charging: item 0x51, does charging
      continue? Stock HU shows the same choice?
- [ ] Schedule edits, first write (user's OK first). Before: micom-livi with the new build but without
      `-ev-schedule-writes`; the Schedule page shows the car's values read-only. Check
      `micomd -query /run/micomd.ctl snapshot` holds 0x8C53 and 0x8C54 (without them every edit fails "nothing
      received yet"; set something from the stock HU or Kia Connect, or add a startup read, first). Note the
      three payloads. Then micomd `-allow-dangerous` and micom-livi `-ev-schedule-writes`, parked, IGN on:
      1. Departure 1: toggle Fri only. Expect one `ev-departures` line in micom-livi's log, 0x8C55 [6] b3:2
         → 1, every other byte of 0x8C53/54/55 unchanged, the page "confirmed" (no failure row).
      2. Toggle it back; same checks.
      3. Off-peak start +1 h. Expect one `ev-off-peak` line, 0x8C53 [1] changed, [0], [5], [7] unchanged.
      4. Off-peak mode Off ↔ the car's mode, if not code 1.
      5. Climate at departure on, then off: 0x8C53 [7] b1:0; [7] b7:2 (temperature) unchanged.
      6. IGN off/on: values kept? Stock HU / Kia Connect show the same?
      Stop at the first unexpected byte; the frames are in micomd's `-record`.
- [ ] 0x0C09 clock: compare the variant's template with a stock strace (weekday bit, hour << 3) before any
      schedule test; without it, what time does the car use?
- [ ] 0x0C5A V2L limit with the V2L adapter: raw vs / 0.5.
- [ ] 0x0C5D utility mode last, READY in P, driver seated: on value, refusal when not in P.
- [ ] For each write: does stock refuse while driving (gear ≠ P)? Does the car ignore it while driving?

## Open questions

1. A startup read of 0x8C53/0x8C54 (stock's 0x0C53/0x0C54), so edits work after a boot with nothing changed.
2. Does the car need the HU clock (0x0C09) for schedules, or does it hold its own?
3. Ownership: LIVI vs Kia Connect vs the car's own scheduler; LIVI shows readback only, never the tap.
4. Which settings stock gates on IGN ("Vehicle power must be On", **A**) or on P.
5. Is micomd's opt-in `-hev-status-request` (0x0C01) enough to show the limits at start, or must it be re-sent on
   IGN3 as stock does?
