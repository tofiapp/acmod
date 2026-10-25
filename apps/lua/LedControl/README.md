# LedControl

Lua aplikace pro Assetto Corsa s Custom Shaders Patch (CSP). Převezme diody na volantu a palubní desce vašeho auta
a řídí je sama: kdy svítí, jakou barvou a jak blikají podle situace (pit limiter, vlajky, řazení, DRS, ABS/TC,
palivo, poškození, start, stání). V kartě Světla umí ovládat i další světla auta.

Změny diod jsou **jen vizuální a jen na vašem autě**. Ostatní jezdci online je nevidí. Výjimkou jsou skutečná světla
auta v kartě Světla (dálková, výstražná, přepínače jako dešťové světlo): ta jsou opravdový stav auta a ostatní je vidí.

## Instalace

1. Vezměte `LedControl-<verze>.zip` (vytvoří ho `./build.sh LedControl` nebo `build.ps1 LedControl`).
2. Přetáhněte ZIP do Content Manageru a potvrďte instalaci. Ručně: složka `apps/lua/LedControl` do složky hry.
3. Ve hře otevřete aplikaci **LedControl** z lišty aplikací. Logika běží i se zavřeným oknem.

Potřebujete CSP 0.2.0 nebo novější (manifest `REQUIRED_VERSION = 2651`).

## Okno

Nahoře je **hlavní vypínač** (vypnutí vrátí autu jeho vlastní diody i světla), stav, počet diod a **preset pro toto
auto**. Pod tím jsou karty:

| Karta | Co v ní je |
| --- | --- |
| **Diody** | Náhled diod ve skutečném pořadí po skupinách a co teď svítí, jas (Noc / Den / Slunce, Auto), testy; sbalené: pořadí a skupiny, způsob převzetí, diagnostika |
| **Otáčky** | Živé otáčky, kde světla začínají, kde jsou plná a kde bliká omezovač; ruční hodnoty a otáčky pro každou diodu |
| **Scénáře** | Seznam situací presetu: zapnutí, priorita, cíl (skupina diod), vzor, barvy, rychlost blikání, Test, vlastní podmínky |
| **Editor** | Vlastní presety a ruční animace: mřížka s tolika políčky, kolik má auto diod, snímky a jejich rychlost |
| **Světla** | Světla, která auto má, a jejich scénáře (dešťové světlo, výstražná světla, dálková, brzdová světla, podsvícení) |
| **Nastavení** | Preset a způsob převzetí pro nové auto, klávesy, ochrana barev, sdílení presetů, smazání dat, výchozí nastavení |

## Jak to funguje

### Hledání diod

Aplikace diody najde sama, v tomto pořadí:

1. `digital_instruments.ini` auta, sekce `[LED_n]` (`OBJECT_NAME`, `RPM_SWITCH`), i z `data.acd`;
2. CSP konfigurace auta, sekce `[EMISSIVE_…]` s `INPUT = RPM`;
3. meshe, které CSP označuje jako diody (`actsAsLED`);
4. meshe kokpitu se jménem obsahujícím LED, RPM nebo SHIFT.

Diody seřadí zleva doprava podle skutečné polohy na volantu a rozdělí do skupin (řada otáček, levé a pravé boční
diody, další řady). Když pořadí nesedí nebo auto diody nemá, v kartě Diody je sbalená sekce **Pořadí a skupiny** (šipky ↑ ↓, **Obrátit** celou skupinu, **Uložit**) nebo
**Vybrat diody ručně** (seznam malých meshů v kokpitu s hledáním). Najetím myší na diodu v náhledu dioda na autě bliká.

### Způsob převzetí

AC zapisuje barvu svých diod každý snímek. Aby se aplikace s AC „nepřetahovala“, má tři způsoby:

- **A – stínová kopie** (doporučená): každá dioda dostane kopii s vlastním materiálem, původní se schová. Kopie se
  pohybuje s volantem i při přepnutí kamery.
- **B – překreslení**: dioda se znovu vykreslí přes tu původní.
- **C – přímý zápis**: zapisuje přímo do materiálu diody. Když AC barvu přepisuje, aplikace ji vrací před každým
  vykreslením.

Když jeden způsob na autě nefunguje, aplikace sama přepne na další a napíše proč. Volba se pamatuje pro každé auto.
Po pádu nebo restartu skriptu se schované diody samy vrátí.

### Otáčky

Karta **Otáčky** ukazuje živě otáčky a kde řadicí světla začínají, kde jsou plná (bod řazení) a kde bliká omezovač.
Automaticky:

- **Omezovač** se naučí ve hře: když AC poprvé zapne svůj omezovač, aplikace si otáčky zapamatuje pro toto auto.
  Jinak vezme omezovač z dat auta.
- **Plno / řazení** je bod řazení z `ai.ini`, ale jen když leží pod omezovačem. U závodních aut bývá v `ai.ini` stejně
  vysoko nebo výš než omezovač, a pak by se světla nikdy nedoplnila a omezovač blikal už v půlce. Pak se použije 97 %
  omezovače.
- **Začátek** je procento z bodu řazení podle presetu.

První dioda se rozsvítí hned na začátku a řada je plná o jeden krok před bodem řazení, takže je plná řada chvíli
vidět, než začne blikání pro řazení.

