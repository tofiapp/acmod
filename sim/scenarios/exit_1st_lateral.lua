-- Corner exit in 1st gear with sustained lateral load (user logs 0.11.0 / 0.11.1, Mustang: most of the real throttle
-- pulsing was in 1st gear at 40-90 km/h with |lat_g| up to ~0.75 g, i.e. ayRel 0.3-0.5 of the car's lateral grip;
-- 0.11.0 logged 4.4 direction changes/s there). A long exit (a slow corner opening onto a straight) from 18 km/h,
-- 75 % of the lateral grip easing to 50 % over 7.6 s, the gas held from 0.3 s, 1st -> 2nd (maxGear 2).
-- Length: the pulse is graded per second of key-held time, so with the earlier 4.5 s (2.7-3.8 s measured) one
-- reversal was worth 0.26-0.37 /s and even the oracle measured 0.5-1 /s. Now 6.4 s are measured in 1st/2nd on every
-- car (oracle 0.31 /s); the rear-drive cars reach their 2nd-gear limit just before the end (Supra 145 km/h).
return {
  description = 'Dlouhý výjezd ze zatáčky v 1. převodu s trvalým bočním zatížením (75 -> 50 % gripu)',
  group = 'dry', start = { gear = 1, kmh = 18 }, duration = 7.6,
  gas = { { 0.3, 7.6 } }, shift = 'auto', maxGear = 2,
  ayRel = '0:0.75 3:0.7 6:0.6 7.6:0.5',
}
