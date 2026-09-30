-- tests/test_toc.lua — the TOC lists every file, and its per-client
-- Interface lines agree with the base line the packager falls back to.

local T = ...
local test, eq, truthy = T.test, T.eq, T.truthy

local function versions(value)
  local set = {}
  for v in (value or ""):gmatch("%d+") do set[v] = true end
  return set
end

test("every listed file exists and every Lua file is listed", function()
  local files = T.tocLines(T.TOC)
  truthy(#files > 0)
  local listed = {}
  for _, f in ipairs(files) do
    listed[f] = true
    truthy(io.open("LootRules/" .. f, "r"), "TOC lists missing file " .. f)
  end
  local p = io.popen("ls LootRules")
  for name in p:lines() do
    if name:match("%.lua$") then truthy(listed[name], name .. " is not in the TOC") end
  end
  p:close()
end)

test("supported clients: Retail and Forever, and the base Interface lists exactly their versions", function()
  local _, d = T.tocLines(T.TOC)
  truthy(d["Interface-Retail"], "Interface-Retail line")
  eq(d["Interface-Forever"], "16001")
  local union = {}
  for k, v in pairs(d) do
    if k:match("^Interface%-") then
      for ver in pairs(versions(v)) do union[ver] = true end
    end
  end
  eq(versions(d.Interface), union, "base ## Interface")
end)
