-- Config.lua — the operations the settings UI performs on the saved config.
-- Kept free of widget code so it can be tested offline; UI.lua only renders
-- and calls into this.

local _, ns = ...
ns = ns or {}

local Config = {}
ns.Config = Config

local function rules() return ns.db.ruleset.rules end

-- ---- settings ---------------------------------------------------------------

-- The on/off settings: every boolean in ns.DEFAULTS (enabled, dryRun, debug,
-- closeWhenDone, confirmBoP, tooltip).
function Config.Get(key) return ns.db[key] end

function Config.Set(key, value)
  if type(ns.DEFAULTS[key]) ~= "boolean" then return end
  ns.db[key] = value and true or false
  ns.ConfigChanged()
end

-- The key that keeps the loot window open when held as it opens: one of
-- ns.MODIFIERS, "NONE" for no key.
function Config.KeepOpenModifier() return ns.db.keepOpenModifier end

function Config.SetKeepOpenModifier(key)
  if not ns.MODIFIER_LABELS[key] then return end
  ns.db.keepOpenModifier = key
  ns.ConfigChanged()
end

-- Switch to the next choice in ns.MODIFIERS, wrapping around.
function Config.CycleKeepOpenModifier()
  local keys = ns.MODIFIERS
  local at = 0
  for i, key in ipairs(keys) do
    if key == ns.db.keepOpenModifier then at = i end
  end
  Config.SetKeepOpenModifier(keys[at % #keys + 1])
end

function Config.ModifierLabel(key) return ns.MODIFIER_LABELS[key] or ns.MODIFIER_LABELS.NONE end

-- ---- rules ------------------------------------------------------------------

function Config.Rules() return rules() end

-- The expression shown in the editor for a rule, whatever form it's stored in.
function Config.RuleExpr(rule)
  local when = type(rule.when) == "table" and rule.when or {}
  if type(when.expr) == "string" and next(when, next(when)) == nil then return when.expr end
  return ns.Engine.WhenToExpr(when)
end

-- Validation error for an expression, or nil if it compiles.
function Config.Validate(expr)
  if type(expr) ~= "string" or expr:match("^%s*$") then return "the condition is empty" end
  local _, err = ns.Engine.CompileExpr(expr)
  return err
end

-- fields: { name = , action = , expr = , onUnknown = } (any subset).
-- Returns an error string without changing anything if the input is invalid.
function Config.UpdateRule(i, fields)
  local rule = rules()[i]
  if not rule then return "no such rule" end
  if fields.action ~= nil and not ns.Engine.ACTIONS[fields.action] then return "unknown action" end
  if fields.onUnknown ~= nil and fields.onUnknown ~= "skip" and fields.onUnknown ~= "match" then
    return "onUnknown must be 'skip' or 'match'"
  end
  if fields.expr ~= nil then
    local err = Config.Validate(fields.expr)
    if err then return err end
  end
  if fields.name ~= nil then
    local n = fields.name:match("^%s*(.-)%s*$")
    rule.name = n ~= "" and n or ("Rule " .. i)
  end
  if fields.action ~= nil then rule.action = fields.action end
  if fields.expr ~= nil then rule.when = { expr = fields.expr } end
  if fields.onUnknown ~= nil then rule.onUnknown = fields.onUnknown == "match" and "match" or nil end
  ns.Rebuild()
end

-- New rules are appended with a condition that never matches, so adding one
-- can't change looting until its condition is edited and saved.
function Config.AddRule()
  local list = rules()
  list[#list + 1] = { name = "New rule", action = "leave", when = { expr = "false" } }
  ns.Rebuild()
  return #list
end

function Config.DeleteRule(i)
  if not rules()[i] then return end
  table.remove(rules(), i)
  ns.Rebuild()
end

-- Returns the rule's new index.
function Config.MoveRule(i, delta)
  local list = rules()
  local j = i + delta
  if not list[i] or j < 1 or j > #list then return i end
  list[i], list[j] = list[j], list[i]
  ns.Rebuild()
  return j
end

function Config.SetRuleEnabled(i, enabled)
  local rule = rules()[i]
  if not rule then return end
  if enabled then rule.enabled = nil else rule.enabled = false end
  ns.Rebuild()
end

function Config.SetDefaultAction(action)
  if not ns.Engine.ACTIONS[action] then return end
  ns.db.ruleset.default = action
  ns.Rebuild()
end

function Config.DefaultAction() return ns.db.ruleset.default or "loot" end

-- The first compile error for one rule (by index), or nil.
function Config.RuleError(i)
  local errors = ns.compileErrors
  return errors and errors.rules[i]
end

-- ---- lists -----------------------------------------------------------------

function Config.ParseItem(text)
  if type(text) == "number" then return text end
  if type(text) ~= "string" then return nil end
  return tonumber(text:match("item:(%d+)")) or tonumber(text:match("^%s*(%d+)%s*$"))
end

-- Returns itemID, or nil + error.
function Config.AddToList(listName, item)
  local id = Config.ParseItem(item)
  if not id then return nil, "not an item link or item ID" end
  ns.db.lists[listName] = ns.db.lists[listName] or {}
  ns.db.lists[listName][id] = true
  ns.ConfigChanged()
  return id
end

function Config.RemoveFromList(listName, id)
  local list = ns.db.lists[listName]
  if list then list[id] = nil end
  ns.ConfigChanged()
end

function Config.ListItems(listName)
  local ids = {}
  for id in pairs(ns.db.lists[listName] or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

-- ---- tester ---------------------------------------------------------------

-- Evaluate the current rules against an item link or ID.
-- Returns a result table or nil + error.
function Config.TestItem(item, quantity)
  local id = Config.ParseItem(item)
  if not id then return nil, "shift-click an item or type an item ID" end
  local link = type(item) == "string" and item:find("item:") and item or ("item:" .. id)
  local ctx = ns.Context.FromLink(link, quantity or 1, ns.db.lists)
  local action, rule, unknowns, ruleIndex, fields = ns.Engine.Evaluate(ns.compiled, ctx)
  return {
    ctx = ctx, action = action, rule = rule, ruleIndex = ruleIndex, unknowns = unknowns,
    values = ns.FormatValues(ctx, fields), -- only what the deciding rule reads
    cached = ctx.vendorValue ~= nil or ctx.name ~= nil,
  }
end

function Config.FormatMoney(c) return ns.FormatMoney(c) end

-- ---- item tooltips ----------------------------------------------------------

-- The lines added to item tooltips: the verdict, and (when a rule decided)
-- the values that rule read. nil when tooltips are off. Tooltips have no
-- loot slot, so this assumes a single unit and that only Quest-class items
-- are quest items.
function Config.TooltipLine(item)
  if not ns.db or not ns.db.tooltip or not ns.compiled then return nil end
  local r = Config.TestItem(item, 1)
  if not r then return nil end
  local verdict = r.action == "loot" and "|cff55ff55Loot|r" or "|cffffaa00Leave|r"
  local line = string.format("|cff33ccffLootRules:|r %s — %s", verdict, ns.DescribeDecider(r.rule, r.ruleIndex))
  if r.unknowns then line = line .. " |cff999999(some data unknown)|r" end
  if not ns.db.enabled then line = line .. " |cff999999(filtering off)|r" end
  return line, r.values and ("|cff999999" .. r.values .. "|r")
end

-- ---- bag picker ---------------------------------------------------------------

-- Distinct items in the player's bags, merged by item ID, filtered by a
-- case-insensitive name substring, best quality first then by name.
function Config.BagItems(filter)
  local byID, out = {}, {}
  local needle = filter and filter:match("^%s*(.-)%s*$"):lower() or ""
  for _, e in ipairs(ns.Context.ScanBags()) do
    local entry = byID[e.itemID]
    if entry then
      entry.count = entry.count + e.count
    else
      local name = e.link:match("%[(.-)%]") or ("item " .. e.itemID)
      if needle == "" or name:lower():find(needle, 1, true) then
        entry = { itemID = e.itemID, link = e.link, name = name, count = e.count, icon = e.icon, quality = e.quality or 0 }
        byID[e.itemID] = entry
        out[#out + 1] = entry
      end
    end
  end
  table.sort(out, function(a, b)
    if a.quality ~= b.quality then return a.quality > b.quality end
    return a.name < b.name
  end)
  return out
end

-- ---- quick reference --------------------------------------------------------

-- Plain text with WoW color codes, built from the engine's own field and
-- helper tables so it can't drift from what the rules can actually use.
function Config.ReferenceText()
  local gold, grey, white = "|cffffd100", "|cffaaaaaa", "|cffffffff"
  local out = {}
  local function add(s) out[#out + 1] = s or "" end

  add(gold .. "How rules work|r")
  add("Rules are checked top to bottom; the first rule whose condition is true decides whether the item is")
  add("looted or left on the corpse. If none match, the default action applies. Money, currency and")
  add("locked slots are never filtered.")
  add("")
  add("A condition is a Lua expression, for example:")
  add(white .. "    quality <= COMMON and vendorValue * maxStack < silver(5) and freeSlots <= 4|r")
  add("")
  add(gold .. "Unknown data|r")
  add("Item data can be missing (item not cached yet, values hidden in combat). A condition that")
  add("reads a missing value is 'undetermined', however the value is used, and the rule is skipped")
  add("unless 'Apply when data is unknown' is ticked. Undetermined conditions are shown in debug output.")
  add("")
  add(gold .. "Fields|r")
  for _, f in ipairs(ns.Engine.Fields) do
    add(string.format("  %s%s|r %s(%s)|r  %s", white, f[1], grey, f[2], f[3]))
  end
  add("")
  add(gold .. "Helpers|r")
  for _, h in ipairs(ns.Engine.Helpers) do
    add(string.format("  %s%s|r  %s", white, h[1], h[2]))
  end
  add("")
  add(gold .. "Operators|r")
  add("  " .. white .. "== ~= < <= > >=|r  compare (" .. white .. "~=|r is 'not equal')")
  add("  " .. white .. "+ - * /|r  arithmetic, e.g. " .. white .. "vendorValue * maxStack|r (value per bag slot)")
  add("  " .. white .. "and or not|r  combine; use parentheses to group")
  add("  " .. white .. "\"text\"|r  strings in double or single quotes")
  add("")
  add(gold .. "Examples|r")
  local examples = {
    { "quality == POOR and vendorValue * maxStack < silver(1)", "grey junk worth under 1s even as a full stack" },
    { "vendorValue * math.min(maxStack, 20) < silver(2)", "value of up to 20 units" },
    { "classID == 2 and quality <= COMMON", "white and grey weapons" },
    { "classID == 4 and subclassID == 4 and quality <= UNCOMMON", "plate armor up to green" },
    { "classID == 7 and owned >= 100", "trade goods you already have 100+ of" },
    { "matches(name, \"^chipped\") or matches(name, \"broken\")", "items by name" },
    { "freeSlots <= 2 and quality < UNCOMMON and quantity > stackRoom",
      "anything below green that needs a new bag slot while bags are almost full" },
    { "vendorValue >= gold(1)", "anything worth 1g+ per unit (use with Loot)" },
  }
  for _, e in ipairs(examples) do
    add(string.format("  %s%s|r", white, e[1]))
    add(string.format("      %s%s|r", grey, e[2]))
  end
  return table.concat(out, "\n")
end
