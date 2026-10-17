# MirrorDelta

Lua aplikace pro Assetto Corsa s Custom Shaders Patch (CSP). Hlavní částí je minimalistický ukazatel delty, který si umístíte nad zpětné zrcátko. Má dvě tenké čáry a deltu v sekundách, bez pozadí a bez titulku. K tomu jsou dvě volitelná okna: pozice s časy kola a teploty pneumatik.

Každé okno má vlastní ikonu na liště aplikací a zapíná se zvlášť:

| Okno | Co ukazuje |
| --- | --- |
| **MirrorDelta** | Čára mini sektorů, čára delty a delta v sekundách (±) |
| **MirrorDelta Timing** | Pozice, kolo, aktuální čas a nejrychlejší kolo |
| **MirrorDelta Tyres** | Teplota jádra pneumatik a teploty pláště (vnitřní / střed / vnější) |
| **MirrorDelta Damage** | Auto shora: čtyři strany karoserie barevně podle poškození a uprostřed stav motoru v % |
| **MirrorDelta Gear** | Ukazatel otáček z 12 dílků, pod ním převod na barevné dlaždici a pod převodem rychlost |

## Instalace

### Přes Content Manager (doporučeno)

1. Vezměte soubor `MirrorDelta-1.3.1.zip`. Buď ho máte stažený, nebo ho vytvoříte build skriptem (viz [Vytvoření ZIPu](#vytvoření-zipu)).
2. Přetáhněte ZIP do okna Content Manageru.
3. Content Manager nabídne instalaci. Potvrďte ji.

### Ručně

Zkopírujte složku `apps/lua/MirrorDelta` do složky hry, tedy tak, aby vznikla cesta:

```
...\steamapps\common\assettocorsa\apps\lua\MirrorDelta\manifest.ini
```

U výchozí instalace Steamu je to `C:\Program Files (x86)\Steam\steamapps\common\assettocorsa\apps\lua\MirrorDelta\`.

### Požadavky

- Custom Shaders Patch 0.2.0 nebo novější (doporučená je nejnovější verze).
- Windows 10 nebo 11 kvůli písmu Bahnschrift. Na starším systému se použije jiné písmo.

## Zapnutí ve hře

1. Ve hře najeďte myší k pravému okraji obrazovky. Otevře se lišta aplikací.
2. Klikněte na ikonu **MirrorDelta** (případně **MirrorDelta Timing**, **MirrorDelta Tyres**, **MirrorDelta Gear** a **MirrorDelta Damage**).
3. **Přesun okna:** najeďte na okno myší. Objeví se titulek, za který okno přetáhnete.
4. **Velikost:** táhněte za pravý dolní roh okna. Čáry vyplní celou šířku okna. Tloušťka čar, mezery a velikost čísla se zvětšují úměrně šířce okna, takže okno stačí roztáhnout přesně na šířku zrcátka.
5. **Nastavení:** při najetí myší klikněte v titulku na ozubené kolečko.

Pokud se ikony na liště neobjeví, aktualizujte CSP a zkontrolujte, že jsou v nastavení CSP zapnuté Lua aplikace.

## Nastavení

Nastavení je společné pro všechna okna a má sedm záložek.

**Delta**
- Zobrazit: mini sektory, čáru delty, deltu v sekundách (každé zvlášť).
- Rozložení:
  - **A:** čas nahoře, čára delty uprostřed, mini sektory dole.
  - **B** (výchozí): mini sektory nahoře, čára delty uprostřed, čas dole.
- Počet mini sektorů (výchozí 24), počet skupin (výchozí 3, tedy 8 | 8 | 8) a mezera mezi skupinami.
- Tloušťka čar, mezera mezi čarami, velikost čísla a průhlednost. Hodnoty v pixelech platí pro okno široké 600 px a se šířkou okna se škálují.
- Na omezovači čára delty bliká modře stejně jako okno s převodem (jde vypnout).
- Intenzita barvy podle velikosti delty: když je zapnutá, plnou barvu má delta od ±0,5 s (nastavitelné).
- Reference: nejlepší kolo této session, nebo nejlepší kolo vůbec (uložené).
- Tlačítko **Smazat uložená data** smaže uložené nejlepší kolo a mini sektory pro aktuální auto a trať. Potvrdíte ho druhým kliknutím.

**Časy**
- Zobrazit: pozici, počet kol, aktuální čas a nejrychlejší čas (každé zvlášť).
- Uspořádání: vedle sebe (výchozí), nebo pod sebou.
- Zvýraznění nejlepšího kola fialovým rámečkem.
- Obarvení času po projetí cíle a jak dlouho trvá (výchozí 4 s).
- Tmavý podklad pro lepší čitelnost.

**Pneumatiky**
- Vzhled:
  - velká čísla jádra s proužkem pláště pod nimi,
  - velké číslo jádra, tvar pneumatiky a pod ní tři čísla pláště.
- Uspořádání: 2 × 2 jako na autě, nebo vedle sebe v řadě.
- Zobrazit: teplotu jádra a zóny pláště.
- Optimální teplota: podle auta, pokud ji CSP poskytuje. Jinak platí záložní hodnota (výchozí 85 °C).
- Tmavý podklad.

**Převody**
- Zobrazit: ukazatel otáček, rychlost pod převodem a tmavý podklad (každé zvlášť).
- Ukazatel otáček má 12 dílků a rozsvěcuje se od obou krajů ke středu: zelená, žlutá, červená. Rozsah se bere z omezovače (`rpmLimiter`) daného auta. První dílky se rozsvítí od nastaveného podílu omezovače (výchozí 0,6).
- Dlaždice s převodem je bílá, s rostoucími otáčkami žlutá a pak červená.
- Na omezovači bliká modře čára, dlaždice s převodem i pruh s rychlostí (jde vypnout).
- Rychlost se nemění po každém km/h, ale až když se posune o celý krok (1, 2, 3 nebo 5 km/h, výchozí 3). Číslo tak neposkakuje.
- Písmo okna je Unbounded. Je přibalené ve složce `fonts` i s licencí SIL OFL.

**Poškození**
- Strany karoserie (přední, zadní, levá, pravá) jsou tmavé, dokud nejsou poškozené. S poškozením se barví od žluté po červenou.
- Uprostřed je dlaždice motoru se zbývající životností v %: bílá, pod 95 % žlutá, pod 50 % červená.
- Volba „Ukázat jen při poškození“ okno skryje, dokud je auto v pořádku.
- Citlivost: od jaké hodnoty z AC je strana plně červená. Aktuální hodnoty z AC vidíte přímo v nastavení, podle nich jde citlivost doladit.

**Diagnostika**
- Ukazuje, co aplikace při měření kola vidí: jestli se kolo měří, kolik průjezdů cílem a referencí zaznamenala a proč naposledy kolo zahodila nebo nezapočítala.
- Zobrazí také hodnoty přímo z AC a případnou chybu skriptu. Když delta nefunguje, pošlete screenshot této záložky.

**Barvy**
- Všechny barvy jde změnit. Tlačítko **Obnovit výchozí barvy** je vrátí zpět.

## Jak to funguje

### Delta

- Referencí je vaše nejlepší **platné** kolo, podle nastavení buď z této session, nebo nejlepší vůbec.
- Během kola aplikace zaznamenává čas v 1000 bodech (každých 0,1 % délky kola). Mezi framy body dopočítává.
- Delta = aktuální čas v kole − čas reference na stejném místě trati.
- Delta je lehce vyhlazená (asi 0,15 s). Barva se přepne až při překročení ±0,02 s, takže kolem nuly nebliká.
- Zelená znamená rychlejší než reference, červená pomalejší. Když reference ještě neexistuje, jsou obě čáry šedé a číslo ukazuje `-.--`.

### Mini sektory

- Kolo je rozdělené na N stejně dlouhých úseků (výchozí 24). Čas průjezdu hranicí úseku se dopočítá mezi framy.
- Po projetí se úsek obarví:
  - **fialově:** nejlepší čas v tomto úseku vůbec (nebo v session, podle zvolené reference),
  - **zeleně:** rychlejší než reference,
  - **žlutě:** pomalejší než reference.
- Neprojeté úseky jsou tmavě šedé a úsek, ve kterém právě jedete, je světlejší.
- Na začátku nového kola se čára vynuluje.

### Cílová čára, boxy a resety

- Pozice v kole se měří od místa, kde AC počítá kola. To nemusí ležet přesně na nule pozice na trati, proto aplikace polohu čáry změří při každém průjezdu.
- **Out lap** a kolo, které začalo v boxové uličce, se nikdy nestanou referencí. Čáry jsou během nich šedé.
- **Neplatné kolo** (řezání trati podle AC nebo průjezd boxy) se nikdy nestane referencí.
- **Teleport do boxů, reset auta a replay:** aktuální kolo se zahodí a měří se znovu od dalšího průjezdu cílem.
- **Nová session nebo restart:** vynuluje se reference session. Uložená nejlepší kola zůstanou.

### Časy po projetí cíle

Čas kola se na chvíli zastaví a obarví:

| Barva | Význam |
| --- | --- |
| Fialová | Nové nejlepší kolo |
| Zelená | Rychlejší než předchozí kolo |
| Červená | Pomalejší než předchozí kolo |
| Šedá | Out lap nebo neplatné kolo |

Nejrychlejší čas (NEJ) je vaše nejlepší kolo v session podle AC a má fialový rámeček.

### Teploty pneumatik

- Velké číslo je vždy **teplota jádra** pneumatiky.
- Plášť (běhoun) má tři zóny: vnitřní, střed a vnější. Vnitřní strana je vždy blíž ke středu auta.
- Barva vychází z optimální teploty: modrá je studená, zelená optimum, žlutá a červená přehřátá.
- Hodnoty čte aplikace přímo z CSP. Pokud je vaše verze CSP neposkytuje, okno ukáže `-` a v nastavení na záložce Pneumatiky je o tom zpráva.

### Ukládání

- Nastavení se ukládá přes `ac.storage` do složky CSP v Dokumentech.
- Nejlepší kolo a nejlepší mini sektory se ukládají do samostatného souboru pro každou kombinaci auto + trať + layout. Přesnou cestu k souboru najdete v nastavení na záložce Delta.
- Zapisuje se jen po dokončeném kole, nikdy během jízdy.

## Vytvoření ZIPu

**Windows (PowerShell):**

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```

**Linux / macOS:**

```bash
./build.sh
```

Výsledek najdete v `dist/MirrorDelta-<verze>.zip` a obsahuje strukturu `apps/lua/MirrorDelta/...`.

## Testy (pro vývoj)

Logika kol, delty, mini sektorů, ukládání i kreslení se testuje mimo hru na simulované jízdě s napodobeným CSP API:

```bash
pip install lupa
python tests/run_tests.py
```

## Známá omezení

- Aplikace zatím nebyla vyzkoušená přímo ve hře, jen v simulaci. Prosím o zpětnou vazbu z prvních jízd.
- Názvy polí pro teploty pneumatik (`tyreCoreTemperature`, `tyreInsideTemperature`, `tyreMiddleTemperature`, `tyreOutsideTemperature`, `tyreOptimumTemperature`) nejsou ve veřejném SDK. Aplikace je proto při startu ověří a bez nich nespadne.
