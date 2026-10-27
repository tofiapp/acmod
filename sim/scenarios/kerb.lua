-- Kerb: 3rd gear, 0.8 g lateral, full gas; the inside wheels hit a kerb at 2.0 s for 0.15 s (grip x 0.4).
return {
  description = 'Obrubník: vnitřní kola 0,15 s na obrubníku (grip × 0,4) při plném plynu v zatáčce',
  group = 'dry', start = { gear = 3, rpm = 4500 }, duration = 5,
  gas = { { 0.2, 5 } }, shift = 'auto', maxGear = 3,
  ayRel = '0:0.53 5:0.53',
  kerbs = { { t = 2.0, len = 0.15, wheels = { 0, 2 }, mu = 0.4 } },
  steady = { { 3.5, 5 } },
}
