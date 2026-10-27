-- Wet track: grip x 0.6, standing start and a gentle corner exit.
return {
  description = 'Mokro (grip × 0,6): rozjezd a výjezd ze zatáčky',
  group = 'wet', start = { gear = 1, kmh = 0 }, duration = 7, mu = '0:0.6',
  gas = { { 0.2, 7 } }, shift = 'auto', maxGear = 3,
  ay = '0:0 4:0 4.5:0.5 6:0.2 7:0',
}
