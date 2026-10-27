-- Short lifts mid-corner (the user's habit: 61 of 99 key releases in the logs are under 0.3 s, median 0.15 s,
-- half of them in gears 1-3 at 0.6-1.5 g): 2nd gear, 80 % of the lateral grip, lifts of 0.12, 0.08, 0.15, 0.08 s.
return {
  description = 'Krátká ubrání plynu v zatáčce (0,08–0,15 s), 2. převod',
  group = 'dry', start = { gear = 2, rpm = 4200 }, duration = 5,
  gas = { { 0.2, 1.5 }, { 1.62, 1.9 }, { 1.98, 2.3 }, { 2.45, 2.75 }, { 2.83, 5 } }, shift = 'auto', maxGear = 3,
  ayRel = '0:0.8 5:0.8',
}
