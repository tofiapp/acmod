-- Slow hairpin exit in 1st gear with a short kerb on the way out (user logs: 1st-gear exits at 25-60 km/h with
-- lateral load; v0.10 report: after a kerb the throttle did not come back). From 25 km/h, 60 % of the lateral grip
-- easing to 15 % by 3.5 s; the inside wheels ride a kerb at 1.6 s for 0.12 s (grip x 0.5). The throttle must not
-- pulse while the corner opens and must come back after the kerb (recoveryTime).
return {
  description = 'Výjezd z vracečky v 1. převodu s krátkým obrubníkem (0,12 s, grip × 0,5)',
  group = 'dry', start = { gear = 1, kmh = 25 }, duration = 4.5,
  gas = { { 0.3, 4.5 } }, shift = 'auto', maxGear = 2,
  ayRel = '0:0.6 1.5:0.5 3.5:0.15 4.5:0',
  kerbs = { { t = 1.6, len = 0.12, wheels = { 0, 2 }, mu = 0.5 } },
  recovery = { after = 1.72 },
}
