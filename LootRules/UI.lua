-- UI.lua — settings panels in the standard Options > AddOns pane:
--   LootRules        general toggles, game Auto Loot status
--     Rules          ordered rule list, editor, item tester
--     Lists          blacklist / whitelist
--     Rules reference  quick reference for the rules language
--
-- All config changes go through ns.Config; this file only draws widgets.

local _, ns = ...
ns = ns or {}

local UI = {}
ns.UI = UI

local Config = ns.Config
local PAD = 16

local COLOR_LOOT = "|cff55ff55"
local COLOR_LEAVE = "|cffffaa00"
local COLOR_ERR = "|cffff5555"
local COLOR_DIM = "|cff999999"

local function actionText(action)
  return action == "loot" and (COLOR_LOOT .. "Loot|r") or (COLOR_LEAVE .. "Leave|r")
end

-- ---------------------------------------------------------------------------
-- Widget helpers
-- ---------------------------------------------------------------------------

local function Label(parent, text, font)
  local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontHighlight")
  fs:SetJustifyH("LEFT")
  fs:SetText(text or "")
  return fs
end

local function Button(parent, text, width, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width or 100, 22)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

local function Tooltip(frame, title, body)
  frame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(title, 1, 1, 1)
    if body then GameTooltip:AddLine(body, nil, nil, nil, true) end
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function Check(parent, label, tip, get, set)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetSize(26, 26)
  cb.label = Label(parent, label)
  cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 1)
  cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
  if tip then Tooltip(cb, label, tip) end
  function cb:Refresh() self:SetChecked(get() and true or false) end
  return cb
end

-- Editboxes that accept items: shift-click (while focused), drag-and-drop,
-- or click with an item on the cursor.
local linkTargets = {}
local lastInsert = { link = nil, time = -1 }

local function insertLink(link)
  if type(link) ~= "string" then return end
  local now = GetTime()
  -- Some clients route one shift-click through two hooked functions.
  if lastInsert.link == link and lastInsert.time == now then return end
  for eb in pairs(linkTargets) do
    if eb:IsVisible() and eb:HasFocus() then
      eb:SetText(link)
      eb:SetCursorPosition(0)
      lastInsert.link, lastInsert.time = link, now
      if eb.onItem then eb.onItem(eb, link) end
      return
    end
  end
end

local function hookLinks()
  if _G.ChatEdit_InsertLink then hooksecurefunc("ChatEdit_InsertLink", insertLink) end
  if _G.ChatFrameUtil and _G.ChatFrameUtil.InsertLink then
    hooksecurefunc(_G.ChatFrameUtil, "InsertLink", insertLink)
  end
end

local function Input(parent, width, onItem)
  local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  eb:SetSize(width, 20)
  eb:SetAutoFocus(false)
  eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  if onItem then
    eb.onItem = onItem
    linkTargets[eb] = true
    local function fromCursor(self)
      local kind, id, link = GetCursorInfo()
      if kind == "item" then
        ClearCursor()
        link = link or ("item:" .. id)
        self:SetText(link)
        self:SetCursorPosition(0)
        onItem(self, link)
      end
    end
    eb:SetScript("OnReceiveDrag", fromCursor)
    eb:HookScript("OnMouseDown", fromCursor)
  end
  return eb
end

local BACKDROP = {
  bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  edgeSize = 12,
  insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local function Box(parent, width, height)
  local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  box:SetSize(width, height)
  box:SetBackdrop(BACKDROP)
  box:SetBackdropColor(0, 0, 0, 0.45)
  box:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
  return box
end

-- Scrolling area inside a Box; returns box, scrollFrame, child.
local function ScrollBox(parent, width, height)
  local box = Box(parent, width, height)
  local sf = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 6, -6)
  sf:SetPoint("BOTTOMRIGHT", -28, 6)
  local child = CreateFrame("Frame", nil, sf)
  child:SetSize(width - 34, 1)
  sf:SetScrollChild(child)
  return box, sf, child
end

