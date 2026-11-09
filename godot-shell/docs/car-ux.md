# In-vehicle centre-display UX: guidelines, standards, laws

Context: Godot shell, 1920x720 at about 12.3", 2024 Kia EV6, LHD with RHD support. Markets: US, EU/UK, AU, JP.
Researched 2026-11-09. "Primary" means the claim was checked against the source text (regulation, guideline PDF, or official platform page). "Secondary" means it comes from a summary, a paper, or a standards preview.

Binding classes:
- **Law**: statute, regulation, or type-approval rule.
- **Rating**: consumer test (Euro NCAP). Voluntary, but it costs stars.
- **Voluntary**: government or industry guideline, or an ISO/SAE standard.
- **Platform**: a rule for Android Auto or CarPlay apps. It binds apps on those platforms, not a head-unit shell, but it is the de facto benchmark for one.

Display geometry, computed for this project and not taken from any source: the panel is 2050.6 px diagonal over 12.3", so about **166.7 ppi**, or **0.152 mm/px**. The panel measures about 293 x 110 mm.

---

## Requirements table

| # | Requirement | Value | Source | Binding | Applies when |
|---|---|---|---|---|---|
| 1 | Single-glance limit | Mean glance ≤ 2.0 s, and 85% of glances ≤ 2.0 s, for 21 of 24 participants | NHTSA Phase 1 (78 FR 24818, 2013) https://www.govinfo.gov/content/pkg/FR-2013-04-26/pdf/2013-09883.pdf | Voluntary (US) | Tasks usable while driving |
| 2 | Total eyes-off-road time per task (TEORT) | ≤ 12.0 s, for 21 of 24 participants | NHTSA Phase 1, same URL | Voluntary (US) | While driving |
| 3 | Occlusion test | 1.5 s vision / 1.5 s occlusion; mean TSOT ≤ 12.0 s | NHTSA Phase 1, same URL; ISO 16673:2017 §4.2 (preview) https://www.sis.se/api/document/preview/922524/ | Voluntary | Test method |
| 4 | Definition of "driving" (NHTSA) | Propulsion active and **not in Park**. Stopped at a light still counts as driving. | NHTSA Phase 1 | Voluntary (US) | Lockout trigger |
| 5 | Definition of "in motion" (AAM) | Speed > 5 mph | AAM Driver Focus-Telematics 2006, Principle 1.4 https://www.theautos.org/downloads/advocacy/safety/driver-focus-guidelines-2006.pdf | Voluntary (US) | Lockout trigger |
| 6 | AAM glance criteria | Single glance generally ≤ 2 s; **total glance time ≤ 20 s** per task | AAM Principle 2.1 Alt. A, same URL | Voluntary (US) | While moving |
| 7 | Per se lockouts (NHTSA) | Manual text entry for messaging/communication/browsing; video; non-driving images; automatically scrolling text; reading books, web, social media, ads, or messages | NHTSA Phase 1 §V.F | Voluntary (US) | While driving, and for a passenger if the screen is visible to the belted driver |
| 8 | Image exceptions (NHTSA) | Maps are allowed, but photorealistic, satellite and 3D detail are "not recommended". Static images that help a selection (e.g. album art) are allowed if they extinguish when the task ends. | NHTSA Phase 1 §V.F.4 | Voluntary (US) | While driving |
| 9 | System response time | ≤ 0.25 s ("best practice"). If > 2.0 s, show a "busy" indication. | NHTSA Phase 1 §V.K; AAM Principle 3.5 (250 ms, "consistent with ISO 15005") | Voluntary | Always |
| 10 | Display position | Downward viewing angle ≤ 30° to display centre | AAM 1.4A; ESoP 2008 §4.3.2 ("approximately 30°"); JAMA Annex 1 | Voluntary | Installation |
| 11 | JAMA text limit | Displaying **31 or more** letters at once is prohibited; a number or unit counts as 1; punctuation is excluded; no scrolling text | JAMA v3.0 Annex 2 §4(4) https://www.jama.or.jp/operation/safety/display_system/pdf/jama_guidelines_v30_en.pdf | Voluntary (JP OEMs; de facto) | While moving |
| 12 | JAMA task limit | Total gaze ≤ **8 s**; occlusion TSOT ≤ **7.5 s** (1.5 s open / 1.0 s closed) | JAMA v3.0 Annex 3 and Appendix | Voluntary (JP) | While moving |
| 13 | JAMA content limits | No video or TV (except simplified traffic info). No addresses, phone numbers or restaurant/hotel descriptions. | JAMA v3.0 Annex 2 | Voluntary (JP) | While moving |
| 14 | SAE J2364 | Static task time ≤ 15 s, or occlusion TSOT ≤ 20 s | Secondary: Green; NHTSA FR discussion | Voluntary (navigation tasks) | While moving |
| 15 | Character height (ISO 15008:2017) | ≥ 20′ arc recommended; ≥ 16′ acceptable; ≥ 12′ minimum (modest reading needs); measured on capital "H" | Secondary: https://pmc.ncbi.nlm.nih.gov/articles/PMC4267594/ ; standard is paywalled | Voluntary | Always |
| 16 | Contrast (ISO 15008:2017 §4.3.2) | Minimums: night **5:1**, twilight 3:1, day 3:1, direct sunlight **2:1** | Secondary: Bauer, SID 2016 https://sid.onlinelibrary.wiley.com/doi/full/10.1002/j.2637-496X.2016.tb00902.x ; Voelz, SID 2025 | Voluntary | Always |
| 17 | Interior light dimming (FMVSS 101 S5.3.4) | Any non-telltale cabin light source forward of the driver that can be lit while moving needs **≥ 2 brightness levels**, or must be "barely discernible" at night, or must be switchable off. Telltales for brakes, high beam, turn signals and seat belts must never be dimmable to invisible. | 49 CFR 571.101 https://www.ecfr.gov/current/title-49/subtitle-B/chapter-V/part-571/subpart-B/section-571.101 | Law (US, on the vehicle) | Always |
| 18 | Telltale colours | Red = danger; yellow/amber = caution or malfunction; green = normal/on; blue = high beam; red/blue for hot/cold | ISO 2575 §5 (preview) https://cdn.standards.iteh.ai/samples/68409/6480e873c14b4e56b7a0066b3ef65afc/ISO-2575-2021.pdf ; FMVSS 101 S5.4 | Voluntary (ISO); Law for FMVSS Table 1 items | Always |
| 19 | Non-regulated indicator colours | Must not use a colour that masks recognition of a Table 1 telltale | FMVSS 101 S5.4.2 | Law (US) | Always |
| 20 | Rear camera: time to image | ≤ **2.0 s** from start of backing event | FMVSS 111 S5.5.3 https://www.ecfr.gov/current/title-49/subtitle-B/chapter-V/part-571/subpart-B/section-571.111 ; UN R158 §16.1.2.1 https://eur-lex.europa.eu/legal-content/EN/TXT/HTML/?uri=CELEX:42021X0828 | Law | Reverse selected |
| 21 | Rear camera: default view, deactivation, linger | Defaults to the compliant view each backing event. Stays until the driver changes the view or leaves R. **Not displayed after the backing event ends** (US). Event ends at ≤ 10 mph / 10 m / 10 s forward (US) or ≤ 16 km/h / 10 m / 10 s (UN). | FMVSS 111 S4, S5.5.4–6; UN R158 §15.1.1, §16.1.1.3 | Law | Reverse |
| 22 | Rear camera: image size | Test objects average ≥ **5′ arc**, each ≥ 3′ arc | FMVSS 111 S5.5.2; UN R158 §16.1.1 | Law | Reverse |
| 23 | Rear camera overlays (UN) | Inside the required field of view, overlays may show only rearward-driving or safety information | UN R158 §16.1.1.2 | Law (UN/EU) | Reverse |
| 24 | Video visible to driver | Prohibited while driving except for vehicle info, navigation/mapping, and manoeuvring cameras (CA). Similar rules exist in many US states. | CA Veh. Code 27602 (secondary text); VA §46.2-1077 https://law.lis.virginia.gov/vacode/title46.2/chapter10/section46.2-1077/ | Law (US states) | While driving |
| 25 | Video visible to driver (UK) | No driving if the driver can see a screen showing anything other than: vehicle state; location/road; road adjacent to vehicle; route to destination | Road Vehicles (Construction and Use) Regs 1986 reg 109 https://www.legislation.gov.uk/uksi/1986/1078/regulation/109 | Law (GB) | Whenever driven |
| 26 | Video visible to driver (AU) | Vehicle standard: unless a driver's aid, no part of the image may be visible from the normal driving position. Road rule: driving with a VDU visible is an offence while moving or stationary-not-parked. | ADR 42/05 cl. 13.2 https://www.legislation.gov.au/F2018L01514/2023-11-02/2023-11-02/text/original/pdf ; Road Rules r 299 (state versions on AustLII) | Law (AU) | Moving, or stopped but not parked |
| 27 | Gazing at a screen (JP) | Driver must not gaze at images on an attached or carried-in display while driving | Road Traffic Act art. 71(v)-5 https://www.japaneselawtranslation.go.jp/en/laws/view/2962 (secondary read) | Law (JP) | While driving |
| 28 | Glance law (DE) | Built-in screens count as "electronic devices". Use is allowed only with a "brief" glance suited to conditions; no fixed seconds in the statute. | StVO §23(1a) (secondary) | Law (DE) | Engine on, not stationary-off |
| 29 | ESoP: non-driving visual content | TV, video, and automatically scrolling images or text: disable, or hide from the driver while in motion | Commission Rec. 2008/653/EC, System behaviour principle I https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX:32008H0653 | Voluntary (EU) | While moving |
| 30 | ESoP: interaction | One hand stays on the wheel; no long uninterruptible sequences; resume at the point of interruption; driver controls the pace | 2008/653/EC §4.3.4 | Voluntary (EU) | While moving |
| 31 | Euro NCAP: touch target (direct touch input) | **≥ 10 x 10 mm** target and **≥ 4 mm** separation; the separation may relax if targets are larger | Euro NCAP Safe Driving – Driver Engagement v1.2 §2.1.1.2 https://cdn.euroncap.com/cars/assets/Euro_NCAP_Protocol_Safe_Driving_Driver_Engagement_v1_2_ebce03a443.pdf | Rating (EU) | Assessed functions |
| 32 | Euro NCAP: menu depth | Menu-based touch counts only if it takes **≤ 2 steps from the home screen**; > 2 steps is "never acceptable" for any assessed function | Same; SD 203 v1.1 https://cdn.euroncap.com/cars/assets/sd_203_driver_controls_test_procedure_v11_a8155228ca.pdf | Rating (EU) | Assessed functions |
| 33 | Euro NCAP: physical-only functions | Indicators, gear selector, hazard lights, eCall, horn, front and rear wipers (manual), full beam, set speed / switch speed-control function | Same, §2.2 | Rating (EU) | — |
| 34 | Euro NCAP: volume and mute | Must be **direct physical or always-visible direct touch** and clustered together. Mute may be merged into volume. | Same, §2.3.1 | Rating (EU) | — |
| 35 | Euro NCAP: other direct touch-or-physical | Next/skip track, answer/reject call, climate temperature/fan/vents/recirculation, front demist, windows, locks, seat, interior lights. Rear demist, source change, seat or wheel heating, and climate off may use a ≤ 2-step menu. | Same, §2.2–2.3 | Rating (EU) | — |
| 36 | Euro NCAP: voice functions | Play artist, tune preset, call contact, navigate to POI/stored/address. These pass with voice **plus** a dedicated voice button **plus** a non-voice alternative. "End navigation" may be touch, physical or voice. | Same, §2.1.1.4, §2.3 | Rating (EU) | — |
| 37 | Android Auto: touch target | ≥ **76 x 76 dp** | https://developers.google.com/cars/design/android-auto/design-system/sizing | Platform | Always |
| 38 | Android Auto: icon sizes | 44 / 36 / 24 dp (primary / secondary / tertiary); map markers ≥ 36 dp | Same; UX requirements https://developer.android.com/design/ui/cars/guides/ux-requirements/overview | Platform | Always |
| 39 | Android Auto: text | Body ≥ **24 dp**. Primary text 32 dp, secondary 24 dp. Sub-24 dp text only for non-crucial items (e.g. status bar). Avoid bold. | https://developers.google.com/cars/design/android-auto/design-system/typography ; visual-principles page | Platform | Always |
| 40 | Android Auto: contrast | ≥ **4.5:1** for text **and icons** (WCAG 2.0 AA) | https://developers.google.com/cars/design/android-auto/design-system/color | Platform | Always |
| 41 | Android Auto: night | True-black background; white text at 96% opacity at night; text tiers at 88/72/56% opacity | Same | Platform | Night |
| 42 | Android Auto: task length | ≤ **5 steps** (must); 2–3 steps (should). Step 5 must not be a list or grid. | https://developer.android.com/design/ui/cars/guides/ux-requirements/plan-task-flows | Platform | While driving |
| 43 | Android Auto: lists | Row count is set by the host per vehicle (ConstraintManager). Secondary text is truncated to **2 lines** while driving. | https://developer.android.com/design/ui/cars/guides/templates/list-template | Platform | While driving |
| 44 | Android Auto: quality | Button response ≤ **2 s** (DR-1); launch ≤ 10 s; content load ≤ 10 s. No auto-scrolling text (ST-1). No animation or video (SA-1). Video/games/browsers not launchable or visible while driving (DD-2/3). | https://developer.android.com/docs/quality-guidelines/car-app-quality | Platform | While driving |
| 45 | Android Auto: auto-transitions | Show content ≥ **8 s** before an auto-advance | UX requirements, same URL as #38 | Platform | While driving |
| 46 | CarPlay: template depth | Audio, comms, EV charging, parking, navigation: **≤ 5** templates. Fueling and voice: ≤ 3. Driving-task apps: 2 (iOS ≤ 26.3) or 3 (iOS ≥ 26.4). Hierarchical lists ≤ 5 levels. | CarPlay Developer Guide, Oct 2026 https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf | Platform | Always |
| 47 | CarPlay: lists | Some cars limit lists to **12 items** while driving; apps must handle it. Keyboard may be disabled while driving. Map panel holds ≤ 12 items. | Same | Platform | While driving (car-signalled) |
| 48 | CarPlay: refresh | Data items refresh at most every **10 s**; POIs at most every **60 s** | Same | Platform | Always |
| 49 | CarPlay: tabs | ≤ 4 tabs (audio), ≤ 5 tabs (others), in current iOS | Same | Platform | Always |
| 50 | CarPlay: resolutions | 800x480, 960x540, 1280x720, **1920x720 (8:3)** are listed as common | https://developer.apple.com/design/human-interface-guidelines/carplay | Platform | — |
| 51 | EU ADDW (driver monitoring) | Mandatory for new types from 7 Jul 2024 and all new M/N vehicles from 7 Jul 2026. Warns on gaze away > 6 s at 20–50 km/h, or > 3.5 s above 50 km/h (secondary). | Reg. (EU) 2019/2144; Deleg. Reg. (EU) 2023/2590 (secondary) | Law (EU, vehicle) | While moving |
| 52 | Downward/lateral position | Place driving-relevant and visually intensive info as close to the forward line of sight as practicable | NHTSA §V.C–D; ESoP; AAM 1.4 | Voluntary | Installation/layout |

