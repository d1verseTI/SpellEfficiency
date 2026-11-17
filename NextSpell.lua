-- NextSpell.lua: a "next spell" icon.
--
-- 1. If Blizzard's Assisted Combat suggests something
--    (C_AssistedCombat.GetNextCastSpell), that is shown.
-- 2. Otherwise SpellEfficiency's theoretical rotation (see /se):
--      energy: keep-ups that ran out (Slice and Dice / Rupture / Rip at their
--              best CP count, Rake) > the cycle's finisher at its CP count
--              > best builder
--      mana:   DoTs that ran out > cooldown spells when ready > mana saver
--              (low mana) > best filler
--
-- Forever hides cooldowns, mana and combo points from addons in combat, so
-- the addon can't pick the spell itself. Instead the icons are STACKED in the
-- same spot, highest priority on top, and each layer's alpha is evaluated by
-- the game from the hidden value (cooldown duration object / power curve):
-- a layer is opaque only while its spell is ready. What you see is the top
-- ready layer = the highest-priority spell you can cast. No hidden value is
-- ever read by the addon; the game draws the answer.
--
-- Buffs/DoTs: auras are hidden too, so "still up?" uses timers started by
-- your own casts (see Own-cast timers). Not handled: range, procs, and buffs
-- or DoTs that someone else removes early (dispels).

local _, SE = ...
local Safe, Secret = SE.Safe, SE.Secret

local SIZE = 52

local frame = CreateFrame("Frame", "SpellEfficiencyNextFrame", UIParent)
frame:SetSize(SIZE, SIZE)
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")
frame:Hide()

frame:SetScript("OnDragStart", function(self) if not SE.db.nextLocked then self:StartMoving() end end)
frame:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local point, _, _, x, y = self:GetPoint()
  SE.db.nextPoint, SE.db.nextX, SE.db.nextY = point, x, y
end)

function SE.ApplyNextLayout()
  local db = SE.db
  frame:ClearAllPoints()
  frame:SetPoint(db.nextPoint, UIParent, db.nextPoint, db.nextX, db.nextY)
  frame:SetScale(db.nextScale or 1)
  frame:EnableMouse(not db.nextLocked)
end
table.insert(SE.onLoad, SE.ApplyNextLayout)

-- One layer = icon + keybind + label (with an opaque label background, so a
-- layer on top fully covers the ones below it).
local layers = {}
local function Layer(i)
  local l = layers[i]
  if l then return l end
  l = CreateFrame("Frame", nil, frame)
  l:SetAllPoints()
  local border = l:CreateTexture(nil, "BACKGROUND")
  border:SetPoint("TOPLEFT", -1, 1); border:SetPoint("BOTTOMRIGHT", 1, -1)
  l.border = border
  l.icon = l:CreateTexture(nil, "ARTWORK")
  l.icon:SetAllPoints()
  l.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  l.key = l:CreateFontString(nil, "OVERLAY")
  l.key:SetFont(STANDARD_TEXT_FONT, 13, "OUTLINE")
  l.key:SetPoint("TOPRIGHT", -2, -3)
  l.labelBg = l:CreateTexture(nil, "BACKGROUND")
  l.labelBg:SetColorTexture(0.05, 0.05, 0.05, 1)
  l.labelBg:SetPoint("TOP", l, "BOTTOM", 0, -1)
  l.labelBg:SetSize(140, 16)
  l.label = l:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  l.label:SetPoint("CENTER", l.labelBg)
  layers[i] = l
  return l
end

local BORDER = {
  best      = { 1, 0.82, 0 },
  efficient = { 0.3, 0.75, 1 },
  cooldown  = { 0.3, 1, 0.3 },
  keepup    = { 0.3, 1, 0.3 },
  finisher  = { 0.3, 1, 0.3 },
  blizzard  = { 0.8, 0.8, 0.8 },
  idle      = { 0, 0, 0 },
}
local TAG = {
  best = "|cffffd100best damage|r", efficient = "|cff66ccffmana saver|r",
  cooldown = "|cff99ff99ready - use it|r", finisher = "|cff99ff99finisher|r",
  keepup = "|cff99ff99keep up|r",
  blizzard = "|cffccccccBlizzard's pick|r",
}