-- Multi-line text editor in a box.
local function TextArea(parent, width, height)
  local box, sf = ScrollBox(parent, width, height)
  local eb = CreateFrame("EditBox", nil, sf)
  eb:SetMultiLine(true)
  eb:SetAutoFocus(false)
  eb:SetFontObject(ChatFontNormal)
  eb:SetWidth(width - 34)
  eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  sf:SetScrollChild(eb)
  box:EnableMouse(true)
  box:SetScript("OnMouseDown", function() eb:SetFocus() end)
  return box, eb
end

local function Panel(title, subtitle)
  local f = CreateFrame("Frame")
  f:Hide()
  local t = Label(f, title, "GameFontNormalLarge")
  t:SetPoint("TOPLEFT", PAD, -PAD)
  if subtitle then
    local s = Label(f, subtitle, "GameFontHighlightSmall")
    s:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -6)
    s:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
  end
  -- Settings canvas callbacks; changes are applied immediately, so no-ops.
  f.OnCommit = function() end
  f.OnDefault = function() end
  f.OnRefresh = function() if f.Refresh then f:Refresh() end end
  f:SetScript("OnShow", function(self) if self.Refresh then self:Refresh() end end)
  return f
end

-- ---------------------------------------------------------------------------
-- Bag item picker
--
-- The Settings panel blocks the bag keybinds, so item boxes can't rely on
-- dragging from open bags. The picker lists what's in your bags inside a
-- popup over the panel; choosing an item hands its link to the caller.
-- ---------------------------------------------------------------------------

local picker
local PICK_ROW_H = 24

