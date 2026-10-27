-- Rapid tapping: gas key 100 ms on / 100 ms off for 3 s in 2nd, then held.
local gas = {}
for i = 0, 14 do gas[#gas + 1] = { 0.2 + i * 0.2, 0.3 + i * 0.2 } end
gas[#gas + 1] = { 3.4, 5 }
return {
  description = 'Rychlé ťukání do plynu (5× za sekundu), pak držení',
  group = 'tapping', start = { gear = 2, rpm = 3000 }, duration = 5,
  gas = gas, shift = 'auto', maxGear = 3,
}