---

## 1. Driver-distraction guidelines

**NHTSA Phase 1 (2013).** Source: https://www.govinfo.gov/content/pkg/FR-2013-04-26/pdf/2013-09883.pdf (78 FR 24818, 26 Apr 2013). Primary. It covers OEM-installed systems and is voluntary.
- Two alternative test protocols:
  - Eye-glance, simulator: for ≥ 21 of 24 participants, mean glance ≤ 2.0 s, 85% of glances ≤ 2.0 s, and TEORT ≤ 12.0 s.
  - Occlusion: 1.5 s open and 1.5 s closed; mean TSOT ≤ 12.0 s for ≥ 21 of 24.
  - The 12 s value is the 85th-percentile TEORT for manual radio tuning (the reference task). The occlusion limit moved from 9 s in the 2012 proposal to 12 s in the final text.
- "Driving" means propulsion is on, unless the transmission is in Park (or parking brake + neutral + < 5 mph for vehicles without Park). **A car stopped in traffic is still "driving."**
- Per se lockouts:
  - Driver only: manual text entry for messaging, communication or browsing.
  - Driver, and passenger if the display is visible to the belted driver: video (except FMVSS-required or backing images); non-video graphical or photographic images; automatically scrolling text; reading books, periodicals, web, social media, ads, or messages.
  - Exceptions: maps (but photorealistic, satellite or 3D detail is not recommended); static images for selection (album art) if they disappear when the task ends; ISO symbols and trademarks.