local function BuildPicker()
  local parent = _G.SettingsPanel or _G.UIParent
  local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  f:Hide()
  f:SetSize(340, 430)
  f:SetPoint("CENTER")
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetToplevel(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetBackdrop(BACKDROP)
  f:SetBackdropColor(0.06, 0.06, 0.08, 0.97)
  f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

  local title = Label(f, "Pick an item from your bags", "GameFontNormal")
  title:SetPoint("TOPLEFT", 14, -14)
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)

  local searchLabel = Label(f, "Search")
  searchLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -14)
  local search = Input(f, 230)
  search:SetPoint("LEFT", searchLabel, "RIGHT", 12, 0)
  f.search = search

  local box, _, child = ScrollBox(f, 312, 330)
  box:SetPoint("TOPLEFT", searchLabel, "BOTTOMLEFT", -2, -10)
  local empty = Label(child, "", "GameFontHighlightSmall")
  empty:SetPoint("TOPLEFT", 4, -4)

  local rows = {}
  local function makeRow(i)
    local row = CreateFrame("Button", nil, child)
    row:SetHeight(PICK_ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * PICK_ROW_H)
    row:SetPoint("RIGHT", child, "RIGHT")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("LEFT", 2, 0)
    row.count = Label(row, "", "GameFontHighlightSmall")
    row.count:SetPoint("RIGHT", -4, 0)
    row.text = Label(row, "")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.text:SetPoint("RIGHT", row.count, "LEFT", -6, 0)
    row.text:SetWordWrap(false)
    row:SetScript("OnClick", function(self)
      local cb = f.callback
      f:Hide()
      if cb then cb(self.link) end
    end)
    row:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink(self.link)
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    rows[i] = row
    return row
  end

  function f:Refresh()
    local items = Config.BagItems(search:GetText())
    for i, item in ipairs(items) do
      local row = rows[i] or makeRow(i)
      row.link = item.link
      row.icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
      row.text:SetText(item.link)
      row.count:SetText(item.count > 1 and ("x" .. item.count) or "")
      row:Show()
    end
    for i = #items + 1, #rows do rows[i]:Hide() end
    empty:SetText(#items == 0 and (COLOR_DIM .. (search:GetText() ~= "" and "No matching items." or "Your bags are empty.") .. "|r") or "")
    child:SetHeight(math.max(1, #items * PICK_ROW_H))
  end

  search:SetScript("OnTextChanged", function() f:Refresh() end)
  f:SetScript("OnHide", function() f.callback = nil end)
  f:RegisterEvent("BAG_UPDATE_DELAYED")
  f:SetScript("OnEvent", function() if f:IsShown() then f:Refresh() end end)
  return f
end

-- Open the picker; callback(link) runs when an item is chosen.
function UI.PickItem(callback)
  picker = picker or BuildPicker()
  picker.callback = callback
  picker.search:SetText("")
  picker:Show()
  picker:Raise()
  picker:Refresh()
  return picker
end

local function PickButton(parent, onPick)
  local b = Button(parent, "Bags…", 60, function() UI.PickItem(onPick) end)
  Tooltip(b, "Pick from bags", "Choose an item from your bags. (Bags can't be opened while the settings are showing.)")
  return b
end

-- ---------------------------------------------------------------------------
-- General
-- ---------------------------------------------------------------------------

local function BuildGeneral()
  local f = Panel("LootRules", "Rule-based autoloot: loots what your rules accept and leaves the rest on the corpse.")
  local function setting(key, label, tip)
    return Check(f, label, tip, function() return Config.Get(key) end, function(v) Config.Set(key, v) end)
  end

  local checks = {
    setting("enabled", "Enabled", "Filter loot with your rules. When off, nothing is looted automatically."),
    setting("dryRun", "Dry run", "Evaluate rules and print what they would do, but loot everything."),
    setting("debug", "Debug output", "Print every loot decision in chat, with the rule that made it."),
    setting("closeWhenDone", "Close loot window when done",
      "After looting the items your rules accept, close the window and leave the rest on the corpse."),
    setting("confirmBoP", "Confirm bind-on-pickup items",
      "Automatically confirm the bind-on-pickup prompt for items your rules chose to loot."),
    setting("tooltip", "Show decision on item tooltips",
      "Add a line to item tooltips saying whether your rules would loot or leave the item, and which rule decides. "
      .. "Tooltips assume a single unit dropped."),
  }
  local prev
  for i, cb in ipairs(checks) do
    if i == 1 then cb:SetPoint("TOPLEFT", PAD, -70) else cb:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -4) end
    prev = cb
  end

  local header = Label(f, "Game Auto Loot", "GameFontNormal")
  header:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -24)
  local status = Label(f, "")
  status:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -8)
  status:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
  local toggle = Button(f, "", 180, function()
    SetCVar("autoLootDefault", GetCVarBool("autoLootDefault") and "0" or "1")
    f:Refresh()
  end)
  toggle:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -8)

  local help = Label(f, COLOR_DIM .. "Holding the autoloot modifier (Shift by default) while opening a corpse makes "
    .. "the game loot everything on it, bypassing your rules for that corpse.|r", "GameFontHighlightSmall")
  help:SetPoint("TOPLEFT", toggle, "BOTTOMLEFT", 0, -10)
  help:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)

  local slash = Label(f, COLOR_DIM .. "/lr opens this panel. /lr debug, /lr dry and /lr tooltip toggle those settings.|r",
    "GameFontHighlightSmall")
  slash:SetPoint("TOPLEFT", help, "BOTTOMLEFT", 0, -16)

  function f:Refresh()
    for _, cb in ipairs(checks) do cb:Refresh() end
    if GetCVarBool("autoLootDefault") then
      status:SetText(COLOR_ERR .. "On|r — the game loots everything before LootRules can filter. Turn it off to use your rules.")
      toggle:SetText("Turn game Auto Loot off")
    else
      status:SetText(COLOR_LOOT .. "Off|r — LootRules is handling looting.")
      toggle:SetText("Turn game Auto Loot on")
    end
  end
  return f
end

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------

local ROW_H = 22

