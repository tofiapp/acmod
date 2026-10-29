-- Throttle parameters found by the simulator's optimizer (sim/optimize.lua, tuning set only, nominal and +-20 %
-- grip/power, plus the open-loop replay of the user's real logs as a caution measure), checked on the hidden set.
-- Used by the game when TRACTION_MODE = 2. Pure data.
-- Round 5, seed 63 (v0.11). The optimizer turned the per-gear/rpm memory off (MEM 0); TRACTION_MEMORY = 1 turns it on.
-- Measured (sim/compare.py, all +-20 % grip/power shifts, 333 Hz / 50-165 fps): tuning 114/320 and 112/320 runs pass
-- (v0.10.x s12: 92 / 99), hidden 61/200 and 57/200 (s12: 45 / 45). Needlessly cut throttle in the user's logs (key held,
-- drive slip under 0.75 of the peak): 4.2 % of the time (s12: 29 %). Price: more short slip spikes over 1.5x the peak
-- (user's cars, tuning set 37/160 runs vs 20; hidden 21/100 vs 6), highest peak about the same (2.8x / 4.9x vs
-- 2.5x / 6.6x). Rear axle slides unchanged; more power-on understeer at low grip (hidden h_kerb_corner_2nd at grip
-- 0.8: the front axle slides ~1.9 s, s12 0.16 s). Picked from the four round-5 results on the tuning set: fewest runs
-- over 1.5x the peak over all cars (111/320) and the lowest highest peak on the user's cars.
-- v0.11.1: + RET_HOLD 0.5 s (core/traction.lua), added by hand after the user's 0.11.0 logs: the cap climbed straight
-- back into the next overshoot in 1st/2nd gear (4-6 throttle direction changes/s, 0.35 s cycle). Open-loop replay of
-- those logs: 1st/2nd-gear direction changes 3.9 -> 2.4 /s (data 1) and 4.1 -> 3.3 (data 2); needless cuts 4.2 -> 4.7 %
-- (11 older datasets; 9.1 -> 11.0 % with the 0.11 logs added).
-- Sim (whose noise is too large and Gaussian, so it shows this cycle only weakly): tuning 112/320 pass (r63 114),
-- hidden 53/200 (61); runs over 1.5x peak slip 110 (121) / 89 (90); more loss fails (83 vs 63).
return {
  throttle = { ASSIST_FALL = 3.60522, ASSIST_FALL_SEVERE = 2.64119, TARGET_SLIP = 0.935125 },
  traction = {
    MODE = 2, RET_HOLD = 0.5, AW = 0.208035, CREEP = 0.05806, D_TAU = 0.0067968, ELLIPSE = 0.921343, FALL_MAX = 3.43851,
    FLOOR = 0.126999, FLOOR_LAT = 0.205001, FORGET_DELAY = 0.237063, FORGET_RATE = 1.09953, GUARD_LEVEL = 1.00505,
    HOLD_BAND = 0.773023, HOLD_RISE = 0.00824764, K_BACK = 1.2049, K_DOWN = 8.50475, K_DOWN_SEVERE = 3.34725,
    K_UP = 0.814397, LAT_SPLIT = 1, LEARN_LAT = 0.551288, LEARN_MARGIN = 0.965525, MEM = 0, PRED = 0.0633396,
    RETURN = 0.908752, SLIP_TAU = 0.012033, SPARE = 0.832833, V_REF = 1.40206, TRACK = 0, GUARD = 1,
  },
}
