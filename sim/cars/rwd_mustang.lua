-- Supercars Gen3 Mustang (supercars_gen3_mustang_2026), calibrated to the user's KeyDrive v0.10 logs (incidents 2-5,
-- ~6000 samples at ~33 Hz, KeyDrive active; keydrive-log.csv and incident 1 were driven without it):
--   gear ratios: median rpm / km/h per gear at low rear slip (60.37, 46.89, 38.35, 31.67, 27.72, 24.20);
--   rev limit 7500 (max logged 7501), upshifts logged at 7240-7500 rpm; max logged speed 293 km/h (still
--   accelerating at 0.07 g, so not a top speed);
--   torque and drag: the Supra curve (same class, Gen3 parity) with this profile's inertia and rolling resistance gave
--   5-15 % too little full-throttle, low-slip longitudinal g (an inertia-free hand calculation had matched); a least-
--   squares fit over 10 gear / speed bins (2nd 143 km/h ... 6th 286 km/h) gives torque x 1.12 and cda 1.05:
--   sim / log g = 0.586 / 0.615 (2nd 143), 0.478 / 0.49 (3rd 164), 0.424 / 0.43 (3rd 181), 0.361 / 0.35 (4th 192),
--   0.305 / 0.29 (4th 212), 0.218 / 0.21 (5th 236), 0.159 / 0.16 (5th 258), 0.112 / 0.095 (6th 268), 0.065 / 0.07
--   (6th 286); rms 0.014 g. Rear slip at full throttle matches too (sim / log ndSlip 0.42 / 0.37 in 3rd at 164,
--   0.30 / 0.25 in 4th at 212, 0.20 / 0.17 in 6th at 286);
--   peak slip ratio learned in the game 0.126 (0.119-0.131): kappaPeak 0.126; alpha peak in the log 7.0 deg;
--   lateral grip: lateral g p95 1.51-1.61, p99 1.70-1.85, flat from 50 to 260 km/h; in the top 5 % of lateral g
--   (1.58 g, median 171 km/h) the fronts sit at ndSlip ~0.82 (6.3 deg) and the rears at ~0.44 (3.2 deg): a
--   front-limited car with a large rear lateral reserve; the front ndSlip stays ~0.9 (130-190 km/h) from 1.2 to 1.85 g,
--   i.e. the front is at its limit whenever the car corners hard. muLat 1.5 is the front axle (limit ~1.55-1.6 g with
--   this downforce), muLatRear 1.12 the rear's multiple: sim rear / front ndSlip without throttle 0.49 / 0.57 at
--   1.45 g and 100 km/h, 0.53 / 0.60 at 1.58 g and 170 km/h (log 1.4-1.7 g: rear 0.41-0.52), 0.46 / 0.48 at 230 km/h
--   (log 0.31-0.35: the real rear gains more with speed than this aero split gives); with throttle 0.46 / sx 0.27 at
--   1.35 g, 160 km/h, 0.7 gas (log 1.2-1.5 g, 130-190 km/h, gas 0.71: 0.52 / sx 0.31) and 0.52 / sx 0.32 at 100 km/h;
--   upshifts (log: +0.15 ndSlip, except 1->2 0.47 -> 1.25 and 3->4 under 0.54 g 0.37 -> 0.99), sim at full throttle
--   without traction control: 2->3 +0.24, 3->4 +0.19 (+0.19 under 0.54 g, the logged lateral case is not reproduced),
--   4->5 +0.08; shift parameters kept from the Supra.
-- Not in the logs (kept from the Supra): launch clutch (no standing start was logged; 1st gear only from 27 km/h),
-- torque shape below 6300 rpm (scaled with the rest), wheel and engine inertia, downforce and its split.
return {
  name = 'rwd_mustang', drive = 'RWD',
  mass = 1400, wheelbase = 2.75, cgHeight = 0.45, frontWeight = 0.52, track = 1.6,
  tyreRadius = 0.33, mu = 1.2, muLat = 1.5, muLatRear = 1.12, kappaPeak = 0.126, alphaPeakDeg = 7.0,
  wheelInertia = 1.4, engineInertia = 0.22,
  idleRpm = 1000, launchRpm = 6200, revLimit = 7500, shiftRpm = 7300,
  clutchSlipRpm = '0:1000 0.1:1900 0.4:3650 0.55:4400 0.7:5150 0.8:5600 1:6200', slipClutchScale = 0.9,
  tyreTail = 0.72,
  torque = '1000:336 2500:482 3500:560 4500:627 5000:650 5500:653 6000:636 6500:598 7000:573 7500:543',
  engineBrake = 60,
  rpmPerKmh = { 60.37, 46.89, 38.35, 31.67, 27.72, 24.20 }, reverseRpmPerKmh = 65,
  shiftTime = 0.035, shiftKeep = 0.7, syncTau = 0.015,
  cda = 1.05, cla = 1.0, aeroFront = 0.45, crr = 0.015,
}
