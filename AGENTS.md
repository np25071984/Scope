# scope

A ⌘Tab window switcher for the current macOS Space, plus refocus after a Space switch, run as a launchd service. One Swift package, no dependencies.

```bash
swift test                  # the decision logic
./build.sh                  # release build, signed, into build/scope
./build.sh --install        # install to ~/.local/bin and restart the service
scope status | list | logs  # the running service
```

## Where things are written down

Each fact lives in one place. Do not repeat it in another. `CLAUDE.md` only imports this file; edit this one.

| What | Where |
|---|---|
| Decision logic: what an event means, ranking, refocus, config grammar, the launchd file | a test in `Tests/scopeTests`, named after the rule and its reason |
| What macOS does, and how the code is wired to it | `IMPLEMENTATION.md` |
| How to use scope | `README.md` |
| What changed in a release | the Changelog in `README.md` |

## Rules

- **A behaviour change comes with a test.** Keep decision logic in the pure types (`KeyTap.State`, `StampTable`, `Refocus`, `Config`, the static functions on `Switcher` and `Service`), not in the classes that call macOS, so it can be tested without a desktop. A new rule gets a test whose name states the rule and why.
- **`IMPLEMENTATION.md` changes only for platform facts and wiring.** Do not copy into it what a test specifies; point to the test file. A newly found macOS behaviour becomes a numbered fact labelled *observed*, *documented* or *believed*, and the code that depends on it cites it as **[Fn]**. Relabel a fact when it is confirmed or disproved.
- **Constants are named.** A number in the code that matters gets a `static let` with a comment on why it has that value, on the type that owns it.
- **No history in the docs.** No "used to", earlier designs or release numbers outside the Changelog.
- **Signing.** The binary is signed with the plain identifier `scope` and carries no `Info.plist`; anything else breaks the Accessibility permission (`IMPLEMENTATION.md`, F25). Search certificates without `find-identity -v` (F26). Install by rename, never in place (F27).
- **Check on the real desktop** what tests cannot: after a change to key handling, focusing or refocus, `./build.sh --install` and try it, or ask the user to when it needs keys pressed.

## Releasing

Bump `version` in `Sources/Scope/Support.swift`, add a dated Changelog entry to `README.md`, and say what an upgrading user has to do if anything.

Once the release PR is merged, tag its merge commit and push the tag. Tags are protected and cannot be moved or deleted, so check the commit first:

```bash
git tag -a vX.Y.Z <merge commit> -m "scope X.Y.Z: <one line>"
git push origin vX.Y.Z
```
