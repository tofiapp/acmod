-- Scenario list (tuning set). Lateral load (ayRel) is a fraction of each car's dry lateral grip. Each runs on every car in sim/cars at both controller rates.
return {
  'standing_start', 'accel_2nd_3rd', 'corner_exit', 'hairpin_exit_1st', 'wet', 'cold_tyres', 'kerb',
  'upshift_full_throttle', 'lift_repress_corner', 'rapid_tapping', 'reverse_standing', 'grip_change',
  'short_lifts_corner', 'slow_corner_1st', 'kerb_straight', 'corner_then_straight',
  -- low-gear exits where the real pulsing is (0.11 logs): sustained lateral, whole key-held pulse check
  'exit_1st_lateral', 'exit_2nd_lateral', 'hairpin_kerb_1st',
}
