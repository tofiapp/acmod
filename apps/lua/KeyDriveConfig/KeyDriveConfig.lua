-- KeyDrive Config app. Phase 8 will add the settings, graph and overlay windows. For now it records a reference of
-- AC's own keyboard handling (normal keyboard input mode, KeyDrive not active), so KeyDrive can copy it.

local reference = require('src/reference')

reference.init()

function script.update(dt)
  reference.update(dt)
end

function script.windowReference(dt)
  reference.window()
end
