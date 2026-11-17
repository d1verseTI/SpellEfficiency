-- Glow.lua: glows the action button of the spell you should press now.
--   gold  = highest damage (mana above /se switch, default 40%)
--   blue  = mana-efficient pick (mana below the switch point)
--   green = finisher at 5 combo points (rogue / cat), when the cycle wins
-- The gold/blue and builder/finisher switch is done by the game itself from
-- hidden values (see PowerAlpha) because Forever hides current mana/CP.
-- Only while you have an attackable target. Works with the default action
-- bars, Bartender4, Dominos and ElvUI.

local _, SE = ...
local Safe = SE.Safe
local Glow = LibStub("LibCustomGlow-1.0-foreverauras")

local COLORS = {
  best      = { 1, 0.82, 0, 1 },
  efficient = { 0.3, 0.75, 1, 1 },
  finisher  = { 0.3, 1, 0.3, 1 },
}

local BAR_PATTERNS = {
  { "ActionButton%d", 12 },
  { "MultiBarBottomLeftButton%d", 12 }, { "MultiBarBottomRightButton%d", 12 },
  { "MultiBarRightButton%d", 12 }, { "MultiBarLeftButton%d", 12 },
  { "MultiBar5Button%d", 12 }, { "MultiBar6Button%d", 12 }, { "MultiBar7Button%d", 12 },
  { "BT4Button%d", 180 }, { "DominosActionButton%d", 180 },
}