-- Keybinds, refreshed once a second.
local keyCache, keyCacheAt = {}, 0
local function Keybind(name)
  local now = GetTime()
  if now - keyCacheAt > 1 then wipe(keyCache); keyCacheAt = now end
  if keyCache[name] == nil then keyCache[name] = SE.KeybindForSpell(name) or false end
  return keyCache[name] or ""
end

-- Hidden "is it ready" -> alpha 1 / 0, evaluated by the game.
local function ReadyAlpha(spellID)
  if not (C_Spell and C_Spell.GetSpellCooldownDuration and C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean) then
    return 0   -- can't tell: never suggest cooldown spells
  end
  local ok, a = pcall(function()
    local dur = C_Spell.GetSpellCooldownDuration(spellID, true)   -- true: ignore the GCD
    return C_CurveUtil.EvaluateColorValueFromBoolean(dur:IsZero(), 1, 0)
  end)
  if ok then return a end
  return 0
end

-- Own-cast timers: Forever hides buffs/debuffs in combat, so "is Slice and
-- Dice / Rupture / Corruption still up?" comes from YOUR casts: casting it
-- starts a timer for the duration the rotation uses (for finishers: the
-- combo point count it recommends). Target-side timers reset when you change
-- target; Slice and Dice (on you) doesn't.
local timers = {}   -- spell name -> { expires, onSelf }
local REFRESH_EARLY = 1.0   -- suggest a refresh this many seconds before it runs out

-- Real aura data, when the game allows it for this spell: Forever's limits
-- are per spell (C_Secrets.ShouldSpellAuraBeSecret), so some buffs/debuffs
-- may stay readable. Returns seconds left (0 = not up), or nil if hidden.
local auraSource = {}   -- spell name -> "aura" / "timer" (shown in the label)
local function AuraRemaining(row, onSelf)
  if not (C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName) then return nil end
  if C_Secrets and C_Secrets.ShouldSpellAuraBeSecret then
    local ok, secret = pcall(C_Secrets.ShouldSpellAuraBeSecret, row.id)
    -- Check Secret() first: comparing a secret value would error.
    if not ok or Secret(secret) or secret ~= false then return nil end
  end
  local unit, filter = "target", "HARMFUL|PLAYER"
  if onSelf then unit, filter = "player", "HELPFUL" end
  local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellName, unit, row.name, filter)
  if not ok or Secret(aura) then return nil end
  if aura == nil then return 0 end
  local expires = Safe(aura.expirationTime)
  if expires == nil then return nil end
  if expires == 0 then return math.huge end   -- no duration
  return expires - GetTime()
end

local function Expired(row, onSelf)
  local left = AuraRemaining(row, onSelf)
  if left then
    auraSource[row.name] = "aura"
    return left < REFRESH_EARLY
  end
  auraSource[row.name] = "timer"
  local t = timers[row.name]
  return not t or t.expires - GetTime() < REFRESH_EARLY
end
SE.AuraSource = auraSource

local function StepFor(name)
  local st = SE.state
  local rot = st and st.rotation
  local steps = rot and (rot.steps or (rot.main and rot.main.steps))
  for _, step in ipairs(steps or {}) do
    if step.row and step.row.name == name and step.dur then return step end
  end
end

local timerEvents = CreateFrame("Frame")
timerEvents:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
timerEvents:RegisterEvent("PLAYER_TARGET_CHANGED")
timerEvents:RegisterEvent("PLAYER_DEAD")
timerEvents:SetScript("OnEvent", function(_, event, _, _, spellID)
  if event == "UNIT_SPELLCAST_SUCCEEDED" then
    spellID = Safe(spellID)
    local name = spellID and SE.SpellInfo(spellID)
    local step = name and StepFor(name)
    if step then timers[name] = { expires = GetTime() + step.dur, onSelf = step.onSelf } end
  elseif event == "PLAYER_TARGET_CHANGED" then
    for name, t in pairs(timers) do if not t.onSelf then timers[name] = nil end end
  else
    wipe(timers)
  end
end)

-- Alpha that shows a layer only at >= cp combo points (evaluated by the game).
local function CPAlpha(cp)
  local max = Safe(UnitPowerMax("player", 4))
  if not max or max <= 0 then max = 5 end
  return SE.PowerAlpha(4, (cp - 0.5) / max, true)
