-- Long fast corner, then a straight (user log, Mustang v0.10.0, t 535-541 s: 3rd gear at 150-168 km/h, 1.4-1.65 g,
-- the gas pressed in the corner, the rear's longitudinal slip crossed the corner target and the learned limit pinned
-- the throttle at 0.52-0.56 with plenty of spare grip afterwards). 3rd gear from 5600 rpm, 70 % of the car's lateral
-- grip tightening to 93 % while the key ramp rises, the corner opens over 0.6 s, then a straight at full gas. Once
-- the corner has ended the throttle must come back (recoveryTime).
return {
  description = 'Dlouhá rychlá zatáčka ve 3. převodu a pak rovina: plyn se má po výjezdu vrátit',
  group = 'dry', start = { gear = 3, rpm = 5600 }, duration = 8,
  gas = { { 0.3, 8 } }, shift = 'auto', maxGear = 4,
  ayRel = '0:0.7 1.2:0.7 1.8:0.93 3.2:0.93 3.8:0 8:0',
  recovery = { after = 3.8 },
}
