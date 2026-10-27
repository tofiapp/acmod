-- Lift and re-press in a corner: 2nd gear, 1.1 g lateral, the driver lifts for 0.3 s at 2 s.
return {
  description = 'Ubrání a znovu přidání plynu v zatáčce (2. převod, 1,1 g)',
  group = 'dry', start = { gear = 2, rpm = 4500 }, duration = 5,
  gas = { { 0.2, 2.0 }, { 2.3, 5 } }, shift = 'auto', maxGear = 3,
  ay = '0:1.1 5:1.1',
}
