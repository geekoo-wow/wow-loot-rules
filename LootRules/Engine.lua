-- Engine.lua — pure rule evaluation. No WoW API calls in here, so it runs
-- unchanged under plain Lua 5.1 in the offline tests.
--
-- A ruleset is an ordered list of rules; the first rule that matches decides.
--
--   { name = "Cheap junk", when = { expr = "quality == POOR and vendorValue * maxStack < silver(1)" }, action = "leave" }
--
-- Every condition in `when` must hold (AND). Each condition evaluates to
-- true, false or nil ("unknown": uncached item data, a secret value, a
-- missing price source...). A rule with any false condition never matches.
-- A rule with no false but at least one unknown condition is "undetermined";
-- by default it is skipped (onUnknown = "skip"), or it can be told to match
-- anyway (onUnknown = "match"). If nothing matches, ruleset.default decides.

local _, ns = ...
ns = ns or {}

local Engine = {}
ns.Engine = Engine

Engine.ACTIONS = { loot = true, leave = true }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Range spec: a number (exact match) or { min = a, max = b } (inclusive,
-- either bound optional). Returns true/false, or nil when the value is unknown.
local function inRange(value, spec)
  if value == nil then return nil end
  if type(spec) == "number" then return value == spec end
  if spec.min ~= nil and value < spec.min then return false end
  if spec.max ~= nil and value > spec.max then return false end
  return true
end

-- Set spec: a single value or an array of values.
local function inSet(value, spec)
  if value == nil then return nil end
  if type(spec) ~= "table" then return value == spec end
  for i = 1, #spec do
    if spec[i] == value then return true end
  end
  return false
end

local function isRange(spec)
  if type(spec) == "number" then return true end
  if type(spec) ~= "table" then return false end
  for k, v in pairs(spec) do
    if (k ~= "min" and k ~= "max") or type(v) ~= "number" then return false end
  end
  return true
end

local function isSet(spec)
  if type(spec) == "number" or type(spec) == "string" then return true end
  if type(spec) ~= "table" or #spec == 0 then return false end
  for _, v in pairs(spec) do
    if type(v) ~= "number" and type(v) ~= "string" then return false end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Condition registry: name -> { check = fn(spec) -> errString|nil,
--                               eval  = fn(spec, ctx) -> true|false|nil }
-- ---------------------------------------------------------------------------

local Conditions = {}
Engine.Conditions = Conditions

local function rangeField(field)
  return {
    field = field, kind = "range",
    check = function(spec) if not isRange(spec) then return "expects a number or {min=,max=}" end end,
    eval = function(spec, ctx) return inRange(ctx[field], spec) end,
  }
end

local function setField(field)
  return {
    field = field, kind = "set",
    check = function(spec) if not isSet(spec) then return "expects a value or a list of values" end end,
    eval = function(spec, ctx) return inSet(ctx[field], spec) end,
  }
end

local function boolField(field)
  return {
    field = field, kind = "bool",
    check = function(spec) if type(spec) ~= "boolean" then return "expects true or false" end end,
    eval = function(spec, ctx)
      local v = ctx[field]
      if v == nil then return nil end
      return (not not v) == spec
    end,
  }
end

Conditions.quality    = rangeField("quality")     -- 0 poor, 1 common, 2 uncommon, 3 rare, 4 epic, 5 legendary
Conditions.vendorValue = rangeField("vendorValue") -- copper, one unit
Conditions.maxStack    = rangeField("maxStack")
Conditions.quantity   = rangeField("quantity")
Conditions.ilvl       = rangeField("ilvl")
Conditions.reqLevel   = rangeField("reqLevel")
Conditions.freeSlots  = rangeField("freeSlots")   -- free bag slots right now
Conditions.owned      = rangeField("owned")       -- how many of this item you already carry
Conditions.itemID     = setField("itemID")
Conditions.classID    = setField("classID")       -- Enum.ItemClass (2 weapon, 4 armor, 7 tradegoods, 15 misc...)
Conditions.subclassID = setField("subclassID")
Conditions.bindType   = setField("bindType")      -- 0 none, 1 BoP, 2 BoE, 3 BoU, 4 quest
Conditions.equipLoc   = setField("equipLoc")
Conditions.quest      = boolField("isQuest")
Conditions.reagent    = boolField("isReagent")

