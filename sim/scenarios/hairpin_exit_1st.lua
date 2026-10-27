-- Hairpin exit in 1st: slow, 1.0 g lateral fading over 2.5 s.
return {
  description = 'Výjezd z vracečky v 1. převodu',
  group = 'dry', start = { gear = 1, rpm = 2500 }, duration = 4,
  gas = { { 0.3, 4 } }, shift = 'auto', maxGear = 2,
  ay = '0:1.0 0.3:1.0 2.8:0 4:0',
}
