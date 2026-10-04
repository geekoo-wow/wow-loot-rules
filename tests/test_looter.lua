-- tests/test_looter.lua — simulated loot windows.

local T = ...
local test, eq = T.test, T.eq

local function setupItems()
  local M = T.mock
  M.item(1, { name = "Tattered Cloth", quality = 0, sellPrice = 5 })    -- cheap junk
  M.item(2, { name = "Silk Cloth", quality = 1, sellPrice = 150 })
  M.item(3, { name = "Green Sword", quality = 2, sellPrice = 2000, bindType = 2 })
  M.item(4, { name = "Quest Head", quality = 1, sellPrice = 0 })
  M.item(5, { name = "Blue Ring", quality = 3, sellPrice = 5000, bindType = 1 })
end

local function printedMatching(pattern)
  local out = {}
  for _, m in ipairs(T.mock.printed) do if m:find(pattern) then out[#out + 1] = m end end
  return out
end

test("loots accepted slots highest-first, leaves junk, closes when done", function()
  local ns = T.load()
  setupItems()
  local M = T.mock
  M.openLoot({ { money = 123 }, { id = 1, qty = 2 }, { id = 2, qty = 3 }, { id = 3 } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  eq(M.looted, { 4, 3, 1 }, "sword, silk, coins — not the junk")
  eq(M.closed, 0, "waits for pending slots")
  ns.Looter.frame:Fire("LOOT_SLOT_CLEARED", 4)
  ns.Looter.frame:Fire("LOOT_SLOT_CLEARED", 3)
  eq(M.closed, 0)
  ns.Looter.frame:Fire("LOOT_SLOT_CLEARED", 1)
  eq(M.closed, 1, "closed once everything we took is gone")
end)

test("does not close when everything was looted", function()
  local ns = T.load()
  setupItems()
  local M = T.mock
  M.openLoot({ { id = 2 }, { id = 3 } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  ns.Looter.frame:Fire("LOOT_SLOT_CLEARED", 2)
  ns.Looter.frame:Fire("LOOT_SLOT_CLEARED", 1)
  eq(M.closed, 0)
end)

test("nothing wanted: closes immediately", function()
  local ns = T.load()
  setupItems()
  T.mock.openLoot({ { id = 1 } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  eq(T.mock.looted, {}); eq(T.mock.closed, 1)
end)

test("closeWhenDone off leaves the window open", function()
  local ns = T.load()
  setupItems()
  ns.db.closeWhenDone = false
  T.mock.openLoot({ { id = 1 } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  eq(T.mock.closed, 0)
end)

test("quest items are always looted", function()
  local ns = T.load()
  setupItems()
  ns.db.lists.blacklist[4] = nil
  T.mock.bags.free = 0
  T.mock.openLoot({ { id = 4, quest = true } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  eq(T.mock.looted, { 1 })
end)

test("locked slots are never touched", function()
  local ns = T.load()
  setupItems()
  T.mock.openLoot({ { id = 3, locked = true } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  eq(T.mock.looted, {})
end)

test("a locked slot counts as left: the window closes once our picks are in", function()
  local ns = T.load()
  setupItems()
  ns.db.debug = true
  T.mock.openLoot({ { id = 3, locked = true }, { id = 2 } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  eq(T.mock.looted, { 2 }); eq(T.mock.closed, 0)
  ns.Looter.frame:Fire("LOOT_SLOT_CLEARED", 2)
  eq(T.mock.closed, 1)
  eq(#printedMatching("skipped .*Green Sword.* slot is locked"), 1)
end)

test("money and currency are looted whatever the rules say", function()
  local ns = T.load()
  setupItems()
  ns.Config.SetDefaultAction("leave")
  T.mock.openLoot({ { money = 5 }, { currency = true }, { id = 2 } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  eq(T.mock.looted, { 2, 1 }, "currency and coins; the silk falls to the default")
end)

-- "Default when unsure is to loot": a Leave rule must not fire on a guess.
test("missing data never gets an item left behind", function()
  local ns = T.load()
  local M = T.mock
  M.item(6, { name = "Uncached Reagent", quality = 1, sellPrice = 50, isReagent = true, cached = false })
  M.item(7, { name = "Odd Trinket", quality = 1, sellPrice = 50 })
  ns.db.debug = true

  ns.db.ruleset.rules = { { name = "No reagents", when = { expr = "not isReagent" }, action = "leave" } }
  ns.Rebuild()
  M.openLoot({ { id = 6 }, { id = 7 } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  eq(M.looted, { 1 }, "the trinket is a known non-reagent; the reagent's data is missing")
  eq(#printedMatching("undetermined: No reagents: condition"), 1)
  ns.Looter.frame:Fire("LOOT_CLOSED")

  ns.db.ruleset.rules = { { name = "No quest", when = { expr = "not isQuest" }, action = "leave" } }
  ns.Rebuild()
  local hidden = {} -- stands in for a value the game hides in combat
  M.secret[hidden] = true
  M.openLoot({ { id = 7, quest = hidden }, { id = 7 } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  eq(M.looted, { 1 }, "a hidden quest flag is unknown in a real loot slot, not 'false'")
  eq(#printedMatching("undetermined: No quest: condition"), 1)
end)

test("each loot window starts a fresh session", function()
  local ns = T.load()
  setupItems()
  T.mock.openLoot({ { id = 1 }, { id = 2 } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  eq(T.mock.looted, { 2 })
  ns.Looter.frame:Fire("LOOT_CLOSED") -- closed by hand before the slot cleared
  eq(ns.Looter.session.active, false); eq(next(ns.Looter.session.pending), nil)
  T.mock.openLoot({ { id = 3 } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  eq(T.mock.looted, { 1 })
  ns.Looter.frame:Fire("LOOT_SLOT_CLEARED", 1)
  eq(T.mock.closed, 0, "nothing was left in the second window")
end)

test("loot events outside a session are ignored", function()
  local ns = T.load()
  setupItems()
  ns.Looter.frame:Fire("LOOT_SLOT_CLEARED", 1)
  ns.Looter.frame:Fire("LOOT_BIND_CONFIRM", 1)
  eq(T.mock.closed, 0); eq(T.mock.confirmed, {})
end)

test("dry run loots everything and prints what would have happened", function()
  local ns = T.load()
  setupItems()
  ns.db.dryRun = true
  T.mock.openLoot({ { id = 1 }, { id = 2 } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  eq(T.mock.looted, { 2, 1 })
  eq(#printedMatching("%[dry run%] would loot .*Silk Cloth.* — no rule matched %(default%)"), 1)
  eq(#printedMatching("%[dry run%] .*would leave.*Tattered Cloth.* — #4 Cheap junk %[quality 0, vendorValue 5c, maxStack 1%]"), 1)
end)

test("debug mode prints each decision with the deciding rule", function()
  local ns = T.load()
  setupItems()
  ns.db.debug = true
  ns.db.lists.whitelist[1] = true
  T.mock.openLoot({ { id = 1, qty = 3 }, { id = 3 } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  -- Debug text is wrapped in a color code, hence the trailing |r.
  eq(#printedMatching("looted.*Green Sword.* x1 — no rule matched %(default%)|r$"), 1, "no values for default")
  eq(#printedMatching("looted.*Tattered Cloth.* x3 — #2 Whitelist|r$"), 1, "inList reads no values")
end)

test("debug mode shows undetermined conditions", function()
  local ns = T.load()
  setupItems()
  ns.db.debug = true
  T.mock.items[1].cached = false
  T.mock.openLoot({ { id = 1 } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  eq(#printedMatching("undetermined: Cheap junk: condition"), 1)
end)

test("without debug or dry run, decisions are silent", function()
  local ns = T.load()
  setupItems()
  T.mock.openLoot({ { id = 1 }, { id = 2 } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  eq(#T.mock.printed, 0)
end)

test("built-in autoloot: does nothing and warns once", function()
  local ns = T.load()
  setupItems()
  T.mock.cvars.autoLootDefault = "1"
  T.mock.openLoot({ { id = 1 } })
  ns.Looter.frame:Fire("LOOT_READY", true)
  ns.Looter.frame:Fire("LOOT_CLOSED")
  ns.Looter.frame:Fire("LOOT_READY", true)
  eq(T.mock.looted, {})
  local warnings = 0
  for _, m in ipairs(T.mock.printed) do if m:find("Auto Loot option is on") then warnings = warnings + 1 end end
  eq(warnings, 1)
end)

test("duplicate LOOT_READY in one window is ignored", function()
  local ns = T.load()
  setupItems()
  T.mock.openLoot({ { id = 2 } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  ns.Looter.frame:Fire("LOOT_READY", false)
  eq(T.mock.looted, { 1 })
end)

test("BoP prompt confirmed only for slots we chose", function()
  local ns = T.load()
  setupItems()
  ns.db.lists.blacklist[5] = true
  T.mock.openLoot({ { id = 5 }, { id = 3 } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  ns.Looter.frame:Fire("LOOT_BIND_CONFIRM", 1) -- blacklisted ring: not ours
  ns.Looter.frame:Fire("LOOT_BIND_CONFIRM", 2)
  eq(T.mock.confirmed, { 2 })
  eq(T.mock.popupsHidden, { "LOOT_BIND" }, "the game's prompt is dismissed for the slot we confirmed")
end)

test("BoP prompts are left alone when auto-confirm is off", function()
  local ns = T.load()
  setupItems()
  ns.db.confirmBoP = false
  T.mock.openLoot({ { id = 5 } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  ns.Looter.frame:Fire("LOOT_BIND_CONFIRM", 1)
  eq(T.mock.looted, { 1 }); eq(T.mock.confirmed, {}); eq(T.mock.popupsHidden, {})
end)

test("autoloot modifier held: the game loots, LootRules stays out and doesn't warn", function()
  local ns = T.load()
  setupItems()
  ns.db.debug = true
  T.mock.openLoot({ { id = 1 } })
  ns.Looter.frame:Fire("LOOT_READY", true) -- the game's Auto Loot option is off
  eq(T.mock.looted, {}); eq(T.mock.closed, 0)
  eq(ns.Looter.session.active, false)
  eq(#printedMatching("Auto Loot option is on"), 0)
  eq(#printedMatching("autoloot modifier held"), 1)
end)

test("disabled addon does nothing", function()
  local ns = T.load()
  setupItems()
  ns.db.enabled = false
  T.mock.openLoot({ { id = 2 } })
  ns.Looter.frame:Fire("LOOT_READY", false)
  eq(T.mock.looted, {})
end)

test("saved settings survive a reload; missing defaults are filled in", function()
  local ns = T.load({ enabled = false, lists = { blacklist = { [42] = true } } })
  eq(ns.db.enabled, false)
  eq(ns.db.lists.blacklist[42], true)
  eq(type(ns.db.lists.whitelist), "table")
  eq(#ns.db.ruleset.rules, #ns.DEFAULTS.ruleset.rules)
end)