-- list = "blacklist" | { "blacklist", "mylist" }: item is in any of the named lists.
Conditions.list = {
  check = function(spec) if not isSet(spec) then return "expects a list name or a list of names" end end,
  eval = function(spec, ctx)
    if ctx.itemID == nil then return nil end
    local names = type(spec) == "table" and spec or { spec }
    for i = 1, #names do
      if ctx.inList(names[i]) then return true end
    end
    return false
  end,
}

-- name = Lua pattern, matched case-insensitively against the item name.
Conditions.name = {
  check = function(spec)
    if type(spec) ~= "string" then return "expects a Lua pattern string" end
    local ok, err = pcall(string.find, "", spec)
    if not ok then return "bad pattern: " .. tostring(err) end
  end,
  eval = function(spec, ctx)
    local n = ctx.name
    if n == nil then return nil end
    return string.find(string.lower(n), string.lower(spec)) ~= nil
  end,
}

-- ---------------------------------------------------------------------------
-- The rules language: Lua expressions over the item's fields.
--
--   quality <= COMMON and vendorValue * maxStack < silver(5) and freeSlots <= 4
--
-- Compiled once per ruleset build and run in a sandbox that only sees the
-- fields and helpers documented below. A runtime error (usually comparing a
-- field that is unknown/nil) makes the condition unknown rather than false.
-- Fields and Helpers double as the in-game quick reference, so every field
-- the context can load must be listed here.
-- ---------------------------------------------------------------------------

Engine.Fields = {
  { "quality",     "number",  "0 poor, 1 common, 2 uncommon, 3 rare, 4 epic, 5 legendary" },
  { "vendorValue", "number",  "vendor sell price of one unit, in copper" },
  { "maxStack",    "number",  "most units a stack can hold (vendorValue * maxStack = value per bag slot)" },
  { "quantity",    "number",  "how many units dropped (1 on tooltips)" },
  { "name",        "string",  "item name" },
  { "itemID",      "number",  "item ID" },
  { "ilvl",        "number",  "item level" },
  { "reqLevel",    "number",  "required character level" },
  { "classID",     "number",  "0 consumable, 2 weapon, 4 armor, 7 trade goods, 9 recipe, 12 quest, 15 misc" },
  { "subclassID",  "number",  "subclass within classID (e.g. armor: 1 cloth, 2 leather, 3 mail, 4 plate)" },
  { "equipLoc",    "string",  "equip slot, e.g. \"INVTYPE_HEAD\"; \"\" if not equippable" },
  { "bindType",    "number",  "0 none, 1 on pickup, 2 on equip, 3 on use, 4 quest" },
  { "expansionID", "number",  "0 classic, 1 TBC, 2 Wrath, …" },
  { "isQuest",     "boolean", "quest item (from the loot window)" },
  { "isReagent",   "boolean", "crafting reagent" },
  { "freeSlots",   "number",  "free general-purpose bag slots right now" },
  { "owned",       "number",  "how many of this item you already carry" },
}

local ExprHelpers = {
  copper = function(n) return n end,
  silver = function(n) return n * 100 end,
  gold   = function(n) return n * 10000 end,
  -- Case-insensitive Lua pattern match.
  matches = function(s, pattern) return string.find(string.lower(s), string.lower(pattern)) ~= nil end,
  POOR = 0, COMMON = 1, UNCOMMON = 2, RARE = 3, EPIC = 4, LEGENDARY = 5,
  math = math,
}
Engine.ExprHelpers = ExprHelpers

Engine.Helpers = {
  { "inList(\"name\")",         "item is on the named list (\"blacklist\", \"whitelist\")" },
  { "matches(text, \"pattern\")", "case-insensitive Lua pattern match, e.g. matches(name, \"^chipped\")" },
  { "copper(n) silver(n) gold(n)", "money amounts in copper, e.g. vendorValue * maxStack < silver(5)" },
  { "POOR COMMON UNCOMMON RARE EPIC LEGENDARY", "quality constants 0–5" },
  { "math.min math.max math.floor …", "Lua math library" },
}

local KEYWORDS = {
  ["and"] = true, ["or"] = true, ["not"] = true, ["true"] = true, ["false"] = true, ["nil"] = true,
  ["function"] = true, ["end"] = true, ["if"] = true, ["then"] = true, ["else"] = true,
  ["elseif"] = true, ["return"] = true, ["local"] = true, ["do"] = true, ["while"] = true,
  ["for"] = true, ["in"] = true, ["repeat"] = true, ["until"] = true, ["break"] = true,
}

