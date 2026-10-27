-- Front-wheel-drive hot hatch (generic, ~230 hp turbo, road tyres): lots of torque low down, light rear, front axle
-- unloads under acceleration, wheelspin in 1st and partly 2nd.
return {
  name = 'fwd_hothatch', drive = 'FWD',
  mass = 1350, wheelbase = 2.63, cgHeight = 0.52, frontWeight = 0.62, track = 1.55,
  tyreRadius = 0.31, mu = 1.0, muLat = 1.1, kappaPeak = 0.09, alphaPeakDeg = 6,
  wheelInertia = 1.0, engineInertia = 0.15,
  idleRpm = 850, launchRpm = 3000, revLimit = 6800, shiftRpm = 6500,
  torque = '850:180 1500:280 1800:350 4500:350 5500:330 6200:300 6800:270',
  engineBrake = 45,
  rpmPerKmh = { 111, 67, 47, 36, 30, 25 }, reverseRpmPerKmh = 105,
  shiftTime = 0.25, shiftKeep = 0.3,
  cda = 0.68, cla = 0.05, aeroFront = 0.5, crr = 0.013,
}
