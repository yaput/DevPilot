# ADR 0001: Architecture and security boundaries

- Status: Accepted
- Date: 2026-10-30

## Context

DevPilot turns assigned Shortcut and Jira tickets into an AI-assisted workflow
(investigate → plan → human approval → implement → test → review → manual commit).
It runs on the developer's work Mac, drives a cloud coding agent (Claude Code CLI), and must
never commit, push, deploy or open PRs. It is distributed for personal use only, not
through the Mac App Store.

## Decisions

### 1. Native SwiftUI app built as a Swift package, not sandboxed

- Swift 6 language mode, SwiftUI, minimum macOS 15.
- `DevPilotCore` (domain, integrations, services; no UI imports) and the `DevPilot` app
  target are separate modules so the core is fully unit-testable.
- The app is **not** App-Sandboxed. It must launch `git`, `claude` and repository test
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

- `TicketProvider` exposes only reads. IDs are provider-prefixed and qualified by source
  (`shortcut:acme/4211`, `jira:acme.atlassian.net/PLAT-182`). Site URLs are user-configurable,
  so a bare issue key is not unique: without the source, switching Jira sites would attach one
  ticket's workflow state and approvals to an unrelated ticket with the same key.
- Each sync records the provider's complete assigned set. Tickets no longer returned are
  marked unassigned and hidden, unless their workflow is in progress.
- Site URLs must be https, and Shortcut pagination links are rejected if they point to another
  host, so tokens are never sent anywhere but the configured site.
- A sync that returns a ticket from another provider is rejected. One provider failing
  does not block the other.
- Ticket text is untrusted input. It is passed to the agent as data, never as instructions
  that can change tool policy.

### 5. App-controlled state lives outside agent-writable space

- The database and generated artifacts (`decision.md`, `review.md`, logs) live in
  `~/Library/Application Support/DevPilot/`, never inside a worktree.
- The agent runs in a per-ticket Git worktree only.

### 6. Agent execution boundaries

The spec named Codex. DevPilot uses **Claude Code** instead, because the developer's company
already uses it, behind the same `AgentRunner` protocol. It authenticates with the developer's
stored claude.ai login. `ANTHROPIC_API_KEY` is never passed to it.

Prompt instructions are not security controls. Enforcement relies on:

- **Investigation and review (read-only, implemented in M3):** `--tools Read,Grep,Glob` so no
  other tools exist, `--permission-mode dontAsk` so anything not allowed is denied,
  `--setting-sources user` plus `--strict-mcp-config` with no servers so the repository's
  `.claude/settings.json`, hooks and `.mcp.json` are ignored, `--no-session-persistence`, and a
  JSON schema for the result. Verified against Claude Code 2.1.314: in this configuration a
  repository hook did not run and its `Bash(*)` permission was ignored.
- **Implementation (M4):** write tools limited to the ticket worktree via Claude Code's sandbox,
  shell commands limited to an approved allowlist, `git commit`/`git push` and network denied.
- A worktree's Git metadata lives in the main repo's `.git/worktrees/<name>`, outside the
  writable root, so commits from inside the sandbox should fail. This must be covered by
  an integration test, not assumed.
- Child processes are started with `posix_spawn`: explicit executable and argument array (no
  shell), a complete replacement environment (`HOME`, `USER`, `LOGNAME`, `TMPDIR`, a fixed
  `PATH`, nothing else), no inherited file descriptors, and a new process group. Timeouts,
  cancellation and app quit terminate the whole group. Tests cover grandchild termination.
- Git runs with `core.hooksPath=/dev/null` when DevPilot creates worktrees, so a repository's
  `post-checkout` hook cannot execute. Branch and path names are slugged to `[a-z0-9_-]`, base
  refs starting with `-` are rejected, and worktree paths are checked to be inside the root.
- Per-ticket single-flight execution, wall-clock and step budgets.
- Test, lint and typecheck commands come only from a per-repository allowlist the user
  approves. Dependency setup (e.g. `npm ci`) is run by the app, not the agent.
- Sandbox permissions are never escalated silently; failures are shown to the user.

## Consequences

- Coworker distribution later requires a Developer ID certificate and notarization.
- Keeping enforcement in the core means the UI cannot bypass approval gates, at the cost
  of the persistence layer knowing workflow rules.
- Sending ticket text and source code to Claude relies on the company's existing approval of
  Claude for development.
- The repository's `CLAUDE.md` is not loaded automatically (a consequence of
  `--setting-sources user`). The prompt asks Claude to read `CLAUDE.md`, `AGENTS.md` and
  `CONTRIBUTING.md` as reference material instead.
