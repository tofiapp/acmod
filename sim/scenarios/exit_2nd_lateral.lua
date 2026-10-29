-- Corner exit in 2nd gear held at half the lateral grip (user logs 0.11.0 / 0.11.1, Mustang: 2nd gear pulsing at
-- 80-120 km/h with |lat_g| 0.5-1.25 g, the worst rate at ~0.5-0.75 g = ayRel ~0.4-0.5; incident 0105-1 t 517-521:
-- 2nd gear ~105 km/h, |lat| 0.7-0.75 g, the cap cycling). From 80 km/h, 50 % of the lateral grip for 3.3 s, then
-- opening to 20 %; the gas is held from 0.3 s.
return {
  description = 'Výjezd ze zatáčky ve 2. převodu: 3 s na 50 % bočního gripu, pak povoluje',
  group = 'dry', start = { gear = 2, kmh = 80 }, duration = 5,
  gas = { { 0.3, 5 } }, shift = 'auto', maxGear = 3,
  ayRel = '0:0.5 3.3:0.5 5:0.2',
}