local knownNames = { inList = true }
for _, f in ipairs(Engine.Fields) do knownNames[f[1]] = true end
for k in pairs(ExprHelpers) do knownNames[k] = true end

-- Catch typos like "qualty" at save time; at runtime they'd silently be nil
-- and make the rule "unknown" forever. Crude lexer: drop strings, numbers
-- and member accesses (x.y, x:y), then check the remaining identifiers.
local function unknownIdentifier(src)
  local s = src:gsub('%b""', '""'):gsub("%b''", "''")
  s = s:gsub("0[xX]%x+", "0"):gsub("%d+%.?%d*[eE][%+%-]?%d+", "0"):gsub("%d+%.?%d*", "0")
  s = s:gsub("[%.:]%s*[%a_][%w_]*", "")
  for id in s:gmatch("[%a_][%w_]*") do
    if not KEYWORDS[id] and not knownNames[id] then return id end
  end
end

-- Fields holding money, shown as "1g 2s 3c" when values are displayed.
Engine.MONEY_FIELDS = { vendorValue = true }

-- Fields an expression reads, in order of first appearance.
local isField = {}
for _, f in ipairs(Engine.Fields) do isField[f[1]] = true end

local function referencedFields(src)
  local s = src:gsub('%b""', '""'):gsub("%b''", "''")
  s = s:gsub("[%.:]%s*[%a_][%w_]*", "")
  local out, seen = {}, {}
  for id in s:gmatch("[%a_][%w_]*") do
    if isField[id] and not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  return out
end

