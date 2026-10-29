-- Corner exit in 1st gear with sustained lateral load (user logs 0.11.0 / 0.11.1, Mustang: most of the real throttle
-- pulsing was in 1st gear at 40-90 km/h with |lat_g| up to ~0.75 g, i.e. ayRel 0.3-0.5 of the car's lateral grip;
-- 0.11.0 logged 4.4 direction changes/s there). From 35 km/h, 45 % of the lateral grip easing to 25 % over 4.5 s,
-- the driver holds the gas from 0.3 s. Graded mainly by the whole key-held pulse check.
return {
  description = 'Výjezd ze zatáčky v 1. převodu s trvalým bočním zatížením (45 -> 25 % gripu)',
  group = 'dry', start = { gear = 1, kmh = 35 }, duration = 4.5,
  gas = { { 0.3, 4.5 } }, shift = 'auto', maxGear = 2,
  ayRel = '0:0.45 2:0.4 4.5:0.25',
}
