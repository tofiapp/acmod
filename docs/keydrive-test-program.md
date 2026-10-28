# KeyDrive – testovací program (v0.11)

Asi 20 minut, auto Supra (supercars_gen3_supra_2026), trať, kterou znáš. Cíl: zjistit, jestli nová regulace plynu
(TRACTION_MODE 2, vyladěná v simulátoru) funguje i ve hře, a dostat data na další kalibraci simulátoru.

## Příprava

1. Nainstaluj `KeyDrive-0.11.x.zip` přes Content Manager (nebo `build-keydrive.ps1 -Install -AcPath "<složka AC>"`).
2. Ovládání: Input method **Gamepad**, **Combine with keyboard** zapnuto, Gamepad FX = **KeyDrive**.
3. V nastavení KeyDrive nech výchozí hodnoty (TRACTION_MODE = 2).
4. Pokud máš most v `C:\AC-Claude` s `ac_export.py`, nech ho běžet (exportuje jen do `C:\AC-Claude\logs`).

## Jízda (TRACTION_MODE = 2)

| # | Co udělat | Na co se soustředit |
|---|---|---|
| 1 | 3× rozjezd z místa v 1. převodu, plyn držet až do řazení | plazí se to? kopne to najednou? protočí se kola? |
| 2 | 2× ve 2. převodu z ~40 km/h plný plyn přes 5000–5600 ot./min | chytí to protočení u vrcholu momentu? |
| 3 | 3× výjezd z pomalé zatáčky / vracečky (1.–2. převod) s plným plynem | smykne se zadek? je plyn plynulý? |
| 4 | 3× výjezd z rychlé zatáčky (3.–4. převod) | ubírá plyn zbytečně, nebo včas? |
| 5 | V zatáčce několikrát krátce pustit a znovu přidat plyn | žádné cukání, plyn se vrací plynule |
| 6 | Řazení nahoru na plný plyn 1→2→3 | kopnutí po řazení se chytí? |
| 7 | 1–2 normální kola v tempu | celkový dojem |
| 8 | Klávesa X: vypnout hlídání, gumovat / roztočit, X znovu a rozjet se | nápis nahoře, plyn se po zapnutí stáhne plynule |

## Srovnání (volitelné, 5 minut)

Přepni `TRACTION_MODE = 1` (předchozí verze) a zopakuj body 1, 2 a 3. Pak vrať 2.

## Pošli

- `Dokumenty\Assetto Corsa\logs\keydrive\keydrive-log.csv` a všechny `keydrive-incident-*.csv`
- pokud běží most: export posledních 10 minut (`export_last_seconds(600)`), soubor z `C:\AC-Claude\logs`
- pár vět: rozjezd, protočení, pulzování plynu, smyky, zbytečná opatrnost, co bylo lepší / horší než v0.10

Pak napiš **„hotovo“**: logy rozeberu, porovnám se simulátorem, simulátor podle nich zpřesním a regulaci znovu vyladím.
