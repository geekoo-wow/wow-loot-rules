-- tests/mock_wow.lua — just enough of the WoW API to run LootRules offline.
-- Tests describe items and loot windows as plain data; the mock records what
-- the addon did (looted slots, closed window, confirmed BoP prompts).

local M = {}

M.items = {}      -- [itemID] = { name, quality, ilvl, reqLevel, maxStack, sellPrice, classID, subclassID, bindType, isReagent, cached }
M.bags = { free = 20 }
M.bagItems = {}   -- [bag] = { [slot] = { id = n, count = n } }
M.owned = {}      -- [itemID] = count
M.cvars = { autoLootDefault = "0" }
M.keys = {}       -- modifier keys held down: SHIFT / CTRL / ALT = true
M.modifiedClicks = { AUTOLOOTTOGGLE = "SHIFT" }
M.secret = {}     -- values in here are "secret"

function M.reset()
  M.items, M.owned, M.secret = {}, {}, {}
  M.bags = { free = 20 }
  M.bagItems = {}
  M.tooltipPostCalls = {}
  M.cvars = { autoLootDefault = "0" }
  M.keys = {}
  M.modifiedClicks = { AUTOLOOTTOGGLE = "SHIFT" }
  M.window = { slots = {} }
  M.looted, M.closed, M.confirmed, M.popupsHidden, M.printed = {}, 0, {}, {}, {}
  M.widgets, M.categories, M.hooks, M.opened, M.cursor = {}, {}, {}, nil, nil
end
M.reset()

function M.item(id, t)
  t.id = id
  if t.cached == nil then t.cached = true end
  M.items[id] = t
  return M.link(id)
end

function M.link(id)
  local t = M.items[id]
  return string.format("|cffffffff|Hitem:%d::::::::|h[%s]|h|r", id, t and t.name or ("Item" .. id))
end

-- slots: array of { money = n } | { currency = true } | { id = n, qty = n, locked = b, quest = b }
function M.openLoot(slots)
  M.window = { slots = slots }
  M.looted, M.closed, M.confirmed, M.popupsHidden = {}, 0, {}, {}
end

-- ---- globals --------------------------------------------------------------

_G.Enum = {
  LootSlotType = { None = 0, Item = 1, Money = 2, Currency = 3 },
  TooltipDataType = { Item = 0 },
}
_G.NUM_BAG_SLOTS = 4

function _G.wipe(t) for k in pairs(t) do t[k] = nil end return t end

function _G.GetNumLootItems() return #M.window.slots end

function _G.GetLootSlotType(slot)
  local s = M.window.slots[slot]
  if not s then return 0 end
  if s.money then return 2 end
  if s.currency then return 3 end
  return 1
end

function _G.GetLootSlotInfo(slot)
  local s = M.window.slots[slot]
  local t = s and s.id and M.items[s.id]
  if not t then return nil end
  return "icon", t.name, s.qty or 1, nil, t.quality, s.locked or false, s.quest or false, nil, true, false
end

function _G.GetLootSlotLink(slot)
  local s = M.window.slots[slot]
  return s and s.id and M.link(s.id)
end