- The 2012 proposal's "≤ 6 button presses" and "≤ 30 characters" rules were **dropped** in the final text. The text limit is now governed by the task test.
- Other recommendations:
  - One hand stays on the wheel.
  - Interruptible tasks that resume where interrupted.
  - Response ≤ 0.25 s best practice; a busy indicator if > 2.0 s.
  - Text legibility per ISO 15008:2003.
  - Sound level adjustable down to mute.

**NHTSA Phase 2 (portable and aftermarket devices).** Proposed 5 Dec 2016: https://www.federalregister.gov/documents/2016/12/05/2016-29051/visual-manual-nhtsa-driver-distraction-guidelines-for-portable-and-aftermarket-devices . It recommends that aftermarket devices follow Phase 1, including its lockouts. **No final version found.**

**NHTSA Phase 3 (auditory-vocal).** Promised in 2013 "after necessary research." **No proposal found.**

**Alliance (AAM) Driver Focus-Telematics, 2006.** Source: https://www.theautos.org/downloads/advocacy/safety/driver-focus-guidelines-2006.pdf . Primary.
- 24 principles.
- 1.4A: display centre at ≤ 30° 2D down-angle. 1.4B gives a 3D variant, valid to 40° lateral.
- 2.1A: single glance generally ≤ 2 s; **≤ 20 s total glance time**.
- 2.1B: alternatively, lane exceedances and headway variability no worse than the radio-tuning reference.
- 3.5: response ≤ 250 ms; a message if > 2 s.
- Video, "continuously moving images" and auto-scrolling text are disabled while in motion, defined as > 5 mph.
- 1.5: minimise glare; brightness control (manual or automatic).

