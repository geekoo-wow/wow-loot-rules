-- Looter.lua — replaces the built-in autoloot: on LOOT_READY, loot the slots
-- the rules accept and leave the rest.
--
-- Requires the game's own Auto Loot option to be OFF (the client loots
-- everything before addons can intervene). Holding the autoloot modifier
-- (Shift by default) then makes the client loot everything for that one
-- corpse, which doubles as a "just take it all" override.
--
-- The addon has two keys of its own, read as the window opens.
-- db.lootAllModifier does what the game's key does, but through LootRules
-- (so bind-on-pickup prompts are confirmed): everything is looted, whatever
-- the rules say. db.keepOpenModifier is the opposite override: the rules run
-- as usual, but the window stays open so what they left can still be picked
-- up by hand.

local _, ns = ...
ns = ns or {}

local Looter = {}
ns.Looter = Looter

local SLOT_ITEM, SLOT_MONEY, SLOT_CURRENCY = 1, 2, 3
local function slotTypes()
  local e = _G.Enum and _G.Enum.LootSlotType
  if e then return e.Item or SLOT_ITEM, e.Money or SLOT_MONEY, e.Currency or SLOT_CURRENCY end
  return SLOT_ITEM, SLOT_MONEY, SLOT_CURRENCY
end

-- State for the currently open loot window. `stays` means the game won't
-- close the window by itself (something was left on the corpse, or there was
-- nothing to take at all: it only closes once the last slot is looted).
-- `opened` means LOOT_OPENED has fired, so the window is really showing.
local session = { active = false, pending = {}, stays = false, keepOpen = false, opened = false }
Looter.session = session

local warnedBuiltin = false

-- Printed as each decision is made, in debug mode. Dry run always prints:
-- it exists to show what the rules would do. `values` lists only the fields
-- the deciding rule read.
function Looter.ReportDecision(label, action, rule, ruleIndex, unknowns, dryRun, values)
  if not (dryRun or ns.db.debug) then return end
  local verb
  if dryRun then
    verb = action == "loot" and "would loot" or "|cffffaa00would leave|r"
  else
    verb = action == "loot" and "|cff55ff55looted|r" or "|cffffaa00left|r"
  end
  local msg = string.format("%s%s %s — %s", dryRun and "[dry run] " or "", verb, label,
    ns.DescribeDecider(rule, ruleIndex))
  if values then msg = msg .. " [" .. values .. "]" end
  if unknowns then msg = msg .. " (undetermined: " .. table.concat(unknowns, "; ") .. ")" end
  ns.Debug(msg, true)
end

local function builtinAutolootOn()
  return _G.GetCVarBool and _G.GetCVarBool("autoLootDefault")
end

-- A key setting's value -> is that key down? "NONE" has no entry.
local MODIFIER_DOWN = { SHIFT = IsShiftKeyDown, CTRL = IsControlKeyDown, ALT = IsAltKeyDown }

local function keyHeld(setting)
  local isDown = MODIFIER_DOWN[ns.db[setting]]
  return isDown ~= nil and isDown() and true or false
end

-- Close once our picks are all in and the window would otherwise stay. Not
-- before LOOT_OPENED: LOOT_READY fires first, and a CloseLoot() between the
-- two is lost, so a corpse with nothing to take was left sitting open.
local function maybeClose()
  if session.active and session.opened and ns.db.closeWhenDone and not session.keepOpen
    and session.stays and next(session.pending) == nil then
    CloseLoot()
  end
end

