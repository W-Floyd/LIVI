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

## State today

| Setting (page id) | Read | Write |
|---|---|---|
| Charge limit AC/DC (`charge_limit_ac/dc`) | ✓ `chargeLimitAc/DcPct` (micom-livi, items 0x21/0x22), never yet seen on the wire | none: row read-only |
| AC charging current (`ac_current`) | none | none |
| Departure 1/2 (`departure_1/2`) | none (go-micomd decodes 0x8C55 hour/minute bits only; micom-livi does not forward) | none |
| Scheduled charging, off-peak window and mode | none | none |
| Climate at departure, temperature, defog | none | none |
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
- Write 0x0C18, 7 B: [2] winter mode (gen ≥ 2: << 6), [4] AC target, [5] DC target, [6] GPS/route target; each
  pct / 0.5, 0xff = unchanged (`setTargetSOCext`). TAppEV3 sends one at a time. **S**
- Read items 0x21 (AC), 0x22 (DC), 0x31 (route); 0x8C01 [50], [51]; x0.5 %. **S, G**. Items not seen in **C**:
  item updates are on change only.
- Range at limit: items 0x1f/0x20, seen 406-414 km. **C**
- Steps of 10 %. **M** Range 50-100 assumed.
- Unknown: bytes [0], [1], [3] of 0x0C18; whether 0xff in [2] leaves winter mode alone; ack beyond the item
  echo; persistence across ignition (likely VCU-held); whether a value outside 50-100 is refused or clamped.
  Without micomd `-hev-status-request` the limits show only once they change.
- Risks: a target below the present SoC stops an AC charge (**M**); the Kia Connect app (TMU, `HKMC_TAppService`)
  sets the same targets: the car's readback, not LIVI, is truth; 0x0C18 also carries winter mode, so a wrong
  byte flips it.

### AC charging current
- Write 0x0C5B [1 max, 2 reduced, 3 min], pulse to 0; this car takes the unified path (0x8C5F [0] → flag 82).
  **S**. Old path 0x0C13 [1, EVSE<<2 | ICCB, 0] when flag 82 ≠ 1. **S**
- Read 0x8C50 [0] b3:2 OBC_CHGINCURRMODSTA, item 0x51 (stock maps 2→1, 3→2, else 0); item 0x3d VCMS. **S**
- Stock labels: Maximum / Reduced / Minimum = 100 / 90 / 60 %; separate "portable (120 V)" and "station
  (240 V)" settings exist. **A, M**
- Unknown: whether one 0x0C5B value covers both portable and station; raw readback values; 0x8C50 is only
  answered to the 0x0C50 startup read (not in **C**).
- Risk: changing it mid-charge may stop the charge.

### Departures (1, 2) and climate at departure
- Write 0x0C06, 7 B, 28 packed slots: per set hour, minute, 7 days, enable, precondition, temperature, unit,
  defrost; gen ≥ 2 MSB-first packing "as listed in code". **S**. Exact bit order not yet extracted.
- Read 0x8C55: [3] set 1 hour b4:0 / minute b7:5, [4] set 2, [5] set 1 Mon-Thu (2 bits each), [6] set 1
  enable/Fri-Sun, [7] set 2 Mon-Thu; [0..2] vary per frame, unread. Seen 56814 times, [3], [4] = 0c (12:00,
  nothing set). **S, C**. 0x8C53 [0] set 2 enable/Fri-Sun; [7] b1:0 scheduled climate enable, b7:2 temperature;
  0x8C54 [0] b1:0 defrost, [3] b7:6 temperature unit. **S**
- 3-bit minute: tens of minutes (inferred).
- Climate is per departure in 0x0C06 but one enable/temperature in 0x8C53. **S**
- Unknown: 0x0C06 bit layout; temperature encoding (0x8C53 [7] = 0x50 → 20 at default: raw >> 2 °C? half
  degrees?); temperature range (17-27 °C assumed); how "once" (no day) is expressed; 2-bit day values.
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
- Unknown: charge-control-mode values (off / scheduled / prioritised / only?); whether LIVI's single window must be
  sent as both weekday and weekend; how "scheduled charging off" is encoded.
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
- Write 0x0C18 [2] (gen ≥ 2 << 6). **S**. Read item 0x44 XEV_WINTERMODESTA, 0x8C1A [6] b2:1, 0x8C01 [94]. **S**
- Unknown: values; whether this EV6 has it (string present in the app, **A**); its relation to battery
  conditioning.

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
- [ ] 0x0C18 with only [4] = 0xa0 (80 %) and every other byte 0xff: item 0x21 → 0xa0? DC and winter untouched?
- [ ] 0x0C18 [5] alone; then [4] = 0x64 (50 %) below SoC while AC charging: does the charge stop as **M** says?
- [ ] 0x0C18 out of range (0x5a = 45 %, 0xc9): refused or clamped?
- [ ] 0x0C5B 2 then 1, AC plugged, not charging; then while charging: readback, does charging continue?
- [ ] 0x0C05 / 0x0C06: only after the bit layout is extracted from S; one departure, readback 0x8C55; check the
      car's computed window 0x8C54 [4..7]; leave the car plugged overnight to see it start on time.
- [ ] 0x0C09 clock: compare the variant's template with a stock strace (weekday bit, hour << 3) before any
      schedule test; without it, what time does the car use?
- [ ] 0x0C5A V2L limit with the V2L adapter: raw vs / 0.5.
- [ ] 0x0C5D utility mode last, READY in P, driver seated: on value, refusal when not in P.
- [ ] For each write: does stock refuse while driving (gear ≠ P)? Does the car ignore it while driving?

## Open questions

1. 0x0C06 and 0x0C05 bit layouts (gen ≥ 2) from the smali, before any schedule write.
2. Does the car need the HU clock (0x0C09) for schedules, or does it hold its own?
3. Ownership: LIVI vs Kia Connect vs the car's own scheduler; LIVI shows readback only, never the tap.
4. Which settings stock gates on IGN ("Vehicle power must be On", **A**) or on P.
5. Is micomd's opt-in `-hev-status-request` (0x0C01) enough to show the limits at start, or must it be re-sent on
   IGN3 as stock does?
