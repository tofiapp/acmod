-- COPY of extension/lua/joypad-assist/KeyDrive/src/shared.lua (the app cannot require the Gamepad FX script's files).
-- Keep both identical: tests/keydrive test 32 compares them. Every side must pass exactly this layout to ac.connect().

local M = {}

function M.connect()
  return ac.connect({
    ac.StructItem.key('KeyDrive.Live.v11'),
    alive = ac.StructItem.int32(),      -- physics update counter, wraps at 1e6
    keyMask = ac.StructItem.int32(),    -- bit 0 gas, 1 brake, 2 left, 3 right, 4 gear up, 5 gear down
    inGas = ac.StructItem.double(),     -- joypad state as it arrived, before KeyDrive
    inBrake = ac.StructItem.double(),
    inSteer = ac.StructItem.double(),
    outGas = ac.StructItem.double(),    -- what KeyDrive wrote
    outBrake = ac.StructItem.double(),
    outSteer = ac.StructItem.double(),
    gasRequest = ac.StructItem.double(), -- ramped key throttle before caps and traction
    cap = ac.StructItem.double(),       -- throttle cap: manual cap reduced in corners
    slip = ac.StructItem.double(),      -- filtered slip of the driven wheels (ndSlip: 1 = tyre peak)
    slipRatio = ac.StructItem.double(), -- longitudinal slip ratio of the driven wheels (diagnostics)
    usesNdSlip = ac.StructItem.boolean(),
    targetSlip = ac.StructItem.double(),
    tcLimit = ac.StructItem.double(),   -- traction cap (absolute throttle level)
    tcMemory = ac.StructItem.double(),  -- throttle level this gear took last time (1 = no limit learned)
    gx = ac.StructItem.double(),        -- lateral g
    brakeRequest = ac.StructItem.double(), -- ramped key brake before limits
    brakeCap = ac.StructItem.double(),  -- manual brake cap reduced by the trail-brake release
    brakeK = ac.StructItem.double(),    -- lock limiter multiplier
    brakeSlip = ac.StructItem.double(), -- highest wheel ndSlip (filtered) while braking
    brakeMemory = ac.StructItem.double(), -- remembered brake level where the wheels last reached the target
    brakeTargetSlip = ac.StructItem.double(),
    brakeState = ac.StructItem.int32(), -- 0 no wheel data, 1 off, 2 car's ABS, 3 ready, 4 limiting
    brakePeakRatio = ac.StructItem.double(), -- learned slip ratio at the tyre's peak
    steerRequest = ac.StructItem.double(), -- ramped key steering before the grip window
    steerLo = ac.StructItem.double(),   -- grip window in output units
    steerHi = ac.StructItem.double(),
    frontAlpha = ac.StructItem.double(), -- front slip angle, deg (steering sign)
    alphaPeak = ac.StructItem.double(), -- learned peak front slip angle, deg
    betaF = ac.StructItem.double(),     -- front axle travel direction, deg
    degPerUnit = ac.StructItem.double(), -- road wheel degrees per steering unit
    steerFromAC = ac.StructItem.boolean(), -- AC computes the keyboard steering itself, KeyDrive leaves it alone
    acSteerVotes = ac.StructItem.int32(),
    steerState = ac.StructItem.int32(), -- 0 no data, 1 low speed (no window), 2 free, 3 limiting, 4 countersteer
    recordLog = ac.StructItem.boolean(),
    tcState = ac.StructItem.int32(),    -- 0 no wheel data, 1 off, 2 wheels in the air, 3 ready, 4 limiting,
                                        -- 5 switched off by the driver with TRACTION_KEY
    leak = ac.StructItem.boolean(),     -- the car runs more throttle than KeyDrive wrote (AC mixes in the keyboard)
    physicsHz = ac.StructItem.double(),
    showDiagnostics = ac.StructItem.boolean(),
    bindGas = ac.StructItem.int32(),
    bindBrake = ac.StructItem.int32(),
    bindLeft = ac.StructItem.int32(),
    bindRight = ac.StructItem.int32(),
    bindGearUp = ac.StructItem.int32(),
    bindGearDown = ac.StructItem.int32(),
    tractionMode = ac.StructItem.int32(), -- 1 remembering foot, 2 regulator (v0.10)
    tcSx = ac.StructItem.double(),       -- mode 2: longitudinal slip of the driven wheels (slipRatio / learned peak)
    tcLateral = ac.StructItem.double(),  -- mode 2: lateral part of the combined slip
    tcTargetX = ac.StructItem.double(),  -- mode 2: longitudinal target left by the friction ellipse
    tcSlipRate = ac.StructItem.double(), -- mode 2: filtered rate of the regulated slip, 1/s
    tcKappaPeak = ac.StructItem.double(), -- mode 2: learned slip ratio at the tyre's peak
    keyboardCaptured = ac.StructItem.boolean(), -- written by the render module: a text field has the keyboard (v10)
    -- v11, written by the KeyDriveConfig app (window "KeyDrive"); cfgSet false = the app has not set anything yet, the
    -- settings.ini values apply
    cfgSet = ac.StructItem.boolean(),
    cfgShowDiag = ac.StructItem.boolean(), -- show the diagnostic overlay
    cfgStrength = ac.StructItem.double(),  -- traction intervention 0..100, 50 = as tuned
    strength = ac.StructItem.double(),     -- written by the core: the strength in effect (the app shows it)
  })
end

return M
