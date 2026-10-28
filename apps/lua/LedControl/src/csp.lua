-- The adapter: the only file of LedControl that reads the CSP globals. Every other module takes the API from here
-- (`local ac, ui = csp.ac, csp.ui` at its top), so the tests can hand the whole app a fake implementation
-- (tests/ledcontrol/fake_csp.lua) and check that no module reaches the game directly: they load every other file
-- in an environment where these globals do not exist.
--
-- What is routed: ac.* (car, sim, scene, INI, storage, callbacks, lights), ui.* (window, ExtraCanvas), render.*,
-- io.* and os.* (CSP extends both: io.save / load / scanDir, os.preciseClock), JSON and stringify, the vector /
-- colour / matrix constructors (vec2, vec3, rgb, rgbm, mat4x4), the script table (callbacks the game calls) and
-- LuaJIT's bit library. Standard Lua (string, math, table, pairs, ...) is used directly.

local M = {
  ac = ac,
  ui = ui,
  render = render,
  io = io,
  os = os,
  JSON = JSON,
  stringify = stringify,
  vec2 = vec2,
  vec3 = vec3,
  rgb = rgb,
  rgbm = rgbm,
  mat4x4 = mat4x4,
  script = script,
  bit = bit,
}

-- Names of the routed globals (tests use this list to hide them from the other modules).
M.NAMES = { 'ac', 'ui', 'render', 'io', 'os', 'JSON', 'stringify', 'vec2', 'vec3', 'rgb', 'rgbm', 'mat4x4', 'script',
  'bit' }

-- The LuaJIT build the game runs (for the self-test protocol).
M.jitVersion = (type(jit) == 'table' and jit.version) or _VERSION

return M
