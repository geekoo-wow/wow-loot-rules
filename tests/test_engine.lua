-- tests/test_engine.lua — rule compilation and evaluation, no loot window.

local T = ...
local test, eq = T.test, T.eq

-- Evaluate one item link against a ruleset.
local function decide(ns, ruleset, link, qty)
  local compiled, errors = ns.Engine.Compile(ruleset)
  eq(#errors, 0, "compile errors: " .. table.concat(errors, "; "))
  local ctx = ns.Context.FromLink(link, qty or 1, ns.db.lists)
  return ns.Engine.Evaluate(compiled, ctx)
end

test("first matching rule wins", function()
  local ns = T.load()
  local link = T.mock.item(100, { name = "Linen Cloth", quality = 1, sellPrice = 13 })
  local action, rule = decide(ns, { rules = {
    { name = "a", when = { quality = 1 }, action = "leave" },
    { name = "b", when = { quality = 1 }, action = "loot" },
  } }, link)
  eq(action, "leave"); eq(rule, "a")
end)

test("falls through to the default", function()
  local ns = T.load()
  local link = T.mock.item(100, { name = "Linen Cloth", quality = 1, sellPrice = 13 })
  local action, rule = decide(ns, { default = "leave", rules = {
    { name = "epics", when = { quality = { min = 4 } }, action = "loot" },
  } }, link)
  eq(action, "leave"); eq(rule, "default")
end)

test("conditions are ANDed; per-slot value uses maxStack, not quantity", function()
  local ns = T.load()
  local rules = { rules = {
    { name = "cheap junk", when = { quality = { max = 0 }, expr = "vendorValue * maxStack <= 100" }, action = "leave" },
  } }
  local small = T.mock.item(101, { name = "Broken Fang", quality = 0, sellPrice = 30, maxStack = 3 })
  eq((decide(ns, rules, small, 1)), "leave", "3 x 30c = 90c")
  eq((decide(ns, rules, small, 3)), "leave", "quantity doesn't matter")
  local big = T.mock.item(102, { name = "Fang Stack", quality = 0, sellPrice = 30, maxStack = 4 })
  eq((decide(ns, rules, big, 1)), "loot", "4 x 30c = 1s 20c")
  local white = T.mock.item(103, { name = "White", quality = 1, sellPrice = 1 })
  eq((decide(ns, rules, white, 1)), "loot", "quality condition fails")
end)

test("uncached items are undetermined and skipped by default", function()
  local ns = T.load()
  local link = T.mock.item(102, { name = "Mystery", quality = 0, sellPrice = 1, cached = false })
  local action, rule, unknowns = decide(ns, { rules = {
    { name = "cheap", when = { vendorValue = { max = 100 } }, action = "leave" },
  } }, link)
  eq(action, "loot"); eq(rule, "default"); eq(unknowns, { "cheap: vendorValue" })
end)

test("onUnknown = match applies the rule when data is missing", function()
  local ns = T.load()
  local link = T.mock.item(102, { name = "Mystery", quality = 0, sellPrice = 1, cached = false })
  local action = decide(ns, { rules = {
    { name = "cheap", when = { vendorValue = { max = 100 } }, action = "leave", onUnknown = "match" },
  } }, link)
  eq(action, "leave")
end)

test("a false condition beats an unknown one", function()
  local ns = T.load()
  local link = T.mock.item(103, { name = "Epic Thing", quality = 4, sellPrice = 50000 })
  T.mock.items[103].cached = false -- sellPrice unknown, but quality comes from the slot... not via link
  local action = decide(ns, { rules = {
    { name = "r", when = { itemID = 999, vendorValue = { max = 1 } }, action = "leave", onUnknown = "match" },
  } }, link)
  eq(action, "loot", "itemID mismatch is a hard false")
end)

test("secret values are treated as unknown", function()
  local ns = T.load()
  T.mock.items[104] = nil
  local link = T.mock.item(104, { name = "Secret", quality = 1, sellPrice = 777 })
  T.mock.secret[777] = true
  local action, _, unknowns = decide(ns, { rules = {
    { name = "cheap", when = { vendorValue = { max = 1000 } }, action = "leave" },
  } }, link)
  eq(action, "loot"); eq(unknowns, { "cheap: vendorValue" })
end)

test("lists: blacklist and whitelist by item ID", function()
  local ns = T.load()
  local link = T.mock.item(105, { name = "Rough Stone", quality = 1, sellPrice = 1 })
  ns.db.lists.blacklist[105] = true
  local action, rule = decide(ns, ns.db.ruleset, link)
  eq(action, "leave"); eq(rule, "Blacklist")
end)

test("name patterns are case-insensitive", function()
  local ns = T.load()
  local link = T.mock.item(106, { name = "Chipped Claw", quality = 0, sellPrice = 500 })
  eq((decide(ns, { rules = { { name = "n", when = { name = "^chipped" }, action = "leave" } } }, link)), "leave")
end)

test("expression rules see context fields and helpers", function()
  local ns = T.load()
  T.mock.bags.free = 3
  local link = T.mock.item(107, { name = "Light Leather", quality = 1, sellPrice = 15, classID = 7 })
  local rules = { rules = { {
    name = "e", action = "leave",
    when = { expr = "classID == 7 and vendorValue * quantity < silver(1) and freeSlots < 5" },
  } } }
  eq((decide(ns, rules, link, 2)), "leave")
  T.mock.bags.free = 10
  eq((decide(ns, rules, link, 2)), "loot")
end)

test("expression errors on nil fields become unknown, not crashes", function()
  local ns = T.load()
  local link = T.mock.item(108, { name = "Uncached", quality = 1, sellPrice = 15, cached = false })
  local action, _, unknowns = decide(ns, { rules = { { name = "e", when = { expr = "vendorValue < 100" }, action = "leave" } } }, link)
  eq(action, "loot"); eq(unknowns, { "e: condition" })
end)

test("expressions cannot assign globals", function()
  local ns = T.load()
  local link = T.mock.item(109, { name = "X", quality = 1, sellPrice = 1 })
  local compiled = ns.Engine.Compile({ rules = {
    { name = "e", when = { expr = "(function() LootSlot = nil end)()" }, action = "leave" },
  } })
  local action = ns.Engine.Evaluate(compiled, ns.Context.FromLink(link, 1, ns.db.lists))
  eq(action, "loot")
  T.truthy(_G.LootSlot ~= nil, "LootSlot must survive")
end)

test("invalid rules are reported and dropped, valid ones still run", function()
  local ns = T.load()
  local compiled, errors = ns.Engine.Compile({ rules = {
    { name = "bad action", when = {}, action = "yeet" },
    { name = "bad cond", when = { colour = "red" }, action = "leave" },
    { name = "bad range", when = { quality = "high" }, action = "leave" },
    { name = "bad expr", when = { expr = "quality <" }, action = "leave" },
    { name = "good", when = { quality = 0 }, action = "leave" },
  } })
  eq(#errors, 4)
  eq(#compiled.rules, 1)
  eq(compiled.rules[1].name, "good")
end)

test("disabled rules are skipped", function()
  local ns = T.load()
  local link = T.mock.item(110, { name = "Grey", quality = 0, sellPrice = 1 })
  eq((decide(ns, { rules = { { name = "d", enabled = false, when = { quality = 0 }, action = "leave" } } }, link)), "loot")
end)

test("default rules: tight bags leave cheap whites, keep valuable ones", function()
  local ns = T.load()
  T.mock.bags.free = 2
  local cheap = T.mock.item(111, { name = "Cheap White", quality = 1, sellPrice = 50 })
  local pricey = T.mock.item(112, { name = "Pricey White", quality = 1, sellPrice = 600 })
  eq((decide(ns, ns.db.ruleset, cheap)), "leave")
  eq((decide(ns, ns.db.ruleset, pricey)), "loot")
end)

test("lazy context only loads what rules read", function()
  local ns = T.load()
  local calls = 0
  local orig = _G.C_Container.GetContainerNumFreeSlots
  _G.C_Container.GetContainerNumFreeSlots = function(...) calls = calls + 1; return orig(...) end
  local link = T.mock.item(113, { name = "Epic", quality = 4, sellPrice = 1 })
  decide(ns, { rules = { { name = "q", when = { itemID = 113 }, action = "loot" } } }, link)
  eq(calls, 0, "freeSlots not needed")
  _G.C_Container.GetContainerNumFreeSlots = orig
end)
