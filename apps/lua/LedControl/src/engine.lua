-- Scenario evaluation. compile() flattens a preset for a layout into preallocated arrays; step() runs every frame:
-- each scenario's test once (with hold timers), then per LED group the highest-priority active scenario that targets
-- the group paints its LEDs; transparent cells (patterns.UNSET) fall through to the next active scenario and finally
-- to the preset's base look ('off' or the car's own logic). No allocation in step().

local color = require('src/color')
local patterns = require('src/patterns')
local conditions = require('src/conditions')
local presets = require('src/presets')
local rpm = require('src/rpm')

local M = {}

local UNSET = patterns.UNSET

local function targetsGroup(to, group, hasRole)
  if to == 'all' then return true end
  if to == group.role then return true end
  -- a target the car does not have falls back to the main row
  if group.role == 'main' and not hasRole[to] then return true end
  return false
end

-- Per LED RPM thresholds of a group (digital_instruments RPM_SWITCH / CSP INPUT_THRESHOLD), or nil when any is missing.
local function thresholdsOf(layout, ids)
  local thr = { rank = {} }
  local lo, hi = math.huge, -math.huge
  for k = 1, #ids do
    local r = tonumber(layout.leds[ids[k]].rpm)
    if not r or r <= 0 or r > 50000 then return nil end
    thr[k] = r
    lo, hi = math.min(lo, r), math.max(hi, r)
  end
  for k = 1, #ids do thr.rank[k] = hi > lo and (thr[k] - lo) / (hi - lo) or 1 end
  return thr
end

