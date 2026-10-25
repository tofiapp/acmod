# LedControl: window design (UI spec)

The user found the window confusing: too many labels and explanations, unclear structure. This spec is the target
for every tab. Use the kit `src/ui/kit.lua` (and nothing that looks different for the same purpose).

## Principles

1. **One purpose per tab, the most important thing on top** (live preview, live RPM, the list), settings below.
2. **Labels are 1 to 3 words.** No sentence longer than about 60 characters in the main view. Explanations go into
   `K.help(text)` (a grey "(?)" with a tooltip) or `K.tip(text)` (tooltip on the control itself). At most one short hint
   line per section, and only when the user must do something (e.g. "Zapněte hlavní vypínač").
3. **Form rows** = `K.label('Jas')` (150 px label column) + one control (`ui.setNextItemWidth(K.CONTROL_W)` = 260 px,
   or less when buttons follow). All rows of a section align.
4. **Sections**: `K.header('Název')` for always visible groups; `K.section('Název##id', open, fn)` (collapsible,
   closed by default) for advanced or rarely used things (pořadí diod, způsob převzetí, diagnostika, podsvícení…).
5. **State by colour, not by sentences**: `K.dot(K.GREEN)` = active now, `K.DIM` = idle / off, `K.ORANGE` = warning,
   `K.RED` = error, followed by one word or a short name.
6. **Choices of 2 to 6 options** = `K.choice(labels, current)` (segmented buttons), not radio lists with long names.
7. **Colours**: `K.colourField(label, rgbm)` = colour button + quick picks of colours that stay true at any
   brightness (`patterns.SAFE_COLOURS`). Keep the picker's own rgbm between frames (refresh it only when the stored
   colour changed elsewhere), so the picker never snaps.
8. **No technical words in the main view** (mesh, LOD, instance, digital_instruments, ksEmissive, method A/B/C
   internals). They belong to the collapsed "Diagnostika" section only.
9. **Terms** (the same everywhere): preset, scénář, skupina diod, priorita (Výš / Níž), základ presetu, otáčky
   (ot/min), jas, Test, Uložit, Zahodit, Přidat, Smazat. Czech with correct diacritics.
10. **Width**: the window is 560 px; no row wider than 520 px (count label column + controls + buttons).
11. **No per-frame allocation** (labels with `##ids` prebuilt, strings rebuilt only when a version counter changes,
    combo / section content functions defined once at module level, no `ui.getCursor()` per frame).
12. Every click gives visible feedback (state changes, or a short message that disappears after a few seconds).

## Header (src/ui/main.lua)

```
[x] Zapnuto   ● běží   Ferrari SF15-T                       (status colour: green běží, grey vypnuto, orange …)
Preset  [F1 styl                    v]
(only when needed, one line each: red error + [Zkusit znovu]; orange "Běží B – překreslení (?)" when a method
 fell back; orange "Online: skutečná světla vidí i ostatní"; orange "Testovací vzor (?)" + [Zpět na provoz])
Tabs: Diody | Otáčky | Scénáře | Editor | Světla | Nastavení
```
Car name: `ac.getCarName(0)` (official RallyCopilot / SetupExchange use it), else the car id.

## Diody (src/ui/tab_leds.lua, src/ui/led_map.lua)

```
Řada otáček   Řadicí světla              ← group name (grey caption) + active scenario (green) or "základ"
■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■             ← colour cells (hover: blinks on the car, tooltip "3. dioda";
Levé  základ          Pravé  základ           click: test colour)
■ ■ ■                 ■ ■ ■
Jas      <====25====>  [Noc][Den][Slunce]  [ ] Auto (?)     (Auto on: two sliders Den / Noc under it)
Test     [Provoz][Duha][Běh][Zhasnout][Bílá][Vlastní] (?)
▶ Pořadí a skupiny        (led_map: rows "1  RPM_LED_3  [skupina v] ↑ ↓ ×", groups, mesh picker)
▶ Způsob převzetí         ([A kopie][B překreslení][C přímý zápis] (?) explanations in the tooltip)
▶ Diagnostika             (LED list, rejected candidates, [Znovu najít] [Kopírovat diagnostiku])
```
No LEDs: one line "Diody nenalezeny." + [Vybrat diody ručně] + [Kopírovat diagnostiku].
Brightness presets: Noc 12, Den 30, Slunce 50 (runtime.setIntensity); Auto = config autoBrightness with
intensityDay / intensityNight (runtime.setBrightness).

## Otáčky (new, src/ui/tab_rpm.lua) — per car RPM range (src/rpm.lua)

