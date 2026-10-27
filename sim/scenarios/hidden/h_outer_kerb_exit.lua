return { description = 'Výjezd přes vnější obrubník (0,25 s, grip × 0,6) ve 2. převodu', group = 'dry',
  start = { gear = 2, rpm = 4000 }, duration = 5, gas = { { 0.2, 5 } }, shift = 'auto', maxGear = 3,
  ay = '0:1.0 3:0.2 5:0', kerbs = { { t = 1.6, len = 0.25, wheels = { 1, 3 }, mu = 0.6 } } }
