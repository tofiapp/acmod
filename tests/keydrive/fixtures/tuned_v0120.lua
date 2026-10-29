-- Throttle parameters used by the game when TRACTION_MODE = 2 (pure data). Found by the simulator's optimizer
-- (sim/optimize.lua, tuning set only, nominal and +-20 % grip/power, plus the open-loop replay of the user's real logs
-- for caution, pulse and risk), checked on the hidden set.
-- v0.12.0: optimizer round 6 (seed 74, start = v0.11.1 + PRED_KD 0.5 / RET_HOLD 0.4) on the recalibrated simulator
-- (heavy-tailed slip noise fitted to the logs, whole-held pulse check, low-gear exit scenarios, cost ranking the sets
-- like the user), then HOLD_BAND 0.597 -> 0.70 by hand: the optimizer's 0.6 stopped the pulsing but brought back slow
-- recovery after kerbs (1-3 s in hairpin_kerb_1st on the user's cars, the v0.10 complaint).
-- Measured against v0.11.1 (r63 + RET_HOLD 0.5):
--   sim 1st/2nd-gear throttle direction changes/s (sim/calibrate.lua, Mustang / Supra): 3.78 / 3.70 -> 1.47 / 1.52
--     (v0.10.x s12 1.69 / 1.65; the sim read v0.11.1 ~1.4x higher than the logs)
--   real-log replay (24 datasets): gears 1-2 pulse 2.79 -> 1.91 /s, needless cuts 12.3 -> 9.8 %, risk (more throttle
--     than the game sent while the real tyres were past their peak) 0.14 -> 0.64 % of held time
--   sim/compare.py, tuning set 333 Hz / fps: passes 98 / 93 -> 127 / 117 of 380, cost 86.4 / 89.9 -> 72.5 / 74.9;
--     runs over 1.5x peak slip 146 / 154 -> 163 / 168; rear/axle slides 64 / 61 -> 64 / 60; recovery fails 0-1 -> 1-5
--   hidden set 333 Hz / fps: passes 54 / 49 -> 60 / 47 of 200, cost 82.3 / 81.7 -> 68.3 / 70.8; over 1.5x 79 / 69 -> 90 / 87
return {
  throttle = {
    ASSIST_FALL = 3.55262, ASSIST_FALL_SEVERE = 2.68795, TARGET_SLIP = 0.931618,
  },
  traction = {
    MODE = 2, AW = 0.147016, CREEP = 0.0615668, D_TAU = 0.0136921, ELLIPSE = 0.926603, FALL_MAX = 3.39175,
    FLOOR = 0.132259, FLOOR_LAT = 0.209092, FORGET_DELAY = 0.228905, FORGET_RATE = 1.05893, GUARD_LEVEL = 1.01148,
    HOLD_BAND = 0.7, HOLD_RISE = 0.0152613, K_BACK = 1.21586, K_DOWN = 6.68475, K_DOWN_SEVERE = 4.10537,
    K_UP = 0.782653, LAT_SPLIT = 1, LEARN_LAT = 0.56064, LEARN_MARGIN = 0.963772, MEM = 0, PRED = 0.0411296,
    PRED_KD = 0.309352, RETURN = 0.905245, RET_ARM = 1.00468, RET_HOLD = 0.490648, RET_LOW = 0.507014,
    SLIP_TAU = 0.0147423, SPARE = 0.82465, V_REF = 1.49558,
  },
}
