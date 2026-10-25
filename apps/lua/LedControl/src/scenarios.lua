-- Catalogue of the built-in LED scenarios. Order = default priority (1 = highest). Each entry:
--   id, name (Czech), cat (section in the Scénáře tab), to (target: 'all' | 'main' | 'side' | 'other'),
--   look (default look, see patterns.lua), hold (s the scenario stays active after its test stops holding),
--   param = { name, unit, default, min, max } (one number the user can change, passed to test / value),
--   test(ST, p) -> bool, value(ST, p) -> 0..1 (fill level, only for fill looks), avail(ST, layout) -> ok, note.
-- Test functions run every frame: no allocation inside.

local color = require('src/color')

local M = {}

local ORANGE, BLUE, GREEN, RED, YELLOW, WHITE, PURPLE, CYAN =
  '#FF8000', '#0050FF', '#00FF40', '#FF0000', '#FFD000', '#FFFFFF', '#A000FF', '#00C8FF'

local function always() return true end

local function hasSide(layout)
  if not layout then return false end
  for i = 1, #layout.groups do if layout.groups[i].role == 'side' then return true end end
  return false
end

local function sideNote(ST, layout)
  if not hasSide(layout) then return true, 'auto nemá boční diody, svítí hlavní řada' end
  return true
end

-- flags (sim.raceFlagType, ac.FlagType values from the SDK enum: the comment there says which ones AC reports)
local function flag(id, name, value, look, works)
  return {
    id = id, name = name, cat = 'Vlajky', to = 'side', look = look, flagValue = value,
    test = function (ST) return ST.flag == value end,
    avail = function (ST, layout)
      if not works then return false, 'AC tuto vlajku zatím nehlásí (podle SDK „does not work yet“)' end
      return sideNote(ST, layout)
    end,
  }
end

local function shiftStart(ST, p)
  return ST.shiftUp * p / 100
end

