-- tests/test_ui.lua — builds the settings panels against stub widgets.
-- This can't check layout, but it catches calls to missing helpers, typos and
-- wiring mistakes between the UI and Config.

local T = ...
local test, eq, truthy = T.test, T.eq, T.truthy

local function findWidget(pred)
  for _, w in ipairs(T.mock.widgets) do if pred(w) then return w end end
end

test("registers the settings categories", function()
  T.load()
  for _, name in ipairs({ "LootRules", "Rules", "Lists", "Rules reference" }) do
    truthy(T.mock.categories[name], "category " .. name)
  end
end)

test("all panels refresh without errors", function()
  local ns = T.load()
  T.mock.item(400, { name = "Listed", quality = 1, sellPrice = 1 })
  ns.Config.AddToList("blacklist", 400)
  ns.Config.AddToList("whitelist", 401) -- uncached item
  for _, p in ipairs(ns.UI.panels) do
    p:Show()
    p:Refresh()
  end
  ns.UI.Refresh()
end)

test("rules panel: selecting and saving a rule goes through Config", function()
  local ns = T.load()
  local panel = ns.UI.rulesPanel
  panel:Show()
  panel:Refresh()
  ns.UI.SelectRule(4)
  -- The condition editor is the multi-line EditBox holding rule 4's expression.
  local cond = findWidget(function(w) return w.kind == "EditBox" and w.text == ns.Config.RuleExpr(ns.Config.Rules()[4]) end)
  truthy(cond, "condition editor loaded")
  cond:SetText("quality == POOR and vendorValue * maxStack < silver(3)")
  local save = findWidget(function(w) return w.kind == "Button" and w.text == "Save" end)
  save:Click()
  eq(ns.db.ruleset.rules[4].when.expr, "quality == POOR and vendorValue * maxStack < silver(3)")
end)

test("rules panel: invalid condition is not saved", function()
  local ns = T.load()
  ns.UI.rulesPanel:Show()
  ns.UI.SelectRule(4)
  local before = ns.db.ruleset.rules[4].when.expr
  local cond = findWidget(function(w) return w.kind == "EditBox" and w.text == before end)
  cond:SetText("qualty == 0")
  findWidget(function(w) return w.kind == "Button" and w.text == "Save" end):Click()
  eq(ns.db.ruleset.rules[4].when.expr, before)
end)

