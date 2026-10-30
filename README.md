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
| M3 | Repo mapping, worktrees, read-only Claude Code investigation, decision record, approval | Done |
| M4 | Sandboxed implementation runs, cancellation, budgets | Next |
| M5 | Test runner, independent review, diff viewer, notifications | |

## Requirements

- macOS 15 or later, Apple Silicon or Intel.
- Xcode 27 or later, selected as the active developer directory
  (`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`). The Command Line
  Tools alone are not enough: they lack the SwiftUI macro plugin needed for `@State`, and
  they fail to load the Swift Testing plugin on some builds.
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI, logged in with your claude.ai
  account (run `claude` once in Terminal and log in). DevPilot uses that stored login, never
  `ANTHROPIC_API_KEY`.

## Build, run, test

```bash
swift test                          # unit tests (DevPilotCore)
DEVPILOT_LIVE_CLAUDE=1 swift test --filter LiveClaudeTests   # one real Claude run (uses quota)
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

## Investigating a ticket (M3)

1. **Settings → Repositories → Add Repository…** and pick the repo's top-level folder. DevPilot
   suggests the base branch from `origin/HEAD`. Optional routing rules map a Jira project key
   (or all Shortcut stories) to a repository.
2. **Settings → Agent → Check** confirms Claude Code is found and logged in.
3. On a ticket: **Select for Investigation**, choose the repository, **Start Investigation**.
   DevPilot creates a worktree at `~/DevPilot/worktrees/<repo>/<provider>-<ticket>` on branch
   `devpilot/<provider>-<ticket>`, and Claude investigates it read-only. Progress shows live.
   **Stop** ends the run, along with everything it started.
4. Outcomes:
   - **Needs clarification**: the blocking questions are listed. Answer them in the app (or
     update the ticket and refresh), then re-investigate. Implementation stays blocked until then.
   - **Awaiting approval**: **Review Plan…** opens the decision record. Approve, Request Revision
     (notes go into the next investigation), or Reject. The approval is bound to the SHA-256
     of the exact text you reviewed.

What "read-only" means here: Claude gets only the Read, Grep and Glob tools, so it has no shell,
no editing and no web access. Anything else is denied without asking. The repository's own
`.claude` settings, hooks and MCP servers are ignored, and the process environment contains no
API keys, SSH agent or cloud credentials. Ticket text and repository files are passed as
untrusted data. Git hooks are disabled while DevPilot creates worktrees.

Decision records and full agent transcripts (prompt, stream-json, stderr) are kept outside
every worktree, in `~/Library/Application Support/DevPilot/artifacts/<ticket>/`.

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
- `artifacts/`: decision records (`decision-vN.md`) and agent transcripts per ticket.

## Layout

```
Sources/DevPilotCore/      domain, integrations, services (no UI; unit-tested)
  Domain/                  Ticket, WorkflowState, Approval/DecisionDocument/ImplementationGate, WorkflowEvent,
                           Investigation, TicketWorkspace, AgentRun
  Agent/                   AgentRunner protocol, ClaudeCodeRunner, investigation prompt + schema,
                           decision record renderer
  Integrations/            TicketProvider protocol, Jira and Shortcut adapters, sample provider,
                           HTTP client with retry/backoff, ADF → Markdown, acceptance criteria
  Services/                AppDatabase (GRDB/SQLite), WorkflowOrchestrator, InvestigationService,
                           GitWorktreeManager, ProcessRunner, settings, Keychain, ProviderFactory
Sources/DevPilot/          SwiftUI app
  App/                     DevPilotApp, AppContainer (composition root), AppModel
  Features/                Dashboard, TicketDetail, Approval, MenuBar, Settings, Components
Tests/DevPilotCoreTests/   state machine, approval gate, persistence, orchestrator, adapters
  Fixtures/                hand-written Jira and Shortcut API responses (real payload shapes)
Support/Info.plist         app bundle metadata
scripts/build-app.sh       bundle + sign
```

## Known TODOs

- Jira scoped API tokens (`api.atlassian.com/ex/jira/{cloudId}`) and OAuth are not supported.
- Sync runs on launch and on Refresh (⌘R) only. Periodic sync is a later addition.
- Worktrees are never deleted automatically. Remove one with `git worktree remove <path>` from
  the repository once you are done.
- Worktrees branch from the *local* base branch. Pull it first if you want the latest code.
- If DevPilot is force-quit mid-run, the Claude process is stopped on normal quit but not on a crash.
  Investigation is read-only, so an orphaned run cannot change anything. M4 must handle this for
  write-enabled runs.
- M4: workspace-write implementation runs (Claude Code sandbox, approved-command allowlist,
  no git commit/push), per-repo dependency setup command for fresh worktrees, blocking
  settings changes while a run is active.
- M5: see milestones above and the spec.
