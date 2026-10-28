-- Kerb on the exit, then straight asphalt (user report, v0.10: "after a kerb the car refused to accelerate although it
-- was back on asphalt with the wheel straight"): 3rd gear, full gas, rear wheels 0.2 s on a kerb (grip x 0.45) with a
-- little lateral load fading, then a straight. The throttle must come back once the grip is back.
return {
  description = 'Obrubník na výjezdu a pak rovina: plyn se má po návratu na asfalt vrátit',
  group = 'dry', start = { gear = 3, rpm = 4200 }, duration = 6,
  gas = { { 0.2, 6 } }, shift = 'auto', maxGear = 4,
  ayRel = '0:0.4 1.6:0.2 2.2:0 6:0',
  kerbs = { { t = 1.5, len = 0.2, wheels = { 2, 3 }, mu = 0.45 } },
  recovery = { after = 1.7 },
}
