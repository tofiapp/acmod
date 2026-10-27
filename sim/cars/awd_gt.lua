-- All-wheel-drive GT (generic, ~550 hp turbo V6/V8, semi-slicks), open centre with 35 % of the torque to the front.
return {
  name = 'awd_gt', drive = 'AWD', frontShare = 0.35,
  mass = 1700, wheelbase = 2.78, cgHeight = 0.5, frontWeight = 0.54, track = 1.6,
  tyreRadius = 0.34, mu = 1.15, muLat = 1.35, kappaPeak = 0.11, alphaPeakDeg = 6.5,
  wheelInertia = 1.6, engineInertia = 0.25,
  idleRpm = 900, launchRpm = 4800, revLimit = 7100, shiftRpm = 6800,
  clutchSlipRpm = '0:900 0.5:3300 1:4800', tyreTail = 0.75,
  torque = '900:300 2000:520 3200:650 6000:650 6600:600 7100:540',
  engineBrake = 70,
  rpmPerKmh = { 105, 66, 48, 37, 30, 25 }, reverseRpmPerKmh = 100,
  shiftTime = 0.12, shiftKeep = 0.4, syncTau = 0.03,
  cda = 0.75, cla = 0.25, aeroFront = 0.45, crr = 0.014,
}
