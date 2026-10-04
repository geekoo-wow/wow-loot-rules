-- tests/test_config.lua — config operations behind the settings UI, the
-- rules-language helpers, and the remaining slash commands.

local T = ...
local test, eq, truthy = T.test, T.eq, T.truthy

local function printedContains(s)
  for _, m in ipairs(T.mock.printed) do if m:find(s, 1, true) then return true end end
  return false
end

-- ---- rules language ---------------------------------------------------------

test("validation catches syntax errors and unknown names", function()
  local ns = T.load()
  eq(ns.Config.Validate("quality <= COMMON and vendorValue * maxStack < silver(5)"), nil)
  eq(ns.Config.Validate("stackVendorPrice < 5"), "unknown name 'stackVendorPrice'", "removed in v5")
  eq(ns.Config.Validate("lootVendorPrice < 5"), "unknown name 'lootVendorPrice'", "removed in v4")
  truthy(ns.Config.Validate("quality <"), "syntax error")
  eq(ns.Config.Validate("qualty == 1"), "unknown name 'qualty'")
  eq(ns.Config.Validate("   "), "the condition is empty")
  eq(ns.Config.Validate('matches(name, "ab.c") and math.max(1, 2) == 2'), nil, "member access and strings ok")
  eq(ns.Config.Validate("vendorValue > 1e3"), nil, "numbers with exponents ok")
end)

test("validation reads expressions like Lua does", function()
  local ns = T.load()
  local ok = {
    'matches(name, "say \\"hi\\" there")',         -- escaped quotes
    "matches(name, 'it\\'s') or name == \"it's\"", -- both quote styles
    "matches(name, [[of the Whale]])",             -- long strings
    "quality == POOR -- grey",                     -- trailing comment
    "quality == POOR --[[ grey ]] and ilvl < 5",
    "quality == POOR -- grey\n and ilvl < 5",
    "vendorValue > .5 and ilvl < 0x10 and reqLevel < 2.5e1",
    'name:lower() == "x" and ("x"):rep(2) == "xx"', -- method calls
    'name .. "!" == "x!"',
  }
  for _, expr in ipairs(ok) do eq(ns.Config.Validate(expr), nil, expr) end
  local bad = {
    ['"x" .. qualty == "x"'] = "qualty",        -- .. is not a member access
    ["ilvl2 > 5"] = "ilvl2",                    -- reported as typed
    ['matches(name, "a") and "b" == b'] = "b",  -- names next to strings
    ["quality == POOR -- grey\n and ilvel < 5"] = "ilvel",
    ["math.floor(ilvl) == floor"] = "floor",    -- only as a member
  }
  for expr, name in pairs(bad) do eq(ns.Config.Validate(expr), "unknown name '" .. name .. "'", expr) end
end)

test("structured rules render as equivalent expressions", function()
  local ns = T.load()
  eq(ns.Engine.WhenToExpr({ quality = { max = 0 }, vendorValue = { max = 100 } }),
    "quality <= 0 and vendorValue <= 100")
  eq(ns.Engine.WhenToExpr({ classID = { 2, 4 }, quest = false }), "(classID == 2 or classID == 4) and not isQuest")
  eq(ns.Engine.WhenToExpr({ list = "blacklist" }), 'inList("blacklist")')
  eq(ns.Engine.WhenToExpr({ name = "^chip" }), 'matches(name, "^chip")')
  eq(ns.Engine.WhenToExpr({}), "true")
  eq(ns.Engine.WhenToExpr({ expr = "isQuest or isReagent", quality = 0 }), "(isQuest or isReagent) and quality == 0")
  eq(ns.Engine.WhenToExpr({ expr = "isQuest -- keep", quality = 0 }), "(isQuest -- keep\n) and quality == 0",
    "a trailing comment can't swallow the parenthesis")
end)