-- preset: preset table; layout: detect layout; ST: car_state.ST (for availability notes).
function M.compile(preset, layout, ST)
  local C = { base = (preset and presets.baseOf(preset) == 'original') and color.ORIGINAL or color.OFF, scen = {}, groups = {},
    warnings = {}, presetId = preset and preset.id or '', layoutSig = layout and layout.signature or '' }
  if not layout then return C end
  local hasRole = {}
  for gi = 1, #layout.groups do hasRole[layout.groups[gi].role] = true end
  local list = presets.effective(preset)
  for i = 1, #list do
    local e = list[i]
    local okAvail, note = true, nil
    if e.def and e.def.avail then okAvail, note = e.def.avail(ST, layout) end
    local sc = { id = e.id, name = e.name, entry = e, def = e.def, custom = e.custom, on = e.on, prio = e.prio, to = e.to,
      param = tonumber(e.param) or 0, cl = patterns.compile(e.look), cond = e.custom and conditions.compile(e.when) or nil,
      avail = okAvail, note = note, active = false, since = 0, holdUntil = -1, forceUntil = -1, u = 1, frames = {},
      thr = {}, hold = e.def and e.def.hold or 0, layoutOk = true }
    -- shift lights reach a full row one step before the shift point, so the full row shows before its blink
    if e.id == 'shiftLights' then sc.cl.lead = true end
    C.scen[i] = sc
  end
  for gi = 1, #layout.groups do
    local g = layout.groups[gi]
    local grp = { gi = gi, name = g.name, role = g.role, ids = g.leds, n = #g.leds, buf = {}, cands = {}, activeName = nil,
      activeId = nil }
    for k = 1, grp.n do grp.buf[k] = UNSET end
    for i = 1, #C.scen do
      local sc = C.scen[i]
      -- switched-off scenarios stay candidates so their Test button still shows them
      if targetsGroup(sc.to, g, hasRole) then
        grp.cands[#grp.cands + 1] = sc
        if sc.cl.p == 'frames' then
          local f = patterns.framesFor(sc.cl, gi, grp.n, sc.entry.look and sc.entry.look.rescale ~= false)
          sc.frames[gi] = f
          if f and not f.ok then
            sc.layoutOk = false
            local word = f.srcN == 1 and 'diodu' or ((f.srcN >= 2 and f.srcN <= 4) and 'diody' or 'diod')
            C.warnings[#C.warnings + 1] = string.format('%s: snímky jsou pro %d %s, skupina %s má %d.', sc.name,
              f.srcN, word, g.name, grp.n)
          end
        end
        if sc.cl.p == 'fill' then
          -- RPM per LED: the car's own values from tab Otáčky (main row, shift lights), else with source 'car'
          -- the thresholds from the car's files
          local thr = nil
          if sc.id == 'shiftLights' and g.role == 'main' and rpm.ledRpm and #rpm.ledRpm == grp.n then
            -- colour zones follow the RPM order (as with the car's own thresholds), so edges-to-centre works too
            thr = { rank = {} }
            local lo, hi = math.huge, -math.huge
            for k = 1, grp.n do
              thr[k] = rpm.ledRpm[k]
              lo, hi = math.min(lo, thr[k]), math.max(hi, thr[k])
            end
            for k = 1, grp.n do thr.rank[k] = hi > lo and (thr[k] - lo) / (hi - lo) or 1 end
          elseif sc.cl.src == 'car' then
            thr = thresholdsOf(layout, g.leds)
          end
          sc.thr[gi] = thr
          if thr and sc.id == 'shiftLights' then
            for k = 1, #thr do if not sc.carStart or thr[k] < sc.carStart then sc.carStart = thr[k] end end
          end
        end
      end
    end
    C.groups[gi] = grp
  end
  return C
end

-- Forces scenario id on for the given seconds (button Test).
function M.test(C, id, seconds, now)
  for i = 1, #C.scen do
    if C.scen[i].id == id then C.scen[i].forceUntil = now + (seconds or 5) end
  end
end

function M.find(C, id)
  for i = 1, #C.scen do if C.scen[i].id == id then return C.scen[i] end end
  return nil
end

local function testOf(sc, ST)
  if sc.custom then return conditions.eval(sc.cond, ST) end
  local def = sc.def
  if not def or not def.test then return false end
  return def.test(ST, sc.param) == true
end

function M.step(C, ST, fb)
  local t = ST.t
  local scen = C.scen
  for i = 1, #scen do
    local sc = scen[i]
    local on = false
    if C.solo and sc.id ~= C.solo then on = false       -- self-test: only the scenario under test
    elseif sc.forceUntil > t then on = true
    elseif sc.on and ST.ready then
      on = testOf(sc, ST)
      if not on and sc.carStart and ST.rpm >= sc.carStart then on = true end
      if on then sc.holdUntil = t + sc.hold
      elseif sc.holdUntil > t then on = true end
    end
    if on and not sc.active then sc.since = t end
    sc.active = on
    if on and sc.def and sc.def.value then sc.u = sc.def.value(ST, sc.param) end
  end
  local groups = C.groups
  for gi = 1, #groups do
    local grp = groups[gi]
    local ids, n, buf = grp.ids, grp.n, grp.buf
    for k = 1, n do fb[ids[k]] = UNSET end
    local left = n
    grp.activeName, grp.activeId = nil, nil
    local cands = grp.cands
    for ci = 1, #cands do
      local sc = cands[ci]
      if sc.active then
        local u = sc.u
        if sc.forceUntil > t and sc.def and sc.def.value then u = (t - sc.since) % 2 / 2 end   -- Test: sweep the fill
        patterns.eval(sc.cl, buf, n, t - sc.since, u, sc.thr[gi], ST.rpm, sc.frames[gi])
        local used = false
        for k = 1, n do
          local id = ids[k]
          if fb[id] == UNSET and buf[k] ~= UNSET then
            fb[id] = buf[k]
            left = left - 1
            used = true
          end
        end
        if used and not grp.activeName then grp.activeName, grp.activeId = sc.name, sc.id end
        if left <= 0 then break end
      end
    end
    if left > 0 then
      local base = C.base
      for k = 1, n do
        if fb[ids[k]] == UNSET then fb[ids[k]] = base end
      end
    end
  end
end

return M