local function BuildRules()
  local f = Panel("Rules", "Checked top to bottom; the first matching rule decides. See 'Rules reference' for the language.")
  local selected -- rule index being edited

  -- ---- list ----
  local listBox, _, listChild = ScrollBox(f, 600, 166)
  listBox:SetPoint("TOPLEFT", PAD, -64)
  local rows = {}

  local function makeRow(i)
    local row = CreateFrame("Button", nil, listChild)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetPoint("RIGHT", listChild, "RIGHT", 0, 0)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.sel = row:CreateTexture(nil, "BACKGROUND")
    row.sel:SetAllPoints()
    row.sel:SetColorTexture(0.2, 0.4, 0.8, 0.35)

    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(20, 20)
    row.check:SetPoint("LEFT", 2, 0)
    row.check:SetScript("OnClick", function(self) Config.SetRuleEnabled(row.index, self:GetChecked() and true or false) end)
    Tooltip(row.check, "Enabled", "Disabled rules are skipped.")

    row.num = Label(row, "", "GameFontDisableSmall")
    row.num:SetPoint("LEFT", row.check, "RIGHT", 2, 0)
    row.num:SetWidth(20)
    row.name = Label(row, "", "GameFontHighlight")
    row.name:SetPoint("LEFT", row.num, "RIGHT", 2, 0)
    row.name:SetWidth(130)
    row.name:SetWordWrap(false)
    row.action = Label(row, "", "GameFontHighlight")
    row.action:SetPoint("LEFT", row.name, "RIGHT", 6, 0)
    row.action:SetWidth(44)
    row.expr = Label(row, "", "GameFontHighlightSmall")
    row.expr:SetPoint("LEFT", row.action, "RIGHT", 6, 0)
    row.expr:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.expr:SetWordWrap(false)

    row:SetScript("OnClick", function() UI.SelectRule(row.index) end)
    rows[i] = row
    return row
  end

  local function refreshList()
    local list = Config.Rules()
    for i, rule in ipairs(list) do
      local row = rows[i] or makeRow(i)
      row.index = i
      row.check:SetChecked(rule.enabled ~= false)
      row.num:SetText(i .. ".")
      row.name:SetText(rule.enabled == false and (COLOR_DIM .. rule.name .. "|r") or rule.name)
      row.action:SetText(actionText(rule.action))
      local err = Config.RuleError(i)
      row.expr:SetText(err and (COLOR_ERR .. "error: " .. err .. "|r") or (COLOR_DIM .. Config.RuleExpr(rule) .. "|r"))
      row.sel:SetShown(i == selected)
      row:Show()
    end
    for i = #list + 1, #rows do rows[i]:Hide() end
    listChild:SetHeight(math.max(1, #list * ROW_H))
  end

  -- ---- list buttons ----
  local add = Button(f, "Add rule", 90, function() UI.SelectRule(Config.AddRule()) end)
  add:SetPoint("TOPLEFT", listBox, "BOTTOMLEFT", 0, -6)
  local up = Button(f, "Move up", 80, function() if selected then UI.SelectRule(Config.MoveRule(selected, -1)) end end)
  up:SetPoint("LEFT", add, "RIGHT", 4, 0)
  local down = Button(f, "Move down", 90, function() if selected then UI.SelectRule(Config.MoveRule(selected, 1)) end end)
  down:SetPoint("LEFT", up, "RIGHT", 4, 0)
  local del
  del = Button(f, "Delete", 70, function()
    if not selected then return end
    -- Two clicks to delete, so a stray click can't lose a rule.
    if del.armed then
      del.armed = false
      Config.DeleteRule(selected)
      UI.SelectRule(math.min(selected, #Config.Rules()))
    else
      del.armed = true
      del:SetText("Confirm?")
    end
  end)
  del:SetPoint("LEFT", down, "RIGHT", 4, 0)
  local reset
  reset = Button(f, "Reset to defaults", 130, function()
    if reset.armed then
      reset.armed = false
      ns.ResetRules()
      UI.SelectRule(1)
    else
      reset.armed = true
      reset:SetText("Click to confirm")
    end
  end)
  reset:SetPoint("TOPRIGHT", listBox, "BOTTOMRIGHT", 0, -6)

  local function disarm()
    del.armed = false; del:SetText("Delete")
    reset.armed = false; reset:SetText("Reset to defaults")
  end

  -- ---- editor ----
  local edHeader = Label(f, "Edit rule", "GameFontNormal")
  edHeader:SetPoint("TOPLEFT", add, "BOTTOMLEFT", 0, -14)

  local nameLabel = Label(f, "Name")
  nameLabel:SetPoint("TOPLEFT", edHeader, "BOTTOMLEFT", 0, -10)
  local nameBox = Input(f, 200)
  nameBox:SetPoint("LEFT", nameLabel, "LEFT", 50, 0)

  local pendingAction = "leave"
  local actionBtn = Button(f, "", 110, function(self)
    pendingAction = pendingAction == "loot" and "leave" or "loot"
    self:SetText("Action: " .. actionText(pendingAction))
  end)
  actionBtn:SetPoint("LEFT", nameBox, "RIGHT", 14, 0)
  Tooltip(actionBtn, "Action", "What happens to items this rule matches. Click to switch between Loot and Leave.")

  local pendingUnknown = false
  local unknownCheck = Check(f, "Apply when data is unknown",
    "If the condition needs data that isn't available (item not cached, value hidden in combat), "
    .. "apply this rule anyway instead of skipping it.",
    function() return pendingUnknown end, function(v) pendingUnknown = v end)
  unknownCheck:SetPoint("LEFT", actionBtn, "RIGHT", 10, 0)

  local condLabel = Label(f, "Condition")
  condLabel:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 0, -16)
  local condBox, condEdit = TextArea(f, 600, 56)
  condBox:SetPoint("TOPLEFT", condLabel, "BOTTOMLEFT", 0, -4)

  local condStatus = Label(f, "", "GameFontHighlightSmall")
  condStatus:SetPoint("TOPLEFT", condBox, "BOTTOMLEFT", 2, -4)
  condStatus:SetPoint("RIGHT", condBox, "RIGHT", -120, 0)
  condStatus:SetWordWrap(false)

  condEdit:SetScript("OnTextChanged", function(self)
    if not selected then return condStatus:SetText("") end
    local err = Config.Validate(self:GetText())
    condStatus:SetText(err and (COLOR_ERR .. err .. "|r") or (COLOR_LOOT .. "Condition OK|r"))
  end)

  local save = Button(f, "Save", 70, function()
    if not selected then return end
    local err = Config.UpdateRule(selected, {
      name = nameBox:GetText(), action = pendingAction, expr = condEdit:GetText(),
      onUnknown = pendingUnknown and "match" or "skip",
    })
    if err then
      condStatus:SetText(COLOR_ERR .. "Not saved: " .. err .. "|r")
    else
      condEdit:ClearFocus(); nameBox:ClearFocus()
      condStatus:SetText(COLOR_LOOT .. "Saved|r")
    end
  end)
  save:SetPoint("TOPRIGHT", condBox, "BOTTOMRIGHT", 0, -4)
  local revert = Button(f, "Revert", 70, function() UI.SelectRule(selected) end)
  revert:SetPoint("RIGHT", save, "LEFT", -4, 0)

  local editorWidgets = { nameBox, actionBtn, unknownCheck, condEdit, save, revert, up, down, del }

  local function loadEditor()
    local rule = selected and Config.Rules()[selected]
    for _, w in ipairs(editorWidgets) do
      if rule then w:Enable() else w:Disable() end
    end
    if not rule then
      nameBox:SetText(""); condEdit:SetText(""); condStatus:SetText("")
      edHeader:SetText("Edit rule — select a rule above")
      return
    end
    edHeader:SetText("Edit rule " .. selected)
    nameBox:SetText(rule.name or "")
    nameBox:SetCursorPosition(0)
    pendingAction = rule.action
    actionBtn:SetText("Action: " .. actionText(pendingAction))
    pendingUnknown = rule.onUnknown == "match"
    unknownCheck:Refresh()
    condEdit:SetText(Config.RuleExpr(rule))
    condEdit:SetCursorPosition(0)
  end

  -- ---- default action ----
  local defaultBtn = Button(f, "", 200, function(self)
    Config.SetDefaultAction(Config.DefaultAction() == "loot" and "leave" or "loot")
    self:SetText("If no rule matches: " .. actionText(Config.DefaultAction()))
  end)
  defaultBtn:SetPoint("TOPRIGHT", reset, "BOTTOMRIGHT", 0, -8)

  -- ---- tester ----
  local testHeader = Label(f, "Test an item", "GameFontNormal")
  testHeader:SetPoint("TOPLEFT", condBox, "BOTTOMLEFT", 0, -36)
  local testResult = Label(f, "", "GameFontHighlightSmall")

  local testBox, qtyBox
  local function runTest()
    local text = testBox:GetText()
    if text == "" then
      testResult:SetText(COLOR_DIM .. "Pick an item with Bags…, type an item ID, or shift-click a chat link into the box.|r")
      return
    end
    local r, err = Config.TestItem(text, tonumber(qtyBox:GetText()) or 1)
    if not r then return testResult:SetText(COLOR_ERR .. err .. "|r") end
    local ctx = r.ctx
    local lines = {
      string.format("%s x%d → %s — %s", ctx.link or text, ctx.quantity, actionText(r.action),
        ns.DescribeDecider(r.rule, r.ruleIndex)),
    }
    -- Only the values the deciding rule read; everything else is irrelevant.
    if r.values then lines[#lines + 1] = COLOR_DIM .. r.values .. "|r" end
    if r.unknowns then lines[#lines + 1] = COLOR_LEAVE .. "undetermined: " .. table.concat(r.unknowns, "; ") .. "|r" end
    if not r.cached then lines[#lines + 1] = COLOR_DIM .. "item data is loading — result will update|r" end
    lines[#lines + 1] = COLOR_DIM .. "Outside a loot window, only Quest-class items count as quest items.|r"
    testResult:SetText(table.concat(lines, "\n"))
  end

  testBox = Input(f, 260, function() runTest() end)
  testBox:SetPoint("TOPLEFT", testHeader, "BOTTOMLEFT", 6, -6)
  testBox:SetScript("OnTextChanged", function() runTest() end)
  local qtyLabel = Label(f, "Qty")
  qtyLabel:SetPoint("LEFT", testBox, "RIGHT", 12, 0)
  qtyBox = Input(f, 40)
  qtyBox:SetPoint("LEFT", qtyLabel, "RIGHT", 8, 0)
  qtyBox:SetNumeric(true)
  qtyBox:SetText("1")
  qtyBox:SetScript("OnTextChanged", function() runTest() end)
  local testPick = PickButton(f, function(link)
    testBox:SetText(link)
    testBox:SetCursorPosition(0)
  end)
  testPick:SetPoint("LEFT", qtyBox, "RIGHT", 10, 0)
  testResult:SetPoint("TOPLEFT", testBox, "BOTTOMLEFT", -6, -8)
  testResult:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)

  -- ---- selection / refresh ----
  function UI.SelectRule(i)
    local n = #Config.Rules()
    selected = (i and n > 0) and math.max(1, math.min(i, n)) or nil
    disarm()
    refreshList()
    loadEditor()
    runTest()
  end

  function f:Refresh()
    defaultBtn:SetText("If no rule matches: " .. actionText(Config.DefaultAction()))
    if selected == nil and #Config.Rules() > 0 then return UI.SelectRule(1) end
    refreshList()
    runTest()
  end
  f.RunTest = runTest
  return f
end

-- ---------------------------------------------------------------------------
-- Lists
-- ---------------------------------------------------------------------------

local function itemDisplay(id)
  local name, link = ns.Context.API.GetItemInfo(id)
  local _, _, _, _, icon = ns.Context.API.GetItemInfoInstant(id)
  return link or name or (COLOR_DIM .. "item " .. id .. " (loading…)|r"), icon
end

local function BuildListColumn(parent, listName, title, blurb, x)
  local col = CreateFrame("Frame", nil, parent)
  col:SetPoint("TOPLEFT", x, -64)
  col:SetSize(290, 480)

  local header = Label(col, title, "GameFontNormal")
  header:SetPoint("TOPLEFT")
  local sub = Label(col, COLOR_DIM .. blurb .. "|r", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
  sub:SetPoint("RIGHT", col, "RIGHT")

  local status = Label(col, "", "GameFontHighlightSmall")
  local input
  local function addFrom(text)
    local id, err = Config.AddToList(listName, text)
    if id then
      input:SetText("")
      status:SetText("")
    else
      status:SetText(COLOR_ERR .. err .. "|r")
    end
  end
  input = Input(col, 150, function(_, link) addFrom(link) end)
  input:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 6, -10)
  input:SetScript("OnEnterPressed", function(self) addFrom(self:GetText()) end)
  local addBtn = Button(col, "Add", 60, function() addFrom(input:GetText()) end)
  addBtn:SetPoint("LEFT", input, "RIGHT", 6, 0)
  local pickBtn = PickButton(col, function(link) addFrom(link) end)
  pickBtn:SetPoint("LEFT", addBtn, "RIGHT", 4, 0)
  status:SetPoint("TOPLEFT", input, "BOTTOMLEFT", -6, -4)

  local box, _, child = ScrollBox(col, 290, 360)
  box:SetPoint("TOPLEFT", input, "BOTTOMLEFT", -6, -22)
  local empty = Label(child, COLOR_DIM .. "Empty — use Bags… or type an item ID above.|r", "GameFontHighlightSmall")
  empty:SetPoint("TOPLEFT", 4, -4)

  local rows = {}
  local function makeRow(i)
    local row = CreateFrame("Frame", nil, child)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetPoint("RIGHT", child, "RIGHT")
    row:EnableMouse(true)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", 2, 0)
    row.text = Label(row, "")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -28, 0)
    row.text:SetWordWrap(false)
    row.remove = Button(row, "x", 22, function() Config.RemoveFromList(listName, row.id) end)
    row.remove:SetHeight(18)
    row.remove:SetPoint("RIGHT", -2, 0)
    row:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(self.id)
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    rows[i] = row
    return row
  end

  function col:Refresh()
    local ids = Config.ListItems(listName)
    for i, id in ipairs(ids) do
      local row = rows[i] or makeRow(i)
      row.id = id
      local text, icon = itemDisplay(id)
      row.text:SetText(text)
      row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
      row:Show()
    end
    for i = #ids + 1, #rows do rows[i]:Hide() end
    empty:SetShown(#ids == 0)
    child:SetHeight(math.max(1, #ids * ROW_H))
  end
  return col
end

local function BuildLists()
  local f = Panel("Lists", "Items by ID. Used by the Blacklist and Whitelist rules, or in any condition via inList(\"name\").")
  local bl = BuildListColumn(f, "blacklist", "Blacklist", "Never looted (rule 'Blacklist').", PAD)
  local wl = BuildListColumn(f, "whitelist", "Whitelist", "Always looted (rule 'Whitelist').", PAD + 310)
  function f:Refresh() bl:Refresh(); wl:Refresh() end
  return f
end

-- ---------------------------------------------------------------------------
-- Reference
-- ---------------------------------------------------------------------------

local function BuildReference()
  local f = Panel("Rules reference")
  local box, _, child = ScrollBox(f, 620, 500)
  box:SetPoint("TOPLEFT", PAD, -44)
  box:SetPoint("BOTTOMRIGHT", -PAD, PAD)
  local text = Label(child, "", "GameFontHighlight")
  text:SetPoint("TOPLEFT", 6, -6)
  text:SetWidth(570)
  text:SetSpacing(2)
  function f:Refresh()
    text:SetText(Config.ReferenceText())
    child:SetHeight(text:GetStringHeight() + 12)
  end
  return f
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

function UI.Refresh()
  for _, p in ipairs(UI.panels or {}) do
    if p:IsVisible() and p.Refresh then p:Refresh() end
  end
end

function UI.Open()
  if not (UI.category and _G.Settings and _G.Settings.OpenToCategory) then return false end
  _G.Settings.OpenToCategory(UI.category:GetID())
  return true
end

function UI.Init()
  if UI.panels or not (_G.Settings and _G.Settings.RegisterCanvasLayoutCategory) then return end
  local general, rules, lists, ref = BuildGeneral(), BuildRules(), BuildLists(), BuildReference()
  UI.panels = { general, rules, lists, ref }
  UI.rulesPanel = rules

  local S = _G.Settings
  local main = S.RegisterCanvasLayoutCategory(general, "LootRules")
  S.RegisterCanvasLayoutSubcategory(main, rules, "Rules")
  S.RegisterCanvasLayoutSubcategory(main, lists, "Lists")
  S.RegisterCanvasLayoutSubcategory(main, ref, "Rules reference")
  S.RegisterAddOnCategory(main)
  UI.category = main

  hookLinks()
  ns.OnConfigChanged = UI.Refresh

  -- Item names/prices arrive asynchronously; redraw what's showing.
  local events = CreateFrame("Frame")
  events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
  events:RegisterEvent("CVAR_UPDATE")
  events:SetScript("OnEvent", function() UI.Refresh() end)
end
