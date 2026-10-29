# KeyDrive

Chytré ovládání Assetto Corsa z klávesnice (CSP). Klávesy zůstávají stejné jako v AC (šipky nebo to, co máš v AC
nastavené), ale KeyDrive z nich dělá plynulý plyn, brzdu a řízení:

- **plyn** plynule najíždí a hlídá prokluz hnaných kol („pamatující noha“ – pamatuje si, kolik plynu auto
  v daném převodu a otáčkách snese);
- **brzda** plynule najíždí, nezablokuje kola, při zatáčení trochu povolí (trail braking);
- **řízení** je přesná kopie klávesnicového řízení AC (změřená), s nastavitelnou rychlostí a zpomalením s rychlostí.

Stav: vývojová verze. Plyn se pořád ladí.

## Instalace

1. Přetáhni `KeyDrive-<verze>.zip` do Content Manageru (nebo rozbal do složky AC).
2. Content Manager → Nastavení → Assetto Corsa → Ovládání:
   - **Input method: Gamepad**,
   - **Combine with keyboard: zapnuto** (aby fungovaly ostatní klávesy – řazení, světla, …),
   - fyzický ovladač připojený být nemusí.
3. Content Manager → Nastavení → Custom Shaders Patch → **Gamepad FX** → zapnout, skript **KeyDrive**.
4. Řídíš klávesami, které máš v AC v režimu Keyboard (GAS, BRAKE, LEFT, RIGHT). Řazení a ruční brzdu KeyDrive
   předává sám.

Proč Gamepad a ne Keyboard: v režimu Gamepad AC na hodnoty, které KeyDrive pošle, už nesahá (ověřeno z logů: volant
= 270° × výstup v každé rychlosti, žádná mrtvá zóna ani zpoždění, plyn v autě = poslaný plyn). Rozbor variant je
v `docs/keydrive-research.md`.

Online: funguje (server uvidí ovládání „Gamepad“). Server, který zakáže joysticky/gamepady („Block Joystick“),
tě pustit nemusí. Respektuj pravidla ligy (KeyDrive hlídá prokluz podobně jako TC/ABS).

## Nastavení (Content Manager → Gamepad FX → KeyDrive)

| Položka | Výchozí | Co dělá |
| --- | --- | --- |
| THROTTLE_RISE_RATE / FALL_RATE | 120 / 400 | Náběh / pokles plynu v % za sekundu |
| MAX_THROTTLE | 100 | Strop plynu v % |
| TRACTION, TARGET_SLIP, TRACTION_RESPONSE | 1, 100, 100 | Hlídání prokluzu, povolený prokluz (v %; u režimu 2 vůči vyladěné hodnotě), rychlost reakce |
| **TRACTION_KEY** | X | Klávesa, která za jízdy vypne a dalším stiskem zase zapne hlídání prokluzu (gumování, schválné roztočení auta). Písmeno nebo číslice, F1–F12 nebo kód klávesy (např. 0x58); 0 = bez klávesy |
| TRACTION_RECOVERY | 100 | Režim 2: jak rychle se plyn vrací, když ho hlídání ubralo, v %; víc = méně opatrné |
| TRACTION_MEMORY | 0 | Režim 2: pamatovat si, v jakém převodu a otáčkách se kola protočila, a ubrat předem (opatrnější) |
| **TRACTION_MODE** | 2 | 2 = regulace vyladěná v simulátoru (v0.10+), 1 = předchozí „pamatující noha“ (v0.9), pro srovnání |
| BRAKE_* , MAX_BRAKE, TRAIL_BRAKE_RELEASE | | Náběh a strop brzdy, hlídání zablokování, povolení brzdy při zatáčení |
| STEER_STYLE | 0 | 0 = kopie řízení AC z klávesnice, 1 = vlastní křivka STEER_SPEED_CURVE |
| **STEER_RATE** | 100 | Rychlost řízení v % klávesnicového řízení AC (30–300) |
| **STEER_SPEED_SLOWDOWN** | 100 | Jak moc se řízení s rychlostí zpomaluje, v % zpomalení AC; 0 = ve všech rychlostech stejně rychle jako na místě |
| STEER_LIMIT_STRENGTH, COUNTERSTEER_ASSIST | 0, 0 | Asistence řízení (vypnuté) |
| SHOW_DIAGNOSTICS, RECORD_LOG | 1, 1 | Diagnostický panel, záznam jízdy |

