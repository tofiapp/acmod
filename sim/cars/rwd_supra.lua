-- Supercars Gen3 Supra (supercars_gen3_supra_2026), calibrated to the user's KeyDrive logs (v0.3-v0.9, ~15700 samples):
--   gear ratios: median rpm / km/h per gear with rear slip ratio < 0.03 (65.5, 51.1, 40.9, 34.2, 30.5, 26.5);
--   torque: full-throttle, low-slip longitudinal g in 3rd-5th gear plus the drag of this profile, so the curve is
--   "torque at the wheels / overall ratio" (drivetrain losses included): ~580 Nm at 5000-5500 rpm, 512 at 7000;
--   rev limit 7600 (max logged 7627); front slip angle peak 7.2 deg, peak slip ratio 0.13 (ndSlip = |ratio| / 0.13);
--   grip: with the rear at ndSlip ~1 in 1st/2nd gear the logs show 0.67-0.72 g and 75-95 % throttle, so the
--   longitudinal friction is ~1.2 while lateral g reaches 1.57 (p99): mu 1.2, muLat 1.5 (see the lateral balance);
--   behaviour to reproduce: 1st gear takes ~70-75 % throttle, 2nd spins near the torque peak (5000-5600 rpm).
--   lateral balance (added with the Mustang profile): the Supra logs showed a front-limited car too (front ndSlip ~1.0
--   at 1.2-1.4 g, rear 0.5-0.6 at 1.4 g), while one muLat 1.5 for both axles gave front 0.45-0.51 and rear 0.54-0.62
--   at 1.4 g. muLat 1.4 (front) x muLatRear 1.07 keeps the rear's absolute grip (1.5) and the rear ndSlip at 1.4 g
--   (0.54-0.62) and moves the front to 0.53-0.63 (0.82-0.86 with throttle); scenarios scale their lateral load by the
--   weaker axle (now the front, 1.4).
-- Below 5000 rpm the curve is a typical NA V8 shape (no clean full-throttle data there).
return {
  name = 'rwd_supra', drive = 'RWD',
  mass = 1400, wheelbase = 2.75, cgHeight = 0.45, frontWeight = 0.52, track = 1.6,
  tyreRadius = 0.33, mu = 1.2, muLat = 1.4, muLatRear = 1.07, kappaPeak = 0.13, alphaPeakDeg = 7.2,
  wheelInertia = 1.4, engineInertia = 0.22,
  idleRpm = 1000, launchRpm = 6300, revLimit = 7600, shiftRpm = 7300,
  -- auto-clutch slip rpm by throttle (logs: 1st gear, engine > 1.15 x wheel rpm; slips up to 50-60 km/h)
  clutchSlipRpm = '0:1000 0.1:1900 0.4:3650 0.55:4400 0.7:5150 0.8:5600 1:6300', slipClutchScale = 0.9,
  tyreTail = 0.72, -- logs: lon g at rear ndSlip 20-80 is ~0.7 of the value at the peak
  torque = '1000:300 2500:430 3500:500 4500:560 5000:580 5500:583 6000:568 6500:534 7000:512 7600:480',
  engineBrake = 60,
  rpmPerKmh = { 65.54, 51.14, 40.94, 34.19, 30.49, 26.49 }, reverseRpmPerKmh = 70,
  shiftTime = 0.035, shiftKeep = 0.7, syncTau = 0.015, -- logs: 1->2 at full throttle rear nd 0.5-0.9 -> 1.3-1.7
  cda = 0.95, cla = 1.0, aeroFront = 0.45, crr = 0.015,
}
