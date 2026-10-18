# MirrorDelta

Lua aplikace pro Assetto Corsa s Custom Shaders Patch (CSP). Hlavní částí je minimalistický ukazatel delty, který si umístíte nad zpětné zrcátko. Má dvě tenké čáry a deltu v sekundách, bez pozadí a bez titulku. K tomu jsou volitelná okna: pozice s časy kola, teploty pneumatik, převod, poškození a notifikace.

Každé okno má vlastní ikonu na liště aplikací a zapíná se zvlášť:

| Okno | Co ukazuje |
| --- | --- |
| **MirrorDelta** | Čára mini sektorů, čára delty a delta v sekundách (±) |
| **MirrorDelta Timing** | Pozice, kolo, aktuální čas, poslední kolo (smazané červeně) a nejrychlejší kolo |
| **MirrorDelta Tyres** | Teplota jádra pneumatik a teploty pláště (vnitřní / střed / vnější) |
| **MirrorDelta Damage** | Poškození jako jednoduchý kříž: předek, zadek, boky, 4 pneumatiky, 4 zavěšení a motor v % |
| **MirrorDelta Gear** | Ukazatel otáček z 12 dílků, pod ním převod na barevné dlaždici a pod převodem rychlost |
| **MirrorDelta Flags** | Aktuální vlajka v pravém horním rohu: vlajka a její název, dokud platí |
| **MirrorDelta Mirror** | Zpětné zrcátko v posuvném obdélníku se šipkami nad auty za vámi (jako kamera v GT3) |
| **MirrorDelta Standings** | Pořadí dole místo původního pořadí AC (F9): vy a auta kolem vás, odstupy |
| **MirrorDelta Setup** | Jeden řádek nahoře uprostřed při změně nastavení auta (TC, ABS, brzdy…) |
| **MirrorDelta Notifications** | Krátké zprávy nahoře: vlajky, nejrychlejší kolo, předjetí, boxy, neplatné kolo, odpojení |

## Instalace

### Přes Content Manager (doporučeno)

