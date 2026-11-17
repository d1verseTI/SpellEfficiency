-- SpellEfficiency: a theoretical comparison of the damage your known spells /
-- abilities can do, with your current spell power, crit, weapon and haste.
--
-- Mana users:   average damage per cast (incl. spell power + crit), damage per
--               second of casting (DPS), damage per mana. Picks the highest
--               DPS filler and the most mana-efficient one that is still
--               comparable (>= 85% of the best DPS by default).
-- Energy users: damage per energy, DPS when spamming (energy regen + 1 s GCD),
--               and builder x5 + finisher cycles (rogue / cat druid).
--
-- Numbers come from the spell tooltips (base damage) plus classic rules for
-- spell power coefficients. It ignores talents that the tooltip doesn't show,
-- hit chance, resistances and armor, so treat it as a guide, not a simulator.
--
-- Everyday use (other files, all reading SE.state from this one):
--   Glow.lua      glows the action button of the spell to press now
--   NextSpell.lua next-spell icon: Blizzard's suggestion, else our priority rotation
--   Tooltip.lua   adds "#1 damage - 13.7 DPS - 0.76 dmg/mana" to spell tooltips
--   (here)        chat message when the winning spell changes; /se table

local ADDON, SE = ...
SE.onLoad = {}   -- functions run once SavedVariables are loaded

local DEFAULTS = {
  point = "CENTER", x = 0, y = 0, ranks = false, comparable = 0.85,
  glow = true, switchAt = 0.4,   -- glow the efficient spell below 40% mana
  tips = true, announce = true,
  next = true, nextLocked = false, nextPoint = "CENTER", nextX = 0, nextY = -160, nextScale = 1,
}

local GCD_CASTER = 1.5
local GCD_ENERGY = 1.0
local SPELL_CRIT_MULT = 1.5   -- spell crits do 150%
local MELEE_CRIT_MULT = 2.0   -- melee crits do 200%

local SCHOOLS = { Holy = 2, Fire = 3, Nature = 4, Frost = 5, Shadow = 6, Arcane = 7 }

local db

local function Secret(v) return issecretvalue and issecretvalue(v) end
local function Safe(v) if Secret(v) then return nil end return v end
local function SafeCall(fn, ...)
  if not fn then return nil end
  local ok, a, b, c, d = pcall(fn, ...)
  if not ok then return nil end
  return Safe(a), Safe(b), Safe(c), Safe(d)
end
SE.Secret, SE.Safe, SE.SafeCall = Secret, Safe, SafeCall

---------------------------------------------------------------------------
-- API compatibility (Forever has a mix of classic and modern APIs)
---------------------------------------------------------------------------

local function SpellInfo(id)
  if C_Spell and C_Spell.GetSpellInfo then
    local ok, info = pcall(C_Spell.GetSpellInfo, id)
    if ok and info then return Safe(info.name), Safe(info.iconID), Safe(info.castTime) end
  elseif GetSpellInfo then
    local name, _, icon, cast = SafeCall(GetSpellInfo, id)
    return name, icon, cast
  end
end

SE.SpellInfo = SpellInfo

local function SpellRank(id)
  return SafeCall((C_Spell and C_Spell.GetSpellSubtext) or GetSpellSubtext, id) or ""
end

local function SpellDescription(id)
  return SafeCall((C_Spell and C_Spell.GetSpellDescription) or GetSpellDescription, id) or ""
end

local function RequestSpellData(id)
  if C_Spell and C_Spell.RequestLoadSpellData then pcall(C_Spell.RequestLoadSpellData, id) end
end

-- Returns cost and power type name ("MANA", "ENERGY", "RAGE", ...)
local function SpellCost(id)
  local fn = (C_Spell and C_Spell.GetSpellPowerCost) or GetSpellPowerCost
  local costs = SafeCall(fn, id)
  if type(costs) ~= "table" then return 0, nil end
  for _, c in ipairs(costs) do
    local cost = Safe(c.cost)
    local name = Safe(c.name)
    local ptype = Safe(c.type)
    if cost and cost > 0 then
      if not name then name = ({ [0] = "MANA", [1] = "RAGE", [3] = "ENERGY" })[ptype] end
      return cost, name
    end
  end
  return 0, nil
end

local function SpellCooldown(id)
  local ms = SafeCall(GetSpellBaseCooldown, id)
  return ms and ms / 1000 or 0
end

local function LevelLearned(id)
  return SafeCall(GetSpellLevelLearned or (C_Spell and C_Spell.GetSpellLevelLearned), id)
end

-- All active (non-passive) spells in your spellbook.
local function SpellbookSpellIDs()
  local ids, seen = {}, {}
  local function add(id)
    if id and not Secret(id) and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
  end
  if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
    local bank = Enum.SpellBookSpellBank.Player
    for tab = 1, C_SpellBook.GetNumSpellBookSkillLines() do
      local line = C_SpellBook.GetSpellBookSkillLineInfo(tab)
      if line and not line.shouldHide then
        for i = line.itemIndexOffset + 1, line.itemIndexOffset + line.numSpellBookItems do
          local info = C_SpellBook.GetSpellBookItemInfo(i, bank)
          if info and info.itemType == Enum.SpellBookItemType.Spell and not info.isPassive and not info.isOffSpec then
            add(info.spellID)
          end
        end
      end
    end
  elseif GetNumSpellTabs then
    for tab = 1, GetNumSpellTabs() do
      local _, _, offset, num = GetSpellTabInfo(tab)
      for i = offset + 1, offset + num do
        local kind, id = GetSpellBookItemInfo(i, BOOKTYPE_SPELL)
        if kind == "SPELL" and not (IsPassiveSpell and IsPassiveSpell(i, BOOKTYPE_SPELL)) then add(id) end
      end
    end
  end
  return ids
end

