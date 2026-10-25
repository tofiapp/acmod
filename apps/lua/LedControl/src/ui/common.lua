-- Small UI helpers shared by the tabs.

local M = {}

local TEXT_COLOUR = ui.StyleColor and ui.StyleColor.Text or nil

-- Coloured text that wraps at the window edge (ui.textColored never wraps, so long Czech notes would be cut off).
-- ui.pushStyleColor(ui.StyleColor.Text, colour) as WebBrowser/ControlsDownloads.lua uses it.
function M.note(text, colour)
  if TEXT_COLOUR and ui.pushStyleColor then
    ui.pushStyleColor(TEXT_COLOUR, colour)
    ui.textWrapped(text)
    ui.popStyleColor()
  else
    ui.textColored(text, colour)
  end
end

return M
