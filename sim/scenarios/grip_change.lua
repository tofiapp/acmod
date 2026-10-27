-- Grip change: 3rd gear full gas, asphalt -> grass (x 0.45) for 1 s -> asphalt.
return {
  description = 'Změna gripu: asfalt → tráva (× 0,45) → asfalt',
  group = 'grip', start = { gear = 3, rpm = 3500 }, duration = 6,
  gas = { { 0.2, 6 } }, shift = 'auto', maxGear = 4,
  mu = '0:1 2:1 2.05:0.45 3:0.45 3.05:1 6:1',
}
