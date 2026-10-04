# LootRules

Rule-based autoloot for **WoW: Forever** and **retail WoW**. LootRules replaces the game's Auto
Loot: when a loot window opens it loots what your rules accept and leaves the
rest on the corpse. Rules are small expressions over the item's rarity, vendor
value, class, bag space, lists and more.

> Prototype. Built for the Forever beta, which uses the Mainline (12.1.5-era)
> addon API, not the Classic one; retail uses the same API.

## Supported clients

| Client | Interface |
|---|---|
| Retail (Midnight 12.x) | 120000, 120001, 120005, 120007, 120100 |
| WoW: Forever | 16001 |

The repo has one `LootRules.toc` with `## Interface-Retail:` and
`## Interface-Forever:` lines; the release packager splits it into
`LootRules_Mainline.toc` and `LootRules_Camelot.toc`, which each client
picks by name. Classic flavors aren't supported. After a client patch, get
the new number with `/dump select(4, GetBuildInfo())` and add it to that
client's line and to the base `## Interface:` line.

## Install

1. Download `LootRules-<version>.zip` from the GitHub releases page and unzip
   it into the client's `Interface/AddOns/` (you should end up with
   `Interface/AddOns/LootRules/`).
2. Open the settings with `/lr` (or Options > AddOns > LootRules) and
   **turn off the game's Auto Loot** there. The client loots everything before
   addons can intervene, so LootRules only works with it off. Holding the
   autoloot modifier (Shift by default) makes the client loot everything on
   that one corpse, a handy override.

Start with **Dry run** on for a few kills: everything is still looted, and
chat shows what the rules *would* have done and which rule decided.

## Settings

Everything is configured in Options > AddOns > LootRules:

- **LootRules**: enable/disable, dry run, debug output, close the loot window
  when done, auto-confirm bind-on-pickup, the tooltip line, and the game's
  Auto Loot status.
- **Rules**: the ordered rule list. Select a rule to edit its name, action
  (Loot/Leave) and condition; the condition is validated as you type. Rules
  can be added, reordered, disabled and deleted, and the action for items no
  rule matches can be switched. The **Test an item** box shows what the
  current rules do with any item and why.
- **Lists**: blacklist and whitelist.
- **Rules reference**: the rules language, all fields, helpers and examples.

The settings panel blocks the bag keybinds, so every item box (lists,
tester) has a **Bags…** button: a searchable list of what's in your bags,
shown over the panel. Item boxes also take a typed item ID or a shift-clicked
chat link.

## Item tooltips

With **Show decision on item tooltips** on (the default; also `/lr tooltip`),
hovering any item, in bags, chat links, vendors or the auction house, adds the
verdict and the values the deciding rule read:

```
LootRules: Leave — #4 Cheap junk
    quality 0, vendorValue 9c, maxStack 10
```

Only the fields in the deciding rule's condition are shown; when no rule
matched there is nothing to show.

This is the quickest way to check your rules without opening the settings.
Tooltips have no loot slot, so they assume a single unit dropped
(`quantity` = 1), and only Quest-class items count as quest items; other
quest drops are recognized only in a real loot window.

`/lr` opens the settings; `/lr debug`, `/lr dry`, `/lr tooltip`, `/lr on` and
`/lr off` are quick toggles.

## Debug output

With **Debug output** on, every decision is printed as it happens, with the
rule that made it and the values that rule read (and nothing else):

```
LootRules: left [Tattered Cloth] x2 — #4 Cheap junk [quality 0, vendorValue 5c, maxStack 1]
LootRules: looted [Silk Cloth] x3 — no rule matched (default)
LootRules: looted [Light Leather] x1 — no rule matched (default) (undetermined: Tight bags: condition)
```

Dry run always prints its decisions ("would loot" / "would leave"). The
settings panel's item tester shows the same verdict and values.

## Rules

Rules are checked top to bottom; the **first matching rule wins**, otherwise
the default action (Loot) applies. Money, currency and locked slots (rolls,
master loot) are never filtered.

Default rules:

| # | Rule | Condition | Action |
|---|------|-----------|--------|
| 1 | Blacklist | `inList("blacklist")` | leave |
| 2 | Whitelist | `inList("whitelist")` | loot |
| 3 | Quest items | `isQuest` | loot |
| 4 | Cheap junk | `quality == POOR and vendorValue * maxStack < silver(1)` | leave |
| 5 | Tight bags | `quality <= COMMON and vendorValue * maxStack < silver(5) and freeSlots <= 4` | leave |

