-- Simulator entry: runs every scenario of a set on every car at both controller rates with the KeyDrive core,
-- compares with the oracle, writes sim/out/report.json and sim/out/summary.txt.
-- Usage (via run.py, or plain LuaJIT from the repo root):  luajit sim/main.lua <repoRoot> [set] [rates] [scale]
--   set: tuning (default) | hidden;  rates: physics,fps;  scale: grip,power multipliers e.g. 0.8,1.2

local ROOT, SET, RATES, SCALE, PARAMS_FILE = ...
ROOT = ROOT or '.'
SET = SET or 'tuning'
RATES = RATES or 'physics,fps'
package.path = ROOT .. '/sim/?.lua;' .. ROOT .. '/extension/lua/joypad-assist/KeyDrive/?.lua;' .. package.path

local runner = require('runner')
local metrics = require('metrics')
local controllers = require('controllers')
local json = require('json')

local CARS = { 'rwd_supra', 'fwd_hothatch', 'awd_gt' }

local scale = { grip = 1, power = 1 }
if SCALE and SCALE ~= '' then
  local g, p = SCALE:match('([%d%.]+),([%d%.]+)')
  scale.grip, scale.power = tonumber(g) or 1, tonumber(p) or 1
end
local params, tractionParams
if PARAMS_FILE and PARAMS_FILE ~= '' then
  local p = dofile(PARAMS_FILE)
  params, tractionParams = p.throttle, p.traction
end

local dir = SET == 'hidden' and '/sim/scenarios/hidden/' or '/sim/scenarios/'
local names = dofile(ROOT .. dir .. 'index.lua')
local rates = {}
for r in RATES:gmatch('[^,]+') do rates[#rates + 1] = r end

local function hash(str)
  local h = 5381
  for i = 1, #str do h = (h * 33 + str:byte(i)) % 2147483647 end
  return h
end

local report = { set = SET, scale = scale, thresholds = metrics.THRESHOLDS, runs = {}, selfTest = {} }
local lines = {}
local total, passed = 0, 0
local failsByCheck = {}
local rise, fall = params and params.RISE or 1.2, params and params.FALL or 4

local function fmt(v, f) return v and string.format(f, v) or '-' end

for _, name in ipairs(names) do
  local scn = dofile(ROOT .. dir .. name .. '.lua')
  for _, carName in ipairs(CARS) do
    local car = dofile(ROOT .. '/sim/cars/' .. carName .. '.lua')
    local common = { car = car, grip = scale.grip, power = scale.power, seed = hash(name .. carName) }
    local function with(extra)
      local o = {}
      for k, v in pairs(common) do o[k] = v end
      for k, v in pairs(extra) do o[k] = v end
      return o
    end
    local oracleTr = runner.run(scn, with({ oracle = true, oracleRise = rise, oracleFall = fall }))
    local zeroTr = runner.run(scn, with({ zero = true }))
    local ref = { oracle = oracleTr, zero = zeroTr, rise = rise, fall = fall }
    -- self-test: a plain ramp without traction control must never beat the oracle
    if scn.group ~= 'reverse' then
      local plain = runner.run(scn, with({ rate = 'physics', controller = controllers.plainRamp(rise, fall) }))
      local pr = metrics.evaluate(scn, plain, ref)
      if pr.values.loss and pr.values.loss < -0.01 then
        report.selfTest[#report.selfTest + 1] = string.format('%s %s: plain ramp beats the oracle by %.1f %%',
          name, carName, -pr.values.loss * 100)
      end
    end
    for _, rate in ipairs(rates) do
      local tr = runner.run(scn, with({ rate = rate, seed = hash(name .. carName .. rate),
        controller = controllers.keydrive(params, tractionParams) }))
      local res = metrics.evaluate(scn, tr, ref)
      total = total + 1
      if res.pass then passed = passed + 1 end
      local failed = {}
      for k, ok in pairs(res.checks) do
        if not ok then
          failed[#failed + 1] = k
          failsByCheck[k] = (failsByCheck[k] or 0) + 1
        end
      end
      table.sort(failed)
      report.runs[#report.runs + 1] = { scenario = name, car = carName, rate = rate, fps = tr.fps, pass = res.pass,
        checks = res.checks, values = res.values, notGraded = res.na, group = scn.group }
      local v = res.values
      lines[#lines + 1] = string.format('%-21s %-12s %-7s %-4s slip %5s >1.3 %5s slide %5s loss %6s rate %4s ' ..
        'jerk %5s dir/s %4s std %5s %s%s',
        name, carName, rate, res.pass and 'OK' or 'FAIL', fmt(v.peakSlip, '%.2f'), fmt(v.over13Time, '%.2f'),
        fmt(v.slideTime, '%.2f'), fmt(v.loss and v.loss * 100, '%.1f%%'), fmt(v.maxRate, '%.1f'),
        fmt(v.maxJerk, '%.0f'), fmt(v.steadyDirChanges, '%.1f'), fmt(v.steadyStd, '%.3f'),
        #failed > 0 and ('[' .. table.concat(failed, ',') .. ']') or '',
        #res.na > 0 and (' n/a:' .. table.concat(res.na, ',')) or '')
    end
  end
end

report.summary = { total = total, passed = passed, failsByCheck = failsByCheck }
local outDir = ROOT .. '/sim/out'
local suffix = SET == 'tuning' and '' or ('-' .. SET)
if scale.grip ~= 1 or scale.power ~= 1 then suffix = suffix .. string.format('-g%.2f-p%.2f', scale.grip, scale.power) end
local f = assert(io.open(outDir .. '/report' .. suffix .. '.json', 'w'))
f:write(json.encode(report))
f:close()
local head = {
  string.format('KeyDrive simulator: set %s, grip x%.2f, power x%.2f: %d/%d runs pass', SET, scale.grip, scale.power,
    passed, total),
  string.format('Thresholds (user): peak slip <= %.1fx tyre peak, above 1.3x <= %.2f s, steady <= %d dir. changes/s ' ..
    'and std < %.2f, loss vs oracle <= %d %% dry. Proposed: loss <= %d %% wet/cold/grip/tapping, axle slide <= %.2f s, ' ..
    'assist rate <= %.0f /s, reverse = plain ramp', metrics.THRESHOLDS.peakSlip, metrics.THRESHOLDS.over13Time,
    metrics.THRESHOLDS.steadyDirChanges, metrics.THRESHOLDS.steadyStd, metrics.THRESHOLDS.lossDry * 100,
    metrics.THRESHOLDS.lossOther * 100, metrics.THRESHOLDS.slideTime, metrics.THRESHOLDS.maxRate),
}
local fk = {}
for k, n in pairs(failsByCheck) do fk[#fk + 1] = k .. ' ' .. n end
table.sort(fk)
head[#head + 1] = 'Failures by check: ' .. (#fk > 0 and table.concat(fk, ', ') or 'none')
head[#head + 1] = 'Self-test (plain ramp vs oracle): ' .. (#report.selfTest > 0 and table.concat(report.selfTest, '; ')
  or 'ok')
head[#head + 1] = ''
local text = table.concat(head, '\n') .. '\n' .. table.concat(lines, '\n') .. '\n'
local f2 = assert(io.open(outDir .. '/summary' .. suffix .. '.txt', 'w'))
f2:write(text)
f2:close()
print(text)
return passed, total
