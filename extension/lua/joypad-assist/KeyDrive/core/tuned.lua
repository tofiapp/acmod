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
-- v0.13.0: the user drove v0.12.1 at slider strength 100 ("much better than 50: very few jerks, the throttle onset
-- is getting good"), so that became the default: TARGET_SLIP x0.8 (0.9316 -> 0.7453), K_BACK, K_UP, FORGET_RATE x0.6.
-- Real logs (Road America, v0.12.1 at 100 vs 50): throttle reversals >= 5 % 0.38 vs 0.65 /s, throttle travel 0.18 vs
-- 0.25 /s, assist-made drops 0.05 vs 0.09 /s; needless-cut share 34 % vs 14 % (the user did not feel it as caution).
-- Sim: big reversals 0.61 vs 0.92 /s, loss vs the oracle 0.17 vs 0.05, runs over 1.5x peak 116 vs 163 of 380.
-- (The measured numbers above this note are for the v0.12.0 set = strength 0 of v0.13.)
-- v0.13.1: optimizer round 7 in ANCHOR mode (sim/evaluate.lua opts.anchor = the v0.13.0 set): smaller throttle
-- amplitude without more loss or real-log caution than the anchor; seed 83. Against v0.13.0: sim (tuning, 333 Hz / fps)
-- passes 43 / 48 -> 126 / 110 of 380, pulse fails 113 -> 47, loss fails 279 -> 181, over 1.5x peak 116 -> 119 (same),
-- slides 57 -> 60, recovery fails 19 -> 17; hidden passes 14 / 17 -> 58 / 62, over 1.5x 66 / 57 -> 63 / 51, recovery
-- fails 5 / 7 -> 9 / 10. Real-log replay: reversals >= 5 % 0.52 -> 0.38 /s (gears 1-2 1.19 -> 0.82), needless cuts
-- 38 -> 35 %, risk 0.16 -> 0.24 %. HOLD_BAND 0.55 with a faster K_BACK 1.03: the onset without wheelspin is faster
-- (0 -> full 0.95 s instead of 1.35 s; THROTTLE_RISE_RATE ~85 brings the old onset back, K_BACK scales with it). A
-- variant keeping K_BACK 0.73 was clearly worse (loss 0.21, caution 44 %): the recovery after cuts needs it.
return {
  throttle = {
    ASSIST_FALL = 3.59753, ASSIST_FALL_SEVERE = 2.51877, TARGET_SLIP = 0.763041,
  },
  traction = {
    MODE = 2, AW = 0.165985, CREEP = 0.0695285, D_TAU = 0.0123033, ELLIPSE = 0.907694, FALL_MAX = 3.55408,
    FLOOR = 0.20735, FLOOR_LAT = 0.116898, FORGET_DELAY = 0.151058, FORGET_RATE = 0.34108, GUARD_LEVEL = 1.02921,
    HOLD_BAND = 0.55, HOLD_RISE = 0.00685547, K_BACK = 1.03499, K_DOWN = 5.22029, K_DOWN_SEVERE = 3.60462,
    K_UP = 0.68592, LAT_SPLIT = 1, LEARN_LAT = 0.347181, LEARN_MARGIN = 0.983805, MEM = 0, PRED = 0.0560064,
    PRED_KD = 0.209141, RETURN = 0.871818, RET_ARM = 0.944237, RET_HOLD = 0.506012, RET_LOW = 0.42934,
    SLIP_TAU = 0.0227815, SPARE = 0.832098, V_REF = 1.6325,
  },
}
