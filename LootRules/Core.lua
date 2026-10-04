-- Core.lua — namespace, defaults, SavedVariables and output.

local ADDON, ns = ...
ns = ns or {}
ns.name = ADDON or "LootRules"

-- Default configuration. Kept in code (not only in SavedVariables) because the
-- Forever beta currently fails to load SavedVariables at startup; with these
-- defaults the addon still does something sensible after every restart.
ns.DEFAULTS = {
  version = 5,
  enabled = true,
  dryRun = false,        -- evaluate and print decisions, but loot everything
  debug = false,         -- print every decision, with the rule that made it
  closeWhenDone = true,  -- close the window once our picks are looted, leaving the rest on the corpse
  confirmBoP = true,     -- auto-confirm bind-on-pickup prompts for slots *we* chose to loot
  tooltip = true,        -- show the rules' decision on item tooltips
  lists = {
    blacklist = {},      -- [itemID] = true
    whitelist = {},
  },
  ruleset = {
    default = "loot",
    rules = {
      { name = "Blacklist",   when = { expr = 'inList("blacklist")' }, action = "leave" },
      { name = "Whitelist",   when = { expr = 'inList("whitelist")' }, action = "loot" },
      { name = "Quest items", when = { expr = "isQuest" },             action = "loot" },
      -- Judged by what a full stack is worth, i.e. what the item is worth per
      -- bag slot, so the outcome doesn't depend on how many happened to drop.
      { name = "Cheap junk",
        when = { expr = "quality == POOR and vendorValue * maxStack < silver(1)" },
        action = "leave" },
      { name = "Tight bags",
        when = { expr = "quality <= COMMON and vendorValue * maxStack < silver(5) and freeSlots <= 4" },
        action = "leave" },
    },
  },
}

local function deepCopy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deepCopy(x) end
  return out
end
ns.DeepCopy = deepCopy

-- Fill in missing keys from defaults without clobbering user settings; a
-- table setting that isn't a table (hand-edited SavedVariables) counts as
-- missing. The ruleset is treated as one unit: if the user has one, it's theirs.
local function mergeDefaults(db, defaults)
  for k, v in pairs(defaults) do
    if db[k] == nil or (type(v) == "table" and type(db[k]) ~= "table") then
      db[k] = deepCopy(v)
    elseif type(v) == "table" and k ~= "ruleset" then
      mergeDefaults(db[k], v)
    end
  end
end

-- SavedVariables can be written by hand. What is wrong with a rule is
-- Engine.Compile's to report; this only establishes the shape the migration
-- and the settings UI rely on: a list of rule tables, each with a name.
local function normalizeRules(db)
  local ruleset = db.ruleset
  if type(ruleset) ~= "table" then
    db.ruleset = nil -- the defaults fill it in
    return
  end
  if type(ruleset.rules) ~= "table" then ruleset.rules = {} end
  local rules = ruleset.rules
  for i = #rules, 1, -1 do
    if type(rules[i]) ~= "table" then table.remove(rules, i) end
  end
  for i, rule in ipairs(rules) do
    if type(rule.name) ~= "string" then rule.name = "Rule " .. i end
  end
end