-- Fields a rule's `when` reads, in a stable order; used to show only the
-- values that decided an item.
function Engine.FieldsOf(when)
  local keys = {}
  for k in pairs(when or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  local out, seen = {}, {}
  local function add(f)
    if f and not seen[f] then seen[f] = true; out[#out + 1] = f end
  end
  for _, k in ipairs(keys) do
    local cond = Conditions[k]
    if k == "expr" and type(when.expr) == "string" then
      for _, f in ipairs(referencedFields(when.expr)) do add(f) end
    elseif k == "name" then
      add("name")
    elseif cond and cond.field then
      add(cond.field)
    end
  end
  return out
end

local function compileExpr(src)
  local fn, err = loadstring("return (" .. src .. ")", "=condition")
  if not fn then
    return nil, (tostring(err):gsub("^condition:%d+:%s*", ""))
  end
  local bad = unknownIdentifier(src)
  if bad then return nil, "unknown name '" .. bad .. "'" end
  return fn
end
Engine.CompileExpr = compileExpr

Conditions.expr = {
  kind = "expr",
  check = function(spec)
    if type(spec) ~= "string" then return "expects an expression string" end
    local _, err = compileExpr(spec)
    if err then return err end
  end,
  compile = function(spec) return (compileExpr(spec)) end,
  eval = function(compiled, ctx)
    local env = setmetatable({}, {
      __index = function(_, k)
        local h = ExprHelpers[k]
        if h ~= nil then return h end
        if k == "inList" then return ctx.inList end
        return ctx[k]
      end,
      __newindex = function() error("expressions cannot assign", 2) end,
    })
    setfenv(compiled, env)
    local ok, result = pcall(compiled)
    if not ok then return nil end
    return not not result
  end,
}

-- Render a structured `when` table as an equivalent expression, so rules
-- written as tables in SavedVariables can be shown and edited in the UI.
local function literal(v)
  if type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end

function Engine.WhenToExpr(when)
  local keys = {}
  for k in pairs(when or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local spec, cond = when[k], Conditions[k]
    local kind = cond and cond.kind or k
    local f = cond and cond.field
    local p
    if kind == "range" then
      if type(spec) == "number" then
        p = f .. " == " .. spec
      else
        local sub = {}
        if spec.min then sub[#sub + 1] = f .. " >= " .. spec.min end
        if spec.max then sub[#sub + 1] = f .. " <= " .. spec.max end
        p = #sub > 0 and table.concat(sub, " and ") or "true"
      end
    elseif kind == "set" then
      local vals = type(spec) == "table" and spec or { spec }
      local sub = {}
      for i = 1, #vals do sub[i] = f .. " == " .. literal(vals[i]) end
      p = #sub == 1 and sub[1] or "(" .. table.concat(sub, " or ") .. ")"
    elseif kind == "bool" then
      p = spec and f or ("not " .. f)
    elseif k == "list" then
      local names = type(spec) == "table" and spec or { spec }
      local sub = {}
      for i = 1, #names do sub[i] = "inList(" .. literal(names[i]) .. ")" end
      p = #sub == 1 and sub[1] or "(" .. table.concat(sub, " or ") .. ")"
    elseif k == "name" then
      p = "matches(name, " .. literal(spec) .. ")"
    elseif k == "expr" then
      p = #keys == 1 and spec or "(" .. spec .. ")"
    else
      p = "--[[" .. tostring(k) .. "?]] true"
    end
    parts[#parts + 1] = p
  end
  return #parts > 0 and table.concat(parts, " and ") or "true"
end

-- ---------------------------------------------------------------------------
-- Compilation: validate a ruleset once, produce a closure list for evaluation
-- ---------------------------------------------------------------------------

-- Returns compiled, errors. `compiled` is always usable: rules with errors are
-- dropped (and reported) so one typo doesn't disable the whole addon.
function Engine.Compile(ruleset)
  local compiled = { rules = {}, default = "loot" }
  local errors = {}

  if type(ruleset) ~= "table" then
    errors[#errors + 1] = "ruleset is not a table"
    return compiled, errors
  end

  if ruleset.default ~= nil then
    if Engine.ACTIONS[ruleset.default] then
      compiled.default = ruleset.default
    else
      errors[#errors + 1] = "default: unknown action '" .. tostring(ruleset.default) .. "', using 'loot'"
    end
  end

  for i, rule in ipairs(ruleset.rules or {}) do
    local label = string.format("rule %d (%s)", i, tostring(rule.name or "unnamed"))
    local ok = true
    local conds = {}

    if not Engine.ACTIONS[rule.action] then
      errors[#errors + 1] = label .. ": unknown action '" .. tostring(rule.action) .. "'"
      ok = false
    end
    if rule.onUnknown ~= nil and rule.onUnknown ~= "skip" and rule.onUnknown ~= "match" then
      errors[#errors + 1] = label .. ": onUnknown must be 'skip' or 'match'"
      ok = false
    end
    if type(rule.when) ~= "table" then
      errors[#errors + 1] = label .. ": 'when' must be a table"
      ok = false
    else
      -- Sorted keys so evaluation order (and the trace) is deterministic.
      local keys = {}
      for k in pairs(rule.when) do keys[#keys + 1] = k end
      table.sort(keys)
      for _, k in ipairs(keys) do
        local spec = rule.when[k]
        local cond = Conditions[k]
        if not cond then
          errors[#errors + 1] = label .. ": unknown condition '" .. tostring(k) .. "'"
          ok = false
        else
          local err = cond.check(spec)
          if err then
            errors[#errors + 1] = label .. ": " .. (k == "expr" and "condition" or k) .. " " .. err
            ok = false
          else
            conds[#conds + 1] = {
              name = k == "expr" and "condition" or k,
              eval = cond.eval,
              spec = cond.compile and cond.compile(spec) or spec,
            }
          end
        end
      end
    end

    if ok and rule.enabled ~= false then
      compiled.rules[#compiled.rules + 1] = {
        index = i,
        name = rule.name or ("rule " .. i),
        action = rule.action,
        onUnknown = rule.onUnknown or "skip",
        conds = conds,
        fields = Engine.FieldsOf(rule.when),
      }
    end
  end

  return compiled, errors
end

-- ---------------------------------------------------------------------------
-- Evaluation
-- ---------------------------------------------------------------------------

-- Returns action ("loot"|"leave"), decidedBy (rule name or "default"),
-- unknowns (array of "rule: condition" strings that were undetermined, or nil),
-- ruleIndex (position of the deciding rule in the ruleset, nil for default),
-- fields (the fields the deciding rule reads, nil for default).
function Engine.Evaluate(compiled, ctx)
  local unknowns
  for _, rule in ipairs(compiled.rules) do
    local result = true
    local unknownCond
    for _, c in ipairs(rule.conds) do
      local r = c.eval(c.spec, ctx)
      if r == false then
        result = false
        break
      elseif r == nil then
        result = nil
        unknownCond = unknownCond or c.name
      end
    end

    if result == true then
      return rule.action, rule.name, unknowns, rule.index, rule.fields
    elseif result == nil then
      unknowns = unknowns or {}
      unknowns[#unknowns + 1] = rule.name .. ": " .. unknownCond
      if rule.onUnknown == "match" then
        return rule.action, rule.name, unknowns, rule.index, rule.fields
      end
    end
  end
  return compiled.default, "default", unknowns, nil
end

return Engine
