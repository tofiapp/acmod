-- Rolling acceleration in 2nd from low revs, through the torque peak, upshift into 3rd.
return {
  description = 'Zrychlení ve 2. převodu z nízkých otáček přes vrchol momentu, pak 3. převod',
  group = 'dry', start = { gear = 2, rpm = 2500 }, duration = 6,
  gas = { { 0.1, 6 } }, shift = 'auto', maxGear = 3,
  steady = { { 4.5, 6 } },
}
