-- LedControl UI kit: the few building blocks every tab uses, so the window looks and reads the same everywhere.
-- Rules (docs/ledcontrol-ui.md): short labels, explanations in (?) tooltips, a label column for form rows,
-- collapsible sections for rarely used settings, colour only for state. Nothing here allocates per call once the
-- caller passes prebuilt labels (helpers that need labels cache them on first use).
-- CSP calls: ui.treeNode with ui.TreeNodeFlags (PocketTechnician), ui.textDisabled (RallyCopilot), ui.itemHovered +
-- ui.setTooltip, ui.pushFont(ui.Font.Small / Title) (official apps), ui.pushStyleColor(ui.StyleColor.Text / Button)
-- (WebBrowser), ui.iconButton(icon, size, padding) with ui.Icons (WebBrowser, AISplineEditor), ui.pushID / popID,
-- ui.colorButton (Flashlight), ui.dummy, ui.getCursorX / getCursorY, ui.drawCircleFilled (MirrorDelta, official apps).

local patterns = require('src/patterns')
local color = require('src/color')

local K = {}

K.LABEL_W = 150            -- label column of form rows
K.CONTROL_W = 260          -- default width of sliders and combos in form rows
K.ROW_W = 520              -- widest row in the 560 px window

K.GREY = rgbm(0.62, 0.62, 0.62, 1)
K.DIM = rgbm(0.45, 0.45, 0.47, 1)
K.GREEN = rgbm(0.35, 0.95, 0.45, 1)
K.ORANGE = rgbm(1, 0.68, 0.2, 1)
K.RED = rgbm(1, 0.38, 0.32, 1)
K.BLUE = rgbm(0.35, 0.6, 1, 1)
K.WHITE = rgbm(1, 1, 1, 1)
K.ACCENT = rgbm(0.2, 0.45, 0.85, 1)

local TEXT = ui.StyleColor and ui.StyleColor.Text or nil
local BUTTON = ui.StyleColor and ui.StyleColor.Button or nil
local FONT_SMALL = ui.Font and ui.Font.Small or nil
local FRAMED = ui.TreeNodeFlags and ui.TreeNodeFlags.Framed or 0
local OPEN = ui.TreeNodeFlags and ui.TreeNodeFlags.DefaultOpen or 0
local HELP_MARK = '(?)'

-- Coloured text that wraps at the window edge (ui.textColored never wraps).
function K.note(text, colour)
  if TEXT and ui.pushStyleColor then
    ui.pushStyleColor(TEXT, colour)
    ui.textWrapped(text)
    ui.popStyleColor()
  else
    ui.textColored(text, colour)
  end
end

-- Small grey text (hints that must stay visible; prefer K.help for explanations).
function K.dim(text)
  if FONT_SMALL and ui.pushFont then ui.pushFont(FONT_SMALL) end
  K.note(text, K.GREY)
  if FONT_SMALL and ui.popFont then ui.popFont() end
end

-- "(?)" on the same line; the explanation shows when the mouse is over it.
function K.help(text)
  ui.sameLine()
  if ui.textDisabled then ui.textDisabled(HELP_MARK) else ui.textColored(HELP_MARK, K.DIM) end
  if ui.itemHovered() then ui.setTooltip(text) end
end

-- Tooltip for the item just drawn.
function K.tip(text)
  if ui.itemHovered() then ui.setTooltip(text) end
end

-- Left column label of a form row; the control follows on the same line, aligned for every row.
-- ui.alignTextToFramePadding (TimeShift) puts the text on the same baseline as the framed control next to it.
function K.label(text)
  if ui.alignTextToFramePadding then ui.alignTextToFramePadding() end
  ui.text(text)
  ui.sameLine(K.LABEL_W)
end

-- Small grey category title inside a list.
function K.caption(text)
  if FONT_SMALL and ui.pushFont then ui.pushFont(FONT_SMALL) end
  ui.textColored(text, K.GREY)
  if FONT_SMALL and ui.popFont then ui.popFont() end
end

-- Section header that is always open.
function K.header(text)
  ui.header(text)
end

