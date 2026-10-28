-- Fake implementation of the adapter apps/lua/LedControl/src/csp.lua for the tests: the same fields, served by the
-- mock CSP API of mock_csp.lua (scene graph, materials with a write log, ui, render, io in a temp folder, storage).
-- The mock follows the signatures of the SDK (acc-lua-sdk: ac_common.lua, ac_scene.lua, ac_ui.lua, ac_render.lua,
-- io / os extensions); behaviour it cannot know is marked "UNSURE" there. helpers.lua loads every app module except
-- src/csp.lua in an environment without these globals, so a direct call from the app fails the test run.

local NAMES = { 'ac', 'ui', 'render', 'io', 'os', 'JSON', 'stringify', 'vec2', 'vec3', 'rgb', 'rgbm', 'mat4x4', 'script',
  'bit' }

return function ()
  local F = { NAMES = NAMES, fake = true, jitVersion = jit.version }
  for i = 1, #NAMES do F[NAMES[i]] = _G[NAMES[i]] end
  return F
end
