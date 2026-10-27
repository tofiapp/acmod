-- Slow corner in 1st gear (10-30 km/h, 15-40 % of the lateral grip): the inside rear spins first (logs: max/min rear
-- ndSlip ~1.9/0.35 at 10-45 km/h with yaw), the clutch still slips.
return {
  description = 'Pomalá zatáčka v 1. převodu (10–30 km/h), vnitřní kolo se protáčí první',
  group = 'dry', start = { gear = 1, kmh = 10 }, duration = 4,
  gas = { { 0.2, 4 } }, shift = 'auto', maxGear = 2,
  ayRel = '0:0.4 2:0.3 4:0.15',
}
