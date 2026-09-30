-- Tooltip.lua — adds the rules' decision to item tooltips, so you can check
-- what LootRules would do with any item by hovering it: in bags, chat links,
-- vendors, the auction house.

local _, ns = ...
ns = ns or {}

local Tooltip = {}
ns.Tooltip = Tooltip

local function isSecret(v)
  return _G.issecretvalue ~= nil and v ~= nil and _G.issecretvalue(v)
end

-- Only the main tooltip and clicked chat links; comparison tooltips would
-- just repeat the line.
local function wanted(tooltip)
  return tooltip == _G.GameTooltip or tooltip == _G.ItemRefTooltip
end

function Tooltip.OnItem(tooltip, data)
  if not wanted(tooltip) then return end
  local link
  if tooltip.GetItem then
    local _, l = tooltip:GetItem()
    link = l
  end
  if isSecret(link) then return end
  if not link and type(data) == "table" and not isSecret(data.id) and type(data.id) == "number" then
    link = "item:" .. data.id
  end
  if type(link) ~= "string" then return end
  local line, values = ns.Config.TooltipLine(link)
  if line then tooltip:AddLine(line) end
  if values then tooltip:AddLine("    " .. values) end
end

function Tooltip.Init()
  local tdp = _G.TooltipDataProcessor
  local itemType = _G.Enum and _G.Enum.TooltipDataType and _G.Enum.TooltipDataType.Item
  if tdp and tdp.AddTooltipPostCall and itemType then
    tdp.AddTooltipPostCall(itemType, Tooltip.OnItem)
  elseif _G.GameTooltip and _G.GameTooltip.HookScript then
    -- Older clients: the pre-TooltipData script hook.
    _G.GameTooltip:HookScript("OnTooltipSetItem", function(tt) Tooltip.OnItem(tt) end)
  end
end
