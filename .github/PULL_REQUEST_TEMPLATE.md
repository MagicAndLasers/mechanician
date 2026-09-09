## What this changes

A short description of the change and why.

## How it was verified

- [ ] `./scripts/check.sh` passes locally. This is the command CI runs, so anything less than a
      full pass here is a red build on the pull request.
- [ ] Exercised the affected flow in the running app, not only the build

Describe what you actually ran and observed:

## Notes

- Did you add or change a user-facing string? `scripts/localization-baseline.sh` is a ratchet: the
  count of strings that cannot be translated may go down but never up. Use a SwiftUI literal so it
  localizes into `app/Resources/Localizable.xcstrings`, `String(localized:)` for AppKit, and
  `Text(verbatim:)` only when the value is user data that must never be translated.
- Did you add or change a field on a persisted model? Adding a stored property to a `Codable` type
  can quarantine every older record even when the property has a default. See
  [docs/architecture/STORAGE-AND-PERSISTENCE.md](../docs/architecture/STORAGE-AND-PERSISTENCE.md).
- User-facing change? (UI, behavior)
- Permission / security relevant? (tool access, unattended runs, computer use)
- Anything reviewers should look at closely?
