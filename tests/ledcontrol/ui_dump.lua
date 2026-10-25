-- Prints a plain text picture of every tab (what the window shows, in order; "|" = same line) for design reviews.
-- Run: python3 tests/ledcontrol/dump_ui.py [tab ...]
local appDir, tmpDir, mockPath, helpersPath, tabsArg = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, frame = H.env, H.frame

local lines, cur, same = {}, nil, false
local depth = 0
local function vis(label)
  label = tostring(label or '')
  return (label:gsub('##.*$', ''):gsub('###.*$', ''))
end
local function put(s)
  if same and cur then
    lines[cur] = lines[cur] .. '  |  ' .. s
  else
    lines[#lines + 1] = string.rep('    ', depth) .. s
    cur = #lines
  end
  same = false
end
local wrap = {
  text = function (t) put(vis(t)) end,
  textWrapped = function (t) put(vis(t)) end,
  textColored = function (t) put('{' .. vis(t) .. '}') end,
  textDisabled = function (t) put('(' .. vis(t) .. ')') end,
  header = function (t) put('== ' .. vis(t) .. ' ==') end,
  button = function (l) put('[' .. vis(l) .. ']') end,
  iconButton = function (i) put('[icon ' .. tostring(i) .. ']') end,
  invisibleButton = function () end,
  checkbox = function (l, v) put((v and '[x] ' or '[ ] ') .. vis(l)) end,
  radioButton = function (l, v) put((v and '(o) ' or '( ) ') .. vis(l)) end,
  selectable = function (l, v) put((v and '> ' or '  ') .. vis(l)) end,
  slider = function (l, v, mn, mx, fmt) put('<' .. vis(l) .. ' ' .. (fmt and string.format(fmt:gsub('%%%%', '%%'), v) or tostring(v)) .. '>') end,
  combo = function (l, p) put('{v ' .. vis(l) .. ': ' .. tostring(p) .. '}') end,
  colorButton = function (l) put('[■' .. vis(l) .. ']') end,
  inputText = function (l, t) put('[_' .. vis(l) .. ': ' .. tostring(t) .. '_]') end,
  progressBar = function (v, s, o) put('[====' .. tostring(o or '') .. '====]') end,
  separator = function () put('------------------------------') end,
  sameLine = function () same = true end,
  setTooltip = function (t) lines[#lines + 1] = string.rep('    ', depth) .. '      (tooltip: ' .. vis(t):gsub('\n', ' / ') .. ')' end,
}
for name, fn in pairs(wrap) do
  local orig = ui[name]
  ui[name] = function (...)
    if env.ui.dump then fn(...) end
    if orig then return orig(...) end
  end
end
local origTree = ui.treeNode
ui.treeNode = function (label, flags, content)
  if content == nil then flags, content = nil, flags end
  if env.ui.dump then put('▼ ' .. vis(label)) end
  depth = depth + 1
  if content then content() end
  depth = depth - 1
end
ui.tabItem = function (label, fn)
  if label == env.ui.tab then fn() end
end

H.formulaCar(1)
env.car.speedKmh = 120
env.car.rpm = 10350
env.storage = {}
H.loadApp()
frame(5)
env.windowOpen = true
for tab in tostring(tabsArg):gmatch('[^,]+') do
  env.ui.tab = tab
  frame(2)
  lines, cur, same = {}, nil, false
  env.ui.dump = true
  frame(1)
  env.ui.dump = false
  print('################ ' .. tab .. ' (' .. #lines .. ' lines)')
  for i = 1, #lines do print(lines[i]) end
end
return 0