## Okno KeyDrive ve hře (nastavení za jízdy)

Aplikace **KeyDrive Config** (instaluje se se ZIPem) má ve hře okno **KeyDrive** (lišta aplikací vpravo):

- **Zobrazit diagnostiku** – skryje nebo ukáže diagnostický panel (nápis „hlídání prokluzu VYP“ se ukáže vždy).
- **Síla zásahu** (0–100, výchozí 50) – kolik hlídání prokluzu ubírá: méně = víc plynu a víc protáčení, víc =
  klidnější a opatrnější. Od v0.13 je 50 to, co bylo ve v0.12.1 na 100 (klidný plyn, plynulý nástup); 0 = výchozí
  nastavení v0.12 (povolený prokluz ×1,25, návrat plynu ×1,67), 100 = ještě o kus opatrnější (×0,85, ×0,75).
  Platí hned, bez restartu. Posuvník se ve v0.13 vrátil na 50.
- Obojí si okno pamatuje. Dokud v okně nic nezměníš, platí hodnoty z Content Manageru (SHOW_DIAGNOSTICS,
  TARGET_SLIP, TRACTION_RECOVERY); posuvník se násobí s nimi.

Ve výchozím nastavení naběhne plyn z klidu na plno asi za 0,95 s (v0.13.1; v0.13.0 1,35 s, samotná klávesa 0,83 s),
protože se strop plynu vrací pomaleji než klávesa. Pomalejší nástup: sniž THROTTLE_RISE_RATE (85 ≈ jako v0.13.0).

## Vypnutí hlídání prokluzu za jízdy

Klávesa **X** (nastavení TRACTION_KEY) hlídání prokluzu vypne – plyn pak jde na klávesu jen s plynulým náběhem, kola se
můžou protáčet (gumování, otočka). Ve hře se ukáže hláška a nahoře uprostřed zůstane nápis **KeyDrive: hlídání prokluzu
VYP**, i když je diagnostika skrytá. Dalším stiskem se hlídání zapne; plyn se pak plynule (ne skokem) stáhne, pokud
kola pořád hrabou. Po restartu skriptu (nová jízda) je hlídání vždy zapnuté, teleport do boxů ho nemění. Ctrl+X
a Alt+X se ignorují (jiné zkratky), stejně jako X při psaní do chatu nebo jiného textového pole CSP a když AC není
aktivní okno. Když je TRACTION_KEY stejná klávesa jako plyn, brzda, řízení, řazení nebo ruční
brzda, vypínač se nepoužije a hra ukáže hlášku.

## Logy pro ladění