-- Collapsible section (closed unless open == true); label must carry a stable '##id'. content is a module-level
-- function (no closure per frame).
function K.section(label, open, content)
  ui.treeNode(label, open and bit.bor(FRAMED, OPEN) or FRAMED, content)
end

-- A row of buttons where one is selected (segmented control). labels: prebuilt '##id' labels; returns the
-- clicked index or nil.
function K.choice(labels, current)
  local clicked = nil
  for i = 1, #labels do
    if i > 1 then ui.sameLine(0, 2) end
    local on = i == current
    if on and BUTTON and ui.pushStyleColor then ui.pushStyleColor(BUTTON, K.ACCENT) end
    if ui.button(labels[i]) and not on then clicked = i end
    if on and BUTTON and ui.popStyleColor then ui.popStyleColor() end
  end
  return clicked
end

-- Icon button with its own id and a tooltip; returns true when clicked (never when disabled).
-- ui.iconButton(icon, size, padding, frame, ui.ButtonFlags.Disabled) as WebBrowser / RGBControl.
local DISABLED = ui.ButtonFlags and ui.ButtonFlags.Disabled or 0
function K.iconButton(id, icon, tooltip, disabled)
  ui.pushID(id)
  local clicked = ui.iconButton(icon, 22, 5, true, disabled and DISABLED or 0)
  ui.popID()
  if tooltip then K.tip(tooltip) end
  return clicked and not disabled
end

-- s cut to at most n bytes on a UTF-8 character boundary, with '…' when cut (call on change, not per frame).
function K.shorten(s, n)
  if type(s) ~= 'string' or #s <= n then return s end
  local cut = n - 3
  while cut > 0 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    cut = cut - 1
  end
  return s:sub(1, cut) .. '…'
end

-- Coloured dot on the text line (state: K.GREEN = active, K.DIM = idle, ...).
local dotPos = vec2()
local DOT_SIZE = vec2(12, 14)
function K.dot(colour)
  dotPos:set(ui.getCursorX() + 6, ui.getCursorY() + 8)     -- numbers, not a new vec2 per call
  ui.dummy(DOT_SIZE)
  ui.drawCircleFilled(dotPos, 4.5, colour, 12)
end

-- Quick picks of colours that stay true at any brightness (patterns.SAFE_COLOURS) after a colour button.
-- c: the rgbm the colour button edits; returns true when a quick pick changed it.
local SWATCH = vec2(16, 16)
local SWATCH_FLAGS = ui.ColorPickerFlags and bit.bor(ui.ColorPickerFlags.NoPicker or 0, ui.ColorPickerFlags.NoTooltip or 0) or 0
local SAFE = {}
for i = 1, #patterns.SAFE_COLOURS do
  local r, g, b = color.unpack(color.parse(patterns.SAFE_COLOURS[i], 0))
  SAFE[i] = rgbm(r, g, b, 1)
end
local swatchLabels = {}
function K.swatches(id, c)
  local labels = swatchLabels[id]
  if not labels then
    labels = {}
    for i = 1, #SAFE do labels[i] = '##sw_' .. id .. '_' .. i end
    swatchLabels[id] = labels
  end
  local changed = false
  for i = 1, #SAFE do
    ui.sameLine(0, 2)
    local s = SAFE[i]
    if ui.colorButton(labels[i], s, SWATCH_FLAGS, SWATCH) or (ui.itemClicked and ui.itemClicked()) then
      c.r, c.g, c.b = s.r, s.g, s.b
      changed = true
    end
  end
  return changed
end

-- Colour button + quick picks. Returns true when the colour changed.
local COLOUR_BUTTON = vec2(40, 0)
function K.colourField(label, c)
  local changed = ui.colorButton(label, c, ui.ColorPickerFlags.PickerHueBar, COLOUR_BUTTON)
  if K.swatches(label, c) then changed = true end
  return changed
end

-- Czech plural: plural(n, 'dioda', 'diody', 'diod')
function K.plural(n, one, few, many)
  if n == 1 then return one end
  if n >= 2 and n <= 4 then return few end
  return many
end

return K