-- Decide and loot every slot. `autoLoot` is LOOT_READY's payload: true when
-- the client itself is auto-looting this window.
function Looter.Process(autoLoot)
  local db = ns.db
  if not db or not db.enabled then return end
  if session.active then return end -- LOOT_READY can fire more than once per window

  if autoLoot then
    if builtinAutolootOn() and not warnedBuiltin then
      warnedBuiltin = true
      ns.Print("the game's Auto Loot option is on, so every item gets looted before rules run. "
        .. "Turn it off in the LootRules settings (/lr) and LootRules will take over.")
    elseif not builtinAutolootOn() then
      ns.Debug("autoloot modifier held — the game loots everything on this corpse")
    end
    return
  end

  session.active = true
  -- Both keys are read once, as the window opens: letting go while the slots
  -- are still being looted changes nothing.
  session.keepOpen = keyHeld("keepOpenModifier")
  local lootAll = keyHeld("lootAllModifier")
  if lootAll then
    ns.Debug(ns.MODIFIER_LABELS[db.lootAllModifier] .. " held — looting everything on this corpse", db.dryRun)
  end
  wipe(session.pending)

  local ITEM, MONEY, CURRENCY = slotTypes()

  local count = GetNumLootItems()
  session.stays = count == 0 -- nothing to take: the game won't close an empty window

  -- Highest slot first so looting can't shift indices under us.
  for slot = count, 1, -1 do
    local kind = GetLootSlotType(slot)
    if kind == MONEY or kind == CURRENCY then
      session.pending[slot] = true
      LootSlot(slot)
    elseif kind == ITEM then
      local ctx = ns.Context.FromLootSlot(slot, db.lists)
      local label = string.format("%s x%s", ctx.link or ctx.name or "?", tostring(ctx.quantity or 1))
      if ctx.locked then
        session.stays = true -- someone else's roll / master loot; not ours to take
        ns.Debug("skipped " .. label .. " — slot is locked (roll or master loot)")
      elseif lootAll then
        session.pending[slot] = true
        LootSlot(slot)
      else
        local action, rule, unknowns, ruleIndex, fields = ns.Engine.Evaluate(ns.compiled, ctx)
        Looter.ReportDecision(label, action, rule, ruleIndex, unknowns, db.dryRun,
          (db.dryRun or db.debug) and ns.FormatValues(ctx, fields) or nil)
        if action == "loot" or db.dryRun then
          session.pending[slot] = true
          LootSlot(slot)
        else
          session.stays = true
        end
      end
    end
  end

  if session.keepOpen and session.stays and db.closeWhenDone then
    ns.Debug(ns.MODIFIER_LABELS[db.keepOpenModifier] .. " held — leaving the loot window open")
  end
  maybeClose()
end

function Looter.OnOpened()
  session.opened = true
  maybeClose()
end

function Looter.OnSlotCleared(slot)
  if not session.active then return end
  session.pending[slot] = nil
  maybeClose()
end

function Looter.OnBindConfirm(slot)
  if session.active and ns.db.confirmBoP and session.pending[slot] then
    ConfirmLootSlot(slot)
    if _G.StaticPopup_Hide then _G.StaticPopup_Hide("LOOT_BIND") end
  end
end

function Looter.OnClosed()
  session.active = false
  session.opened = false
  session.stays = false
  session.keepOpen = false
  wipe(session.pending)
end

-- ---------------------------------------------------------------------------
-- Event wiring
-- ---------------------------------------------------------------------------

function Looter.Init()
  local frame = CreateFrame("Frame")
  frame:RegisterEvent("ADDON_LOADED")
  frame:RegisterEvent("LOOT_READY")
  frame:RegisterEvent("LOOT_OPENED")
  frame:RegisterEvent("LOOT_SLOT_CLEARED")
  frame:RegisterEvent("LOOT_BIND_CONFIRM")
  frame:RegisterEvent("LOOT_CLOSED")
  frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
      if arg1 == ns.name then
        ns.InitDB()
        if ns.UI then ns.UI.Init() end
        frame:UnregisterEvent("ADDON_LOADED")
      end
    elseif event == "LOOT_READY" then
      Looter.Process(arg1)
    elseif event == "LOOT_OPENED" then
      Looter.OnOpened()
    elseif event == "LOOT_SLOT_CLEARED" then
      Looter.OnSlotCleared(arg1)
    elseif event == "LOOT_BIND_CONFIRM" then
      Looter.OnBindConfirm(arg1)
    elseif event == "LOOT_CLOSED" then
      Looter.OnClosed()
    end
  end)
  Looter.frame = frame
end
