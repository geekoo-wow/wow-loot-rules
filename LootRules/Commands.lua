-- Commands.lua — /lr (alias /lootrules). Configuration lives in the settings
-- panel; the slash command only opens it and flips the quick toggles.

local _, ns = ...
ns = ns or {}

local Commands = {}
ns.Commands = Commands

local function onOff(v) return v and "|cff55ff55on|r" or "|cffff5555off|r" end

local TOGGLES = {
  debug = { key = "debug", label = "debug output" },
  dry   = { key = "dryRun", label = "dry run" },
  tooltip = { key = "tooltip", label = "tooltip line" },
}

function Commands.Run(msg)
  local cmd = ((msg or ""):match("^%s*(%S*)") or ""):lower()
  if cmd == "" or cmd == "config" or cmd == "options" then
    if ns.UI and ns.UI.Open() then return end
    ns.Print("settings panel unavailable")
  elseif TOGGLES[cmd] then
    local t = TOGGLES[cmd]
    ns.Config.Set(t.key, not ns.Config.Get(t.key))
    ns.Print(t.label .. " " .. onOff(ns.Config.Get(t.key)))
  elseif cmd == "on" or cmd == "off" then
    ns.Config.Set("enabled", cmd == "on")
    ns.Print("filtering " .. onOff(ns.Config.Get("enabled")))
  else
    ns.Print("/lr — open settings; /lr debug | dry | tooltip | on | off — quick toggles")
  end
end

function Commands.Init()
  _G.SLASH_LOOTRULES1 = "/lr"
  _G.SLASH_LOOTRULES2 = "/lootrules"
  _G.SlashCmdList = _G.SlashCmdList or {}
  _G.SlashCmdList.LOOTRULES = Commands.Run
end
