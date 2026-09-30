-- tests/run.lua — tiny test runner. Usage (from the repo root):
--   lua5.1 tests/run.lua
-- Each test gets a fresh mock WoW API and a freshly loaded addon, read in
-- the order listed in the .toc so the file list can't drift.

package.path = "./tests/?.lua;" .. package.path
local mock = require("mock_wow")

local ADDON_DIR = "LootRules/"

-- The single TOC; the packager splits it per client at release time.
local TOC = "LootRules.toc"

local function tocLines(toc)
  local files, directives = {}, {}
  for line in io.lines(ADDON_DIR .. toc) do
    local key, value = line:match("^##%s*([%w%-_]+):%s*(.-)%s*$")
    if key then
      directives[key] = value
    elseif line:match("%.lua%s*$") and not line:match("^#") then
      files[#files + 1] = line:match("^%s*(.-)%s*$")
    end
  end
  return files, directives
end

local function tocFiles() return (tocLines(TOC)) end

-- Loads the addon like the client does: each file gets (addonName, ns).
-- Fires ADDON_LOADED so SavedVariables init runs. Returns ns.
local function loadAddon(savedVars)
  mock.reset()
  _G.LootRulesDB = savedVars
  local ns = {}
  for _, f in ipairs(tocFiles()) do
    local chunk = assert(loadfile(ADDON_DIR .. f))
    chunk("LootRules", ns)
  end
  ns.Looter.frame:Fire("ADDON_LOADED", "LootRules")
  return ns
end

-- ---- assertions -----------------------------------------------------------

local T = { mock = mock, load = loadAddon, TOC = TOC, tocLines = tocLines }

local function fmt(v)
  if type(v) ~= "table" then return tostring(v) end
  local parts = {}
  for i = 1, #v do parts[i] = fmt(v[i]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function deepEq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

function T.eq(actual, expected, msg)
  if not deepEq(actual, expected) then
    error(string.format("%sexpected %s, got %s", msg and (msg .. ": ") or "", fmt(expected), fmt(actual)), 2)
  end
end

function T.truthy(v, msg) if not v then error(msg or "expected truthy value", 2) end end

-- ---- run ------------------------------------------------------------------

local tests = {}
function T.test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

for _, f in ipairs({
  "tests/test_toc.lua", "tests/test_engine.lua", "tests/test_looter.lua", "tests/test_config.lua", "tests/test_ui.lua",
}) do
  assert(loadfile(f))(T)
end

local failed = 0
for _, t in ipairs(tests) do
  local ok, err = pcall(t.fn)
  if ok then
    print("  ok    " .. t.name)
  else
    failed = failed + 1
    print("  FAIL  " .. t.name .. "\n        " .. tostring(err))
  end
end
print(string.format("\n%d tests, %d failed", #tests, failed))
os.exit(failed == 0 and 0 or 1)
