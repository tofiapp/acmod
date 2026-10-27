-- Standing start: gas held from 0.2 s, driver upshifts at the car's shift rpm.
return {
  description = 'Rozjezd z místa na plný plyn, řazení nahoru u omezovače',
  group = 'dry', start = { gear = 1, kmh = 0 }, duration = 7,
  gas = { { 0.2, 7 } }, shift = 'auto',
}
