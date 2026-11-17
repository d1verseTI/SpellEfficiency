-- Tooltip.lua: a small block in spell tooltips (spellbook and action bars):
--   SpellEfficiency              Mana saver
--   Avg damage per cast                  19
--   Cast time                          1.5s
--   Damage per second     12.6 (92% of Fireball)
--   Damage per mana       0.76 (+12% vs Fireball)
--   Mana per second                    16.7
-- Roles: Best damage, Mana saver, Use on cooldown, Keep up (DoT), AoE, Weaker.
-- Rogue / cat: Best builder, Use at 5 CP, Finisher, Situational, Weaker.

local _, SE = ...
local Safe = SE.Safe

local GOLD, BLUE, GREEN, GREY = "|cffffd100", "|cff66ccff", "|cff99ff99", "|cffaaaaaa"
local SEP = " · "

local function Pct(a, b) return math.floor(a / b * 100 + 0.5) end
local function Signed(n) return n > 0 and ("+" .. n) or tostring(n) end

local function ManaRole(row, st)
  local best = st.best
  if row == best then return GOLD .. "Best damage|r" end
  if row.aoe then return GREY .. "AoE|r" end
  if row.isDot then
    return row.dps > best.dps and (GREEN .. "Keep up (DoT)|r") or (GREY .. "DoT|r")
  end
  if row.cooldown and row.cooldown > row.time then
    local cd = ("(%ds)"):format(row.cooldown)
    return row.dps > best.dps and (GREEN .. "Use on cooldown " .. cd .. "|r") or (GREY .. "Cooldown " .. cd .. "|r")
  end
  if row == st.eff then return BLUE .. "Mana saver|r" end
  return GREY .. "Weaker|r"
end

-- Returns the role and a list of { label, value } rows.
local function DescribeMana(row, st)
  local best = st.best
  if not best then return nil end
  local stats = {}
  local isBest = row == best
  local vs = isBest and "" or (" |cffaaaaaa(%d%% of %s)|r"):format(Pct(row.dps, best.dps), best.name)
  stats[#stats + 1] = { "Avg damage per cast", ("%.0f"):format(row.dmg) }
  -- Effective time: cast time, channel duration, or the 1.5s GCD for instants.
  stats[#stats + 1] = { "Time per cast", ("%.1fs"):format(row.time) }
  stats[#stats + 1] = { "Damage per second", ("%.1f"):format(row.dps) .. vs }
  if row.dpm then
    local rel = ""
    if not isBest and best.dpm and best.dpm > 0 then
      rel = (" |cffaaaaaa(%s%% vs %s)|r"):format(Signed(Pct(row.dpm, best.dpm) - 100), best.name)
    end
    stats[#stats + 1] = { "Damage per mana", ("%.2f"):format(row.dpm) .. rel }
  end
  if row.mps then stats[#stats + 1] = { "Mana per second", ("%.1f"):format(row.mps) } end
  return ManaRole(row, st), stats
end

local function EnergyRole(row, st)
  local best = st.bestB
  if row == best then return GOLD .. "Best builder|r" end
  -- Chosen by the theoretical rotation (DoT / Slice and Dice upkeep).
  if row.keepUp then
    return GREEN .. (row.finisher and ("Keep up (%d CP)|r"):format(row.keepCP or row.topCP or 5) or "Keep up|r")
  end
  if row.finisher then
    for _, c in ipairs(st.cycles) do
      if c.finisher == row and c.dps > best.dps then return GREEN .. "Use at 5 CP|r" end
    end
    return GREY .. "Finisher (not worth it)|r"
  end
  if not row.builder then return GREY .. "Situational|r" end
  return GREY .. "Weaker|r"
end

local function DescribeEnergy(row, st)
  local best = st.bestB
  if not best then return nil end
  local stats = {}
  local isBest = row == best
  stats[#stats + 1] = { "Avg damage", ("%.0f%s"):format(row.dmg, row.finisher and (" (%d CP)"):format(row.topCP or 5) or "") }
  stats[#stats + 1] = { "Energy cost", ("%d"):format(row.cost) }
  if row.finisher and row.pkgDPE then
    -- Same honest number as the /se window: builders for its points included.
    stats[#stats + 1] = { ("Dmg per energy (%d CP + builders)"):format(row.bestCP), ("%.2f"):format(row.pkgDPE)
      .. (" |cffaaaaaa(spam %s: %.2f)|r"):format(best.name, best.dpe or 0) }
  elseif row.dpe then
    local rel = (not isBest and best.dpe and best.dpe > 0)
      and (" |cffaaaaaa(%d%% of %s)|r"):format(Pct(row.dpe, best.dpe), best.name) or ""
    stats[#stats + 1] = { "Damage per energy", ("%.2f"):format(row.dpe) .. rel }
  end
  if row.finisher then
    for _, c in ipairs(st.cycles) do
      if c.finisher == row then
        stats[#stats + 1] = { ("Cycle DPS (5x %s + this)"):format(best.name), ("%.0f"):format(c.dps) }
      end
    end
    if best.dps then stats[#stats + 1] = { ("Spamming %s"):format(best.name), ("%.0f DPS"):format(best.dps) } end
  else
    if row.dps then stats[#stats + 1] = { "DPS when spammed", ("%.0f"):format(row.dps) } end
    if row.eps then stats[#stats + 1] = { "Energy per second", ("%.1f"):format(row.eps) } end
  end
  return EnergyRole(row, st), stats
end

local function Describe(row, st)
  if st.power == "MANA" then return DescribeMana(row, st) end
  return DescribeEnergy(row, st)
end

local function AddLine(tt, spellID)
  local db, st = SE.db, SE.state
  if not (db and db.tips and st and spellID) then return end
  local row = st.byID[spellID]
  if not row then
    local name = SE.SpellInfo(spellID)
    row = name and st.byName[name]
  end
  if not row then return end
  local role, stats = Describe(row, st)
  if not role then return end
  tt:AddLine(" ")
  tt:AddDoubleLine("|cff33ff99SpellEfficiency|r", role)
  for _, s in ipairs(stats) do
    tt:AddDoubleLine(s[1], s[2], 0.8, 0.8, 0.8, 1, 1, 1)
  end
  tt:Show()
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell, function(tt, data)
    if tt ~= GameTooltip or not data then return end
    pcall(AddLine, tt, Safe(data.id))
  end)
else
  GameTooltip:HookScript("OnTooltipSetSpell", function(tt)
    local ok, _, id = pcall(tt.GetSpell, tt)
    if ok then pcall(AddLine, tt, Safe(id)) end
  end)
end
