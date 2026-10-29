-- Slow hairpin exit in 1st gear with a short kerb on the way out (user logs: 1st-gear exits at 25-60 km/h with
-- lateral load; v0.10 report: after a kerb the throttle did not come back). From 15 km/h, 80 % of the lateral grip
-- easing to 40 % over 8 s, 1st -> 2nd (maxGear 2); the inside wheels ride a kerb at 1.6 s for 0.12 s (grip x 0.5).
-- The throttle must not pulse while the corner opens and must come back after the kerb (recoveryTime). Lengthened
-- from 4.5 s so that ~6.2 s of key-held time are measured for the pulse (kerb window left out; oracle 0.16-0.32 /s).
return {
  description = 'Výjezd z vracečky v 1. převodu s krátkým obrubníkem (0,12 s, grip × 0,5)',
  group = 'dry', start = { gear = 1, kmh = 15 }, duration = 8,
  gas = { { 0.3, 8 } }, shift = 'auto', maxGear = 2,
  ayRel = '0:0.8 1.5:0.75 4:0.65 7:0.5 8:0.4',
  kerbs = { { t = 1.6, len = 0.12, wheels = { 0, 2 }, mu = 0.5 } },
  recovery = { after = 1.72 },
}
