-- Corner exit in 2nd gear held at high lateral load (user logs 0.11.0 / 0.11.1, Mustang: 2nd gear pulsing at
-- 80-120 km/h with |lat_g| 0.5-1.25 g, the worst rate at ~0.5-0.75 g = ayRel ~0.4-0.5; incident 0105-1 t 517-521:
-- 2nd gear ~105 km/h, |lat| 0.7-0.75 g, the cap cycling). A long 2nd-gear exit from 35 km/h (low revs) through
-- 80-120 km/h, 80 % of the lateral grip easing to 55 %, the gas held from 0.3 s. Lengthened from 5 s (3 s measured,
-- one reversal = 0.33 /s) to 6.5 s of key-held time in 2nd on every car (oracle 0.14-0.56 /s); the rear-drive cars
-- reach their 2nd-gear limit in the last ~0.5 s.
return {
  description = 'Dlouhý výjezd ze zatáčky ve 2. převodu: 80 -> 55 % bočního gripu',
  group = 'dry', start = { gear = 2, kmh = 35 }, duration = 7.3,
  gas = { { 0.3, 7.3 } }, shift = 'auto', maxGear = 2,
  ayRel = '0:0.8 4:0.75 6.5:0.65 7.3:0.55',
}