test("shift-click inserts links into a focused item box", function()
  local ns = T.load()
  local lists = ns.UI.panels[3]
  lists:Show()
  local link = T.mock.item(410, { name = "Shifty", quality = 1, sellPrice = 1 })
  -- The first item box on the lists panel belongs to the blacklist column.
  local boxes = {}
  for _, w in ipairs(T.mock.widgets) do if w.kind == "EditBox" and rawget(w, "onItem") then boxes[#boxes + 1] = w end end
  local target
  for _, b in ipairs(boxes) do b:ClearFocus() end
  for i, b in ipairs(boxes) do
    T.mock.now = i -- each attempt is a separate click
    b:SetFocus()
    T.mock.hooks.ChatEdit_InsertLink(link)
    b:ClearFocus()
    if ns.db.lists.blacklist[410] then target = b; break end
  end
  truthy(target, "some item box added the item to the blacklist")
end)

test("dragging an item onto a list box adds it", function()
  local ns = T.load()
  T.mock.item(420, { name = "Dragged", quality = 1, sellPrice = 1 })
  local added = false
  for _, w in ipairs(T.mock.widgets) do
    if w.kind == "EditBox" and rawget(w, "onItem") and not added then
      T.mock.cursor = 420
      w.scripts.OnReceiveDrag(w)
      added = ns.db.lists.blacklist[420] or ns.db.lists.whitelist[420]
    end
  end
  truthy(added)
  eq(T.mock.cursor, nil, "cursor cleared")
end)

-- ---- item tooltips ------------------------------------------------------------

test("item tooltips show the decision and deciding rule", function()
  T.load()
  T.mock.item(500, { name = "Tattered Cloth", quality = 0, sellPrice = 5 })
  local lines = T.mock.showTooltip(_G.GameTooltip, 500)
  eq(#lines, 2)
  truthy(lines[1]:find("Leave") and lines[1]:find("#4 Cheap junk", 1, true), lines[1])
  truthy(lines[2]:find("quality 0, vendorValue 5c, maxStack 1", 1, true), lines[2])
  T.mock.item(501, { name = "Stackable", quality = 0, sellPrice = 41, maxStack = 10 })
  lines = T.mock.showTooltip(_G.ItemRefTooltip, 501)
  truthy(lines[1]:find("Loot") and lines[1]:find("no rule matched", 1, true), lines[1])
  eq(#lines, 1, "no rule decided, so no values")
end)

test("tooltip line respects the setting, skips other tooltips, flags filtering off", function()
  local ns = T.load()
  T.mock.item(502, { name = "Thing", quality = 2, sellPrice = 100 })
  eq(#T.mock.showTooltip(T.mock.widgets[1], 502), 0, "not GameTooltip/ItemRefTooltip")
  ns.db.enabled = false
  truthy(T.mock.showTooltip(_G.GameTooltip, 502)[1]:find("filtering off", 1, true))
  ns.db.tooltip = false
  eq(#T.mock.showTooltip(_G.GameTooltip, 502), 0)
end)

test("Quest-class items count as quest items outside loot windows", function()
  T.load()
  T.mock.item(503, { name = "Kobold Candle", quality = 1, sellPrice = 0, classID = 12 })
  truthy(T.mock.showTooltip(_G.GameTooltip, 503)[1]:find("#3 Quest items", 1, true))
end)

-- ---- bag picker -----------------------------------------------------------------

test("bag items are merged by item, filtered by name and sorted by quality", function()
  local ns = T.load()
  T.mock.item(510, { name = "Linen Cloth", quality = 1, sellPrice = 13 })
  T.mock.item(511, { name = "Green Blade", quality = 2, sellPrice = 900 })
  T.mock.item(512, { name = "Broken Fang", quality = 0, sellPrice = 5 })
  T.mock.bagItems = {
    [0] = { [1] = { id = 510, count = 20 }, [3] = { id = 512, count = 2 } },
    [2] = { [1] = { id = 510, count = 7 }, [2] = { id = 511 } },
  }
  local items = ns.Config.BagItems("")
  eq(#items, 3)
  eq(items[1].name, "Green Blade")
  eq(items[2].name, "Linen Cloth"); eq(items[2].count, 27)
  eq(items[3].name, "Broken Fang")
  local found = ns.Config.BagItems("  CLOTH ")
  eq(#found, 1); eq(found[1].itemID, 510)
end)

test("picker fills the tester and adds to lists", function()
  local ns = T.load()
  T.mock.item(520, { name = "Picked", quality = 1, sellPrice = 3 })
  T.mock.bagItems = { [0] = { [1] = { id = 520, count = 4 } } }
  -- Every "Bags…" button opens the picker; clicking a row hands back the link.
  local buttons = {}
  for _, w in ipairs(T.mock.widgets) do if w.kind == "Button" and w.text == "Bags…" then buttons[#buttons + 1] = w end end
  eq(#buttons, 3, "tester, blacklist, whitelist")
  for _, b in ipairs(buttons) do
    b:Click()
    local row
    for _, w in ipairs(T.mock.widgets) do
      if w.kind == "Button" and rawget(w, "link") == T.mock.link(520) and w.shown then row = w end
    end
    truthy(row, "picker row for the bag item")
    row:Click()
  end
  eq(ns.db.lists.blacklist[520], true)
  eq(ns.db.lists.whitelist[520], true)
  local testBox
  for _, w in ipairs(T.mock.widgets) do
    if w.kind == "EditBox" and w.text == T.mock.link(520) then testBox = w end
  end
  truthy(testBox, "tester box holds the picked link")
end)