end

-- Priority list from the theoretical rotation, top first: { row, kind, alpha }.
--   energy: keep-ups that ran out (at their CP count) > the cycle's finisher
--           (at its CP count) > best builder
--   mana:   DoTs that ran out > cooldown spells when ready > mana saver (low
--           mana) > best filler
local function Priorities(st, db)
  local list = {}
  local rot = st.rotation
  if st.power == "ENERGY" and st.bestB then
    if rot then
      for _, step in ipairs(rot.steps) do
        if step.row and Expired(step.row, step.onSelf) then
          -- (no `x and secret or 1`: an `or` would test the secret value and error)
          local alpha = 1
          if step.cp then alpha = CPAlpha(step.cp) end
          list[#list + 1] = { step.row, "keepup", alpha, step.cp }
        end
      end
      local P = rot.filler
      if P and P.row and P.cp then list[#list + 1] = { P.row, "finisher", CPAlpha(P.cp), P.cp } end
    end
    list[#list + 1] = { st.bestB, "best", 1 }
  elseif st.power == "MANA" and st.best then
    local steps = rot and rot.main and rot.main.steps or {}
    for _, step in ipairs(steps) do
      if step.kind == "dot" and Expired(step.row, false) then list[#list + 1] = { step.row, "keepup", 1 } end
    end
    for _, step in ipairs(steps) do
      if step.kind == "cooldown" then list[#list + 1] = { step.row, "cooldown", ReadyAlpha(step.row.id) } end
    end
    if st.eff and st.eff ~= st.best then
      list[#list + 1] = { st.eff, "efficient", SE.PowerAlpha(0, db.switchAt, false) }
    end
    list[#list + 1] = { st.best, "best", 1 }
  end
  return list
end

local function Paint(l, level, texture, name, kind, alpha, cp)
  l:SetFrameLevel(level)
  l.icon:SetTexture(texture or 134400)
  l.icon:SetDesaturated(kind == "idle")
  local c = BORDER[kind] or BORDER.idle
  l.border:SetColorTexture(c[1], c[2], c[3], 1)
  l.key:SetText(name and Keybind(name) or "")
  -- Just the name; finishers also show how many combo points to use.
  l.label:SetText(cp and ("%s · %d CP"):format(name or "", cp) or (name or ""))
  l:Show()
  pcall(l.SetAlpha, l, alpha)
end

local function HideFrom(i)
  for j = i, #layers do layers[j]:Hide() end
end

local function BlizzardPick()
  if not (C_AssistedCombat and C_AssistedCombat.GetNextCastSpell) then return nil end
  local ok, id = pcall(C_AssistedCombat.GetNextCastSpell)
  id = ok and Safe(id)
  if id and id ~= 0 then return id end
end

local function Update()
  local db, st = SE.db, SE.state
  if not db then return end
  local active = db.next and st and (InCombatLockdown() or SE.HasEnemyTarget())

  if not active then
    if db.next and not db.nextLocked then
      Paint(Layer(1), frame:GetFrameLevel() + 1, 134400, "Next spell - drag me (/se lock)", "idle", 1)
      HideFrom(2)
      frame:Show()
    else
      frame:Hide()
    end
    return
  end

  local base = frame:GetFrameLevel() + 1
  local blizz = BlizzardPick()
  if blizz then
    local name, tex = SE.SpellInfo(blizz)
    Paint(Layer(1), base, tex, name, "blizzard", 1)
    HideFrom(2)
    frame:Show()
    return
  end

  local list = Priorities(st, db)
  if #list == 0 then frame:Hide(); return end
  -- Top of the list gets the highest frame level.
  for i, p in ipairs(list) do
    local row, kind, alpha, cp = p[1], p[2], p[3], p[4]
    Paint(Layer(i), base + (#list - i) * 3, row.icon, row.name, kind, alpha, cp)
  end
  HideFrom(#list + 1)
  frame:Show()
end

C_Timer.NewTicker(0.1, function()
  local ok, err = pcall(Update)
  if not ok and SE.db then SE.db.lastError = tostring(err) end
end)