1. Vezměte soubor `MirrorDelta-1.17.0.zip`. Buď ho máte stažený, nebo ho vytvoříte build skriptem (viz [Vytvoření ZIPu](#vytvoření-zipu)).
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
2. Klikněte na ikonu **MirrorDelta** (případně **MirrorDelta Timing**, **MirrorDelta Tyres**, **MirrorDelta Gear**, **MirrorDelta Damage** a **MirrorDelta Notifications**).
3. **Přesun okna:** najeďte na okno myší. Objeví se titulek, za který okno přetáhnete.
4. **Velikost:** táhněte za pravý dolní roh okna. Čáry vyplní celou šířku okna. Tloušťka čar, mezery a velikost čísla se zvětšují úměrně šířce okna, takže okno stačí roztáhnout přesně na šířku zrcátka.
5. **Nastavení:** při najetí myší klikněte v titulku na ozubené kolečko.

Po instalaci nové verze se všechna okna MirrorDelta jednou sama zobrazí a rozmístí kolem středu obrazovky. Kdykoli je tam vrátíte tlačítkem **Zobrazit všechna okna uprostřed obrazovky** nahoře v nastavení.

### Vypnutí původních ukazatelů AC

- **Pořadí AC (F9)** aplikace vypne sama, stejně jako to dělá oficiální aplikace CSP Unbound.
- **Systémové zprávy AC** (původní řádek nahoře: ABS, TC, penalizace, připojení…) aplikace skryje tak, že zapne volbu CSP „Hide system messages“ ve vašem `Documents/Assetto Corsa/cfg/extension/gui.ini` (stejně zapisuje nastavení CSP oficiální aplikace ControllerTweaks). Je to stejná volba jako **Content Manager > Nastavení > Custom Shaders Patch > GUI > Hide system messages**. Když v nastavení MirrorDelta skrývání vypnete, vrátí ji zpět. Zprávy o nastavení auta pak ukáže okno MirrorDelta Setup, ostatní okno MirrorDelta Notifications. Kdyby se původní řádek dál ukazoval, zapněte volbu ručně v Content Manageru a restartujte jízdu.
- **Vlajky** ukazuje okno MirrorDelta Flags v pravém horním rohu a pod ním okno MirrorDelta Notifications se všemi zprávami ve stejném stylu (barevná ikona vpravo, text vlevo od ní). Po instalaci se tam obě samy přesunou.
- Okna s deltou, časy, pneumatikami, notifikacemi, vlajkou a poškozením mají matné průsvitné pozadí podle velikosti obsahu. Sytost jde změnit v nastavení na záložce Barvy.

Když některé okno narazí na chybu, ukáže ji červeně přímo v sobě a ostatní okna běží dál. Chyba je i v záložce Diagnostika.

Pokud se ikony na liště neobjeví, aktualizujte CSP a zkontrolujte, že jsou v nastavení CSP zapnuté Lua aplikace.

## Nastavení

Nastavení je společné pro všechna okna a má osm záložek.

**Delta**
- Zobrazit: mini sektory, čáru delty, deltu v sekundách (každé zvlášť).
- Rozložení:
  - **A:** čas nahoře, čára delty uprostřed, mini sektory dole.
  - **B** (výchozí): mini sektory nahoře, čára delty uprostřed, čas dole.
- Počet mini sektorů (výchozí 24), počet skupin (výchozí 3, tedy 8 | 8 | 8) a mezera mezi skupinami.
- Tloušťka čar, mezera mezi čarami, velikost čísla a průhlednost. Hodnoty v pixelech platí pro okno široké 600 px a se šířkou okna se škálují.
- Čára delty (výchozí) je rozdělená uprostřed a pohybuje se plynule jako původní ukazatel AC. Doprava roste zelená, když teď jedete rychleji než v referenčním kole, doleva červená, když pomaleji. Porovnává se posledních zhruba 3 sekund jízdy, ne celkový čas. Plná délka na jednu stranu odpovídá rozdílu 0,1 s (nastavitelné). Číslo pod čarou ukazuje celkovou deltu. Jde přepnout na celou čáru barvou podle celkové delty.
- Na omezovači blikají modře čára delty i mini sektory, stejně jako okno s převodem (jde vypnout).
- Intenzita barvy podle velikosti delty: když je zapnutá, plnou barvu má delta od ±0,5 s (nastavitelné).
- Zdroj delty:
  - **Vlastní měření, jinak delta z AC** (výchozí): dokud aplikace nemá vlastní referenci (out lap, první kolo, kolo po resetu), ukazuje deltu, kterou počítá samotné AC (ne v režimu Předchozí kolo).
  - **Jen vlastní měření.**
  - **Jen delta z AC.**
- Reference: předchozí kolo (výchozí), nejlepší kolo této session, nebo nejlepší kolo vůbec (uložené).
  - **Předchozí kolo** porovnává jen s kolem těsně před tím a s ničím jiným (ani s uloženým kolem, ani s deltou z AC). Out lap tedy deltu nemá. Druhé kolo se porovná s out lapem: delta naskočí v místě, kde jste vyjeli z boxů, a počítá celý čas out lapu včetně boxové uličky, takže na cílové čáře se rovná rozdílu časů kol. Před tím místem delta není a sektory jsou šedé.
- Tlačítko **Smazat uložená data** smaže uložené nejlepší kolo a mini sektory pro aktuální auto a trať. Potvrdíte ho druhým kliknutím.

**Pořadí dole (MirrorDelta Standings)**
- Vy uprostřed a auta před vámi a za vámi v pořadí AC (výchozí 7 aut, nastavitelné v záložce Časy). Každé auto: pozice, zkratka jména (tři písmena příjmení) a odstup.
- V závodě odstup v sekundách (auto před vámi záporně, červeně; za vámi kladně, zeleně; o kolo a víc „KOLO“). Odstup se počítá podle nastavení: průběžně z polohy na trati, po každém sektoru, nebo jen po projetí cílem. Po sektoru a cíli se měří jako na časomíře: z časů, kdy obě auta projela stejný bod trati (počet sektorů na kolo nastavitelný, výchozí 3).
- Odstup k vám, nebo k autu před ním (interval). Jména: zkratka, celé příjmení, nebo bez jmen. Barvy odstupů jdou vypnout.
- V tréninku a kvalifikaci rozdíl nejlepších kol. Auto v boxech ukazuje BOX.

**Časy**
- Zobrazit: pozici, počet kol, aktuální čas, poslední kolo a nejrychlejší čas (každé zvlášť). Smazané poslední kolo je červené.
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
- Jeden jednoduchý vzhled (kříž): předek a zadek jsou vodorovné pruhy nahoře a dole, levý a pravý bok svislé pruhy po stranách. V každém rohu je pneumatika (opotřebení, defekt) a vedle ní čtvereček zavěšení s vlastním stavem. Uprostřed je motor v %: bílá, pod 95 % žlutá, pod 50 % červená.
- Část v pořádku je světle šedá, s poškozením se barví od žluté po červenou. Část, do které jste právě narazili, krátce blikne bíle.
- Okno je vlevo uprostřed obrazovky a ukáže se jen po nárazu na 8 sekund, jako původní ukazatel AC. V nastavení jde přepnout na „vždy“ nebo „dokud je něco poškozené“. Při najetí myší je vidět vždy, ať ho jde přesunout.
- Poškození zavěšení CSP v žádné oficiální aplikaci neukazuje. Aplikace ho zkouší číst, a když ho vaše verze CSP nedá, čtverečky zavěšení zůstanou šedé (stav je vidět v nastavení).
- Citlivost: od jaké hodnoty z AC je strana plně červená. Aktuální hodnoty z AC vidíte přímo v nastavení, podle nich jde citlivost doladit.

**Zrcátko**
- Okno MirrorDelta Mirror ukazuje zpětný pohled AC (stejný obraz jako virtuální zrcátko) v rámečku, který jde posunout a zvětšit kamkoli. Výchozí tvar je obdélník 400 × 150. Obraz se nikdy nedeformuje: okno ukáže výřez zrcátka ve svém poměru stran (užší okno prostředek šířky), přiblížení jde zvýšit. Obraz zrcátka dává CSP v HDR (před úpravou obrazu AC), proto jsou čtyři způsoby, jak z něj udělat normální obraz: gamma (výchozí), YEBIS jako pohled pro OBS, tonemapping UI a bez úprav. Přepínají se kliknutím do okna; po najetí myší okno ukáže verzi a aktivní způsob. Jas jde zvýšit i snížit.
- Původní zrcátko AC se vypíná ve hře volbou virtual cockpit / virtuální zrcátko.
- Dvě nejbližší auta za vámi mají kolem sebe rohový rámeček jako radar v GT3, ve výrazných barvách s tmavým obrysem: zelený (nedotahuje), oranžový (dotahuje), červený (blízko, méně než 8 m nebo u vás do 1,5 s; navíc šipka nad ním). Velikost rámečku odpovídá vzdálenosti, značky se pohybují plynule. U nejbližšího auta je odstup v sekundách.
- Počítají se jen auta, která jsou za vámi i podle polohy na trati, takže auto na vedlejší rovince se neoznačí.
- Auto za vámi mimo zobrazený výřez: šipka u toho okraje. Auto vedle vás: červený pruh na té straně, jeho jasná část ukazuje, jestli je auto vepředu, na úrovni nebo vzadu.
- Šířka záběru (výchozí 50°) se nastavuje tak, aby značky seděly přesně na autech; hlídaná vzdálenost výchozí 60 m.
- Nastavitelné: kolik nejbližších aut se označí (1–6, výchozí 2), značka (rohový rámeček, celý rámeček, šipka nad autem), barvy (zelená/oranžová/červená, bílá/žlutá/červená, modrá/žlutá/červená), tloušťka čar, výplň a odstup u nejbližšího auta.
- Okna jiných aplikací, která vypadají jako zpětné zrcátko nebo vlajky, aplikace skryje (pokud je AC vede jako okna aplikací) a jednou to oznámí notifikací. Vestavěné virtuální zrcátko a vlajky AC, které okny nejsou, CSP aplikacím vypnout nedovolí. Když AC zpětný pohled zrovna nevykresluje (třeba mimo kokpit), okno to napíše.

**Notifikace**
- Vzhled: zaoblená pilulka (výchozí), šikmý pruh jako v TV grafice, nebo jen tenká linka s textem.
- Jak dlouho zpráva zůstane (výchozí 4,5 s) a kolik zpráv je vidět najednou (výchozí 2).
- Co oznamovat (každé jde vypnout):
  - nejrychlejší kolo session (kdokoli, se jménem a časem),
  - vaše pozice: posun nahoru a ztráta, s tím, koho jste předjeli nebo kdo vás předjel (nová pozice musí vydržet 1 s, takže boj bok po boku nebliká),
  - ostatní auta v boxech a z boxů,
  - vlajky: žlutá, modrá, černá, penalizace, poslední kolo a cíl,
  - vaše neplatné kolo (řezání trati), jen během měřeného kola, ne v out lapu,
  - odpojení jezdce, jen online.
- Pozice a boxy se standardně hlásí jen v závodě, v tréninku by jich bylo moc.
- Tlačítko **Ukázat ukázku** zobrazí dvě zkušební zprávy, podle nich okno umístěte (výchozí šířka 520 px, patří doprostřed nahoru).
- **Nastavení auta (jeden řádek nahoře):** okno MirrorDelta Setup ukáže na 2,5 s (nastavitelné) jeden řádek, když změníte trakční kontrolu, TC2, ABS, rozložení brzd, brzdění motorem, mapu paliva, turbo, MGU-K / MGU-H, omezovač v boxech nebo rychlosti, automatické řazení nebo spojku. Řádek má pořád stejnou velikost: krátký název vlevo (TC, ABS, BRZDY VPŘEDU…), hodnota vpravo a dole dílky úrovně, třeba „TC 3 / 8“. Nová změna řádek přepíše, takže při držení tlačítka brzd se hodnota jen plynule mění. Řádek je jen pro nastavení auta: zprávu AC o nastavení ukáže jen tehdy, když změnu nezachytila aplikace sama (nic se nezdvojí). Ostatní systémové zprávy AC (česky) a penalizace jsou zvlášť v notifikacích. Hodnoty čte stejně jako oficiální aplikace Unbound; co daná verze CSP nemá, se vynechá.

**Diagnostika**
- Ukazuje, co aplikace při měření kola vidí: jestli se kolo měří, kolik průjezdů cílem a referencí zaznamenala a proč naposledy kolo zahodila nebo nezapočítala.
- Zobrazí také hodnoty přímo z AC a případnou chybu skriptu. Když delta nefunguje, pošlete screenshot této záložky.

**Barvy**
- Všechny barvy jde změnit. Tlačítko **Obnovit výchozí barvy** je vrátí zpět.

## Jak to funguje

### Delta

- Výchozí referencí je **předchozí kolo** (i neplatné, i out lap od výjezdu z boxů). Nic jiného se v tomto režimu nepoužije.
- V režimech nejlepšího kola je referencí vaše nejlepší **platné** kolo, podle nastavení buď z této session, nebo nejlepší vůbec. Když zvolená reference není, použije se ta druhá. Následující čtyři body platí jen pro tyto režimy.
- Když AC uzná kolo jako své nejlepší a aplikace ho měla celé změřené, stane se referencí, i když ho vlastní kontrola nevzala.
- Když vlastní reference není, ale AC nejlepší čas zná, běží delta proti tomuto času. Průběh kola se odhadne podle změřeného kola, nebo rovnoměrně.
- **Od prvního kola:** dokud platné kolo není, slouží jako dočasná reference celé kolo, které platné být nemůže (kolo začínající v boxové uličce nebo kolo s řezáním). První platné kolo ji nahradí. Dočasná reference se nikdy neukládá.
- **Out lap:** mini sektory se měří vždy už od výjezdu z boxové uličky. Sektor, ve kterém jste vyjeli, zůstane šedý.
  - S referencí (uloženou nebo z této session) se sektory barví proti ní a běží i delta. Ukazuje, kolik jste od výjezdu ztratili nebo získali proti referenci na stejném úseku trati.
  - Bez reference se sektory barví podle delty z AC, pokud ji AC má. Jinak se jen označí jako projeté.
  - Polohu cílové čáry si aplikace pamatuje pro každé auto a trať, takže sektory sedí i před prvním průjezdem cílem.
- Kdy delta zatím není a proč, ukazuje záložka Diagnostika. V okně delty žádný nápis není.
- Během kola aplikace zaznamenává čas v 1000 bodech (každých 0,1 % délky kola). Mezi framy body dopočítává.
- Delta = aktuální čas v kole − čas reference na stejném místě trati.
- Delta je lehce vyhlazená (asi 0,15 s). Barva se přepne až při překročení ±0,02 s, takže kolem nuly nebliká.
- Když vlastní reference ještě není, použije se delta z AC (`performanceMeter`). AC ji počítá proti svému nejlepšímu kolu v session. Mini sektory se pak barví podle toho, jestli se delta z AC v sektoru zlepšila (zeleně), nebo zhoršila (žlutě).
- Zelená znamená rychlejší než reference, červená pomalejší. Když reference ještě neexistuje, jsou obě čáry šedé a číslo ukazuje `-.--`.

### Mini sektory

- Fialový sektor je osobní rekord. Počítá se po sektorech: sektor projetý bez řezání a mimo boxy platí, i když celé kolo platné není.

- Kolo je rozdělené na N stejně dlouhých úseků (výchozí 24). Čas průjezdu hranicí úseku se dopočítá mezi framy.
- Po projetí se úsek obarví:
  - **fialově:** nejlepší čas v tomto úseku vůbec (nebo v session, podle zvolené reference),
  - **zeleně:** rychlejší než reference,
  - **žlutě:** pomalejší než reference.
- Neprojeté úseky jsou tmavě šedé a úsek, ve kterém právě jedete, je světlejší.
- Na začátku nového kola se čára vynuluje.

### Cílová čára, boxy a resety

- Pozice v kole se měří od místa, kde AC počítá kola. To nemusí ležet přesně na nule pozice na trati, proto aplikace polohu čáry změří při každém průjezdu.
- **Out lap** a kolo, které začalo v boxové uličce, se nikdy nestanou platnou referencí (jen dočasnou, viz výše).
- Kolo se počítá, jen když AC zároveň zvýší počet kol. Samotné vynulování časovače (třeba při výjezdu z boxů) se za průjezd cílem nepovažuje.
- **Neplatné kolo** (řezání trati podle AC nebo průjezd boxy) se nikdy nestane referencí.
- **Teleport do boxů, reset auta a replay:** aktuální kolo se zahodí a měří se znovu od dalšího průjezdu cílem.
- **Nová session nebo restart:** vynuluje se reference session. Uložená nejlepší kola zůstanou.

### Časy po projetí cíle

Čas kola se na chvíli zastaví a obarví:

| Barva | Význam |
| --- | --- |
| Fialová | Nové nejlepší kolo |
| Zelená | Rychlejší než předchozí kolo |
| Červená | Pomalejší než předchozí kolo, nebo smazané kolo (řezání, nebo ho AC po dojetí označilo za neplatné) |
| Šedá | Out lap nebo kolo z boxové uličky |

Za řezání se počítá jen změna z platného na neplatné během kola (AC po out lapu ještě chvíli hlásí neplatné kolo, to se nepočítá). Když AC samo kolo hlásí jako neplatné, nikdy není nejrychlejší a NEJ ukáže nejlepší čas před ním. Když AC kolo vezme jako svůj nejlepší čas, AC ho počítá, a aplikace ho nikdy neukáže jako smazané (AC neplatná kola za nejlepší nebere). Smazané kolo ohlásí notifikace „KOLO SMAZÁNO“ s důvodem (kdo ho smazal a nejlepší čas v AC). Proč bylo kolo smazané, ukazuje záložka Diagnostika (řádky „Smazané kolo“ a „Hlášení AC po kole“). Sloupec POSL ukazuje poslední kolo, smazané červeně.
Nejrychlejší čas (NEJ) je vaše nejlepší kolo v session podle AC (bez smazaných kol) a má fialový rámeček.

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

- Písmo ve všech oknech je bez stínu.
- Původní pořadí (leaderboard) z AC aplikace skrýt neumí, protože CSP umí skrýt jen všechny aplikace najednou. Zavřete ho ručně na liště aplikací.
- Aplikace zatím nebyla vyzkoušená přímo ve hře, jen v simulaci. Prosím o zpětnou vazbu z prvních jízd.
- Názvy polí pro teploty pneumatik (`tyreCoreTemperature`, `tyreInsideTemperature`, `tyreMiddleTemperature`, `tyreOutsideTemperature`, `tyreOptimumTemperature`) nejsou ve veřejném SDK. Aplikace je proto při startu ověří a bez nich nespadne.