local buttons = {}
local function CollectButtons()
  wipe(buttons)
  for _, p in ipairs(BAR_PATTERNS) do
    for i = 1, p[2] do
      local b = _G[p[1]:format(i)]
      if b then buttons[#buttons + 1] = b end
    end
  end
  for bar = 1, 15 do
    for i = 1, 12 do
      local b = _G[("ElvUI_Bar%dButton%d"):format(bar, i)]
      if b then buttons[#buttons + 1] = b end
    end
  end
end

local function SlotOf(b)
  local slot = b.action
  if not slot and b._state_type == "action" then slot = b._state_action end
  if not slot and b.GetAttribute then
    local ok, a = pcall(b.GetAttribute, b, "action")
    if ok then slot = a end
  end
  return tonumber(Safe(slot))
end

-- slot -> spell name, cleared when your bars change.
local nameCache = {}
local function SpellNameInSlot(slot)
  local cached = nameCache[slot]
  if cached ~= nil then return cached or nil end
  local name = false
  local ok, kind, id = pcall(GetActionInfo, slot)
  kind, id = Safe(kind), Safe(id)
  if ok and kind == "spell" and id then
    name = SE.SpellInfo(id) or false
  elseif ok and kind == "macro" and id and GetMacroSpell then
    local okMacro, sid = pcall(GetMacroSpell, id)
    sid = okMacro and Safe(sid)
    name = sid and SE.SpellInfo(sid) or false
  end
  nameCache[slot] = name
  return name or nil
end

-- Forever hides your current mana and combo points from addons (even out of
-- combat), so the addon can't decide "gold or blue" itself. Instead both
-- glows run, each inside a holder frame whose alpha comes from a step curve
-- evaluated by the game on the hidden value (UnitPowerPercent + curve, the
-- same trick ForeverAuras uses). The game shows exactly one of them.
local curves = {}
local function StepCurve(at, below, above)
  local key = ("%.3f:%s:%s"):format(at, below, above)
  if curves[key] then return curves[key] end
  local c = C_CurveUtil.CreateCurve()
  c:SetType(Enum.LuaCurveType.Step)
  c:AddPoint(0, below)
  c:AddPoint(at, above)
  c:AddPoint(1, above)
  curves[key] = c
  return c
end

local canCurve = C_CurveUtil and C_CurveUtil.CreateCurve and UnitPowerPercent and Enum.LuaCurveType
-- Alpha for a glow shown only below / above a share of a power type.
local function PowerAlpha(powerType, at, showAbove)
  if not canCurve then return 1 end
  local ok, a = pcall(UnitPowerPercent, "player", powerType, false,
    StepCurve(at, showAbove and 0 or 1, showAbove and 1 or 0))
  -- Never test `a` (or, ==, ~=): it's a secret value and any test errors.
  if ok then return a end
  return 1
end

-- Keybind text of the first visible action button holding this spell.
function SE.KeybindForSpell(name)
  if not name then return nil end
  for _, b in ipairs(buttons) do
    local slot = b:IsVisible() and SlotOf(b)
    if slot and SpellNameInSlot(slot) == name then
      local hk = b.HotKey or b.hotKey or _G[(b:GetName() or "") .. "HotKey"]
      local text = hk and Safe(hk:GetText())
      -- Blizzard shows a dot for "no binding"
      if text and text ~= "" and text ~= RANGE_INDICATOR then return text end
    end
  end
end
SE.PowerAlpha = PowerAlpha

local holders = {}   -- button -> holder frame (the glow lives on the holder)
local glowing = {}   -- button -> color key
local function Holder(b)
  local h = holders[b]
  if not h then
    h = CreateFrame("Frame", nil, b)
    h:SetAllPoints(b)
    holders[b] = h
  end
  return h
end

local function SetGlow(b, key, alpha)
  if glowing[b] ~= key then
    local h = Holder(b)
    if glowing[b] then Glow.ButtonGlow_Stop(h) end
    glowing[b] = key
    if key then Glow.ButtonGlow_Start(h, COLORS[key], 0.25) end
  end
  if key then pcall(holders[b].SetAlpha, holders[b], alpha) end
end

local function StopAll()
  for b in pairs(glowing) do Glow.ButtonGlow_Stop(holders[b]) end
  wipe(glowing)
end

-- What to glow: list of { name, colorKey, alpha }.
local function Wanted()
  local db, st = SE.db, SE.state
  if not (db and db.glow and st and st.best and SE.HasEnemyTarget()) then return nil end
  local list = {}
  if st.power == "MANA" then
    if st.eff and st.eff ~= st.best then
      list[1] = { st.best.name, "best", PowerAlpha(0, db.switchAt, true) }
      list[2] = { st.eff.name, "efficient", PowerAlpha(0, db.switchAt, false) }
    else
      list[1] = { st.best.name, "best", 1 }
    end
  elseif st.power == "ENERGY" then
    local fin = st.cycleBetter and st.cycles[1] and st.cycles[1].finisher
    if fin then
      -- 5 of 5 combo points = 100%.
      list[1] = { st.bestB.name, "best", PowerAlpha(4, 0.99, false) }
      list[2] = { fin.name, "finisher", PowerAlpha(4, 0.99, true) }
    else
      list[1] = { st.bestB.name, "best", 1 }
    end
  end
  return list
end

local function Tick()
  local list = Wanted()
  if not list then
    if next(glowing) then StopAll() end
    return
  end
  for _, b in ipairs(buttons) do
    local slot = b:IsVisible() and SlotOf(b)
    local name = slot and SpellNameInSlot(slot)
    local key, alpha
    if name then
      for _, w in ipairs(list) do
        if w[1] == name then key, alpha = w[2], w[3] end
      end
    end
    SetGlow(b, key, alpha)
  end
end

local events = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_PAGE_CHANGED",
  "UPDATE_BONUS_ACTIONBAR", "UPDATE_SHAPESHIFT_FORM", "SPELLS_CHANGED", "UPDATE_MACROS" }) do
  events:RegisterEvent(e)
end
events:SetScript("OnEvent", function(_, event)
  wipe(nameCache)
  if event == "PLAYER_ENTERING_WORLD" then
    CollectButtons()
    C_Timer.After(3, CollectButtons)   -- bar addons may create buttons late
  end
end)

C_Timer.NewTicker(0.2, function()
  local ok = pcall(Tick)
  if not ok then StopAll() end
end)
