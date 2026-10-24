-- Live data shared between the physics core, its render-thread module and (later) the KeyDriveConfig app.
-- Every side must pass exactly this layout to ac.connect().

local M = {}

function M.connect()
  return ac.connect({
    ac.StructItem.key('KeyDrive.Live.v2'),
    alive = ac.StructItem.int32(),      -- physics update counter, wraps at 1e6
    keyMask = ac.StructItem.int32(),    -- bit 0 gas, 1 brake, 2 left, 3 right, 4 gear up, 5 gear down
    inGas = ac.StructItem.double(),     -- joypad state as it arrived, before KeyDrive
    inBrake = ac.StructItem.double(),
    inSteer = ac.StructItem.double(),
    outGas = ac.StructItem.double(),    -- what KeyDrive wrote
    outBrake = ac.StructItem.double(),
    outSteer = ac.StructItem.double(),
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
