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
| M2 | Shortcut and Jira Cloud adapters, configurable URLs, Keychain credentials | Done |
| M3 | Repo mapping, worktrees, read-only Codex investigation, decision doc, approval UI | Next |
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

## Connecting Shortcut and Jira

Open **DevPilot → Settings… → Providers** (⌘,). Everything there can be changed at any time,
so you can point DevPilot at a different Jira site or Shortcut workspace, or someone else can
use their own.

**Shortcut**
1. Create an API token: Shortcut → Settings → Your Account → API Tokens.
2. Turn on *Sync stories assigned to me*, paste the token, click **Test Connection**, then **Save**.
3. The token decides the workspace. Leave *API URL* at `https://api.app.shortcut.com`
   unless you go through a proxy.

**Jira Cloud**
1. Create an API token at <https://id.atlassian.com/manage-profile/security/api-tokens>.
   Use a classic API token. Scoped tokens use a different API host and are not supported yet.
2. Fill in *Site URL* (`https://your-company.atlassian.net`; `your-company.atlassian.net` also
   works), your Atlassian account email and the token. Test, then Save.
3. Optional: if your team keeps acceptance criteria in a custom field, enter its ID
   (`customfield_NNNNN`). You can find the ID in the issue's JSON at
   `https://your-company.atlassian.net/rest/api/3/issue/KEY-1?fields=*all`. Otherwise DevPilot
   reads an "Acceptance criteria" heading from the description.

What gets synced:
- Jira: `assignee = currentUser() AND statusCategory != Done`, newest first.
- Shortcut: stories you own that are not done or archived.
- Both are read-only. Nothing is ever written back to Jira or Shortcut.
- Tickets that stop being returned (reassigned, finished, or from a site you switched away from)
  disappear from the dashboard. If work on one is in progress, it stays visible and is marked
  *Not assigned*.
- Ticket IDs include the site or workspace (`jira:acme.atlassian.net/PLAT-182`,
  `shortcut:acme/4211`), so the same key on two Jira sites is never confused.

Tokens are stored in the login Keychain under `dev.devpilot.DevPilot`. Non-secret settings are
stored in `defaults read dev.devpilot.DevPilot providerSettings`.

### Signing

Ad-hoc signing (the default) is enough to run on your own Mac. Because an ad-hoc signature
changes on every build, macOS asks again for Keychain access to your tokens after each rebuild.
A stable signing identity fixes that. No Apple ID is needed:

1. Open **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: `DevPilot Local Signing`, Identity Type: *Self-Signed Root*, Certificate Type:
   *Code Signing*, then Create.
3. Build with it:
   ```bash
   SIGN_IDENTITY="DevPilot Local Signing" scripts/build-app.sh --install
   ```
4. The first time the app reads a token, macOS asks for Keychain access. Choose **Always Allow**.
   Later rebuilds keep that permission.

If `codesign` says the identity is not valid, open the certificate in Keychain Access and
set **Trust → Code Signing** to *Always Trust*. If you have an Apple ID, your free
"Apple Development" identity from Xcode → Settings → Accounts works the same way.

The app is deliberately **not** sandboxed (it must run `git`, `codex` and test commands),
so it cannot ship on the Mac App Store. Sharing it with coworkers would require a paid
Developer ID certificate and notarization.

## Data

`~/Library/Application Support/DevPilot/`

- `devpilot.sqlite`: tickets, workflow state, approvals and audit trail.
- `devpilot-sample.sqlite`: used only while *Use sample data* is on. Safe to delete.

## Layout

```
Sources/DevPilotCore/      domain, integrations, services (no UI; unit-tested)
  Domain/                  Ticket, WorkflowState, Approval/DecisionDocument/ImplementationGate, WorkflowEvent
  Integrations/            TicketProvider protocol, Jira and Shortcut adapters, sample provider,
                           HTTP client with retry/backoff, ADF → Markdown, acceptance criteria
  Services/                AppDatabase (GRDB/SQLite), WorkflowOrchestrator, settings, Keychain,
                           ProviderFactory
Sources/DevPilot/          SwiftUI app
  App/                     DevPilotApp, AppContainer (composition root), AppModel
  Features/                Dashboard, TicketDetail, MenuBar, Settings, Components
Tests/DevPilotCoreTests/   state machine, approval gate, persistence, orchestrator, adapters
  Fixtures/                hand-written Jira and Shortcut API responses (real payload shapes)
Support/Info.plist         app bundle metadata
scripts/build-app.sh       bundle + sign
```

## Known TODOs

- Jira scoped API tokens (`api.atlassian.com/ex/jira/{cloudId}`) and OAuth are not supported.
- Shortcut's `!is:done` search filter has not been checked against a real workspace yet. Stories are
  re-filtered by workflow state type either way.
- Sync runs on launch and on Refresh (⌘R) only. Periodic sync is a later addition.
- Changing settings while an agent run is active must be blocked once M4 adds agent runs.
- M3: repository mappings, worktree manager (sanitized paths and branches), Codex runner
  with PATH resolution (GUI apps do not inherit your shell `PATH`), per-repo setup command
  for dependencies in fresh worktrees.
- M4/M5: see milestones above and the spec.