-- Tooltip lines (for "Channeled" and the cast time line).
local scanner
local function TooltipLines(id)
  local lines = {}
  if C_TooltipInfo and C_TooltipInfo.GetSpellByID then
    local ok, data = pcall(C_TooltipInfo.GetSpellByID, id)
    if ok and data and data.lines then
      for _, l in ipairs(data.lines) do
        local a, b = Safe(l.leftText), Safe(l.rightText)
        if a then lines[#lines + 1] = a end
        if b then lines[#lines + 1] = b end
      end
    end
    return lines
  end
  if not scanner then
    scanner = CreateFrame("GameTooltip", "SpellEfficiencyScanTip", nil, "GameTooltipTemplate")
  end
  scanner:SetOwner(WorldFrame, "ANCHOR_NONE")
  scanner:ClearLines()
  pcall(scanner.SetSpellByID, scanner, id)
  for i = 1, scanner:NumLines() do
    for _, side in ipairs({ "Left", "Right" }) do
      local fs = _G["SpellEfficiencyScanTipText" .. side .. i]
      local t = fs and Safe(fs:GetText())
      if t then lines[#lines + 1] = t end
    end
  end
  scanner:Hide()
  return lines
end

local function HasLine(lines, pattern)
  for _, l in ipairs(lines) do if l:find(pattern) then return true end end
  return false
end

---------------------------------------------------------------------------
-- Parsing spell descriptions (enUS)
---------------------------------------------------------------------------

-- Caster spell: direct and/or over-time damage of a magic school.
-- Collapse runs of spaces/newlines: Forever's texts can have double spaces
-- ("18 to 20  Frost damage"), which would break the patterns below.
local function Normalize(desc)
  return (desc:gsub("%s+", " "))
end

local function ParseCaster(desc)
  desc = Normalize(desc)
  if desc:find("weapon") or desc:find("[Rr]anged") or desc:find("attack power") then return nil end
  -- Not castable damage: shields/wards ("absorbs 165 Frost damage"), damage
  -- to attackers (Thorns, Lightning Shield), totems/pets (Searing Totem).
  if desc:find("[Aa]bsorb") or desc:find("attacker") or desc:find("[Ss]ummons") or desc:find("struck") then return nil end
  local p = {}
  p.aoe = desc:find("enemies") ~= nil or desc:find(" area") ~= nil
  p.slows = desc:find("[Ss]low") ~= nil or desc:find("movement speed") ~= nil

  -- Per-second channels: "26 Arcane damage each second for 5 sec"
  local n, s, d = desc:match("(%d+) (%a+) damage each second for (%d+) sec")
  if not n then n, s, d = desc:match("(%d+) (%a+) damage every second for (%d+) sec") end
  if n and SCHOOLS[s] then
    p.dot, p.dur, p.school, p.perSecond = tonumber(n) * tonumber(d), tonumber(d), s, true
    return p
  end

  local text = desc
  local dn, ds, dd = text:match("(%d+) (%a+) damage over (%d+) sec")
  if dn and SCHOOLS[ds] then
    p.dot, p.dur, p.school = tonumber(dn), tonumber(dd), ds
    text = text:gsub("%d+ %a+ damage over %d+ sec", "", 1)
  end

  local lo, hi, s2 = text:match("(%d+) to (%d+) (%a+) damage")
  if lo and SCHOOLS[s2] then
    p.direct = (tonumber(lo) + tonumber(hi)) / 2
    p.school = p.school or s2
  else
    local one, s3 = text:match("(%d+) (%a+) damage")
    if one and SCHOOLS[s3] then
      p.direct = tonumber(one)
      p.school = p.school or s3
    end
  end

  if not (p.direct or p.dot) then return nil end
  return p
end

-- Melee ability (energy users).
local function ParseMelee(desc)
  desc = Normalize(desc)
  local p = {
    finisher = desc:find("Finishing move") ~= nil,
    stealth  = desc:find("[Ss]tealth") ~= nil or desc:find("[Pp]rowl") ~= nil,
    behind   = desc:find("behind") ~= nil,
    proc     = desc:find("parr") ~= nil or desc:find("dodge") ~= nil,
  }
  if p.finisher then
    -- Every combo point level from the tooltip table ("1 point : 6-10 damage",
    -- "3 points: 88 damage over 12 secs", "2 points: 12 seconds").
    p.levels, p.mult, p.bonus = {}, 0, 0
    if desc:find("attack speed") then
      -- Slice and Dice: "increases melee attack speed by 20%"
      local pct = desc:match("by (%d+)%%")
      if not pct then return nil end
      p.haste, p.buff = tonumber(pct), true
      for k, sec in desc:gmatch("(%d) points?%s*:%s*(%d+) sec") do
        p.levels[tonumber(k)] = { dur = tonumber(sec) }
      end
    else
      for k, a, b in desc:gmatch("(%d) points?%s*:%s*(%d+)%s*%-%s*(%d+)") do
        p.levels[tonumber(k)] = { bonus = (tonumber(a) + tonumber(b)) / 2 }
      end
      if not next(p.levels) then
        for k, d, dur in desc:gmatch("(%d) points?%s*:%s*(%d+) damage over (%d+)") do
          p.levels[tonumber(k)] = { dot = tonumber(d), dur = tonumber(dur) }
        end
      end
    end
    local top
    for k in pairs(p.levels) do if not top or k > top then top = k end end
    if not top then return nil end
    p.topCP = top
    local L = p.levels[top]
    p.bonus, p.dot, p.dur = L.bonus or 0, L.dot, L.dur
    return p
  end
  local m, b = desc:match("(%d+)%% weapon damage plus (%d+)")
  if not m then m, b = desc:match("(%d+)%% damage plus (%d+)") end
  if m then p.mult, p.bonus = tonumber(m) / 100, tonumber(b); return p end
  m = desc:match("(%d+)%% weapon damage")
  if m then p.mult, p.bonus = tonumber(m) / 100, 0; return p end
  b = desc:match("(%d+) damage in addition to your normal weapon damage") or desc:match("(%d+) additional damage")
  if b then p.mult, p.bonus = 1, tonumber(b); return p end
  local a, d, dur = desc:match("for (%d+) damage and an additional (%d+) damage over (%d+) sec")
  if a then p.mult, p.bonus, p.dot, p.dur = 0, tonumber(a), tonumber(d), tonumber(dur); return p end
  if desc:find("weapon damage") then p.mult, p.bonus = 1, 0; return p end
  return nil
end

---------------------------------------------------------------------------
-- Calculations
---------------------------------------------------------------------------

-- Classic spell power coefficients.
--   direct: cast time / 3.5 (instants count as 1.5 s), max 1
--   DoT:    duration / 15, max 1
--   both:   the two are split by their share (classic hybrid formula)
--   channel: duration / 3.5, max 1
--   AoE: about 1/3; spells with a slow: -5%
local function Coefficients(p, cast, channel)
  local cDirect, cDot = 0, 0
  if channel then
    cDot = math.min((p.dur or 0) / 3.5, 1)
  elseif p.direct and p.dot then
    local d = math.min(math.max(cast, GCD_CASTER), 3.5) / 3.5
    local o = math.min((p.dur or 0) / 15, 1)
    local dotShare = o / (o + d)
    cDirect, cDot = d * (1 - dotShare), o * dotShare
  elseif p.direct then
    cDirect = math.min(math.max(cast, GCD_CASTER), 3.5) / 3.5
  elseif p.dot then
    cDot = math.min((p.dur or 0) / 15, 1)
  end
  if p.aoe then cDirect, cDot = cDirect / 3, cDot / 3 end
  if p.slows then cDirect, cDot = cDirect * 0.95, cDot * 0.95 end
  return cDirect, cDot
end

-- Spell power penalty for low-level spells and lower ranks (classic rules).
local function RankPenalty(learned, nextLearned, playerLevel)
  local f = 1
  if learned and learned < 20 then f = f * (1 - (20 - learned) * 0.0375) end
  if nextLearned and playerLevel and playerLevel > 0 then
    f = f * math.min(1, (nextLearned - 1 + 5) / playerLevel)
  end
  return math.max(f, 0)
end

local function CasterRow(s, playerLevel)
  local p = s.caster
  local school = SCHOOLS[p.school]
  local sp = SafeCall(GetSpellBonusDamage, school) or 0
  local crit = (SafeCall(GetSpellCritChance, school) or 0) / 100
  local cast = (s.castMs or 0) / 1000
  local cDirect, cDot = Coefficients(p, cast, s.channel)
  local pen = RankPenalty(s.learned, s.nextLearned, playerLevel)
  cDirect, cDot = cDirect * pen, cDot * pen

  local direct = p.direct and (p.direct + cDirect * sp) * (1 + crit * (SPELL_CRIT_MULT - 1)) or 0
  local dot = p.dot and (p.dot + cDot * sp) or 0
  local dmg = direct + dot
  local time = s.channel and (p.dur or GCD_CASTER) or math.max(cast, GCD_CASTER)

  local notes = {}
  if s.channel then notes[#notes + 1] = "channel" end
  -- Instants (and casts under 1.5s) still lock you out for the global cooldown.
  if not s.channel and cast < GCD_CASTER then
    notes[#notes + 1] = cast == 0 and "instant (GCD 1.5s)" or "GCD 1.5s"
  end
  if p.dot and not p.direct and not s.channel then notes[#notes + 1] = "DoT" end
  if p.aoe then notes[#notes + 1] = "AoE" end
  if s.cooldown > time then notes[#notes + 1] = ("CD %ds"):format(s.cooldown) end
  if pen < 0.999 then notes[#notes + 1] = ("SP x%.2f"):format(pen) end

  return {
    id = s.id, name = s.name, rank = s.rank, icon = s.icon,
    dmg = dmg, time = time, dps = dmg / time,
    cost = s.cost, dpm = s.cost > 0 and dmg / s.cost or nil,
    mps = s.cost > 0 and s.cost / time or nil,   -- mana per second while spamming it
    school = p.school,
    isDot = p.dot and not p.direct and not s.channel,
    dur = p.dur,
    aoe = p.aoe, cooldown = s.cooldown,
    filler = not p.aoe and not (p.dot and not p.direct and not s.channel) and s.cooldown <= time,
    note = table.concat(notes, ", "),
  }
end

local function EnergyRegen()
  local base, casting = SafeCall(GetPowerRegen)
  local r = (casting and casting > 0 and casting) or (base and base > 0 and base) or 10
  return r
end

-- Auto-attack damage per second (main + off hand, incl. crit; ignores
-- misses, glancing blows and armor).
local function WhiteDPS()
  local mh, oh = SafeCall(UnitAttackSpeed, "player")
  local mhMin, mhMax, ohMin, ohMax = SafeCall(UnitDamage, "player")
  local crit = (SafeCall(GetCritChance) or 0) / 100
  local dps = 0
  if mh and mh > 0 and mhMin and mhMax then dps = dps + (mhMin + mhMax) / 2 / mh end
  if oh and oh > 0 and ohMin and ohMax then dps = dps + (ohMin + ohMax) / 2 / oh end
  return dps * (1 + crit * (MELEE_CRIT_MULT - 1))
end
SE.WhiteDPS = WhiteDPS

local function MeleeRow(s)
  local p = s.melee
  local lo, hi = SafeCall(UnitDamage, "player")
  local weapon = (lo and hi) and (lo + hi) / 2 or 0
  local crit = (SafeCall(GetCritChance) or 0) / 100
  local hit = (p.mult * weapon + p.bonus) * (1 + crit * (MELEE_CRIT_MULT - 1))
  local regen = EnergyRegen()
  local cost = s.cost
  local perSec = cost > 0 and math.min(regen / cost, 1 / GCD_ENERGY) or 1 / GCD_ENERGY
  local dmg = hit + (p.dot or 0)
  -- Slice and Dice: worth the extra auto-attack damage over its duration.
  if p.buff then dmg = WhiteDPS() * p.haste / 100 * p.dur end
  -- Finishers: damage and duration at every combo point level.
  local levels
  if p.levels then
    levels = {}
    local critMult = 1 + crit * (MELEE_CRIT_MULT - 1)
    local white = p.buff and WhiteDPS() or 0
    for k, L in pairs(p.levels) do
      local d
      if p.buff then d = white * p.haste / 100 * L.dur
      elseif L.dot then d = L.dot
      else d = (L.bonus or 0) * critMult end
      levels[k] = { dmg = d, dur = L.dur }
    end
  end
  -- A builder's DoT (Rake) can't stack: when spammed, only the part that
  -- fits between casts counts.
  local spamDmg = dmg
  if not p.finisher and p.dot and p.dur and p.dur > 0 then
    spamDmg = hit + p.dot * math.min(1, (1 / perSec) / p.dur)
  end

  local notes = {}
  if p.finisher then notes[#notes + 1] = ("finisher (%d CP)"):format(p.topCP or 5) end
  if p.buff then notes[#notes + 1] = ("+%d%% attack speed %ds"):format(p.haste, p.dur) end
  if p.dot then notes[#notes + 1] = ("DoT %ds"):format(p.dur or 0) end
  if p.stealth then notes[#notes + 1] = "stealth" end
  if p.behind then notes[#notes + 1] = "behind" end
  if p.proc then notes[#notes + 1] = "proc" end
  if s.cooldown > GCD_ENERGY then notes[#notes + 1] = ("CD %ds"):format(s.cooldown) end

  return {
    id = s.id, name = s.name, rank = s.rank, icon = s.icon,
    dmg = dmg, cost = cost, dpe = cost > 0 and spamDmg / cost or nil,
    spamDmg = spamDmg, dot = p.dot, dur = p.dur, isBuff = p.buff,
    levels = levels, topCP = p.topCP,
    dps = p.finisher and nil or spamDmg * perSec,
    eps = (not p.finisher and cost > 0) and cost * perSec or nil,   -- energy per second while spamming
    finisher = p.finisher,
    builder = not p.finisher and not p.stealth and not p.proc and s.cooldown <= GCD_ENERGY,
    note = table.concat(notes, ", "),
  }
end

-- Collects every damaging spell you know, grouped by name (ranks).
local pendingData = false
local skipped = {}   -- spells we looked at but couldn't compare (shown + saved)
local function CollectSpells(powerName)
  local byName = {}
  wipe(skipped)
  db.scan = {}       -- every spell scanned, saved for troubleshooting
  for _, id in ipairs(SpellbookSpellIDs()) do
    local name, icon, castMs = SpellInfo(id)
    local cost, ptype = SpellCost(id)
    local desc = name and SpellDescription(id) or ""
    db.scan[#db.scan + 1] = ("%d | %s | %s %s | %s"):format(id, tostring(name), tostring(cost), tostring(ptype), desc)
    if name and (ptype == powerName or (ptype == nil and powerName == "MANA")) then
      if desc == "" then
        RequestSpellData(id); pendingData = true
        if ptype then skipped[name] = "text not loaded" end
      else
        local s = {
          id = id, name = name, icon = icon, castMs = castMs or 0, cost = cost or 0,
          rank = SpellRank(id), cooldown = SpellCooldown(id), learned = LevelLearned(id),
        }
        if powerName == "MANA" then
          s.caster = ParseCaster(desc)
          if s.caster then
            s.channel = HasLine(TooltipLines(id), "^Channeled")
            byName[name] = byName[name] or {}
            table.insert(byName[name], s)
          elseif ptype and desc:find("damage") then
            skipped[name] = "couldn't read damage"
          end
        else
          s.melee = ParseMelee(desc)
          if s.melee then
            byName[name] = byName[name] or {}
            table.insert(byName[name], s)
          elseif desc:find("damage") then
            skipped[name] = "couldn't read damage"
          end
        end
      end
    end
  end
  -- A spell with one readable rank isn't "not compared".
  for name in pairs(byName) do skipped[name] = nil end
  -- Ranks: sort by level learned; the next rank's level drives the penalty.
  local list = {}
  for _, ranks in pairs(byName) do
    table.sort(ranks, function(a, b) return (a.learned or 0) < (b.learned or 0) end)
    for i, s in ipairs(ranks) do
      local nxt = ranks[i + 1]
      s.nextLearned = nxt and nxt.learned or nil
      s.isTopRank = (i == #ranks)
      if db.ranks or s.isTopRank then list[#list + 1] = s end
    end
  end
  return list
end

---------------------------------------------------------------------------
-- Engine: one shared result that the window, glow and tooltips
-- all read (SE.state). Recomputed on spell/gear/level/aura/form changes.
---------------------------------------------------------------------------

local function CurrentPowerName()
  local ptype, token = UnitPowerType("player")
  token = Safe(token)
  if token then return token end
  return ({ [0] = "MANA", [1] = "RAGE", [3] = "ENERGY" })[Safe(ptype) or 0]
end


---------------------------------------------------------------------------
-- Theoretical rotation
--
-- Mana: filler + cooldown spells (on cooldown) + DoTs (refreshed when they
-- run out), each only if it beats the filler per second of casting. Gives
-- DPS, mana per second, and how long a FULL mana bar lasts (max mana and
-- regen are readable; current mana isn't). Compared with the mana saver as
-- filler: which deals more total damage before OOM.
--
-- Energy: energy is the limit (regen per second). Every finisher is valued
-- as a package with the 5 builders it needs: damage / energy. DoT and buff
-- finishers (Rupture, Rip, Slice and Dice) and builder DoTs (Rake) can only
-- be used once per duration ("capped"): they're kept up if they're worth more
-- per energy than the best uncapped option, and the rest of the energy goes
-- to the best uncapped option (builder spam or 5x builder + direct finisher).
---------------------------------------------------------------------------

function SE.ManaRotation(st)
  local maxMana = Safe(UnitPowerMax("player", 0)) or 0
  local _, casting = SafeCall(GetManaRegen)
  local regen = casting or 0

  local function Plan(filler)
    local frac, dps, mps, steps = 1, 0, 0, {}
    for _, r in ipairs(st.rows) do
      if r ~= filler and not r.aoe and r.cooldown and r.cooldown > r.time and not r.isDot and r.dps > filler.dps then
        local rate = 1 / r.cooldown
        frac = frac - r.time * rate
        dps, mps = dps + r.dmg * rate, mps + r.cost * rate
        steps[#steps + 1] = { text = ("%s on cooldown (every %ds)"):format(r.name, r.cooldown), gain = r.dmg * rate - filler.dps * r.time * rate,
          row = r, kind = "cooldown" }
      end
    end
    for _, r in ipairs(st.rows) do
      if r.isDot and r.dur and r.dur > 0 and not r.aoe and r.dmg / r.time > filler.dps then
        local rate = 1 / r.dur
        frac = frac - r.time * rate
        dps, mps = dps + r.dmg * rate, mps + r.cost * rate
        steps[#steps + 1] = { text = ("keep %s up (refresh every %ds)"):format(r.name, r.dur), gain = r.dmg * rate - filler.dps * r.time * rate,
          row = r, kind = "dot", dur = r.dur }
      end
    end
    frac = math.max(frac, 0)
    dps = dps + filler.dps * frac
    mps = mps + (filler.mps or 0) * frac
    local drain = mps - regen
    local lasts = (drain > 0 and maxMana > 0) and maxMana / drain or nil
    return { filler = filler, dps = dps, mps = mps, lasts = lasts, total = lasts and dps * lasts or nil, steps = steps }
  end

  local rot = { main = Plan(st.best), maxMana = maxMana, regen = regen }
  if st.eff and st.eff ~= st.best then rot.alt = Plan(st.eff) end
  return rot
end

function SE.EnergyRotation(st)
  local B, R = st.bestB, st.regen
  if not B or not R or R <= 0 then return nil end
  local spam = { name = "spam " .. B.name, dpe = B.dpe or 0 }
  local uncapped = { spam }
  local cappedAbilities = {}   -- one entry per ability: its options (CP levels)
  local finishers = {}          -- for the comparison list

  for _, f in ipairs(st.rows) do
    if f.finisher and f.cost and f.levels then
      local opts = {}
      for k, L in pairs(f.levels) do
        local e = k * B.cost + f.cost
        local d = k * B.spamDmg + L.dmg
        opts[#opts + 1] = { row = f, cp = k, energy = e, dmg = d, dpe = d / e, cap = L.dur }
      end
      local capped = (f.dot or f.isBuff) and true or false
      if capped then
        cappedAbilities[#cappedAbilities + 1] = { row = f, opts = opts }
      else
        for _, o in ipairs(opts) do
          o.name = ("%dx %s + %s"):format(o.cp, B.name, f.name)
          uncapped[#uncapped + 1] = o
        end
      end
      finishers[#finishers + 1] = { row = f, opts = opts, capped = capped }
    elseif f ~= B and f.builder and f.dot and f.dur and f.dur > 0 and f.cost > 0 then
      -- Builder with a DoT (Rake): full value once per duration.
      cappedAbilities[#cappedAbilities + 1] = { row = f, opts = {
        { row = f, energy = f.cost, dmg = f.dmg, dpe = f.dmg / f.cost, cap = f.dur } } }
    end
  end

  -- Best repeatable option (builder spam, or N x builder + direct finisher).
  local P = spam
  for _, u in ipairs(uncapped) do if u.dpe > P.dpe then P = u end end

  -- For DoTs / buffs, the best CP count is the one with the most damage per
  -- second ON TOP of what that energy would do in P. Fewer points = shorter
  -- but cheaper; e.g. a 1-2 point Slice and Dice is often worth more.
  local function Gain(o) return (o.dmg - o.energy * P.dpe) / o.cap end
  for _, a in ipairs(cappedAbilities) do
    for _, o in ipairs(a.opts) do
      if o.cap and o.cap > 0 and (not a.best or Gain(o) > Gain(a.best)) then a.best = o end
    end
  end
  table.sort(cappedAbilities, function(x, y)
    return (x.best and Gain(x.best) or -1) > (y.best and Gain(y.best) or -1)
  end)

  local budget, dps, steps = R, 0, {}
  for _, a in ipairs(cappedAbilities) do
    local o = a.best
    if o and Gain(o) > 0 then
      local need = o.energy / o.cap
      if need <= budget then
        budget = budget - need
        dps = dps + o.dmg / o.cap
        local cpText = o.cp and ("%d CP, "):format(o.cp) or ""
        steps[#steps + 1] = { text = ("keep %s up (%severy %ds)"):format(a.row.name, cpText, o.cap), gain = Gain(o),
          row = a.row, cp = o.cp, dur = o.cap, kind = "keepup", onSelf = a.row.isBuff and true or false }
        a.row.keepUp, a.row.keepCP = true, o.cp   -- tooltips say "Keep up"
      end
    end
  end
  dps = dps + budget * P.dpe

  -- Comparison list: each finisher at its best CP count.
  for _, f in ipairs(finishers) do
    for _, o in ipairs(f.opts) do
      if f.capped and o.cap and o.cap > 0 then o.gain = Gain(o) end
      local better
      if f.capped then better = not f.best or (o.cap and Gain(o) > Gain(f.best))
      else better = not f.best or o.dpe > f.best.dpe end
      if better then f.best = o end
    end
    f.gain = f.capped and f.best and Gain(f.best) or nil
    -- What it really costs: the finisher plus the builders for its points,
    -- and what that same energy would do in the best repeatable option.
    local o = f.best
    f.own = o.dmg - o.cp * B.spamDmg       -- the finisher's own damage / value
    f.alt = o.energy * P.dpe               -- that energy spent on P instead
    f.row.pkgDPE, f.row.bestCP = o.dpe, o.cp
    -- for the table's expandable per-CP rows
    table.sort(f.opts, function(x, y) return x.cp < y.cp end)
    f.row.cpOpts, f.row.bestOpt, f.row.capped, f.row.builderDmg = f.opts, o, f.capped, B.spamDmg
  end
  table.sort(finishers, function(x, y) return x.best.dpe > y.best.dpe end)

  return { dps = dps, white = WhiteDPS(), filler = P, steps = steps, finishers = finishers, regen = R }
end

local function ComputeMana(list)
  local level = UnitLevel("player")
  local st = { power = "MANA", rows = {}, lines = {} }
  for _, s in ipairs(list) do st.rows[#st.rows + 1] = CasterRow(s, level) end
  table.sort(st.rows, function(a, b) return a.dps > b.dps end)

  -- Best filler (spammable single target), then the most mana-efficient one
  -- that still does at least db.comparable of the best DPS.
  for _, r in ipairs(st.rows) do
    if r.filler and (not st.best or r.dps > st.best.dps) then st.best = r end
  end
  if st.best then
    for _, r in ipairs(st.rows) do
      if r.filler and r.dpm and r.dps >= st.best.dps * db.comparable and (not st.eff or r.dpm > st.eff.dpm) then st.eff = r end
    end
  end
  for _, r in ipairs(st.rows) do
    if not r.aoe and r.dpm and (not st.mostEff or r.dpm > st.mostEff.dpm) then st.mostEff = r end
  end
  if st.best then st.rotation = SE.ManaRotation(st) end
  return st
end

local function ComputeEnergy(list)
  local st = { power = "ENERGY", rows = {}, cycles = {}, regen = EnergyRegen() }
  for _, s in ipairs(list) do st.rows[#st.rows + 1] = MeleeRow(s) end
  table.sort(st.rows, function(a, b) return (a.dpe or 0) > (b.dpe or 0) end)
  for _, r in ipairs(st.rows) do
    if r.builder and r.dps and (not st.bestB or r.dps > st.bestB.dps) then st.bestB = r end
  end
  -- Cycles: 5x best builder + one finisher.
  if st.bestB then
    for _, f in ipairs(st.rows) do
      -- Direct-damage finishers only: DoT/buff finishers can't be spammed
      -- (they're handled by the rotation solver, refreshed once per duration).
      if f.finisher and not f.dot and not f.isBuff then
        local energy = st.bestB.cost * 5 + f.cost
        local time = math.max(energy / st.regen, 6 * GCD_ENERGY)
        local dmg = st.bestB.spamDmg * 5 + f.dmg
        st.cycles[#st.cycles + 1] = { name = f.name, finisher = f, dps = dmg / time, dpe = dmg / energy }
      end
    end
    table.sort(st.cycles, function(a, b) return a.dps > b.dps end)
    local top = st.cycles[1]
    st.cycleBetter = top and top.dps > st.bestB.dps or false
    st.best = st.bestB
    st.rotation = SE.EnergyRotation(st)
  end
  return st
end

SE.state = nil
SE.listeners = {}
function SE.OnUpdate(fn) table.insert(SE.listeners, fn) end

local pendingRetries = 0
local function Compute()
  pendingData = false
  local power = CurrentPowerName()
  local st
  if power == "MANA" then st = ComputeMana(CollectSpells("MANA"))
  elseif power == "ENERGY" then st = ComputeEnergy(CollectSpells("ENERGY"))
  else st = { power = power, rows = {} } end
  st.byID, st.byName = {}, {}
  for i, r in ipairs(st.rows) do
    r.place = i
    st.byID[r.id] = r
    if not st.byName[r.name] or (r.dps or 0) > (st.byName[r.name].dps or 0) then st.byName[r.name] = r end
  end
  st.skipped = {}
  for name in pairs(skipped) do st.skipped[#st.skipped + 1] = name end
  table.sort(st.skipped)
  return st
end

-- Tells you when the winning spell changes (level, rank, gear). Needs a 3%
-- margin so two near-equal spells don't flip back and forth on every buff.
local function CheckWinner(st)
  local best = st.best
  if not best or not db.announce then return end
  db.winner = db.winner or {}
  local prev = db.winner[st.power]
  if prev == best.name then return end
  local old = prev and st.byName[prev]
  if old and old.dps and old.dps > 0 then
    local gain = best.dps / old.dps - 1
    if gain < 0.03 then return end
    print(("|cff33ff99SpellEfficiency|r: |cffffd100%s|r now beats %s (+%d%% DPS)."):format(best.name, prev, gain * 100 + 0.5))
  end
  db.winner[st.power] = best.name
end

function SE.Update()
  local ok, st = pcall(Compute)
  if not ok then db.lastError = tostring(st); return end
  -- In combat the client can hide spell texts: keep the last good result.
  if #st.rows == 0 and SE.state and #SE.state.rows > 0 and InCombatLockdown() then return end
  SE.state = st
  CheckWinner(st)
  for _, fn in ipairs(SE.listeners) do pcall(fn, st) end
  if pendingData and pendingRetries < 5 then
    pendingRetries = pendingRetries + 1
    C_Timer.After(1, SE.Update)
  else
    pendingRetries = 0
  end
end

-- The spell you should press now (for the glow): highest damage while mana
-- is above db.switchAt, the mana-efficient pick below it. Rogue/cat: best
-- builder, or the best finisher at 5 combo points when the cycle is better.
function SE.CurrentPick()
  local st = SE.state
  if not st or not st.best then return nil end
  if st.power == "MANA" then
    local mana, maxMana = Safe(UnitPower("player", 0)), Safe(UnitPowerMax("player", 0))
    if mana and maxMana and maxMana > 0 and mana / maxMana < db.switchAt and st.eff then
      return st.eff, "efficient"
    end
    return st.best, "best"
  elseif st.power == "ENERGY" then
    local cp = Safe(GetComboPoints and GetComboPoints("player", "target")) or Safe(UnitPower("player", 4)) or 0
    if cp >= 5 and st.cycleBetter and st.cycles[1] then return st.cycles[1].finisher, "finisher" end
    return st.bestB, "best"
  end
end

function SE.HasEnemyTarget()
  if not UnitExists("target") then return false end
  local dead = Safe(UnitIsDead("target"))
  if dead then return false end
  local can = UnitCanAttack("player", "target")
  if Secret(can) then return true end
  return can and true or false
end

---------------------------------------------------------------------------
-- Window (/se): the detailed table
---------------------------------------------------------------------------

local ROW_H, MAX_ROWS = 18, 30
local frame = CreateFrame("Frame", "SpellEfficiencyFrame", UIParent)
frame:SetSize(700, 200)
frame:SetFrameStrata("DIALOG")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:Hide()
tinsert(UISpecialFrames, "SpellEfficiencyFrame")   -- Escape closes it

local bg = frame:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints()
bg:SetColorTexture(0.05, 0.05, 0.07, 0.92)
local edge = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
edge:SetPoint("TOPLEFT", -1, 1); edge:SetPoint("BOTTOMRIGHT", 1, -1)
edge:SetColorTexture(0.3, 0.3, 0.35, 1)

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 12, -10)
title:SetText("Spell Efficiency")

local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 2, 2)

local summary = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
summary:SetPoint("TOPLEFT", 12, -36)
summary:SetPoint("RIGHT", -12, 0)
summary:SetJustifyH("LEFT")
summary:SetSpacing(3)

local footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
footer:SetPoint("BOTTOMLEFT", 12, 8)
footer:SetPoint("RIGHT", -12, 0)
footer:SetJustifyH("LEFT")

frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local point, _, _, x, y = self:GetPoint()
  db.point, db.x, db.y = point, x, y
end)

local header, rows = {}, {}
local function Cell(isHeader)
  return frame:CreateFontString(nil, "OVERLAY", isHeader and "GameFontNormalSmall" or "GameFontHighlightSmall")
end

local function Layout(cols, top)
  for c = 1, math.max(#cols, #header) do
    header[c] = header[c] or Cell(true)
    header[c]:SetShown(cols[c] ~= nil)
  end
  local x = 12
  for c, col in ipairs(cols) do
    local h = header[c]
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", x, -top)
    h:SetWidth(col.w)
    h:SetJustifyH(col.right and "RIGHT" or "LEFT")
    h:SetText(col.title)
    col.x = x
    x = x + col.w + 8
  end
  frame:SetWidth(math.max(700, x + 4))
end

local function Row(i)
  local r = rows[i]
  if r then return r end
  r = { cells = {} }
  r.icon = frame:CreateTexture(nil, "ARTWORK")
  r.icon:SetSize(ROW_H - 2, ROW_H - 2)
  r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  r.hl = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
  r.hl:SetHeight(ROW_H)
  -- click target for rows that do something (expanding finishers)
  r.btn = CreateFrame("Button", nil, frame)
  r.btn:SetHeight(ROW_H)
  r.btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  r.btn:SetScript("OnClick", function(self) if self.item and self.item.onClick then self.item.onClick() end end)
  rows[i] = r
  return r
end

local function Fmt(v, f) if not v then return "-" end return (f or "%.0f"):format(v) end

local GOLD, BLUE, GREY, WHITE = { 1, 0.82, 0 }, { 0.4, 0.8, 1 }, { 0.6, 0.6, 0.6 }, { 1, 1, 1 }

local function Render(list, cols, values, top, colorFor)
  Layout(cols, top)
  local y = top + ROW_H
  local shown = math.min(#list, MAX_ROWS)
  for i = 1, math.max(shown, #rows) do
    local r = Row(i)
    local item = list[i]
    local visible = i <= shown
    r.icon:SetShown(visible and not (item and item.noIcon)); r.hl:SetShown(visible)
    r.btn:SetShown(visible and item.onClick ~= nil)
    r.btn.item = visible and item or nil
    for c = 1, math.max(#cols, #r.cells) do
      r.cells[c] = r.cells[c] or Cell(false)
      r.cells[c]:SetShown(visible and cols[c] ~= nil)
    end
    if visible then
      local rowTop = -(y + (i - 1) * ROW_H)
      r.hl:ClearAllPoints()
      r.hl:SetPoint("TOPLEFT", 8, rowTop + 1); r.hl:SetPoint("RIGHT", -8, 0)
      r.btn:ClearAllPoints()
      r.btn:SetPoint("TOPLEFT", 8, rowTop + 1); r.btn:SetPoint("RIGHT", -8, 0)
      r.hl:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0)
      r.icon:ClearAllPoints()
      r.icon:SetPoint("TOPLEFT", cols[1].x, rowTop)
      r.icon:SetTexture(item.icon or 134400)
      local color = colorFor(item) or WHITE
      local vals = values(item)
      for c, col in ipairs(cols) do
        local fs = r.cells[c]
        fs:ClearAllPoints()
        local xOff = col.x + (c == 1 and ROW_H + 2 or 0)
        fs:SetPoint("TOPLEFT", xOff, rowTop - 2)
        fs:SetWidth(col.w - (c == 1 and ROW_H + 2 or 0))
        fs:SetJustifyH(col.right and "RIGHT" or "LEFT")
        fs:SetWordWrap(false)
        fs:SetText(vals[c])
        fs:SetTextColor(color[1], color[2], color[3])
      end
    end
  end
  return y + shown * ROW_H
end

local function SpellLabel(row)
  if db.ranks and row.rank and row.rank ~= "" then return row.name .. " (" .. row.rank .. ")" end
  return row.name
end
SE.SpellLabel = SpellLabel

local function Short(n)
  if n >= 10000 then return ("%.1fk"):format(n / 1000) end
  return ("%d"):format(n + 0.5)
end
local function Duration(t)
  if t >= 90 then return ("%dm %02ds"):format(t / 60, t % 60) end
  return ("%ds"):format(t + 0.5)
end

local function RenderMana(st)
  local best, eff, mostEff = st.best, st.eff, st.mostEff
  local lines = {}
  if best then
    lines[#lines + 1] = ("|cffffd100Most damage:|r %s - %.0f DPS (%.0f per cast, %.1fs)"):format(SpellLabel(best), best.dps, best.dmg, best.time)
  end
  if eff and eff ~= best then
    lines[#lines + 1] = ("|cff66ccffMana-efficient pick:|r %s - %.0f DPS (%d%% of best), %.2f dmg/mana vs %.2f"):format(
      SpellLabel(eff), eff.dps, eff.dps / best.dps * 100 + 0.5, eff.dpm, best.dpm or 0)
  elseif best then
    lines[#lines + 1] = "|cff66ccffMana-efficient pick:|r same spell - nothing comparable is cheaper per damage."
  end
  if mostEff and mostEff ~= eff and mostEff ~= best then
    lines[#lines + 1] = ("|cff999999Cheapest damage overall:|r %s - %.2f dmg/mana (%.0f DPS)"):format(SpellLabel(mostEff), mostEff.dpm, mostEff.dps)
  end
  local rot = st.rotation
  if rot then
    local function Lasts(plan)
      if not plan.lasts then return "your regen keeps up - never OOM" end
      return ("full mana lasts %s -> %s dmg"):format(Duration(plan.lasts), Short(plan.total))
    end
    lines[#lines + 1] = " "
    lines[#lines + 1] = "|cff33ff99Theoretical rotation:|r"
    for i, step in ipairs(rot.main.steps) do
      lines[#lines + 1] = ("  %d. %s  |cff999999(+%.1f DPS)|r"):format(i, step.text, step.gain)
    end
    lines[#lines + 1] = ("  %d. fill with |cffffd100%s|r -> |cffffffff%.1f DPS|r, %.1f mana/s, %s"):format(
      #rot.main.steps + 1, rot.main.filler.name, rot.main.dps, rot.main.mps, Lasts(rot.main))
    if rot.alt then
      lines[#lines + 1] = ("  or fill with |cff66ccff%s|r -> %.1f DPS, %.1f mana/s, %s"):format(
        rot.alt.filler.name, rot.alt.dps, rot.alt.mps, Lasts(rot.alt))
      local a, b = rot.main, rot.alt
      if a.total and (not b.total or b.total > a.total) then
        lines[#lines + 1] = ("  |cff999999Short fights: %s. Long fights without drinking: %s deals more before OOM.|r"):format(a.filler.name, b.filler.name)
      else
        lines[#lines + 1] = ("  |cff999999%s wins both short and long fights.|r"):format(a.filler.name)
      end
    end
    lines[#lines + 1] = ("  |cff999999Max mana %d, regen while casting %.1f/s. Your current mana can't be read, so it assumes full.|r"):format(rot.maxMana, rot.regen)
  end
  if #st.rows == 0 then lines[1] = "No damaging mana spells found in your spellbook." end
  summary:SetText(table.concat(lines, "\n"))

  local cols = {
    { title = "Spell", w = 190 }, { title = "Avg dmg", w = 60, right = true },
    { title = "Time", w = 40, right = true }, { title = "DPS", w = 50, right = true },
    { title = "Mana", w = 45, right = true }, { title = "Dmg/Mana", w = 60, right = true },
    { title = "Mana/s", w = 50, right = true }, { title = "Notes", w = 115 },
  }
  local top = 36 + summary:GetStringHeight() + 12
  return Render(st.rows, cols, function(r)
    return { SpellLabel(r), Fmt(r.dmg), Fmt(r.time, "%.1fs"), Fmt(r.dps), Fmt(r.cost), Fmt(r.dpm, "%.2f"), Fmt(r.mps, "%.1f"), r.note }
  end, top, function(r)
    if r == best then return GOLD elseif r == eff then return BLUE elseif not r.filler then return GREY end
  end)
end

local RenderWindow
local function RenderEnergy(st)
  local bestB = st.bestB
  local lines = {}
  lines[#lines + 1] = ("|cff999999Energy regen %.1f/s, GCD %.1fs.|r"):format(st.regen, GCD_ENERGY)
  if bestB then
    lines[#lines + 1] = ("|cffffd100Best builder:|r %s - %.0f dmg, %.2f dmg/energy"):format(SpellLabel(bestB), bestB.dmg, bestB.dpe or 0)
  end
  local rot = st.rotation
  if rot then
    lines[#lines + 1] = " "
    lines[#lines + 1] = "|cff33ff99Theoretical rotation:|r"
    for i, step in ipairs(rot.steps) do
      lines[#lines + 1] = ("  %d. %s  |cff999999(+%.1f DPS)|r"):format(i, step.text, step.gain)
    end
    lines[#lines + 1] = ("  %d. %s %s -> |cffffffff%.0f DPS from abilities|r + %.0f auto-attack"):format(
      #rot.steps + 1, #rot.steps > 0 and "otherwise" or "", rot.filler.name, rot.dps, rot.white)
  end
  if #st.rows == 0 then lines[1] = "No damaging energy abilities found in your spellbook." end
  summary:SetText(table.concat(lines, "\n"))

  local cols = {
    { title = "Ability", w = 190 }, { title = "Avg dmg", w = 60, right = true },
    { title = "Energy", w = 50, right = true }, { title = "Dmg/Energy", w = 70, right = true },
    { title = "Dmg/CP", w = 55, right = true },
    { title = "DPS spam", w = 65, right = true }, { title = "Energy/s", w = 55, right = true },
    { title = "Notes", w = 150 },
  }

  -- Finishers unfold into one line per combo point count (click to toggle).
  db.expandCP = db.expandCP or {}
  local list = {}
  for _, r in ipairs(st.rows) do
    list[#list + 1] = r
    if r.finisher and r.cpOpts then
      local name = r.name
      r.onClick = function() db.expandCP[name] = not db.expandCP[name]; RenderWindow(SE.state) end
      if db.expandCP[name] then
        for _, o in ipairs(r.cpOpts) do
          list[#list + 1] = { sub = true, parent = r, opt = o, noIcon = true }
        end
      end
    end
  end

  local top = 36 + summary:GetStringHeight() + 12
  return Render(list, cols, function(r)
    if r.sub then
      local f, o = r.parent, r.opt
      local own = o.dmg - o.cp * (f.builderDmg or 0)   -- the finisher's own damage at this CP
      local note = ("with %dx %s"):format(o.cp, bestB and bestB.name or "builder")
      if o.cap and o.cap > 0 and (f.dot or f.isBuff) then note = note .. (", %ds"):format(o.cap) end
      if o.gain then note = note .. (", %s%.1f DPS up"):format(o.gain >= 0 and "+" or "", o.gain) end
      return { ("      %d CP"):format(o.cp), Fmt(own), Fmt(o.energy), Fmt(o.dpe, "%.2f"), Fmt(own / o.cp), "-", "-", note }
    end
    if r.finisher and r.pkgDPE then
      local marker = db.expandCP[r.name] and "|cffffd100[-]|r " or "|cffffd100[+]|r "
      local o = r.bestOpt
      local own = o and (o.dmg - o.cp * (r.builderDmg or 0))
      local note = ("best at %d CP"):format(r.bestCP)
      if r.isBuff then note = note .. " (extra auto-attack)" end
      return { marker .. SpellLabel(r), Fmt(r.dmg), Fmt(r.cost), Fmt(r.pkgDPE, "%.2f"), own and Fmt(own / o.cp) or "-", "-", "-", note }
    end
    return { SpellLabel(r), Fmt(r.dmg), Fmt(r.cost), Fmt(r.dpe, "%.2f"), "-", Fmt(r.dps), Fmt(r.eps, "%.1f"), r.note }
  end, top, function(r)
    if r.sub then return (r.opt == r.parent.bestOpt) and GOLD or { 0.8, 0.8, 0.8 } end
    if r == bestB then return GOLD elseif not r.builder and not r.finisher then return GREY end
  end)
end

function RenderWindow(st)
  if not st or not frame:IsShown() then return end
  local bottom
  if st.power == "MANA" then
    bottom = RenderMana(st)
  elseif st.power == "ENERGY" then
    bottom = RenderEnergy(st)
  else
    summary:SetText(("Power type %s isn't supported yet (mana and energy only)."):format(tostring(st.power)))
    bottom = Render({}, {}, function() return {} end, 60, function() end)
  end
  footer:SetText((#st.skipped > 0 and ("|cffff8040Not compared:|r " .. table.concat(st.skipped, ", ") .. "\n") or "")
    .. (db.ranks and "[all ranks]" or "/se ranks shows lower ranks"))
  frame:SetHeight(bottom + 22 + footer:GetStringHeight())
end
SE.OnUpdate(RenderWindow)

frame:SetScript("OnShow", function()
  if SE.state then RenderWindow(SE.state) end
  SE.Update()
end)

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local queued
function SE.QueueUpdate()
  if queued or not db then return end
  queued = true
  C_Timer.After(0.5, function() queued = false; SE.Update() end)
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
for _, e in ipairs({ "SPELLS_CHANGED", "PLAYER_EQUIPMENT_CHANGED", "PLAYER_LEVEL_UP",
  "CHARACTER_POINTS_CHANGED", "UPDATE_SHAPESHIFT_FORM", "PLAYER_REGEN_ENABLED" }) do
  events:RegisterEvent(e)
end
events:RegisterUnitEvent("UNIT_AURA", "player")
events:RegisterUnitEvent("UNIT_DISPLAYPOWER", "player")
events:SetScript("OnEvent", function(self, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 ~= ADDON then return end
    SpellEfficiencyDB = SpellEfficiencyDB or {}
    db = SpellEfficiencyDB
    SE.db = db
    for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = v end end
    -- Remove data from the old kill check / debug tools.
    for _, k in ipairs({ "kill", "killLocked", "killPoint", "killX", "killY", "mobHP", "killDebug", "debugProbe" }) do
      db[k] = nil
    end
    frame:ClearAllPoints()
    frame:SetPoint(db.point, UIParent, db.point, db.x, db.y)
    for _, fn in ipairs(SE.onLoad) do fn(db) end
    self:UnregisterEvent("ADDON_LOADED")
    return
  end
  if event == "PLAYER_LOGIN" then C_Timer.After(2, SE.Update); return end
  if db then SE.QueueUpdate() end
end)

local function Print(msg) print("|cff33ff99SpellEfficiency|r: " .. msg) end
SE.Print = Print

local function Toggle(key, label)
  db[key] = not db[key]
  Print(label .. " " .. (db[key] and "on" or "off"))
  SE.Update()
end

SLASH_SPELLEFFICIENCY1 = "/se"
SLASH_SPELLEFFICIENCY2 = "/spelleff"
SlashCmdList.SPELLEFFICIENCY = function(msg)
  local cmd, arg = (msg or ""):lower():match("^(%S*)%s*(.-)$")
  if cmd == "ranks" then
    Toggle("ranks", "lower ranks in the table")
    frame:Show()
  elseif cmd == "comparable" and tonumber(arg) then
    db.comparable = math.min(1, math.max(0.5, tonumber(arg) / 100))
    Print(("mana-efficient pick needs at least %d%% of the best DPS"):format(db.comparable * 100))
    SE.Update()
  elseif cmd == "glow" then
    Toggle("glow", "action bar glow")
  elseif cmd == "switch" and tonumber(arg) then
    db.switchAt = math.min(1, math.max(0, tonumber(arg) / 100))
    Print(("glow switches to the mana-efficient spell below %d%% mana"):format(db.switchAt * 100))
  elseif cmd == "tips" then
    Toggle("tips", "tooltip line")
  elseif cmd == "announce" then
    Toggle("announce", "winner-change message")
  elseif cmd == "next" then
    Toggle("next", "next spell icon")
  elseif cmd == "lock" or cmd == "unlock" then
    db.nextLocked = (cmd == "lock")
    if SE.ApplyNextLayout then SE.ApplyNextLayout() end
    Print("next spell icon " .. (db.nextLocked and "locked" or "unlocked - drag it where you like"))
  elseif cmd == "scale" and tonumber(arg) then
    db.nextScale = math.min(3, math.max(0.5, tonumber(arg)))
    if SE.ApplyNextLayout then SE.ApplyNextLayout() end
    Print("next spell icon scale " .. db.nextScale)
  elseif cmd == "reset" then
    for k, v in pairs(DEFAULTS) do db[k] = v end
    frame:ClearAllPoints(); frame:SetPoint(db.point, UIParent, db.point, db.x, db.y)
    if SE.ApplyNextLayout then SE.ApplyNextLayout() end
    Print("reset.")
    SE.Update()
  elseif cmd == "help" then
    Print("/se - table | glow | switch <0-100> | tips | announce | next | lock | unlock | scale <0.5-3> | ranks | comparable <50-100> | reset")
  else
    frame:SetShown(not frame:IsShown())
  end
end