**European Statement of Principles (ESoP).** 2006 text, re-issued as Commission Recommendation 2008/653/EC: https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX:32008H0653 . Primary.
- Applies to OEM and aftermarket systems. It has no numeric glance limits.
- Displays within about 30° down-angle and as close to the line of sight as practicable.
- Avoid glare and reflections; "automatic brightness control" is the "Good" example.
- One hand on the wheel. No long uninterruptible sequences. Resume after interruption. Driver controls the pace.
- Responses should be "timely and clearly perceptible."
- System sounds must not mask warnings.
- While moving, disable TV, video and auto-scrolling images and text, or hide them from the driver.
- Functions not meant for use while driving are made impossible to use, or carry a clear warning (example: "not available while driving").
- "Good" example: frequently used controls within fingertip reach of the wheel rim.

**JAMA Guidelines v3.0 (18 Aug 2004).** Source: https://www.jama.or.jp/operation/safety/display_system/pdf/jama_guidelines_v30_en.pdf . Primary.
- While moving:
  - No video or TV.
  - No scrolling text.
  - Displaying ≥ 31 letters at once is prohibited (the Annex text). A number or unit counts as 1 letter; punctuation is not counted.
  - No addresses, phone numbers or POI descriptions.
  - Map detail is restricted by scale.
