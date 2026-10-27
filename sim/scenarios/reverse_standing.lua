-- Reverse from standstill, then neutral: traction is off in reverse (plain ramp), nothing may misbehave.
return {
  description = 'Couvání z místa a neutrál (bez regulace, jen náběh plynu)',
  group = 'reverse', start = { gear = -1, kmh = 0 }, duration = 4,
  gas = { { 0.2, 2.5 }, { 3.0, 4 } }, shift = { { 2.7, 'neutral' } },
}
