-- Context.lua — builds the per-item context the rule engine reads.
--
-- Fields are loaded lazily through __index: cheap loot-slot data is read
-- up front, while item-cache data, bag scans and item counts are only
-- fetched the first time a rule actually reads them. Anything we can't
-- know yet (uncached item, secret value) is left nil = "unknown".

local _, ns = ...
ns = ns or {}

local Context = {}
ns.Context = Context

-- WoW API access goes through this table so tests can swap it out and so the
-- C_Item / legacy global differences live in one place.
local API = {}
Context.API = API

local function pick(ns_, name, global)
  return function(...)
    local t = _G[ns_]
    local f = (t and t[name]) or _G[global]
    if f then return f(...) end
  end
end

API.GetItemInfo        = pick("C_Item", "GetItemInfo", "GetItemInfo")
API.GetItemInfoInstant = pick("C_Item", "GetItemInfoInstant", "GetItemInfoInstant")
API.GetItemCount       = pick("C_Item", "GetItemCount", "GetItemCount")
API.GetContainerNumFreeSlots = pick("C_Container", "GetContainerNumFreeSlots", "GetContainerNumFreeSlots")
API.GetContainerNumSlots     = pick("C_Container", "GetContainerNumSlots", "GetContainerNumSlots")
API.GetContainerItemInfo     = pick("C_Container", "GetContainerItemInfo", "GetContainerItemInfo")

-- Midnight-era "secret values": opaque during combat, can't be compared.
-- Treat them as unknown so rules degrade gracefully instead of erroring.
local function clean(v)
  local isSecret = _G.issecretvalue
  if isSecret and v ~= nil and isSecret(v) then return nil end
  return v
end

local function itemIDFromLink(link)
  if type(link) ~= "string" then return nil end
  return tonumber(link:match("item:(%d+)"))
end
Context.ItemIDFromLink = itemIDFromLink

local function countFreeSlots()
  local total, known = 0, false
  local numBags = _G.NUM_BAG_SLOTS or 4
  for bag = 0, numBags do
    local free, bagType = API.GetContainerNumFreeSlots(bag)
    free, bagType = clean(free), clean(bagType)
    -- bagType 0 = general-purpose bag; profession bags only take their own items.
    if free and (bagType == nil or bagType == 0) then
      total = total + free
      known = true
    end
  end
  return known and total or nil
end

-- Lazy loaders: each fills one or more ctx fields via rawset.
local loaders = {}

local function loadInstant(ctx)
  local item = ctx.link or ctx.itemID
  if item == nil then return end -- the game API raises an error on nil
  local id, _, _, equipLoc, _, classID, subclassID = API.GetItemInfoInstant(item)
  rawset(ctx, "classID", clean(classID))
  rawset(ctx, "subclassID", clean(subclassID))
  rawset(ctx, "equipLoc", clean(equipLoc))
  if rawget(ctx, "itemID") == nil then rawset(ctx, "itemID", clean(id)) end
end

local function loadInfo(ctx)
  local item = ctx.link or ctx.itemID
  if item == nil then return end
  local name, _, quality, ilvl, reqLevel, _, _, maxStack, _, _, unitPrice,
        _, _, bindType, expansionID, _, isReagent = API.GetItemInfo(item)
  if name == nil then return end -- not cached yet: everything stays unknown
  if rawget(ctx, "name") == nil then rawset(ctx, "name", clean(name)) end
  if rawget(ctx, "quality") == nil then rawset(ctx, "quality", clean(quality)) end
  rawset(ctx, "ilvl", clean(ilvl))
  rawset(ctx, "reqLevel", clean(reqLevel))
  rawset(ctx, "maxStack", clean(maxStack))
  rawset(ctx, "vendorValue", clean(unitPrice))
  rawset(ctx, "bindType", clean(bindType))
  rawset(ctx, "expansionID", clean(expansionID))
  rawset(ctx, "isReagent", clean(isReagent))
end

loaders.classID, loaders.subclassID, loaders.equipLoc = loadInstant, loadInstant, loadInstant
for _, f in ipairs({ "ilvl", "reqLevel", "maxStack", "vendorValue", "bindType", "expansionID", "isReagent", "name", "quality" }) do
  loaders[f] = loadInfo
end

loaders.freeSlots = function(ctx)
  rawset(ctx, "freeSlots", countFreeSlots())
end

loaders.owned = function(ctx)
  if ctx.itemID then rawset(ctx, "owned", clean(API.GetItemCount(ctx.itemID))) end
end