`Dokumenty\Assetto Corsa\logs\keydrive\`:

- `keydrive-log.csv` – posledních 60 s jízdy (ukládá se každých 10 s),
- `keydrive-incident-N.csv` – 3 s po smyku, nárazu nebo vyjetí,
- `ac-reference.csv` – záznam z okna **KeyDrive Reference** (AC v režimu Keyboard, bez KeyDrive),
- `kb-test.csv` – záznam z okna **KeyDrive Test klávesnice** (viz níže).

## Test čisté klávesnice (KeyDrive Test klávesnice)

Zkušební appka pro variantu „Input method = Keyboard“: v režimu Keyboard převezme plyn, brzdu a řízení přes CSP
(`ac.overrideCarControls`) a měří, jestli je AC potom ještě mění. Běží jen s otevřeným oknem; zavřením okna nebo
tlačítkem „Vypnout test“ se řízení vrátí AC.

1. Content Manager → Ovládání → **Input method: Keyboard**; v nastavení CSP pro jistotu vypni Gamepad FX.
2. Ve hře otevři okno **KeyDrive Test klávesnice** (lišta aplikací vpravo) a klikni **Zapnout test**.
3. Jezdi normálně aspoň 5 minut: rozjezdy v 1. a 2. převodu s plným plynem (prokluz), tvrdé brzdění, rychlé
   zatáčky nad 100 km/h.
4. Okno ukazuje u plynu, brzdy a řízení **SEDÍ** / **NESEDÍ**. Pošli `kb-test.csv` a screenshot okna.

Pozor: zpomalení řízení s rychlostí je v testu schválně 0 % – ve vysoké rychlosti zatáčí rychleji než AC. Jinak by
nešlo poznat, jestli AC svůj klávesnicový filtr na řízení ještě používá.

## Export telemetrie z MCP mostu (C:\AC-Claude)

`tools/ac-bridge/ac_export.py` přidá do tvého mostu export CSV. Sdílenou paměť AC jen čte a zapisuje výhradně do
`C:\AC-Claude\logs`; cesty i názvy souborů si určuje sám a nic jiného nezapíše.

1. Zkopíruj `ac_export.py` do `C:\AC-Claude\`.
2. V `ac_telemetry_mcp.py` za vytvoření serveru (`mcp = FastMCP(...)`) přidej:
   ```python
   import ac_export
   ac_export.register(mcp)
   ```
3. Claude pak umí zavolat `export_last_seconds(60)` (posledních N sekund, max. 600) nebo `export_last_lap()`
   (poslední dokončené kolo).

Samostatný test bez Clauda (AC musí běžet): `py C:\AC-Claude\ac_export.py --seconds 30`.

## Vývoj

Logika plynu a řízení je v čistých Lua modulech `extension/lua/joypad-assist/KeyDrive/core/` (bez CSP). Hra je spouští
přes `assist.lua`, simulátor a testy přímo.

LuaJIT na Windows: stačí Python (`py`) a balík **lupa**, který LuaJIT 2.1 obsahuje hotový (nic se nekompiluje):

```bat
py -m pip install lupa
py tests\keydrive\run_tests.py
```

Na Linuxu/macOS:

```bash
pip install lupa && python tests/keydrive/run_tests.py   # testy KeyDrive
./build-keydrive.sh                                       # nebo build-keydrive.ps1 → dist/KeyDrive-<verze>.zip
python sim/run.py                                         # simulátor: sim/out/report.json + summary.txt
python sim/optimize.py --mode 2 --procs 4                 # optimalizace na ladicích scénářích
```

### Simulátor (sim/)

Spouští stejné jádro plynu jako hra na modelu auta (přenos zatížení, křivka momentu, automatická spojka, řazení
s výpadkem tahu, setrvačnost kol a motoru, Pacejka s kombinovaným prokluzem, boční zatížení ze scénáře, RWD/FWD/AWD,
333 Hz fyzika, ovladač na 333 Hz i na 50–165 fps s trhanými snímky, šum a zpoždění senzoru). Supra je nakalibrovaná
na tvoje logy. Ideální noha (orákulum) slouží jen ke srovnání. Skrytá sada `sim/scenarios/hidden/` se nikdy nepoužívá
k ladění.

Prahy (tvoje): prokluz ≤ 1,5× vrchol pneumatiky, nad 1,3× nejvýš 0,1 s, v ustáleném stavu ≤ 1 změna směru plynu za
sekundu a rozptyl < 2 %, ztráta proti ideální noze ≤ 5 % na suchu. Navržené (moje, dokud je nepotvrdíš): ztráta
≤ 15 % na mokru/studených/změně gripu/ťukání, smyk nápravy ≤ 0,1 s u všech pohonů, změny plynu od asistence
≤ 5 /s, při couvání čistá rampa.