-- A rule with a condition the engine doesn't understand is dropped, so it
-- never matches; shown in the editor (and saved from it) it must not turn
-- into a rule that does.
test("conditions the engine doesn't understand render as false", function()
  local ns = T.load()
  eq(ns.Engine.WhenToExpr({ colour = "red", quality = 0 }), "--[[colour?]] false and quality == 0")
  eq(ns.Engine.WhenToExpr({ quality = true }), "--[[quality?]] false")
  eq(ns.Config.Validate(ns.Engine.WhenToExpr({ colour = "red", quality = 0 })), nil)
  eq(ns.Config.RuleExpr({ when = { expr = 5 } }), "--[[expr?]] false")
  eq(ns.Config.RuleExpr({ when = "quality == 0" }), "true", "no usable conditions at all")
end)

test("rendered expressions behave like the structured rule", function()
  local ns = T.load()
  local when = { quality = { max = 0 }, vendorValue = { max = 100 }, classID = { 15, 7 } }
  local structured = ns.Engine.Compile({ rules = { { name = "s", when = when, action = "leave" } } })
  local expr = ns.Engine.Compile({ rules = { { name = "e", when = { expr = ns.Engine.WhenToExpr(when) }, action = "leave" } } })
  for id, item in pairs({
    [300] = { name = "A", quality = 0, sellPrice = 50 },
    [301] = { name = "B", quality = 0, sellPrice = 500 },
    [302] = { name = "C", quality = 1, sellPrice = 1 },
    [303] = { name = "D", quality = 0, sellPrice = 1, classID = 2 },
  }) do
    local link = T.mock.item(id, item)
    local a = ns.Engine.Evaluate(structured, ns.Context.FromLink(link, 1, ns.db.lists))
    local b = ns.Engine.Evaluate(expr, ns.Context.FromLink(link, 1, ns.db.lists))
    eq(a, b, item.name)
  end
end)

test("every documented field is loadable and every field is documented", function()
  local ns = T.load()
  local link = T.mock.item(310, { name = "Full", quality = 2, sellPrice = 10, classID = 4, subclassID = 2 })
  local ctx = ns.Context.FromLink(link, 1, ns.db.lists)
  for _, f in ipairs(ns.Engine.Fields) do truthy(ctx[f[1]] ~= nil, "field " .. f[1] .. " should load") end
  local ref = ns.Config.ReferenceText()
  for _, f in ipairs(ns.Engine.Fields) do truthy(ref:find(f[1], 1, true), "reference mentions " .. f[1]) end
end)

test("reference examples all validate", function()
  local ns = T.load()
  local ref = ns.Config.ReferenceText()
  local inExamples = false
  local count = 0
  for line in ref:gmatch("[^\n]+") do
    if line:find("Examples") then inExamples = true
    elseif inExamples and line:match("^  |cffffffff") then
      local expr = line:match("^  |cffffffff(.-)|r")
      eq(ns.Config.Validate(expr), nil, expr)
      count = count + 1
    end
  end
  truthy(count >= 5, "found examples")
end)

-- ---- rule editing -----------------------------------------------------------

