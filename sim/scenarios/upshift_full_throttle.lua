-- Upshifts at full throttle from 2nd at 6000 rpm: the engine speed mismatch kicks the wheels after each shift.
return {
  description = 'Řazení nahoru na plný plyn (2. → 3. → 4.)',
  group = 'dry', start = { gear = 2, rpm = 6000 }, duration = 6,
  gas = { { 0, 6 } }, shift = { { 0.6, 'up' } }, shiftAuto = true, maxGear = 4,
}