local function deepEqual(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- Earlier versions of the default rules. Unedited copies are upgraded to
-- the current defaults.
local OLD_DEFAULTS = {
  ["Cheap junk"] = {
    { quality = { max = 0 }, stackValue = { max = 100 } },            -- v1
    { expr = "quality == POOR and stackValue < silver(1)" },          -- v2
    { expr = "quality == POOR and stackVendorPrice < silver(1)" },    -- v3-v4
  },
  ["Tight bags"] = {
    { quality = { max = 1 }, stackValue = { max = 499 }, freeSlots = { max = 4 } },
    { expr = "quality <= COMMON and stackValue < silver(5) and freeSlots <= 4" },
    { expr = "quality <= COMMON and stackVendorPrice < silver(5) and freeSlots <= 4" },
  },
}

-- Fields that no longer exist, and what replaces them in saved rules. Each
-- is rewritten as its own definition, so old rules behave exactly as before.
--   sellPrice (v1-v2), unitVendorPrice (v3-v4)  -> vendorValue
--   stackVendorPrice (v3-v4)                    -> vendorValue * maxStack
--   stackValue (v1-v2), lootVendorPrice (v3)    -> vendorValue * quantity
local SLOT_VALUE = "(vendorValue * maxStack)"
local DROP_VALUE = "(vendorValue * quantity)"
local EXPR_REWRITES = {
  sellPrice = "vendorValue",
  unitVendorPrice = "vendorValue",
  stackVendorPrice = SLOT_VALUE,
  stackValue = DROP_VALUE,
  lootVendorPrice = DROP_VALUE,
}
local STRUCTURED_TO_EXPR = {
  stackVendorPrice = SLOT_VALUE,
  stackValue = DROP_VALUE,
  lootVendorPrice = DROP_VALUE,
}

local function rewriteFields(when)
  for _, old in ipairs({ "sellPrice", "unitVendorPrice" }) do
    if when[old] ~= nil then
      if when.vendorValue == nil then when.vendorValue = when[old] end
      when[old] = nil
    end
  end

  if type(when.expr) == "string" then
    for old, new in pairs(EXPR_REWRITES) do
      when.expr = when.expr:gsub("%f[%w_]" .. old .. "%f[^%w_]", new)
    end
  end

  -- Structured conditions on computed values have no structured replacement,
  -- so the whole rule becomes an expression.
  local terms = {}
  local keys = {}
  for key in pairs(STRUCTURED_TO_EXPR) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local spec, value = when[key], STRUCTURED_TO_EXPR[key]
    if spec ~= nil then
      when[key] = nil
      if type(spec) == "number" then
        terms[#terms + 1] = value .. " == " .. spec
      elseif type(spec) == "table" then
        if spec.min then terms[#terms + 1] = value .. " >= " .. spec.min end
        if spec.max then terms[#terms + 1] = value .. " <= " .. spec.max end
      end
    end
  end
  if #terms > 0 then
    -- WhenToExpr returns a lone expression as written; ANDed with the new
    -- terms it needs parentheses (it may contain an `or`).
    local loneExpr = when.expr ~= nil and next(when, next(when)) == nil
    local rest = ns.Engine.WhenToExpr(when)
    if loneExpr then rest = ns.Engine.Parenthesize(rest) end
    local expr = table.concat(terms, " and ")
    if rest ~= "true" then expr = rest .. " and " .. expr end
    for k in pairs(when) do when[k] = nil end
    when.expr = expr
  end
end

local function migrate(db)
  if db.verbose ~= nil then -- v1: "verbose" printed only leave decisions
    if db.debug == nil then db.debug = db.verbose end
    db.verbose = nil
  end

  local rules = db.ruleset and db.ruleset.rules
  if type(rules) == "table" and (db.version or 1) < 5 then
    local current = {}
    for _, r in ipairs(ns.DEFAULTS.ruleset.rules) do current[r.name] = r end
    for _, rule in ipairs(rules) do
      if type(rule.when) == "table" then
        local upgraded = false
        for _, old in ipairs(OLD_DEFAULTS[rule.name] or {}) do
          if deepEqual(rule.when, old) then
            rule.when = deepCopy(current[rule.name].when)
            upgraded = true
            break
          end
        end
        if not upgraded then rewriteFields(rule.when) end
      end
    end
  end

  db.version = ns.DEFAULTS.version
end

function ns.InitDB()
  if type(_G.LootRulesDB) ~= "table" then _G.LootRulesDB = {} end
  local db = _G.LootRulesDB
  normalizeRules(db)
  migrate(db)
  mergeDefaults(db, ns.DEFAULTS)
  ns.db = db
  ns.Rebuild()
  return db
end

-- Recompile the ruleset; call after any rule change.
function ns.Rebuild()
  local compiled, errors = ns.Engine.Compile(ns.db.ruleset)
  ns.compiled = compiled
  ns.compileErrors = errors
  for _, e in ipairs(errors) do ns.Print("|cffff5555rule error:|r " .. e) end
  if ns.OnRulesChanged then ns.OnRulesChanged() end
  return errors
end

function ns.ResetRules()
  ns.db.ruleset = deepCopy(ns.DEFAULTS.ruleset)
  return ns.Rebuild()
end

function ns.Print(msg)
  local frame = _G.DEFAULT_CHAT_FRAME
  local line = "|cff33ccffLootRules|r: " .. tostring(msg)
  if frame then frame:AddMessage(line) else print(line) end
end

-- Debug output, printed only in debug mode (or when forced, e.g. dry run).
function ns.Debug(msg, force)
  if force or (ns.db and ns.db.debug) then ns.Print("|cff999999" .. tostring(msg) .. "|r") end
end

-- "quality 0, vendorValue 9c, maxStack 10": the values of the fields a rule
-- reads, for debug lines, tooltips and the tester. Unknown values show "?".
function ns.FormatValues(ctx, fields)
  if not fields or #fields == 0 then return nil end
  local parts = {}
  for _, f in ipairs(fields) do
    local v = ctx[f]
    local shown
    if v == nil then
      shown = "?"
    elseif ns.Engine.MONEY_FIELDS[f] and type(v) == "number" then
      shown = ns.FormatMoney(v)
    elseif type(v) == "string" then
      shown = string.format("%q", v)
    else
      shown = tostring(v)
    end
    parts[#parts + 1] = f .. " " .. shown
  end
  return table.concat(parts, ", ")
end

function ns.FormatMoney(c)
  if c == nil then return "?" end
  local g, s, cc = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
  if g > 0 then return string.format("%dg %ds %dc", g, s, cc) end
  if s > 0 then return string.format("%ds %dc", s, cc) end
  return cc .. "c"
end

-- "#4 Cheap junk" / "no rule matched (default)"
function ns.DescribeDecider(ruleName, ruleIndex)
  if ruleIndex then return string.format("#%d %s", ruleIndex, ruleName) end
  return "no rule matched (default)"
end