test("add, update, move, disable, delete", function()
  local ns = T.load()
  local n = #ns.Config.Rules()
  local i = ns.Config.AddRule()
  eq(i, n + 1)
  eq(ns.Config.UpdateRule(i, { name = " Weapons ", action = "leave", expr = "classID == 2", onUnknown = "match" }), nil)
  local r = ns.Config.Rules()[i]
  eq(r.name, "Weapons"); eq(r.when, { expr = "classID == 2" }); eq(r.onUnknown, "match")
  eq(ns.Config.MoveRule(i, -1), i - 1)
  eq(ns.Config.Rules()[i - 1].name, "Weapons")
  eq(ns.Config.MoveRule(1, -1), 1, "can't move above the top")
  ns.Config.SetRuleEnabled(i - 1, false)
  eq(ns.Config.Rules()[i - 1].enabled, false)
  eq(#ns.compiled.rules, n)
  ns.Config.DeleteRule(i - 1)
  eq(#ns.Config.Rules(), n)
end)

test("invalid updates change nothing", function()
  local ns = T.load()
  local before = ns.Config.RuleExpr(ns.Config.Rules()[4])
  truthy(ns.Config.UpdateRule(4, { name = "renamed", expr = "quality <" }))
  eq(ns.Config.Rules()[4].name, "Cheap junk")
  eq(ns.Config.RuleExpr(ns.Config.Rules()[4]), before)
  truthy(ns.Config.UpdateRule(4, { action = "burn" }))
  truthy(ns.Config.UpdateRule(4, { name = "renamed", onUnknown = "sometimes" }))
  eq(ns.Config.Rules()[4].name, "Cheap junk")
  eq(ns.Config.Rules()[4].onUnknown, nil)
  eq(ns.Config.UpdateRule(99, { name = "x" }), "no such rule")
  eq(#ns.compileErrors, 0)
end)

test("onUnknown is stored only when it isn't the default", function()
  local ns = T.load()
  eq(ns.Config.UpdateRule(4, { onUnknown = "match" }), nil)
  eq(ns.Config.Rules()[4].onUnknown, "match")
  eq(ns.Config.UpdateRule(4, { onUnknown = "skip" }), nil)
  eq(ns.Config.Rules()[4].onUnknown, nil)
end)

test("new rules never match until edited", function()
  local ns = T.load()
  ns.Config.AddRule()
  local link = T.mock.item(320, { name = "Anything", quality = 3, sellPrice = 1 })
  local r = ns.Config.TestItem(link)
  eq(r.action, "loot"); eq(r.ruleIndex, nil)
end)

test("rule errors from hand-edited SavedVariables are reported per rule", function()
  local ns = T.load({ ruleset = { rules = {
    { name = "ok", when = { expr = "quality == 0" }, action = "leave" },
    { name = "typo", when = { expr = "qualty == 0" }, action = "leave" },
  } } })
  eq(ns.Config.RuleError(1), nil)
  eq(ns.Config.RuleError(2), "condition unknown name 'qualty'")
  truthy(printedContains("rule error"))
  truthy(printedContains("rule 2 (typo): condition unknown name 'qualty'"))
end)

test("rule errors don't depend on what the rule is called", function()
  local ns = T.load({ ruleset = { rules = {
    { name = "Junk (cheap", when = { expr = "qualty == 0" }, action = "leave" },
    { name = "a) b", when = { expr = "quality == 0" }, action = "burn" },
  } } })
  eq(ns.Config.RuleError(1), "condition unknown name 'qualty'")
  eq(ns.Config.RuleError(2), "unknown action 'burn'")
end)

-- SavedVariables are plain Lua that people edit by hand (the README invites
-- it). Whatever is in there, the addon has to load and the panels have to draw.
test("hand-edited SavedVariables: malformed rulesets still load", function()
  local ns = T.load({ version = 5, ruleset = { rules = {
    7,
    { when = { expr = "quality == POOR" }, action = "leave", enabled = false }, -- no name
    "junk",
    { name = "Kept", when = { expr = "quality == POOR" }, action = "leave" },
  } } })
  local rules = ns.Config.Rules()
  eq(#rules, 2, "entries that aren't rules are dropped")
  eq(rules[1].name, "Rule 1"); eq(rules[2].name, "Kept")
  eq(#ns.compileErrors, 0)
  for _, p in ipairs(ns.UI.panels) do p:Show(); p:Refresh() end
  ns.UI.SelectRule(1)

  ns = T.load({ version = 5, ruleset = { default = "leave" } })
  eq(ns.Config.Rules(), {}, "a ruleset without rules has none")
  eq(ns.Config.DefaultAction(), "leave")
  eq(ns.Config.AddRule(), 1)

  ns = T.load({ version = 5, ruleset = "none", lists = { blacklist = 5 } })
  eq(#ns.Config.Rules(), #ns.DEFAULTS.ruleset.rules, "not a ruleset at all: back to the defaults")
  eq(ns.Config.AddToList("blacklist", 12), 12)
  eq(ns.Config.ListItems("whitelist"), {})
end)

test("default action can be switched", function()
  local ns = T.load()
  ns.Config.SetDefaultAction("leave")
  local link = T.mock.item(321, { name = "Plain", quality = 2, sellPrice = 99999 })
  eq(ns.Config.TestItem(link).action, "leave")
end)

-- ---- lists / tester -------------------------------------------------------------

test("lists accept links and IDs", function()
  local ns = T.load()
  local link = T.mock.item(330, { name = "Broken Branch", quality = 0, sellPrice = 1 })
  eq(ns.Config.AddToList("blacklist", link), 330)
  eq(ns.Config.AddToList("blacklist", "331"), 331)
  local id, err = ns.Config.AddToList("blacklist", "hello")
  eq(id, nil); truthy(err)
  eq(ns.Config.ListItems("blacklist"), { 330, 331 })
  ns.Config.RemoveFromList("blacklist", 330)
  eq(ns.Config.ListItems("blacklist"), { 331 })
end)

test("tester reports action, deciding rule and index", function()
  local ns = T.load()
  local link = T.mock.item(340, { name = "Tattered Cloth", quality = 0, sellPrice = 5 })
  local r = ns.Config.TestItem(link, 2)
  eq(r.action, "leave"); eq(r.rule, "Cheap junk"); eq(r.ruleIndex, 4)
  eq(ns.DescribeDecider(r.rule, r.ruleIndex), "#4 Cheap junk")
  eq(ns.Config.TestItem(link, 40).action, "leave", "unstackable: a full stack is still 5c")
end)

test("vendorValue and maxStack load from item data", function()
  local ns = T.load()
  local link = T.mock.item(341, { name = "Stackable Grey", quality = 0, sellPrice = 41, maxStack = 10 })
  local ctx = ns.Config.TestItem(link, 2).ctx
  eq(ctx.vendorValue, 41)
  eq(ctx.maxStack, 10)
end)

test("default junk rule judges a full stack, not the drop (41c x 10 stack)", function()
  local ns = T.load()
  local link = T.mock.item(342, { name = "Stackable Grey", quality = 0, sellPrice = 41, maxStack = 10 })
  for _, qty in ipairs({ 1, 2, 10 }) do
    eq(ns.Config.TestItem(link, qty).action, "loot", "qty " .. qty)
  end
  local cheap = T.mock.item(343, { name = "Cheap Grey", quality = 0, sellPrice = 9, maxStack = 10 })
  eq(ns.Config.TestItem(cheap, 10).action, "leave", "9c x 10 = 90c")
end)

test("arithmetic works in conditions", function()
  local ns = T.load()
  ns.Config.UpdateRule(4, { expr = "quality == POOR and vendorValue * math.min(maxStack, 5) < silver(1)" })
  local link = T.mock.item(344, { name = "Grey", quality = 0, sellPrice = 19, maxStack = 20 })
  eq(ns.Config.TestItem(link).action, "leave", "19c x 5 = 95c")
end)

test("v2 SavedVariables: unedited old defaults upgrade, edited rules keep their meaning", function()
  local ns = T.load({ version = 2, ruleset = { default = "loot", rules = {
    { name = "Cheap junk", when = { expr = "quality == POOR and stackValue < silver(1)" }, action = "leave" },
    { name = "Tight bags", when = { quality = { max = 1 }, stackValue = { max = 499 }, freeSlots = { max = 4 } },
      action = "leave" },
    { name = "Mine", when = { expr = "sellPrice > 10 and stackValue < silver(2) and mysellPriceX" }, action = "leave" },
    { name = "Mine2", when = { sellPrice = { max = 5 } }, action = "leave" },
    { name = "Mine3", when = { quality = { max = 0 }, stackValue = { min = 10, max = 100 } }, action = "leave" },
  } } })
  local rules = ns.db.ruleset.rules
  eq(rules[1].when.expr, "quality == POOR and vendorValue * maxStack < silver(1)")
  eq(rules[2].when.expr, "quality <= COMMON and vendorValue * maxStack < silver(5) and freeSlots <= 4")
  eq(rules[3].when.expr, "vendorValue > 10 and (vendorValue * quantity) < silver(2) and mysellPriceX",
    "whole identifiers only")
  eq(rules[4].when, { vendorValue = { max = 5 } })
  eq(rules[5].when, { expr = "quality <= 0 and (vendorValue * quantity) >= 10 and (vendorValue * quantity) <= 100" })
  eq(ns.db.version, 5)
end)

test("migration keeps the precedence of an expression it adds terms to", function()
  local ns = T.load({ version = 2, ruleset = { default = "loot", rules = {
    { name = "Mixed", when = { expr = "quality == POOR or quality == COMMON", stackValue = { max = 100 } }, action = "leave" },
  } } })
  eq(ns.db.ruleset.rules[1].when,
    { expr = "(quality == POOR or quality == COMMON) and (vendorValue * quantity) <= 100" })
  local pricey = T.mock.item(351, { name = "Pricey Grey", quality = 0, sellPrice = 5000 })
  eq(ns.Config.TestItem(pricey).action, "loot", "the value limit applies to greys too")
end)

test("v3 SavedVariables: lootVendorPrice is rewritten and still evaluates the same", function()
  local ns = T.load({ version = 3, ruleset = { default = "loot", rules = {
    { name = "Drop value", when = { expr = "lootVendorPrice < silver(1)" }, action = "leave" },
  } } })
  eq(ns.db.ruleset.rules[1].when.expr, "(vendorValue * quantity) < silver(1)")
  eq(#ns.compileErrors, 0)
  local link = T.mock.item(350, { name = "Fang", quality = 0, sellPrice = 30, maxStack = 20 })
  eq(ns.Config.TestItem(link, 3).action, "leave", "3 x 30c = 90c")
  eq(ns.Config.TestItem(link, 4).action, "loot", "4 x 30c = 1s 20c")
end)

test("money formatting", function()
  local ns = T.load()
  eq(ns.Config.FormatMoney(123456), "12g 34s 56c")
  eq(ns.Config.FormatMoney(250), "2s 50c")
  eq(ns.Config.FormatMoney(7), "7c")
end)

-- ---- saved variables / slash ----------------------------------------------------

test("v1 'verbose' setting migrates to debug", function()
  local ns = T.load({ version = 1, verbose = true })
  eq(ns.db.debug, true); eq(ns.db.verbose, nil); eq(ns.db.version, 5)
end)

test("/lr opens settings; toggles still work", function()
  local ns = T.load()
  ns.Commands.Run("")
  eq(T.mock.opened, "LootRules")
  ns.Commands.Run("debug")
  eq(ns.db.debug, true)
  ns.Commands.Run("dry")
  eq(ns.db.dryRun, true)
  ns.Commands.Run("off")
  eq(ns.db.enabled, false)
  ns.Commands.Run("  ON  ")
  eq(ns.db.enabled, true)
  truthy(printedContains("filtering"))
end)

test("/lr with an unknown word prints the usage and changes nothing", function()
  local ns = T.load()
  local before = ns.DeepCopy(ns.db)
  ns.Commands.Run("frobnicate")
  truthy(printedContains("/lr debug | dry | tooltip | on | off"))
  eq(ns.db, before)
  eq(T.mock.opened, nil)
end)

test("settings are booleans set through Config", function()
  local ns = T.load()
  local refreshes = 0
  ns.OnConfigChanged = function() refreshes = refreshes + 1 end
  ns.Config.Set("dryRun", 1)
  eq(ns.Config.Get("dryRun"), true); eq(ns.db.dryRun, true)
  ns.Config.Set("dryRun", nil)
  eq(ns.db.dryRun, false)
  eq(refreshes, 2, "the UI hears about each change")
  ns.Config.Set("ruleset", false)
  ns.Config.Set("version", true)
  ns.Config.Set("nonsense", true)
  eq(type(ns.db.ruleset), "table"); eq(ns.db.version, 5); eq(ns.db.nonsense, nil)
  eq(refreshes, 2)
end)

-- ---- relevant values ------------------------------------------------------------

test("FieldsOf lists only fields a rule reads, not helpers or constants", function()
  local ns = T.load()
  eq(ns.Engine.FieldsOf({ expr = "quality == POOR and vendorValue * maxStack < silver(1)" }),
    { "quality", "vendorValue", "maxStack" })
  eq(ns.Engine.FieldsOf({ expr = 'inList("blacklist")' }), {})
  eq(ns.Engine.FieldsOf({ expr = 'matches(name, "quality") and math.max(ilvl, 1) > 5' }), { "name", "ilvl" },
    "strings and member accesses ignored")
  eq(ns.Engine.FieldsOf({ quality = 0, quest = true, list = "x", name = "^a" }), { "name", "quality", "isQuest" },
    "structured: in condition-key order")
  eq(ns.Engine.FieldsOf({ expr = 'matches("" .. name, "x") and ilvl > 1e3 -- not quality' }), { "name", "ilvl" },
    "fields after .. count; exponents and comments don't")
end)

-- Tooltips and the tester have no loot slot to ask, so they assume the item
-- isn't a quest item unless its class says so (a real slot would say).
test("previews assume non-Quest-class items aren't quest items", function()
  local ns = T.load()
  ns.Config.UpdateRule(4, { expr = "not isQuest and quality == POOR" })
  local grey = T.mock.item(363, { name = "Grey", quality = 0, sellPrice = 1 })
  local r = ns.Config.TestItem(grey)
  eq(r.action, "leave"); eq(r.unknowns, nil)
  eq(r.values, "isQuest false, quality 0")
  local plain = T.mock.item(364, { name = "Plain", quality = 1, sellPrice = 1 })
  eq(ns.Config.TestItem(plain).unknowns, nil, "the default rules leave nothing undetermined for a cached item")
  local uncached = T.mock.item(365, { name = "Later", quality = 0, sellPrice = 1, cached = false })
  r = ns.Config.TestItem(uncached)
  eq(r.action, "loot"); truthy(r.unknowns, "not cached: undetermined"); eq(r.cached, false)
end)

test("tester reports only the deciding rule's values", function()
  local ns = T.load()
  local link = T.mock.item(360, { name = "Cheap Grey", quality = 0, sellPrice = 9, maxStack = 10 })
  eq(ns.Config.TestItem(link).values, "quality 0, vendorValue 9c, maxStack 10")
  local green = T.mock.item(361, { name = "Green", quality = 2, sellPrice = 9 })
  eq(ns.Config.TestItem(green).values, nil, "default decision reads nothing")
  ns.Config.AddToList("blacklist", 361)
  eq(ns.Config.TestItem(green).values, nil, "inList reads no field values")
end)

test("unknown values show as ?", function()
  local ns = T.load()
  T.mock.bags.free = 1
  ns.Config.UpdateRule(5, { expr = "freeSlots <= 4 and owned >= 0" })
  local link = T.mock.item(362, { name = "White", quality = 1, sellPrice = 99999 })
  eq(ns.Config.TestItem(link).values, "freeSlots 1, owned 0")
  eq(ns.FormatValues({ vendorValue = nil, name = "A" }, { "vendorValue", "name" }), 'vendorValue ?, name "A"')
end)

test("v4 SavedVariables: unitVendorPrice and stackVendorPrice are rewritten", function()
  local ns = T.load({ version = 4, ruleset = { default = "loot", rules = {
    { name = "Cheap junk", when = { expr = "quality == POOR and stackVendorPrice < silver(1)" }, action = "leave" },
    { name = "Mine", when = { expr = "unitVendorPrice > 5 and stackVendorPrice < silver(9)" }, action = "leave" },
    { name = "Mine2", when = { quality = 0, stackVendorPrice = { max = 50 } }, action = "leave" },
    { name = "Mine3", when = { unitVendorPrice = { min = 1 } }, action = "leave" },
  } } })
  local rules = ns.db.ruleset.rules
  eq(rules[1].when.expr, "quality == POOR and vendorValue * maxStack < silver(1)", "default upgraded")
  eq(rules[2].when.expr, "vendorValue > 5 and (vendorValue * maxStack) < silver(9)")
  eq(rules[3].when, { expr = "quality == 0 and (vendorValue * maxStack) <= 50" })
  eq(rules[4].when, { vendorValue = { min = 1 } })
  eq(#ns.compileErrors, 0)
end)

test("/lr tooltip toggles the tooltip line", function()
  local ns = T.load()
  eq(ns.db.tooltip, true)
  ns.Commands.Run("tooltip")
  eq(ns.db.tooltip, false)
  ns.Commands.Run("tooltip")
  eq(ns.db.tooltip, true)
end)