-- The bags loot lands in: the backpack and the equipped bags, plus the
-- reagent bag on clients that have one.
local function bagIndices()
  local lastBag = _G.NUM_BAG_SLOTS or 4
  local reagentBag = _G.Enum and _G.Enum.BagIndex and _G.Enum.BagIndex.ReagentBag
  local bags = {}
  for bag = 0, lastBag do bags[#bags + 1] = bag end
  if reagentBag and reagentBag > lastBag then bags[#bags + 1] = reagentBag end
  return bags
end

-- How many more units of the item fit into the stacks of it already in the
-- bags, i.e. what can be looted without taking a new slot: loot joins a
-- partial stack before it takes an empty slot, in any bag, so every bag is
-- scanned. 0 when no stack of it is carried, which needs no item data.
-- Unknown when a slot can't be read (secret values): a stack we can't see
-- could absorb the drop, and guessing would get it left behind.
local function countStackRoom(ctx)
  local id = ctx.itemID
  if id == nil then return nil end
  local room = 0
  for _, bag in ipairs(bagIndices()) do
    local numSlots = clean(API.GetContainerNumSlots(bag))
    if numSlots == nil then return nil end
    for slot = 1, numSlots do
      local info = API.GetContainerItemInfo(bag, slot) -- nil: an empty slot
      if info ~= nil then
        local slotID = type(info) == "table" and clean(info.itemID) or nil
        if slotID == nil then return nil end
        if slotID == id then
          local count, maxStack = clean(info.stackCount), ctx.maxStack
          if count == nil or maxStack == nil then return nil end
          room = room + math.max(0, maxStack - count)
        end
      end
    end
  end
  return room
end

loaders.stackRoom = function(ctx)
  rawset(ctx, "stackRoom", countStackRoom(ctx))
end

-- Loot slots set isQuest directly, so this runs for previews (tooltips, the
-- tester) and for slots whose flag was secret. Items of the Quest class are
-- definitely quest items. For anything else (quest starters, quest-flagged
-- drops) only a loot slot can tell: a slot leaves it unknown, while a preview
-- assumes "not a quest item", the same way it assumes a quantity of 1.
local QUEST_CLASS = 12 -- Enum.ItemClass.Questitem

loaders.isQuest = function(ctx)
  local classID = ctx.classID
  if classID == QUEST_CLASS then
    rawset(ctx, "isQuest", true)
  elseif classID ~= nil and rawget(ctx, "preview") then
    rawset(ctx, "isQuest", false)
  end
end

-- Marks which lazy fields have already been attempted, so an unknown field
-- doesn't re-run its loader on every read.
local attempted = setmetatable({}, { __mode = "k" })

local mt = {
  __index = function(ctx, key)
    local loader = loaders[key]
    if not loader then return nil end
    local tried = attempted[ctx]
    if not tried then tried = {}; attempted[ctx] = tried end
    if tried[loader] then return rawget(ctx, key) end
    tried[loader] = true
    loader(ctx)
    return rawget(ctx, key)
  end,
}

local function finish(ctx, lists)
  ctx.inList = function(listName)
    local list = lists and lists[listName]
    return list ~= nil and ctx.itemID ~= nil and list[ctx.itemID] == true
  end
  return setmetatable(ctx, mt)
end

-- Context for an open loot-window slot.
function Context.FromLootSlot(slot, lists)
  local _, name, quantity, _, quality, locked, isQuest, questID = GetLootSlotInfo(slot)
  local link = GetLootSlotLink(slot)
  local ctx = {
    slot = slot,
    link = clean(link),
    name = clean(name),
    quantity = clean(quantity),
    quality = clean(quality),
    locked = clean(locked),
    isQuest = clean(isQuest),
    questID = clean(questID),
  }
  ctx.itemID = itemIDFromLink(ctx.link)
  return finish(ctx, lists)
end

-- Context for an arbitrary item link: item tooltips and the tester. There is
-- no loot slot behind it, so it is a preview: what dropped is assumed
-- (`quantity`, default 1, and see loaders.isQuest).
function Context.FromLink(link, quantity, lists)
  local ctx = {
    preview = true,
    link = link,
    itemID = itemIDFromLink(link),
    quantity = quantity or 1,
  }
  return finish(ctx, lists)
end

-- Everything in the player's bags, one entry per bag slot:
-- { itemID, link, count, icon, quality }. Secret or missing entries are skipped.
function Context.ScanBags()
  local out = {}
  for _, bag in ipairs(bagIndices()) do
    for slot = 1, clean(API.GetContainerNumSlots(bag)) or 0 do
      local info = API.GetContainerItemInfo(bag, slot)
      if type(info) == "table" then
        local link, id = clean(info.hyperlink), clean(info.itemID)
        if link and id then
          out[#out + 1] = {
            itemID = id, link = link,
            count = clean(info.stackCount) or 1,
            icon = clean(info.iconFileID),
            quality = clean(info.quality),
          }
        end
      end
    end
  end
  return out
end

return Context
