-- Live data shared between the physics core, its render-thread module and (later) the KeyDriveConfig app.
-- Every side must pass exactly this layout to ac.connect().

local M = {}

function M.connect()
  return ac.connect({
    ac.StructItem.key('KeyDrive.Live.v3'),
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
    slip = ac.StructItem.double(),      -- filtered slip ratio of the driven wheels
    targetSlip = ac.StructItem.double(),
    tcLimit = ac.StructItem.double(),
    tcState = ac.StructItem.int32(),    -- 0 no wheel data, 1 off, 2 wheels in the air, 3 ready, 4 limiting
    leak = ac.StructItem.boolean(),     -- the car runs more throttle than KeyDrive wrote (AC mixes in the keyboard)
    physicsHz = ac.StructItem.double(),
    showDiagnostics = ac.StructItem.boolean(),
    bindGas = ac.StructItem.int32(),
    bindBrake = ac.StructItem.int32(),
    bindLeft = ac.StructItem.int32(),
    bindRight = ac.StructItem.int32(),
    bindGearUp = ac.StructItem.int32(),
    bindGearDown = ac.StructItem.int32(),
  })
end

return M
