-- Cold tyres: grip x 0.75 warming up to 0.95 during the run, acceleration in 2nd.
return {
  description = 'Studené pneumatiky (grip 0,75 → 0,95)',
  group = 'cold', start = { gear = 2, rpm = 3000 }, duration = 7, mu = '0:0.75 7:0.95',
  gas = { { 0.2, 7 } }, shift = 'auto', maxGear = 3,
}