Každou hodnotu jde nastavit ručně (vypnout Auto) nebo tlačítkem **Teď** podle aktuálních otáček (např. na neutrál
vytočit motor do omezovače a kliknout). V sekci **Každá dioda zvlášť** má každá dioda řady vlastní otáčky.

### Jas a barvy

Jas je v kartě Diody: posuvník, předvolby Noc / Den / Slunce a **Auto** podle denní doby (zvlášť jas ve dne a v noci).
Vestavěné barvy jsou čisté (zelená, modrá, …), takže při vysokém jasu nepřecházejí do jiného odstínu. U vlastních
barev to hlídá **Ochrana barev** v Nastavení; vedle každého výběru barvy jsou rychlé volby barev, které drží odstín
při jakémkoli jasu.

### Scénáře a priorita

Každá skupina diod ukazuje nejvýš postavený aktivní scénář, který na ni míří. Části bez barvy (průhledné) propustí
scénář pod ním. Když nic neplatí, ukáže skupina **základ presetu**: zhasnuto, nebo diody podle auta.

Vestavěné scénáře (pořadí = výchozí priorita): pit limiter, pit lane bez limiteru, vlajky (modrá, žlutá, černá,
penalizace, bílá, šachovnice; červenou AC zatím nehlásí), omezovač otáček, ideální bod řazení (z `ai.ini`), řadicí
světla podle otáček (plnění zleva doprava nebo od krajů ke středu, prahy relativní nebo z auta), DRS k dispozici a
otevřené, zásah ABS a TC, málo paliva, poškození, odpočet startu a zelená, stání nebo vypnutý motor a **vlastní
podmínky** (veličina, porovnání, hodnota, víc řádků musí platit zároveň).

Vzory: svítí, bliká, střídá liché a sudé, pulzuje, běžící světlo, plní se (zleva, zprava, od krajů, od středu),
duha, vlastní snímky. Rychlost se zadává v Hz.

### Presety

- **F1 styl**: řada se plní zleva zelená – červená – modrá, v bodě řazení vše modře, omezovač bliká.
- **GT3 styl**: plnění od krajů ke středu zelená – žlutá – červená, bod řazení bliká červeně.
- **Minimální**: otáčky ukazuje auto samo, přidá jen pit limiter a modrou a žlutou vlajku.

Vestavěné presety jsou relativní, fungují na libovolném počtu diod. Když vestavěný preset upravíte, vytvoří se jeho
kopie a auto začne používat ji. Preset se pamatuje pro každé auto. Ruční animace z Editoru jsou vázané na počet
diod: na autě s jiným počtem se přepočítají, nebo (když přepočet vypnete) se scénář vypne s upozorněním.

Sdílení: **Nastavení → Sdílení → Do schránky** dá do schránky jeden řádek textu začínající `LEDCONTROL-PRESET 1`.
**Ze schránky** ho načte jako nový preset.

### Světla

Karta Světla ukazuje jen to, co auto opravdu má (světlomety, dálková, výstražná světla, přepínače CSP jako dešťové
světlo, brzdová světla). Scénáře světel mají zapnutí, prioritu, Test a své parametry:

- **Dešťové světlo bliká s pit limiterem** (formule). Dešťové světlo jde dvěma způsoby, volí se pro každé auto:
  *přepínač* (skutečný přepínač auta, ostatní ho vidí; zvládne nejvýš 2 Hz) nebo *meshe* (vizuální kopie vybraných
  meshů, jen u vás).
- **Dešťové světlo svítí v dešti** (výchozí vypnuto).
- **Výstražná světla při zastavení na trati** (mimo pit lane, po startu, po nastaveném čase).
- **Světla za šera a v dešti**.
- **Brzdová světla blikají při prudkém brzdění** (jen u vás).
- **Podsvícení palubní desky a kabiny**: barevné světlo v kabině a/nebo vybrané meshe palubní desky (jen u vás);
  volitelně oranžově s pit limiterem.
- **Problik dálkovými na klávesu** (klávesa v Nastavení).

Skutečná světla dostane auto vždy zpátky tak, jak je měl jezdec: po skončení scénáře, hlavním vypínačem, při chybě
i při vypnutí aplikace. Příkazy posílá jen při změně a nejvýš čtyřikrát za sekundu. Když světlo během scénáře
přepnete sami, scénář ho pustí. Online se nad kartou ukáže upozornění a skutečná světla jde online vypnout.

### Klávesy

V Nastavení lze přiřadit klávesu nebo tlačítko volantu: hlavní vypínač, další preset, problik dálkovými světly.
Fungují i se zavřeným oknem.

## Když něco nefunguje

V kartě Diody (sekce Diagnostika) je **Kopírovat diagnostiku**, diagnostika světel je v kartě Světla. Text obsahuje nalezené diody a jejich polohu,
odmítnuté kandidáty s důvodem, sekce `[LED_n]` z auta, stav převzetí a scénářů. Pošlete ho autorovi.

Uložená data jsou ve složce `Documents/Assetto Corsa/cfg/extension/state/lua/app/LedControl` (CSP `ScriptConfig`): `car_<auto>.lon`
(způsob, preset, ruční pořadí diod, světla) a `presets.lon` (vaše presety).

## Vývoj

```bash
pip install lupa && python tests/ledcontrol/run_tests.py   # testy LedControl (vlastní simulace CSP)
./build.sh LedControl                                        # dist/LedControl-<verze>.zip
```