```
 8 450 ot/min                             max 10 950       ← big number (ui.Font.Title), max seen small grey
[████████████░░░░░░░|░░░░░|░░]                              ← bar 0..limiter*1.05: fill = current rpm, markers:
 ■ ■ ■ ■ ■ ■ ■ ■ ░ ░ ░ ░ ░ ░ ░                                 start green, shift blue, limiter red (drawRectFilled)
                                                              under it the main row live (small cells)
Začátek        [x] Auto  7 200            [Teď]            ← Auto off: slider instead of the value
Plno / řazení  [x] Auto  10 670 (?)       [Teď]            ← (?) tooltip: source "ai.ini" / "97 % omezovače"
Omezovač       [ ] Auto  <==10 400==>     [Teď]            ← learned: "naměřeno 10 400" + [Zapomenout]
▶ Každá dioda zvlášť     [x] Zapnout  [Rozložit rovnoměrně] [Podle auta]
     1 ●  <== 7 000 ==> [Teď]
     2 ●  <== 7 230 ==> [Teď] …                             ← ● = the LED's colour in the fill
```
API: `runtime.rpm` (src/rpm.lua): `rpm.start` (0 = from the preset's Začátek %), `rpm.shift`, `rpm.limiter`,
`rpm.auto.{limiter, limiterFrom, shift, shiftFrom}`, `rpm.learned`, `rpm.maxSeen`, `rpm.ledRpm`, `rpm.version`;
`rpm.set(key, value | nil, runtime.ST)` for 'start' / 'shift' / 'limiter' (nil = Auto), `rpm.forgetLearned(ST)`,
`rpm.setLeds(list | nil, ST)`, `rpm.setLed(k, value, ST)`, `rpm.spread(n, startRpm, ST)`. The automatic start =
`runtime.ST.shiftUp * (preset shiftLights param) / 100` (presets.effective(runtime.preset()) → entry 'shiftLights'
.param). Current RPM: `runtime.ST.rpm`. Main row: `runtime.layout.groups[1]` (role 'main'); colours of the cells
from `runtime.fb`. Car thresholds ("Podle auta"): `runtime.layout.leds[id].rpm` when every LED of the row has one.
Sliders: drag changes the value live (rpm.set), it is saved by rpm.lua itself (deferred).

## Scénáře (src/ui/tab_scenarios.lua)

```
Základ (když nic nesvítí)  [Zhasnuto][Podle auta] (?)          ← one line; built-in preset: (?) says that the first
                                                                  change creates a copy
BOX                                                            ← K.caption per category
[x] Pit limiter zapnutý                  ● [Test] [↑][↓]        ← click on the name expands; ● green when active
[x] V pit lane bez limiteru                [Test] [↑][↓]
VLAJKY
[x] Modrá vlajka                           [Test] [↑][↓]
[ ] Červená vlajka (?)                                          ← unavailable: grey name, reason in (?)
   expanded:  Kde       [boční diody v]
              Vzor      [Bliká v]
              Barva     [■] ■■■■■■■■
              Rychlost  <== 2.0 Hz ==>
              …only what the pattern uses (patterns.USES)…
[+ Přidat vlastní scénář]
```
Řadicí světla expanded: also a line "Otáčky: karta Otáčky" (a button that switches is not possible: just the text).

## Editor (src/ui/tab_editor.lua)

```
Preset    [Moje F1          v]  [+] [⧉] [✎] [🗑]        ← icon buttons with tooltips (Nový, Kopie, Přejmenovat, Smazat)
Animace   [Pit limiter       v]  [Nová animace]
Řada otáček  □□□□■■■■□□□□□□□                              ← the grid
Štětec    [.][0][■][■][■]…                                 ← palette, right click / colour button edits a colour
Snímky    [1][2][3] [+] [⧉] [×] [←] [→]   Rychlost <== 6 /s ==>
[Uložit] [Test na autě] [Zahodit]   ● neuloženo
```

## Světla (src/ui/tab_lights.lua)

```
[x] Ovládat světla auta   [x] I online (?)
Auto má     ● Světlomety (skutečné)  ● Výstražná  ○ Dešťové (jen u vás) …   ← dots = on/off, (?) per kind
▶ Dešťové světlo   [Přepínač][Meshe][Ne]  [zdroj v]  (mesh picker inside)
▶ Podsvícení        (cabin light, dash meshes)
SCÉNÁŘE SVĚTEL      (rows like the Scénáře tab: [x] name ● [Test] [↑][↓], click expands parameters / colour)
```

## Nastavení (src/ui/tab_settings.lua)

```
NOVÉ AUTO     Preset [Automaticky v]    Převzetí [A][B][C] (?)
KLÁVESY       Zapnout / vypnout  [ F1 ]
              Další preset       [ … ]
              Problik dálkovými  [ … ]
BARVY         Ochrana barev <== 70 % ==> (?)     ← config colourGuard (runtime.setBrightness('colourGuard', v))
SDÍLENÍ       [Kopírovat preset] [Vložit preset]
DATA          [Smazat uložená data] [Výchozí nastavení]      ← two-click confirm (existing)
LedControl 0.3.0                                              ← small grey
```

## Checking a tab

`python3 tests/ledcontrol/dump_ui.py Diody` prints the tab as text (`|` = same line, `▼` = section, `{}` = coloured
text, `(tooltip: …)`). Read it as the user would: is the first screen clear, is any line long, is anything said twice?
