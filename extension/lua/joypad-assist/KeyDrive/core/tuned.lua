-- Throttle parameters found by the simulator's optimizer (sim/optimize.lua, tuning set only, nominal and +-20 %
-- grip/power), checked on the hidden set. Used by the game when TRACTION_MODE = 2. Pure data.
-- Candidate s12 (round 2): tuning set 100/210 runs pass at 333 Hz (v0.9.3 defaults: 71/210), hidden set 61/135
-- (v0.9.3: 33/135); runs with slip over 1.5x the tyre peak: 35 (was 131) tuning, 20 (was 95) hidden.
return {
  throttle = { ASSIST_FALL = 3.32804, ASSIST_FALL_SEVERE = 2.94788, TARGET_SLIP = 0.778157 },
  traction = {
    MODE = 2, AW = 0.235667, CREEP = 0.0646699, D_TAU = 0.0128844, FALL_MAX = 2.91375, FLOOR = 0.0901778,
    HOLD_BAND = 0.609368, K_BACK = 1.16368, K_DOWN = 13.4135, K_DOWN_SEVERE = 4.12124, K_UP = 0.808318, LAT_SPLIT = 1,
    LEARN_MARGIN = 0.960905, MEM = 1, PRED = 0.0631275, RETURN = 0.898109, SLIP_TAU = 0.011891, V_REF = 1.93315,
  },
}
