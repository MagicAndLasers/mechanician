# Postmortem: schema v7 bricked launch for every existing library

**Date:** 2026-08-14
**Change:** commit `6efaa1d`, "feat(memory): add the durable memory authority (schema v7) and its search index"
**Author:** a coding agent (Claude Opus 5, 1M context), co-authoring with the maintainer
**Impact:** a daily build cut from `6efaa1d` refused to launch on any machine that already had a
SQLite library. The app opened straight to the Storage Recovery screen. No user data was lost or
touched.
**Resolution:** revert `6efaa1d` (commit `e686da2`), rebuild, reinstall. Launch restored.

This file is written for the next agent that touches storage. The change looked safe, was tested,
claimed 2239 passing tests and "ships dark", and still bricked the app for everyone who ran it. The
gap between those two facts is the whole lesson.

## What the change did

Two things, in one commit:

- `SQLiteLibraryStore.schemaVersion` went from `6` to `7`, adding seven `memory_*` tables to
  `library.db` behind a new `migrateV6ToV7`.
- `ProjectionStore` schema went from `5` to `6`, adding a `memory_fts` search table to
  `projections.db`.

The commit message was explicit that the migration was the risky part and that it "cannot be walked
back once a user's library has run it", so it proved the DDL and its invariants in unit tests before
anything read the tables. That reasoning was correct about the one risk it named. It did not check
whether an existing library would ever reach the migration at all.

## What actually happened

The running app never reaches `migrateV6ToV7` on a real library. It cannot.

There are two open paths in `SQLiteLibraryStore`, and only one of them migrates:

- The **shadow** path (`init(supportRoot:)` to `openOrReset` to `verifyExistingSchema`) runs the
  `migrateV2ToV3`..`migrateV6ToV7` ladder. Its first guard requires `authority_state == "shadow"`
  (see `verifyExistingSchema`, the `guard authorityState == "shadow"` line). A shadow database is a
  disposable candidate, not the live library.
- The **active** path (`LibraryAuthorityRepository.open` to `SQLiteLibraryStore.openActiveAuthority`
  to `verifyExactActiveSchema`) is what the product uses to open a real library on launch. It never
  migrates. It asserts an exact match:

  ```
  grep -n 'marker.schemaVersion == Self.schemaVersion' app/Sources/Mechanician/SQLiteLibraryStore.swift
  ```

A real library on disk is an **active** authority. Its on-disk marker records `schemaVersion: 6`.
When the v7 binary opened it, `verifyExactActiveSchema` compared marker `6` against code `7`, threw,
and `SQLiteAuthorityRepositoryPreflight.evaluate` turned that throw into a `.blocked` disposition.
`.blocked` is the Storage Recovery screen.

Nothing in the codebase upgrades an already-active authority across a schema bump.
`SQLiteLibraryBootstrapService.provisionIfNeeded` only acts on an absent marker on a pristine root,
which is a first install, not an upgrade. So the active library sat at v6 forever and the app
refused to run against it.

## Why this was the first schema bump to break anything

`schemaVersion` was born at `6`. The SQLite cutover shipped around 0.26.21, and every library that
exists was **provisioned fresh** at v6 by `createSchema`, which replays `applyV3`..`applyV7` in one
shot and lands directly on the current version. `git log -S 'schemaVersion = 5'` on the store file
returns nothing: v5 was never a shipped current version.

That means the migration ladder and the whole "open an older active authority with a newer binary"
scenario had never run in production. v7 was the first schema bump ever delivered to an
already-provisioned active library. The code that was supposed to carry a library forward across a
version had no callers and no coverage, and it turned out not to exist for the active case at all.

## Why the tests did not catch it

`./scripts/check.sh` was green: 2239 Swift tests, 0 failures. Every one of those tests provisions a
fresh database at the current `schemaVersion` and exercises it. None of them opens a pre-existing
older-version active authority with a newer binary, because until this commit that situation could
not occur, so nobody had written the test.

The tooling to catch it was already in the tree and was not wired into the gate:

```
ls scripts/build-migration-rehearsal-fixture.sh scripts/diagnose-migration-refusal.sh
```

A fresh-provision test and an upgrade test look almost identical and prove completely different
things. Only the second one would have failed here.

## The reasoning error to learn from

The author identified the correct risk (an applied migration cannot be undone) and mitigated exactly
that risk (prove the DDL, ship the tables with no reader). Both moves were sound. The failure was a
category error one level up:

**A version-gating constant is not "dark".** "Ships dark" means the new code paths are never
reached. It was true of the seven new tables, which nothing reads. It was false of the
`schemaVersion` bump itself. Every launch reads that constant, on every machine, before any table is
touched. Changing it changed the gate that every existing library has to pass, and there was no path
through the new gate for a library that already existed. The tables were dark. The version was the
brightest thing in the build.

## Remediation

Taken:

- `git revert 6efaa1d` (`e686da2`). Safe precisely because the tables shipped dark: reverting them
  removes nothing any code reads. The v6 binary opens the v6 library normally. `projections.db`,
  which had already advanced to v6 on the broken run, drops and rebuilds under the reverted v5
  `ProjectionStore`, which is a search reindex and loses no durable data.
- Rebuilt with `./scripts/dogfood.sh --install`, then verified by launching the installed build
  against the real 786 MB v6 library and confirming it opened the Home workspace rather than Storage
  Recovery. The prior build was parked at `/Applications/Mechanician-rollback.app`.

Required before the memory schema can land again:

1. **Build the active-authority upgrade path.** When an active marker's `schemaVersion` is below the
   code's, rebuild a shadow from the active authority, run the migration ladder on the shadow, and
   promote it. The shadow lifecycle and the promotion machinery already exist; nothing wires them to
   a version gap.
2. **Add a cross-version upgrade test to `check.sh`.** It must open a real, pre-existing,
   older-version active authority with the current binary and assert the app launches. Use the
   existing `build-migration-rehearsal-fixture.sh` and `diagnose-migration-refusal.sh` as the
   starting point. A green suite that only provisions fresh is not evidence that upgrades work.
3. **Do not bump `schemaVersion` until 1 and 2 exist.**

## A second, self-inflicted failure during diagnosis

While reproducing the brick, the diagnosing agent launched several app instances at once against the
real 786 MB library. Concurrent instances tripped the read-only storage-authority probe: `scalarInt`
on an early `PRAGMA` returned a non-`ROW` step and was reported as "query returned no row"
(`probeDatabase`, the `throw ... "query returned no row"` line). That instance then cached the
resulting `.blocked` disposition for its whole process lifetime, because recognition runs once:

```
grep -n 'guard stored == nil else { return }' app/Sources/Mechanician/StorageAuthorityMarker.swift
```

The result was a second, different-looking recovery screen ("query returned no row" instead of a
schema mismatch) that appeared even after the correct fix was installed, and briefly read as "the
revert did not work". A clean quit and a single relaunch probed the consistent on-disk state and
opened normally.

Two lessons from this half:

- **The recovery decision is cached per process.** A machine that has ever shown Storage Recovery in
  a given launch will keep showing it until the process is quit, regardless of the disk healing
  underneath it. Always reproduce and verify storage problems with one instance and a clean launch.
- **Never diagnose a storage-authority failure with concurrent instances against the real library.**
  Copy the library first, or run one process at a time. The read-only probe is not the place to
  discover you are your own second writer.

## The one-line version

Bumping a launch-gating schema version is not a dark change, a fresh-provision test suite does not
prove upgrades work, and there was no code to carry an existing active library across the bump. Prove
the upgrade on a real old library with the new binary before the version moves, or do not move it.
