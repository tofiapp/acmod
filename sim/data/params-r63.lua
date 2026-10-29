-- Fixture for sim/calibrate.lua: parameter set r63 (optimizer round 5, seed 63) as shipped in KeyDrive v0.11.0, without
-- RET_HOLD; the user drove it (logs sim/data/real e*, f*). Copy of sim/out/cand-r5-63.lua.
-- cost 32.6040, 80/192 runs pass (tuning set, physics rate, 3 grip/power scale(s))
return {
  throttle = { ASSIST_FALL = 3.60522, ASSIST_FALL_SEVERE = 2.64119, TARGET_SLIP = 0.935125 },
  traction = { AW = 0.208035, CREEP = 0.05806, D_TAU = 0.0067968, ELLIPSE = 0.921343, FALL_MAX = 3.43851, FLOOR = 0.126999, FLOOR_LAT = 0.205001, FORGET_DELAY = 0.237063, FORGET_RATE = 1.09953, GUARD_LEVEL = 1.00505, HOLD_BAND = 0.773023, HOLD_RISE = 0.00824764, K_BACK = 1.2049, K_DOWN = 8.50475, K_DOWN_SEVERE = 3.34725, K_UP = 0.814397, LAT_SPLIT = 1, LEARN_LAT = 0.551288, LEARN_MARGIN = 0.965525, MEM = 0, MODE = 2, PRED = 0.0633396, RETURN = 0.908752, SLIP_TAU = 0.012033, SPARE = 0.832833, V_REF = 1.40206 },
}
