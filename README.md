# DevPilot

Native macOS app that turns tickets assigned to you in Shortcut and Jira Cloud into an
AI-assisted engineering workflow: ingest → investigate → decision document → **human
approval** → implement in an isolated worktree → test → review → **you commit manually**.

DevPilot never commits, pushes, deploys or opens PRs. See
[ADR 0001](docs/adr/0001-architecture-and-security.md) for the architecture and security boundaries.

## Status

| Milestone | Scope | Status |
|---|---|---|
| M1 | App shell, menu bar, settings shell, mock tickets, SQLite, state machine + tests | Done |
| M2 | Real Shortcut and Jira adapters, Keychain credentials | Next |
| M3 | Repo mapping, worktrees, read-only Codex investigation, decision doc, approval UI | |
| M4 | Sandboxed implementation runs, cancellation, budgets | |
| M5 | Test runner, independent review, diff viewer, notifications | |

## Requirements

- macOS 15 or later, Apple Silicon or Intel.
- Xcode 27 or later, selected as the active developer directory
  (`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`). The Command Line
  Tools alone are not enough: they lack the SwiftUI macro plugin needed for `@State`, and
  they fail to load the Swift Testing plugin on some builds.
- From M3: [Codex CLI](https://github.com/openai/codex), logged in (`codex login`).

## Build, run, test

```bash
swift test                          # unit tests (DevPilotCore)
swift run DevPilot                  # quick dev run, no app bundle
scripts/build-app.sh                # build/DevPilot.app, ad-hoc signed
scripts/build-app.sh --install      # also copy to /Applications
open build/DevPilot.app
```

To open in Xcode: `open Package.swift`, choose the `DevPilot` scheme, then Run.

### Signing

Ad-hoc signing (the default) is enough to run on your own Mac. Because the signature changes
on each build, macOS asks again for Keychain access after a rebuild. To avoid that, sign with
your free Apple Development identity. Add your Apple ID in Xcode → Settings → Accounts, then:

```bash
security find-identity -v -p codesigning
SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" scripts/build-app.sh --install
```

The app is deliberately **not** sandboxed (it must run `git`, `codex` and test commands),
so it cannot ship on the Mac App Store. Sharing it with coworkers would require a paid
Developer ID certificate and notarization.

## Data

`~/Library/Application Support/DevPilot/`

- `devpilot-mock.sqlite`: M1 database backed by mock tickets. Safe to delete.

## Layout

```
Sources/DevPilotCore/      domain, integrations, services (no UI; unit-tested)
  Domain/                  Ticket, WorkflowState, Approval/DecisionDocument/ImplementationGate, WorkflowEvent
  Integrations/            TicketProvider protocol, MockTicketProvider
  Services/                AppDatabase (GRDB/SQLite), WorkflowOrchestrator
Sources/DevPilot/          SwiftUI app
  App/                     DevPilotApp, AppContainer (composition root), AppModel
  Features/                Dashboard, TicketDetail, MenuBar, Settings, Components
Tests/DevPilotCoreTests/   state machine, approval gate, persistence, orchestrator
Support/Info.plist         app bundle metadata
scripts/build-app.sh       bundle + sign
```

## Known TODOs

- M2: Shortcut and Jira adapters (pagination, retries/backoff, ADF → text), Keychain
  store, provider settings UI, handling of tickets no longer assigned.
- M3: repository mappings, worktree manager (sanitized paths and branches), Codex runner
  with PATH resolution (GUI apps do not inherit your shell `PATH`), per-repo setup command
  for dependencies in fresh worktrees.
- M4/M5: see milestones above and the spec.
