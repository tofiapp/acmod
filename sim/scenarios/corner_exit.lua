-- Corner exit in 3rd: lateral load 80 % of the car's grip fading to 0 over 3 s, driver presses the gas at 0.5 s.
return {
  description = 'Výjezd ze zatáčky ve 3. převodu (80 % bočního gripu, postupně povoluje)',
  group = 'dry', start = { gear = 3, rpm = 4000 }, duration = 5,
  gas = { { 0.5, 5 } }, shift = 'auto', maxGear = 3,
  ayRel = '0:0.8 0.5:0.8 3.5:0 5:0',
}
