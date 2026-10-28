-- Supercars Gen3 Supra (supercars_gen3_supra_2026). Refit to the user's KeyDrive v0.10.0 Supra logs (2026-10-28,
-- logs-0102: keydrive-log + incidents merged by t, ~9600 samples at ~33 Hz, KeyDrive active, TRACTION_MODE 2; compact
-- copy in sim/data/real/2026-10-28b-supra.csv). Older logs (v0.3-v0.9, ~15700 samples) set the launch behaviour.
--   gear ratios: rpm / km/h / (1 + rear slip ratio), median over samples with |ratio| < 0.01 / 0.03 / 0.06 (stable to
--   0.1): 66.80, 51.53, 41.45, 34.69, 29.78, 26.11 (old fit, uncorrected: 65.54, 51.14, 40.94, 34.19, 30.49, 26.49);
--   rev limit 7600 (max logged 7619, upshifts at 6670-7570 rpm);
--   torque and drag: least squares over 10 full-throttle, low-slip (rear ndSlip < 0.6, |lat| < 0.35 g) gear / speed
--   bins (3rd 144 km/h ... 6th 235 km/h), simulated with this profile's rotating inertia and rolling resistance:
--   torque x 1.10 on the old curve (which an inertia-free hand fit had produced) and cda 1.05 (0.95 before; the
--   Mustang fit gave the same 1.05). sim / log g: 0.553 / 0.55 (3rd 144), 0.502 / 0.50 (3rd 158), 0.433 / 0.43 (4th
--   171), 0.383 / 0.39 (4th 187), 0.335 / 0.33 (4th 203), 0.331 / 0.315 (5th 197), 0.279 / 0.28 (5th 215), 0.240 / 0.24
--   (5th 230), 0.239 / 0.23 (6th 224), 0.206 / 0.19 (6th 235); weighted rms 0.005 g (old profile, new ratios: 0.037).
--   Rear ndSlip there sim / log 0.51 / 0.48 ... 0.28 / 0.25. Part throttle: 2nd 101 km/h, gas 0.86: 0.65 g, nd 0.72
--   (log 0.62 g at nd 0.6-0.8); 3rd 134 km/h, gas 0.91: 0.53 g (log 0.56);
--   peak slip ratio learned in the game 0.126 (0.118-0.131): kappaPeak 0.126; front slip angle peak 7.2 deg (old logs);
--   longitudinal grip mu 1.2 (old logs: rear at ndSlip ~1 in 1st/2nd gives 0.67-0.72 g);
--   lateral balance: front-limited. Without throttle at 50-130 km/h the fronts sit at ndSlip 0.93-0.96 from 1.2 to
--   1.55 g (at their limit), the rears at 0.48; top 5 % of lateral g (>= 1.30 g, ~80 km/h): front 0.98, rear 0.54;
--   lateral g p95 / p99 1.37 / 1.50 at 50-100 km/h. muLat 1.4 (front, limit ~1.42 g at 80 km/h) x muLatRear 1.1: sim
--   rear ndSlip 0.44 / 0.51 / 0.60 at 1.2 / 1.3 / 1.4 g (80-100 km/h); with 0.63 gas in 2nd at 1.0 g rear 0.65,
--   sx 0.53 (log 0.8-1.2 g, gas 0.63: 0.67, sx 0.46). The sim's front reads only 0.43-0.61 there: the normalised tyre
--   (tyre.lua) reaches 95 % of its force at ndSlip ~0.6, AC's tyre later;
--   upshifts at full throttle, sim / log rise of the rear ndSlip: 2->3 +0.24 / +0.27, 3->4 +0.18 / +0.04, 4->5
--   +0.12 / +0.04 (shift parameters kept from the old fit, 1->2 logged +0.83 with traction control at 0.8 gas);
--   behaviour from the old logs: 1st gear takes ~70-75 % throttle, 2nd spins near the torque peak (5000-5600 rpm).
-- Below 5000 rpm the curve is a typical NA V8 shape (no clean full-throttle data there).
return {
  name = 'rwd_supra', drive = 'RWD',
  mass = 1400, wheelbase = 2.75, cgHeight = 0.45, frontWeight = 0.52, track = 1.6,
  tyreRadius = 0.33, mu = 1.2, muLat = 1.4, muLatRear = 1.1, kappaPeak = 0.126, alphaPeakDeg = 7.2,
  wheelInertia = 1.4, engineInertia = 0.22,
  idleRpm = 1000, launchRpm = 6300, revLimit = 7600, shiftRpm = 7300,
  -- auto-clutch slip rpm by throttle (logs: 1st gear, engine > 1.15 x wheel rpm; slips up to 50-60 km/h)
  clutchSlipRpm = '0:1000 0.1:1900 0.4:3650 0.55:4400 0.7:5150 0.8:5600 1:6300', slipClutchScale = 0.9,
  tyreTail = 0.72, -- logs: lon g at rear ndSlip 20-80 is ~0.7 of the value at the peak
  torque = '1000:330 2500:473 3500:550 4500:616 5000:638 5500:641 6000:625 6500:587 7000:563 7600:528',
  engineBrake = 60,
  rpmPerKmh = { 66.80, 51.53, 41.45, 34.69, 29.78, 26.11 }, reverseRpmPerKmh = 70,
  shiftTime = 0.035, shiftKeep = 0.7, syncTau = 0.015, -- logs: 1->2 at full throttle rear nd 0.5-0.9 -> 1.3-1.7
  cda = 1.05, cla = 1.0, aeroFront = 0.45, crr = 0.015,
}