- Task: total gaze ≤ 8 s; occlusion TSOT ≤ 7.5 s with 1.5 s open / **1.0 s** closed. That differs from ISO and NHTSA, which use 1.5 s closed.
- Monitor top edge must sit below the lower boundary of the 180° forward field. Screen centre ≤ 30° below horizontal from the JIS eye point.
- Applies to factory and dealer-installed systems.

**SAE J2364 / J2365** (paywalled; secondary sources: Green 1999, https://journals.sagepub.com/doi/10.1177/154193129904301809 , and NHTSA FR discussion):
- J2364 covers navigation functions while moving: static task time ≤ 15 s (the "15-second rule"), or occlusion TSOT ≤ 20 s.
- J2365 estimates task time with a keystroke-level model (M operator = 1.5 s).
- NHTSA declined to adopt J2365.

**ISO 16673:2017 (occlusion).** Paywalled; preview read at https://www.sis.se/api/document/preview/922524/ .
- §4.2: vision interval 1.5 s, occlusion interval 1.5 s.
- TSOT = sum of vision intervals. Approximation: (TTT_occl / 3.0) x 1.5.
- Resumability ratio R = TSOT / TTT_unoccluded.
- **No pass/fail limit in the standard itself.** Limits come from NHTSA (12 s), J2364 (20 s) and JAMA (7.5 s).

## 2. Legibility and display standards

**ISO 15008:2017.** Paywalled. Values are from secondary sources.
- Character height, measured on capital "H":
  - ≥ 20′ arc recommended; ≥ 16′ acceptable; ≥ 12′ minimum where reading needs are modest. Source: PMC4267594 (which cites the 2009 edition).
  - Older or other standards (ISO 9241-303, DOT HFDS) use 16′ minimum and 20–22′ preferred.
- Contrast minimums (§4.3.2):
  - Night 5:1, twilight 3:1, day 3:1, direct sunlight 2:1. Sources: Bauer, SID 2016; Voelz, SID 2025.
  - Measured from the rearmost point of the cyclopean eyellipse.
  - Test illuminance: diffuse 5 klx; direct sun 45 klx (secondary).
  - If transient states (dawn, dusk) lack contrast, add outlines (secondary).
- Annex B rates colour pairs. Saturated red-on-blue and blue-on-black or red backgrounds are "not recommended" (secondary).
- **Derived for this panel** (computed; assumes about 750 mm eye-to-screen, the distance Jung et al. 2021 used; the actual EV6 distance was not measured):
  - 20′ is about 4.4 mm cap height, about **29 px**.
  - 16′ is about 3.5 mm, about **23 px**.
  - 12′ is about 2.6 mm, about **17 px**.
  - Font size in px is roughly cap height / 0.7, so about 41 px for 20′.

**ISO 15005:2017 (dialogue management).** Paywalled; the preview has only the scope. Principles: compatible with driving, controllable by the driver, consistent, interruptible. The "250 ms" figure is attributed to ISO 15005 by AAM Principle 3.5, but **not verified in the ISO text**.

**ISO 2575 (symbols).** Preview, §5: red = danger; yellow/amber = caution or malfunction; green = safe/on; blue = high beam; red = hot, blue = cold. Turn-signal telltales flash green.

**FMVSS 101.** Primary: https://www.ecfr.gov/current/title-49/subtitle-B/chapter-V/part-571/subpart-B/section-571.101
- S5.3.2: Table 1 controls and indicators need ≥ 2 brightness levels. At the lower level they are "barely discernible" to a dark-adapted driver. Automatic dimming to invisible requires a driver means to restore.
- S5.3.4: other forward light sources that can be lit while moving need ≥ 2 levels, or a single barely-discernible level, or a way to turn off. **A centre display that is not a regulated display falls here.** This is the only binding night-brightness rule found.
- S5.4.2: colours must not mask Table 1 telltales.
- S5.5: rules for a common space shared by multiple messages.

**Night dimming, other sources.** ESoP and AAM recommend manual or automatic brightness control. Android Auto prescribes a black background and 96%-opacity white text at night. **No numeric cd/m² requirement for an infotainment display was found in any law.** UN R46 camera monitors do have luminance and contrast rules, but they apply only to mirror-replacement systems; values not verified.

## 3. Touch and interaction

- **Euro NCAP 2026 (primary): ≥ 10 x 10 mm target, ≥ 4 mm gap** for direct touch controls. The gap may relax when targets are larger. That is about **66 x 66 px with a 27 px gap** on this panel (computed).
  - Euro NCAP's "direct physical input" means mechanical travel, findable by touch, with haptic feedback.
  - A non-mechanical alternative is allowed only if it works with cold, wet or gloved fingers.
- **Android Auto: 76 x 76 dp minimum.** The dp-to-mm mapping depends on the head unit's configured density. Google gives no mm value.
- **Research (secondary):**
  - Kim et al. 2014: ≥ 17.5 mm recommended.
  - Feng, Liu & Chen 2018: ≥ 24 mm; 4–6 buttons per screen; more buttons meant longer glances.
  - Jung et al. 2021, IJHCI: 18.7 mm recommended, 9 mm minimum; font 4.3 mm recommended, 2.6 mm minimum, at 75 cm. https://www.tandfonline.com/doi/full/10.1080/10447318.2021.1886484
  - Colle & Hiszem 2004 (kiosk, not driving): 20 mm.
  - Review of 73 studies: https://doi.org/10.1016/j.trip.2026.101873
  - Computed px on this panel: 17.5 mm ≈ 115 px; 24 mm ≈ 158 px.
- **Response time:**
  - NHTSA: ≤ 250 ms best practice; > 2 s needs a busy indication.
  - AAM: the same.
  - Android quality DR-1: app buttons respond within ≤ 2 s.
  - JAMA: a wait/ready state that can be perceived without looking.
- **Haptic and audio feedback:** no numeric rule found. Euro NCAP rewards haptic feedback through its physical-input definition. ESoP: feedback must be "clearly perceptible," and system sounds must not mask warnings.

## 4. Platform guidelines

**Android for Cars** (Design for Driving and quality guidelines; primary). See table rows 37–45. Also:
- Toggles only in list rows.
- Weather maps: ≤ 5 annotation types, ≤ 3 legend items or colours while driving.
- Map text ≥ 24 dp.
- Purchase flows: no payment-method setup, no subscriptions, no multi-item selection.
- AAOS: "status bar elements appear in the same order for LHD and RHD" (search summary of https://docs.partner.android.com/drivingux/automotive-os/system-experience/overview ; not opened directly).
- TalkBack, Switch Access and Voice Access are **not available on AAOS** (https://developer.android.com/training/cars/platforms/automotive-os).

**Apple CarPlay** (HIG, primary: https://developer.apple.com/design/human-interface-guidelines/carplay ; Developer Guide Oct 2026, primary). Also:
- Put the most important content in the upper half of the screen.
- Use distinct colours for interactive and non-interactive elements.
- Support light and dark; the system may switch automatically.
- Never lock the user out because the phone needs input.
- Don't auto-start audio.
- **The HIG CarPlay page gives no touch-target size or minimum font size.** Templates handle both; not found.

## 5. Laws

**Video visible to the driver**
- **California VC 27602** (text via FindLaw/Justia summaries; the official site returned 403):
  - Prohibits operating a screen showing TV/video "entertainment or business applications" forward of the back of the driver's seat, or visible to the driver while driving.
  - Exceptions: vehicle information, GPS/mapping, and manoeuvring-view displays; screens interlocked to show only those.
  - Exact current wording of (b) **not verified from the official source**.
- **Virginia §46.2-1077** (primary): bans TV visible to the driver while moving. Exceptions: rear-view systems, manoeuvring displays, factory screens with an interlock.
- DC, FL, ME, NJ, AK, IL, PA have similar rules (secondary compilation: https://www.blank-it.com/state-laws-regarding-use-of-video-displays-in-the-car/ , dated). **No authoritative 50-state table found.**
- **UK, reg 109** (primary): the four allowed categories are in table row 25. It applies to any screen showing an image from broadcast, recording, camera or computer. Note: "information to assist the driver to reach his destination" covers navigation. Media artwork and UI are outside the listed categories (interpretive; no case law checked).
- **Australia:**
  - ADR 42/05 cl. 13: mounting, plus no visible image unless it is a driver's aid. Primary.
  - Road Rules r 299: state variants. A driver's aid must be integrated, or in a commercial mount. Examples: navigation, rear-view screens, vehicle monitoring.
  - AMVCB VDU installation guideline: driver aids as close as practicable to the line of sight. https://www.aaaa.com.au/wp-content/uploads/2018/02/Guidelines-for-the-installation-and-location-of-in-vehicle-VDU-devices.pdf
- **Japan:** Road Traffic Act art. 71(v)-5, no gazing at an on-board display while driving (official translation site, read secondarily). A commonly cited "2 s" enforcement threshold appears only in non-official sources. **Not verified.**
- **EU:** no EU-wide in-use video ban. Member-state traffic codes apply, e.g. DE StVO §23(1a), "brief glance" (secondary). The 2017 draft's 1 s limit was dropped. "≤ 2 s" is case-law commentary, **not statute**. ESoP is the EU-level guideline.

**Rear-view camera**
- US FMVSS 111 (primary; vehicles ≤ 10,000 lb GVWR; full effect 1 May 2018):
  - Image within 2.0 s.
  - Test objects ≥ 5′ arc average, ≥ 3′ each.
  - Defaults to the compliant view each event.
  - Visible until the driver modifies the view or leaves R.
  - **Must not linger** after the backing event ends.
- UN R158 (primary; EU mandatory for new types from 6 Jul 2022):
  - 2.0 s.
  - Backing event ends ≤ 16 km/h / 10 m / 10 s forward.
  - Overlays inside the required field of view only for rearward-driving or safety information.
  - Object-detection audible or haptic signal within 0.6 s.
- UN R46: camera-monitor systems that replace mirrors (frame rate, latency, luminance). Numbers **not verified**; a supplier cites < 200 ms latency.
- **Design consequence:** if the shell overlays or replaces the OEM reverse view, it inherits these timings. Otherwise it must yield the screen within the OEM's 2.0 s budget.

**EU General Safety Regulation 2019/2144** (secondary for details):
- ISA: overspeed warning; can be switched off; re-enables at each start.
- DDAW from 2022/2024.
- ADDW: new types 7 Jul 2024, all new vehicles 7 Jul 2026.
- These are vehicle-level systems. The relevance here is that the shell must not hide their HMI. **No GSR article was found that regulates infotainment screen content directly.**

**Euro NCAP 2026** (primary; rating, not law):
- General Vehicle Controls is worth 5 of 30 Driver Engagement points: Driving 2.5, Comfort & Infotainment 2.5.
- Physical-only functions are listed in table row 33.
- Hazard lights on or next to the vehicle centre line. From 2029, the preferred lower boundary is near the bottom of the steering wheel (SD 203 App. A).
- Exterior light, ADAS and set-speed status must be in the driver's direct line of sight (the cluster, not the centre screen).
- Press release, 12 Oct 2026: https://www.euroncap.com/press-media/buttons-are-back-for-basic-functions-euro-ncap-confirms-in-testing/
- An aftermarket shell cannot change the car's score. These criteria are a benchmark only.

**Night brightness rules:** only FMVSS 101 S5.3.2–S5.3.4 (US) was found as binding. No EU, UK, AU or JP rule on infotainment luminance was found.

## 6. Accessibility

- Colour: ISO 15008 Annex B discourages saturated red/blue pairs (secondary). FMVSS 101 and ISO 2575 make colour carry meaning for telltales, so warnings should add shape, icon or text. The redundancy recommendation is inferred; **no automotive standard was found that mandates redundant coding for colour-vision deficiency.**
- Contrast: Android Auto 4.5:1 for text and icons (WCAG AA); ISO 15008 night 5:1.
- Text scaling: **no automotive guidance found** on user font scaling. Android Auto and AAOS specify fixed dp sizes. AAOS has no TalkBack, Switch Access or Voice Access.
- Euro NCAP requires non-mechanical controls to work for cold, wet, calloused or gloved fingers. This is an accessibility-adjacent robustness criterion.
- No automotive-specific accessibility standard was located (e.g. no ISO/SAE "accessible HMI" standard). **Not found.**

## 7. RHD / LHD

- The guidelines (ESoP, NHTSA, AAM, JAMA) are side-neutral: "as close to the forward line of sight as practicable," and frequently used controls within reach of the wheel rim.
- Google Maps on Android Auto (2021) moves the navigation strip and turn cards to the right in RHD cars because the controls were out of reach. https://9to5google.com/2021/09/21/google-maps-right-hand-android-auto/
- AAOS: the status bar keeps the same order in LHD and RHD (secondary, see §4).
- TomTom Automotive (https://docs.tomtom.com/automotive-solutions/en/driver-experience/left-right-hand-driving):
  - Panels move to the driver side, keeping their content order. Map buttons go to the opposite edge.
  - Not mirrored: full-screen views, headers, reading order. RTL language handling is independent of RHD.
- Euro NCAP SD 203 zones are written for LHD (indicator "left side of steering wheel"). Hazard lights are on the centre line regardless of side.
- **No standard was found that mandates UI mirroring.** The practice is OEM and platform convention.

---

## Not verified, contested, or not found

- **ISO 15008 values** (20/16/12′ arc; 5:1 / 3:1 / 3:1 / 2:1) come from secondary sources. The standard is paywalled. Editions differ: 2009 vs 2017 changed the character-height rules.
- **ISO 15005 "250 ms"**: attributed by AAM; not seen in ISO text.
- **SAE J2364/J2365 values**: secondary only (paywalled).
- **JAMA 30 vs 31 characters**: the Annex prohibits "31 or more," and the Appendix rationale says 30. NHTSA's 2012 notice flagged this inconsistency. NHTSA's final text dropped the 30-character rule.
- **JAMA "in motion" speed threshold (often quoted as 5 km/h)**: not found in v3.0. The doc does not define a speed.
- **NHTSA Phase 2 final / Phase 3**: none found. Phase 2 remains a 2016 proposal.
- **CA VC 27602(b) exact current wording**: not fetched from the official site (403).
- **Japan "2 s" gaze rule**: non-official sources only.
- **DE "≤ 2 s" brief glance**: commentary, not statute.
- **Android "≥ 23 dp between targets"**: in a search summary only; not present on the sizing pages fetched. Treat as unverified.
- **CarPlay touch-target and minimum text size**: not published in the HIG CarPlay page.
- **UN R46 CMS numbers** (30 Hz, 200 ms, luminance): not verified.
- **EU ADDW thresholds** (6 s / 3.5 s): secondary.
- **dp-to-px density for AA/CarPlay projection on this panel**: set by the head-unit implementation. Not determined here.
- **Euro NCAP "nine functions"**: confirmed in the primary protocol, which lists more than the five the press release names.
- **Euro NCAP 10 mm figure**: confirmed in the final protocol. Earlier forum reports cited a draft.
- **Paywalled (numbers taken only from previews or secondary sources):** ISO 15008, 15005, 16673, 2575, 16505; SAE J2364, J2365, J1757/1.
- **Primary-verified:** NHTSA 2013 FR; AAM 2006; ESoP 2008/653/EC; JAMA v3.0; FMVSS 101 and 111 (eCFR); UN R158 (EUR-Lex); UK reg 109; ADR 42/05 (summary); Euro NCAP Driver Engagement v1.2 and SD 203 v1.1; Android for Cars pages; CarPlay Developer Guide and HIG.
