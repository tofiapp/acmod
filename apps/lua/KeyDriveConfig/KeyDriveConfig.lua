-- KeyDrive Config app. Window "KeyDrive": in-game settings (diagnostic overlay on/off, traction intervention
-- strength). Window "KeyDrive Reference": records AC's own keyboard handling (normal keyboard input mode, KeyDrive not
-- active), so KeyDrive can copy it.

local reference = require('src/reference')
local settings = require('src/settings')

reference.init()

function script.update(dt)
  reference.update(dt)
  settings.update(dt)
end

function script.windowSettings(dt)
  settings.window()
end

function script.windowReference(dt)
  reference.window()
end