function _G.LootSlot(slot) M.looted[#M.looted + 1] = slot end
function _G.CloseLoot() M.closed = M.closed + 1 end
function _G.ConfirmLootSlot(slot) M.confirmed[#M.confirmed + 1] = slot end
function _G.StaticPopup_Hide(which) M.popupsHidden[#M.popupsHidden + 1] = which end

local function resolve(item)
  local id = type(item) == "number" and item or tonumber(tostring(item):match("item:(%d+)"))
  return id, id and M.items[id]
end

_G.C_Item = {}

-- Like the game, these raise an error when called without an item.
function _G.C_Item.GetItemInfo(item)
  assert(item ~= nil, "Usage: C_Item.GetItemInfo(itemInfo)")
  local _, t = resolve(item)
  if not t or not t.cached then return nil end
  return t.name, M.link(t.id), t.quality, t.ilvl or 1, t.reqLevel or 0, "Type", "SubType", t.maxStack or 1,
    t.equipLoc or "", "icon", t.sellPrice, t.classID or 15, t.subclassID or 0, t.bindType or 0, 0, nil, t.isReagent or false
end

function _G.C_Item.GetItemInfoInstant(item)
  assert(item ~= nil, "Usage: C_Item.GetItemInfoInstant(itemInfo)")
  local id, t = resolve(item)
  if not id then return nil end
  t = t or {}
  return id, "Type", "SubType", t.equipLoc or "", "icon", t.classID or 15, t.subclassID or 0
end

function _G.C_Item.GetItemCount(id) return M.owned[id] or 0 end

_G.C_Container = {}
function _G.C_Container.GetContainerNumFreeSlots(bag)
  if bag == 0 then return M.bags.free, 0 end
  return 0, 0
end
function _G.C_Container.GetContainerNumSlots(bag)
  local slots = M.bagItems[bag]
  if not slots then return 0 end
  local n = 0
  for slot in pairs(slots) do if slot > n then n = slot end end
  return n
end
function _G.C_Container.GetContainerItemInfo(bag, slot)
  local e = M.bagItems[bag] and M.bagItems[bag][slot]
  if not e then return nil end
  local t = M.items[e.id] or {}
  return { itemID = e.id, hyperlink = M.link(e.id), stackCount = e.count or 1, iconFileID = 1, quality = t.quality }
end

function _G.issecretvalue(v) return M.secret[v] == true end

function _G.GetCVarBool(name) return M.cvars[name] == "1" end
function _G.SetCVar(name, v) M.cvars[name] = tostring(v) end

function _G.IsShiftKeyDown() return M.keys.SHIFT == true end
function _G.IsControlKeyDown() return M.keys.CTRL == true end
function _G.IsAltKeyDown() return M.keys.ALT == true end
function _G.GetModifiedClick(action) return M.modifiedClicks[action] or "NONE" end

_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) M.printed[#M.printed + 1] = msg end }

-- Widgets: a permissive stub. Known getters return stored state; every other
-- method is a no-op, so the UI can be built offline to catch nil-call and
-- typo errors (layout itself can only be checked in game).
local Widget = {}
local noop = function() end
local widgetMT = { __index = function(_, k) return Widget[k] or noop end }

local function newWidget(kind)
  return setmetatable({ kind = kind, events = {}, scripts = {}, text = "", shown = true }, widgetMT)
end
M.widgets = {}

function Widget:RegisterEvent(e) self.events[e] = true end
function Widget:UnregisterEvent(e) self.events[e] = nil end
function Widget:SetScript(name, fn) self.scripts[name] = fn; if name == "OnEvent" then self.handler = fn end end
function Widget:HookScript(name, fn) self.scripts[name] = self.scripts[name] or fn end
function Widget:GetScript(name) return self.scripts[name] end
function Widget:Fire(event, ...) if self.events[event] then self.handler(self, event, ...) end end
function Widget:Click(...) local fn = self.scripts.OnClick; if fn then fn(self, ...) end end
function Widget:SetText(t)
  self.text = t == nil and "" or tostring(t)
  local fn = self.scripts.OnTextChanged
  if fn then fn(self, false) end
end
function Widget:GetText() return self.text end
function Widget:SetChecked(v) self.checked = v and true or false end
function Widget:GetChecked() return self.checked end
function Widget:Show() self.shown = true end
function Widget:Hide() self.shown = false end
function Widget:SetShown(v) self.shown = v and true or false end
function Widget:IsShown() return self.shown end
function Widget:IsVisible() return self.shown end
function Widget:HasFocus() return self.focused == true end
function Widget:SetFocus() self.focused = true end
function Widget:ClearFocus() self.focused = false end
function Widget:Enable() self.enabled = true end
function Widget:Disable() self.enabled = false end
function Widget:GetStringHeight() return 12 end
function Widget:CreateFontString() return newWidget("FontString") end
function Widget:CreateTexture() return newWidget("Texture") end

function _G.CreateFrame(kind)
  local w = newWidget(kind)
  M.widgets[#M.widgets + 1] = w
  return w
end

_G.GameTooltip = newWidget("GameTooltip")
_G.ItemRefTooltip = newWidget("ItemRefTooltip")
_G.UIParent = newWidget("UIParent")

-- Tooltips: M.tooltipItem is what the tooltip is showing; AddLine is recorded.
function Widget:GetItem() local id = M.tooltipItem; if id then return "name", M.link(id), id end end
function Widget:AddLine(text) self.lines = rawget(self, "lines") or {}; self.lines[#self.lines + 1] = text end
_G.TooltipDataProcessor = {
  AddTooltipPostCall = function(kind, fn) M.tooltipPostCalls[#M.tooltipPostCalls + 1] = { kind = kind, fn = fn } end,
}
function M.showTooltip(tooltip, id)
  M.tooltipItem = id
  tooltip.lines = {}
  for _, pc in ipairs(M.tooltipPostCalls) do pc.fn(tooltip, { id = id }) end
  return tooltip.lines
end
_G.ChatFontNormal = {}
function _G.GetTime() return M.now or 0 end
function _G.GetCursorInfo() return M.cursor and "item" or nil, M.cursor, M.cursor and M.link(M.cursor) end
function _G.ClearCursor() M.cursor = nil end
M.hooks = {}
function _G.hooksecurefunc(a, b, c)
  local name, fn = a, b
  if type(a) == "table" then name, fn = b, c end
  M.hooks[name] = fn
end

-- Settings API (canvas categories).
_G.Settings = {}
M.categories = {}
function _G.Settings.RegisterCanvasLayoutCategory(frame, name)
  local cat = { frame = frame, name = name, GetID = function() return name end }
  M.categories[name] = cat
  return cat
end
function _G.Settings.RegisterCanvasLayoutSubcategory(_, frame, name)
  return _G.Settings.RegisterCanvasLayoutCategory(frame, name)
end
function _G.Settings.RegisterAddOnCategory() end
function _G.Settings.OpenToCategory(id) M.opened = id end
_G.ChatEdit_InsertLink = function() return false end

return M
