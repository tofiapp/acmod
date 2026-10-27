-- Corner exit in 3rd: lateral load 1.2 g fading to 0 over 3 s, driver presses the gas at 0.5 s.
return {
  description = 'Výjezd ze zatáčky ve 3. převodu (1,2 g bočně, postupně povoluje)',
  group = 'dry', start = { gear = 3, rpm = 4000 }, duration = 5,
  gas = { { 0.5, 5 } }, shift = 'auto', maxGear = 3,
  ay = '0:1.2 0.5:1.2 3.5:0 5:0',
}
