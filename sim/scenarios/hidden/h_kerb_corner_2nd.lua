-- HIDDEN (never tune on it): 2nd-gear corner with a bumpy inside kerb in the middle, then a straight.
return {
  description = 'Zatáčka ve 2. převodu s hrbolatým vnitřním obrubníkem uprostřed, pak rovina',
  group = 'dry', start = { gear = 2, rpm = 4000 }, duration = 6.5,
  gas = { { 0.2, 6.5 } }, shift = 'auto', maxGear = 3,
  ayRel = '0:0.75 2.4:0.75 3.0:0 6.5:0',
  kerbs = { { t = 1.3, len = 0.3, wheels = { 0, 2 }, mu = 0.9, bump = 0.8, hz = 10 } },
  recovery = { after = 3.0 },
}
