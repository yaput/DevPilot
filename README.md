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
| M4 | Sandboxed implementation in the worktree, per-repo commands, integration branch names | Done |
| M5 | Test runner, independent review, diff viewer, notifications, worktree cleanup | Next |

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
DEVPILOT_LIVE_CLAUDE=1 swift test --filter LiveClaudeTests   # real Claude runs (uses quota): read-only
                                                             # investigation + sandboxed implementation that must not commit
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

## Implementing an approved plan (M4)

On an approved ticket, **Implement** does the following:
1. Re-checks that the approval still matches the latest plan, word for word.
2. Runs the repository's checked **setup commands** in the worktree (e.g. `pnpm install`), with
   network access. These are your commands, run by DevPilot, not by Claude.
3. Runs Claude with the approved plan. Claude can edit files **in that worktree only** and run
   **only the checked commands** for the repository, inside Claude Code's sandbox: no network, no
   writes outside the worktree and build caches (`~/.m2`, `~/.gradle`, npm/pnpm stores), no reads of
   `~/.ssh`, cloud credentials or shell profiles, and the git metadata is read-only, so commits fail.
4. Verifies HEAD did not move, lists the changed files, and moves the ticket to *Validating* with
   Claude's report (what was done, commands run, deviations, remaining work).

You then review the changes in your IDE and commit them yourself. If a run fails or you stop it,
**Retry Implementation** goes back to the approved plan; **Restart** starts over from investigation.

**Per-repository commands:** Settings → Repositories → *Configure Commands…*. Detected
automatically from build files (top level and up to two folders down, for monorepos): Maven,
Gradle, npm, pnpm, yarn. Everything starts checked; uncheck what you don't want. Some commands
are always blocked (git writes, publish/deploy, curl, ssh, sudo).

**Build tools:** apps opened from Finder don't see your shell's `PATH`/`JAVA_HOME`. DevPilot
imports just those two from your login shell on first implementation (Settings → Agent →
*Import from Login Shell* to refresh).

**Branches:** new worktrees use your trackers' conventions so integrations link the PR:
`feat/sc-4211`, `fix/sc-4230`, `chore/sc-4300` (Shortcut) and `feat/PLAT-182`, `fix/MOB-77`
(Jira). Bugs get `fix/`, chores/tasks `chore/`, everything else `feat/`.

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
- After a crash, leftover Claude processes are stopped on the next launch (matched by process
  group *and* command, so an unrelated program can never be killed).
- Maven and Gradle builds inside the sandbox have not been verified against a real project yet.
  npm, pnpm, `javac`/`java` have. If a Gradle/Maven command fails with a sandbox violation, the
  transcript shows which path or connection was denied.
- Command rules match the start of a command (`pnpm` allows `pnpm anything`). Publishing and
  deploying are blocked by the deny list and, regardless of wording, by the network being off.
- M5: running the approved tests independently, a separate read-only review, diff viewer,
  notifications, worktree cleanup when a ticket is done.