The junk rules judge an item by what a **full stack** is worth (its value per
bag slot), so a stackable grey worth 41c each (4s 10c per stack of 10) is
looted however many drop.

A condition is a Lua expression over the item's fields (`quality`,
`vendorValue`, `maxStack`, `quantity`, `name`, `itemID`, `ilvl`, `classID`,
`subclassID`, `bindType`, `freeSlots`, `owned`, …) with helpers such as
`silver(n)`, `gold(n)`, `inList("name")` and `matches(name, "pattern")`. The
full list is in the in-game **Rules reference** panel. Typos in field names
are rejected when you save.

Fields are primitives; anything derived is arithmetic in the condition:

| Field | Value |
|---|---|
| `vendorValue` | vendor sell price of one unit, in copper (100c = 1s, 10,000c = 1g) |
| `maxStack` | most units a stack can hold |
| `quantity` | how many units dropped (1 on tooltips) |

`vendorValue * maxStack` is what a bag slot of the item can be worth, which
is what the default junk rules use. `vendorValue * quantity` is the value of
what dropped.

**Unknown data.** Item data can be missing (item not cached yet, values
hidden during combat). A condition that reads a missing value is
*undetermined*, whatever it does with the value: `not isReagent` and
`bindType ~= 1` are as undetermined as `vendorValue < silver(1)` when the
item's data hasn't arrived. The rule is then skipped unless "Apply when data
is unknown" is ticked. Skipping means falling through to later rules and
ultimately the default (Loot), since leaving something valuable behind is
worse than picking up junk. `and` / `or` stop as early as in Lua, so a value
that is never reached doesn't count: `quality >= RARE and vendorValue > gold(1)`
is simply false for a grey item, whether or not its price is known.

Rules are stored in `LootRulesDB.ruleset` in SavedVariables. Rules written by
hand there may also use the structured form
(`when = { quality = { max = 0 }, vendorValue = { max = 9 } }`); the settings
panel shows these as the equivalent expression and saves them back as one.
A rule the addon can't make sense of (unknown condition, bad expression,
unknown action) is reported in chat at login, marked in red in the rule list
and skipped; the other rules keep working.

## Known limitations

- **Forever beta SavedVariables bug**: the beta saves SavedVariables on logout
  but doesn't load them on startup. The defaults are in code so the addon still
  works, but your lists and rule edits won't survive a restart until Blizzard
  fixes it (the Forever Data Protect addon works around it).
- Not yet verified in the Forever client; the WoW API is mocked in the tests,
  and the settings panels are only checked for wiring, not layout.
- No auction-price source yet (TSM / Auctionator integration is planned).
- Group loot rolls are untouched; only the personal loot window is filtered.

## Development

```
lua5.1 tests/run.lua   # offline tests against a mocked WoW API
luacheck .             # lint
```

Layout:

- `Engine.lua`: pure rule compilation and evaluation, the rules language and
  its field/helper documentation (no WoW API)
- `Context.lua`: lazy per-item context; the only place that reads item data
- `Config.lua`: config operations used by the settings UI (testable offline)
- `UI.lua`: settings panels and the bag picker; draws widgets and calls `Config`
- `Tooltip.lua`: the decision line on item tooltips
- `Looter.lua`: loot-window event handling and decision output
- `Commands.lua`: `/lr`
- `Core.lua`: defaults, SavedVariables, output helpers
- `LootRules.toc`: the file list and per-client interface versions

Every push to a branch runs lint and tests, then builds the addon zip without
publishing it: download it from the run's **Artifacts** to try a build in game.

## Releasing

Push an annotated `v*` tag. CI runs lint and tests, generates the release
notes from `Changelog:` commit trailers, packages the addon with the
[BigWigs packager](https://github.com/BigWigsMods/packager) and publishes a
GitHub release. The commit convention and steps are in
[CONTRIBUTING.md](CONTRIBUTING.md).

## Changes to saved rules

Saved rules are upgraded automatically when the addon loads, with each
removed field rewritten as its definition, so they behave exactly as before;
unedited copies of older default rules become the current defaults.

| Old field | Versions | Becomes |
|---|---|---|
| `sellPrice` | v1–v2 | `vendorValue` |
| `unitVendorPrice` | v3–v4 | `vendorValue` |
| `stackVendorPrice` | v3–v4 | `(vendorValue * maxStack)` |
| `stackValue` | v1–v2 | `(vendorValue * quantity)` |
| `lootVendorPrice` | v3 | `(vendorValue * quantity)` |

## License

MIT; see [LICENSE](LICENSE).
