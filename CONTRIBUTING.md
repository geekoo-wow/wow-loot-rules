# Contributing to LootRules

## Release notes come from commit trailers

`RELEASE_NOTES.md` is **not** tracked in this repository — do not create or edit it. When a release tag is pushed, CI generates it from `Changelog:` trailers in the commit messages since the previous tag, and that becomes both the GitHub release body and the CurseForge changelog.

### Commit message format

For every **user-facing** change, add one `Changelog:` trailer line per change at the end of the commit message, in the trailer block (after a blank line, alongside trailers like `Co-Authored-By`):

```
Short imperative subject line

Optional body explaining the change for developers reading git history.

Changelog: Fixed stackable grey items being left behind when only one dropped.
Changelog: Added a Bags… button to pick items from your bags in the settings.
```

Rules:

- Write trailer lines **for players**, describing the visible effect in the game ("Fixed the tooltip line showing on comparison tooltips"), not the implementation ("Refactored tooltip hook").
- One complete sentence per trailer, on a single line, starting at the beginning of the line. Use multiple `Changelog:` trailers for multiple changes.
- Past tense or noun phrase, capitalized, ending with a period.
- Purely internal changes (CI, refactors, docs, comments, tests) get **no** `Changelog:` trailer and stay out of the release notes automatically.

### Releasing

1. Ensure every user-facing commit since the last tag carries its `Changelog:` trailers.
2. `git tag -a vX.Y.Z -m "LootRules vX.Y.Z"` (annotated — the packager derives `@project-version@` from it)
3. `git push origin vX.Y.Z`

CI then runs lint and tests, packages the addon, creates the GitHub release with the generated notes, and uploads to CurseForge (project 1718897, from `X-Curse-Project-ID` in the TOC). If no commit since the previous tag has a `Changelog:` trailer, the notes say "Maintenance release."

Every branch push also builds the addon zip without publishing it; download it from the workflow run's **Artifacts** to try a build in game before tagging.
