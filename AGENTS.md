# LootRules — agent instructions

Follow the commit message and release conventions in [CONTRIBUTING.md](CONTRIBUTING.md). In particular: release notes are generated from `Changelog:` commit trailers — never create or edit `RELEASE_NOTES.md`.

WoW: Forever addon (Mainline 12.1.5-era API, Lua 5.1). Rule-based replacement
for the built-in autoloot. See README.md for behaviour.

## Commands

- Test: `lua5.1 tests/run.lua` (must pass before committing)
- Lint: `luacheck .`

## Architecture rules

- `LootRules/Engine.lua` must stay free of WoW API calls so it runs offline.
- Item data is read only in `LootRules/Context.lua`, lazily, through `Context.API`.
  New item fields: add a loader there and a condition in `Engine.Conditions`.
- Missing data is `nil` = "unknown", never a guessed value. Wrap anything
  read from the game with `clean()` (secret values).
- Default when unsure is to loot.
- The rules language is documented from `Engine.Fields` / `Engine.Helpers`;
  a new context field must be added there too (a test enforces it).
- Settings UI: `UI.lua` only draws widgets; every config change goes through
  `Config.lua`, which is what the tests exercise. `tests/test_ui.lua` builds
  the panels against stub widgets (catches wiring errors, not layout).
- `Tooltip.lua` only hooks tooltips; the line's content comes from
  `Config.TooltipLine`. Bag contents are read in `Context.ScanBags` and
  shaped for the picker by `Config.BagItems`.
- Context fields are primitives; derived values (e.g. value per bag slot =
  `vendorValue * maxStack`) are arithmetic in conditions, not new fields.
- Debug lines, tooltips and the tester show only the values of the fields the
  deciding rule reads (`Engine.FieldsOf` -> `ns.FormatValues`).
- Removing or renaming a field needs a SavedVariables migration in `Core.lua`
  that rewrites saved rules to the field's definition, plus a version bump.
- Decisions are reported as they happen via `Looter.ReportDecision` (debug
  mode / dry run); there is no log buffer.
- New WoW globals the addon uses go in `.luacheckrc` `read_globals` and get a
  mock in `tests/mock_wow.lua`.
- `LootRules/LootRules.toc` is the only TOC and is authoritative for the file
  list; the test runner loads files in its order. Supported clients are the
  `## Interface-Retail:` and `## Interface-Forever:` lines; the packager splits
  them into per-client TOCs at release time (`enable-toc-creation`). The base
  `## Interface:` must list every per-client version (tests/test_toc.lua).
- Releases: pushing a `v*` tag runs `.github/workflows/release.yml`. Never tag
  or push tags unless asked.
