-- The adapter rule: no LedControl module but src/csp.lua touches the CSP API. helpers.lua already loads every
-- module without the CSP globals (a direct read fails the run); this file adds the static side (code paths a test
-- never runs) and checks that the real adapter and the fake one offer the same fields. It also records the LuaJIT
-- build the tests run on.

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local check = H.check

local NAMES = { 'ac', 'ui', 'render', 'io', 'os', 'JSON', 'stringify', 'vec2', 'vec3', 'rgb', 'rgbm', 'mat4x4', 'script',
  'bit' }

-- the real adapter, loaded with the (mock) globals
local real = dofile(appDir .. '/src/csp.lua')
local fake = dofile(appDir .. '/../../../tests/ledcontrol/fake_csp.lua')()
local same = #real.NAMES == #NAMES and #fake.NAMES == #NAMES
for i = 1, #NAMES do
  if real.NAMES[i] ~= NAMES[i] or fake.NAMES[i] ~= NAMES[i] then same = false end
  if real[NAMES[i]] ~= _G[NAMES[i]] then same = false end
end
check(same, 'src/csp.lua and the fake adapter route the same globals')

-- static scan: every use of a routed name in a module comes from a local bound to csp.<name>
local function strip(src)
  src = src:gsub('%-%-%[%[.-%]%]', '')
  src = src:gsub('%-%-[^\n]*', '')
  src = src:gsub("'[^'\n]*'", "''"):gsub('"[^"\n]*"', '""')
  return src
end
local files = {}
local p = io.popen('find "' .. appDir .. '" -name "*.lua"')
for line in p:lines() do files[#files + 1] = line end
p:close()
table.sort(files)
local bad = {}
for _, path in ipairs(files) do
  if not path:match('/src/csp%.lua$') then
    local f = io.open(path, 'r')
    local src = f:read('*a')
    f:close()
    local code = strip(src)
    local bound = {}
    local names, values = code:match('local csp = require%(\'\'%)%s*\nlocal ([%w_, ]+) = ([%w_., ]+)')
    if names then
      local vals = {}
      for v in values:gmatch('[%w_.]+') do vals[#vals + 1] = v end
      local k = 0
      for n in names:gmatch('[%w_]+') do k = k + 1; if vals[k] == 'csp.' .. n then bound[n] = true end end
    end
    for _, n in ipairs(NAMES) do
      -- a use: the name not preceded by a letter, digit, '_', '.' or ':'
      if (' ' .. code):find('[^%w_.:]' .. n .. '[^%w_]') and not bound[n] then
        bad[#bad + 1] = path:match('LedControl/(.*)$') .. ': ' .. n
      end
    end
    if code:find('[^%w_]_G[^%w_]') or code:find('getfenv') or code:find('rawget%(_G') then
      bad[#bad + 1] = path:match('LedControl/(.*)$') .. ': _G / getfenv'
    end
  end
end
check(#bad == 0, 'every module takes the CSP API from src/csp.lua (' .. table.concat(bad, '; ') .. ')')
check(#files > 25, 'scanned the app files (' .. #files .. ')')

-- LuaJIT the tests run on (CSP: "OpenResty's fork of LuaJIT compiled with 5.2 compatibility", acc-lua-sdk README)
print('LuaJIT of the tests: ' .. tostring(jit and jit.version) .. ', 5.2 compat: '
  .. tostring(table.pack ~= nil and rawlen ~= nil))
check(jit ~= nil and jit.version:match('^LuaJIT 2%.1') ~= nil, 'tests run on LuaJIT 2.1 like CSP')

return H.finish('test_adapter')
