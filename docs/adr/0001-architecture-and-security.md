# ADR 0001: Architecture and security boundaries

- Status: Accepted
- Date: 2026-10-30

## Context

DevPilot turns assigned Shortcut and Jira tickets into an AI-assisted workflow
(investigate → plan → human approval → implement → test → review → manual commit).
It runs on the developer's work Mac, drives a cloud coding agent (Codex CLI), and must
never commit, push, deploy or open PRs. It is distributed for personal use only, not
through the Mac App Store.

## Decisions

### 1. Native SwiftUI app built as a Swift package, not sandboxed

- Swift 6 language mode, SwiftUI, minimum macOS 15.
- `DevPilotCore` (domain, integrations, services; no UI imports) and the `DevPilot` app
  target are separate modules so the core is fully unit-testable.
- The app is **not** App-Sandboxed. It must launch `git`, `codex` and repository test
  commands against arbitrary local repositories, which App Sandbox forbids. This also
  rules out App Store distribution, which is acceptable.
- `scripts/build-app.sh` assembles and signs `DevPilot.app`. Ad-hoc signing works; a stable
  Apple Development identity is preferred so Keychain ACLs survive rebuilds.

### 2. One state machine, enforced in the persistence layer

- `WorkflowState.allowedNextStates` is the only definition of legal transitions.
- Every transition runs inside one SQLite write transaction together with its audit
  event (`AppDatabase.applyTransition`). Illegal transitions throw and leave no trace.
- `needs_clarification` can only return to `investigating`. Only
  `awaiting_plan_approval` can reach `approved`, and only `approved` (plus the bounded
  fix-retry edges from `validating`/`reviewing`) can reach `implementing`.
- On launch, any ticket in a running state (`investigating`, `implementing`,
  `validating`, `reviewing`) is moved to `failed`. Runs are never resumed automatically.

### 3. Approval is bound to plan content

- Decision documents are versioned; each stores a SHA-256 of its Markdown.
- An approval records the hash of the exact plan the user saw. Recording fails if that
  hash is not the latest plan's.
- New plan versions can only be saved while `investigating`, so a plan cannot be replaced
  under a pending or granted approval.
- `ImplementationGate.evaluate` recomputes the hash of the latest plan and must return
  `.allowed` before any code-writing agent runs.

### 4. Ticket providers are read-only and identity-preserving

- `TicketProvider` exposes only reads. IDs are always provider-prefixed
  (`shortcut:4211`, `jira:PLAT-182`).
- A sync that returns a ticket from another provider is rejected. One provider failing
  does not block the other.
- Ticket text is untrusted input. It is passed to the agent as data, never as instructions
  that can change tool policy.

### 5. App-controlled state lives outside agent-writable space

- The database and generated artifacts (`decision.md`, `review.md`, logs) live in
  `~/Library/Application Support/DevPilot/`, never inside a worktree.
- The agent runs in a per-ticket Git worktree only.

### 6. Agent execution boundaries (M3/M4; recorded now so earlier work does not erode them)

Prompt instructions and `auto_commit: false` are not security controls. Enforcement relies on:

- Codex `--sandbox read-only` for investigation and review, and `--sandbox workspace-write`
  with network disabled for implementation, rooted at the ticket worktree via `-C`.
- A worktree's Git metadata lives in the main repo's `.git/worktrees/<name>`, outside the
  writable root, so commits from inside the sandbox should fail. This must be covered by
  an integration test, not assumed.
- `Process` launched with an explicit executable path and an argument array (no shell
  string), plus an environment allowlist: no `SSH_AUTH_SOCK`, cloud credentials or tokens.
- Each run in its own process group so cancellation terminates the whole tree.
- Per-ticket single-flight execution, wall-clock and step budgets.
- Test, lint and typecheck commands come only from a per-repository allowlist the user
  approves. Dependency setup (e.g. `npm ci`) is run by the app, not the agent.
- Sandbox permissions are never escalated silently; failures are shown to the user.

## Consequences

- Coworker distribution later requires a Developer ID certificate and notarization.
- Keeping enforcement in the core means the UI cannot bypass approval gates, at the cost
  of the persistence layer knowing workflow rules.
- Sending ticket text and source code to a cloud model requires company policy approval
  before M3 is used on real repositories.
