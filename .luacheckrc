std = "lua51"
max_line_length = 140
codes = true
self = false -- unused self in methods and script handlers is normal WoW style

-- WoW API used by the addon.
read_globals = {
  "C_Item", "C_Container", "Enum", "NUM_BAG_SLOTS", "DEFAULT_CHAT_FRAME",
  "CreateFrame", "GetCVarBool", "SetCVar", "wipe", "issecretvalue",
  "GetNumLootItems", "GetLootSlotType", "GetLootSlotInfo", "GetLootSlotLink",
  "LootSlot", "CloseLoot", "ConfirmLootSlot", "StaticPopup_Hide",
  "GetItemInfo", "GetItemInfoInstant", "GetItemCount", "GetContainerNumFreeSlots",
  "GameTooltip", "GetTime", "hooksecurefunc", "GetCursorInfo", "ClearCursor", "ChatFontNormal",
  "Settings", "ChatEdit_InsertLink", "ChatFrameUtil",
}

globals = { "LootRulesDB", "SlashCmdList", "SLASH_LOOTRULES1", "SLASH_LOOTRULES2" }

files["tests/"] = {
  -- The mock defines the WoW API.
  globals = { "_G" },
  allow_defined_top = true,
  ignore = { "111", "112", "121", "122" },
}