M.list = {
  { id = 'pitLimiter', name = 'Pit limiter zapnutý', cat = 'Box', to = 'all',
    look = { p = 'alternate', c = { ORANGE, '#000000' }, hz = 3 },
    test = function (ST) return ST.pitLimiter end, avail = always },
  { id = 'pitLane', name = 'V pit lane bez limiteru', cat = 'Box', to = 'all',
    look = { p = 'blink', c = { RED, '#000000' }, hz = 4 },
    test = function (ST) return ST.inPitlane and not ST.pitLimiter end, avail = always },

  flag('flagBlue', 'Modrá vlajka (pouští rychlejší auto)', 12, { p = 'blink', c = { BLUE, '#000000' }, hz = 2 }, true),
  flag('flagYellow', 'Žlutá vlajka', 2, { p = 'blink', c = { YELLOW, '#000000' }, hz = 2 }, true),
  flag('flagBlack', 'Černá vlajka', 5, { p = 'alternate', c = { WHITE, '#000000' }, hz = 1 }, true),
  flag('flagPenalty', 'Penalizace (zajet do boxů)', 8, { p = 'alternate', c = { RED, WHITE }, hz = 2 }, true),
  flag('flagWhite', 'Bílá vlajka (poslední kolo)', 14, { p = 'solid', c = { WHITE } }, true),
  flag('flagChequered', 'Šachovnice (cíl)', 13, { p = 'alternate', c = { WHITE, '#000000' }, hz = 3 }, true),
  flag('flagRed', 'Červená vlajka (přerušení)', 15, { p = 'blink', c = { RED, '#000000' }, hz = 2 }, false),

  { id = 'limiter', name = 'Omezovač otáček', cat = 'Řazení', to = 'main', hold = 0.15,
    look = { p = 'blink', c = { BLUE, '#000000' }, hz = 8 },
    test = function (ST) return ST.engineLimiter or (ST.limiterKnown and ST.rpm >= ST.rpmLimiter * 0.995) end,
    avail = always },
  { id = 'shiftPoint', name = 'Ideální bod řazení', cat = 'Řazení', to = 'main',
    look = { p = 'solid', c = { PURPLE } },
    test = function (ST) return ST.gear > 0 and ST.rpm >= ST.shiftUp end,
    avail = function (ST)
      if ST.shiftKnown then return true, string.format('ai.ini: %d ot/min', ST.shiftUp) end
      return true, 'ai.ini nemá bod řazení, beru 97 % omezovače'
    end },
  { id = 'shiftLights', name = 'Řadicí světla podle otáček', cat = 'Řazení', to = 'main',
    param = { name = 'Začátek', unit = '% bodu řazení', default = 75, min = 30, max = 99 },
    look = { p = 'fill', dir = 'left', src = 'relative', c = { WHITE, '#000000' },
      zones = { 0, GREEN, 0.4, RED, 0.75, BLUE } },
    test = function (ST, p) return ST.rpm >= shiftStart(ST, p) end,
    value = function (ST, p)
      local a = shiftStart(ST, p)
      local span = ST.shiftUp - a
      if span <= 1 then return 1 end
      return (ST.rpm - a) / span
    end,
    avail = always },

  { id = 'drsActive', name = 'DRS otevřené', cat = 'DRS', to = 'side',
    look = { p = 'solid', c = { GREEN } },
    test = function (ST) return ST.drsActive end,
    avail = function (ST, layout)
      if not ST.drsPresent then return false, 'auto nemá DRS' end
      return sideNote(ST, layout)
    end },
  { id = 'drsAvailable', name = 'DRS k dispozici', cat = 'DRS', to = 'side',
    look = { p = 'blink', c = { GREEN, '#000000' }, hz = 3 },
    test = function (ST) return ST.drsAvailable and not ST.drsActive end,
    avail = function (ST, layout)
      if not ST.drsPresent then return false, 'auto nemá DRS' end
      return sideNote(ST, layout)
    end },

  { id = 'abs', name = 'Zásah ABS', cat = 'Asistenty', to = 'side', hold = 0.3,
    look = { p = 'blink', c = { YELLOW, '#000000' }, hz = 8 },
    test = function (ST) return ST.absInAction end,
    avail = function (ST, layout)
      if not ST.hasAbs then return false, 'auto nemá ABS' end
      return sideNote(ST, layout)
    end },
  { id = 'tc', name = 'Zásah TC', cat = 'Asistenty', to = 'side', hold = 0.3,
    look = { p = 'blink', c = { CYAN, '#000000' }, hz = 8 },
    test = function (ST) return ST.tcInAction end,
    avail = function (ST, layout)
      if not ST.hasTc then return false, 'auto nemá TC' end
      return sideNote(ST, layout)
    end },

  { id = 'lowFuel', name = 'Málo paliva', cat = 'Varování', to = 'side',
    param = { name = 'Pod', unit = 'l (0 = podle auta, jinak 5 l)', default = 0, min = 0, max = 50 },
    look = { p = 'pulse', c = { ORANGE, '#000000' }, hz = 1 },
    test = function (ST, p)
      local limit = p > 0 and p or (ST.fuelWarn > 0 and ST.fuelWarn or 5)
      return ST.fuel > 0 and ST.fuel < limit
    end,
    avail = sideNote },
  { id = 'damage', name = 'Poškození', cat = 'Varování', to = 'side',
    param = { name = 'Karoserie nad', unit = '(surová hodnota AC)', default = 30, min = 1, max = 500 },
    look = { p = 'blink', c = { RED, '#000000' }, hz = 1 },
    test = function (ST, p) return ST.engineLife < 500 or ST.damage > p end,
    avail = sideNote },

  { id = 'startCountdown', name = 'Odpočet startu', cat = 'Start', to = 'main',
    look = { p = 'fill', dir = 'edges', c = { RED, '#000000' }, zones = { 0, RED } },
    test = function (ST) return ST.timeToStart > 0 and ST.timeToStart < 7000 end,
    value = function (ST) return ST.timeToStart / 7000 end,
    avail = always },
  { id = 'startGo', name = 'Start! (zelená)', cat = 'Start', to = 'all',
    look = { p = 'blink', c = { GREEN, '#000000' }, hz = 6 },
    test = function (ST) return ST.timeToStart <= 0 and ST.timeToStart > -1500 end,
    avail = always },
  { id = 'idle', name = 'Stání nebo vypnutý motor', cat = 'Klid', to = 'all',
    param = { name = 'Po', unit = 's stání', default = 3, min = 0, max = 60 },
    look = { p = 'run', dir = 'bounce', c = { '#003C50', '#000000' }, hz = 0.5, width = 2 },
    test = function (ST, p) return ST.engineOff or ST.standingFor >= p end,
    avail = always },
}

-- Custom scenario template (Vlastní podmínka).
M.CUSTOM_LOOK = { p = 'blink', c = { WHITE, '#000000' }, hz = 2 }

M.byId = {}
for i = 1, #M.list do
  local d = M.list[i]
  d.order = i
  d.hold = d.hold or 0
  M.byId[d.id] = d
end

M.TARGETS = { 'all', 'main', 'side', 'other' }
M.TARGET_NAMES = { all = 'všechny diody', main = 'hlavní řada', side = 'boční diody', other = 'další řady' }

function M.isCustom(id)
  return type(id) == 'string' and id:sub(1, 7) == 'custom:'
end

-- Packed colour helper for the UI
M.color = color

return M
