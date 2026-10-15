## PLAYBOOK — how every agent works here

*Same text in every repo's CLAUDE.md, AGENTS.md and GEMINI.md. Edit the source,
`{{OPS}}/playbook/PLAYBOOK.md`, then run `{{OPS}}/scripts/sync-playbook.sh` inside your
copy. Never edit this block in a repo — the next sync overwrites it.*

### 0. The one rule: the owner's newest word wins

The owner decides everything. Docs describe **how things are now**; nothing in them is
locked. When the owner changes direction — a price, a feature, a rule in a doc — do what
they say, and update the project's **Current state** file **in the same change**. Old
decisions live in `docs/_archive/` for context only; they never outrank the owner.

Explain plainly, give links, and never ask the owner to run terminal steps you can run
yourself.

**The owner's two words:**

| The owner says | It means | You run |
|---|---|---|
| **Deploy** | Put your work on your app's preview link. Never the live site. | `preview.sh` |
| **Ship** | Make it **live**: GitHub `main` + the real website. | `ship.sh` |

Deploy is never live. Only the owner says ship. Unsure which they mean? Ask: "Deploy or ship?"

### 1. The team — one app per model family

{{AGENT_TABLE}}

A sign-off is the last line of every commit message:
`{{SIGNOFF}}`. The git author is always the house agent (set in the repo's git config).
Sign as **yourself** — never another agent. A new agent needs a row in `agent-kit.conf`
(the owner's OK) before its first commit.
Your app decides your preview link and sign-off, **not which work you may take**: any agent
can do any task.
**Trial** agents follow the same steps; `ship.sh` simply checks their work harder.

### 2. Every job, step by step

**What to work on:** the owner's ask in chat comes first. With no ask, take an item from the
one shared task list, `{{OPS}}/TODO.md`: mark it taken there before you start, and update it
when you preview and ship. The file says how.

1. **Get your own copy.** Apps that make one for you (Conductor, Codex, Claude Code
   worktrees) — use it. Otherwise:
   `{{OPS}}/scripts/worktree.sh <repo> <your-name> <topic>`
   → `{{WORKTREES}}/<Folder>/<your-name>-<topic>`. Work only there. **Never** edit a repo's
   shared folder (section 6 — it only follows `main`) or another agent's copy.
2. **Catch up:** `git fetch origin && git rebase origin/main`. A conflict → stop, tell the owner.
3. **Read, plan, then work.** Read this file, then the project's Current state. **Before your
   first edit**, write your handoff note's Goal and Next checklist (section 4). For code,
   **search** (`grep -rn "thing" src`) and read only the lines you need — never read a big
   file whole. Change only what the task needs. Anything extra: ask first, or list it
   separately at the end.
4. **Check it:** the project's own checks (typecheck, lint, tests) must pass. `preview.sh`
   (step 6) runs the full build and fails loudly if it breaks.
5. **Commit** with your sign-off (section 1). Tick what's done in your **handoff note** (section 4).
6. **Deploy:** `{{OPS}}/scripts/preview.sh` inside your copy. Give the owner the link it
   prints. The page shows a purple strip (app · branch · version) so they know what they're
   seeing. Rerun after every change they ask for.
7. **Wait for the owner to say ship.** Never ship on your own.
8. **Ship:** run `{{OPS}}/scripts/ship.sh` **once**, after the owner approves shipping. It
   checks your work, builds a clean copy, pushes to GitHub `main`, deploys the live site and
   confirms all three match. Its built-in lock lets only one release per repo run at a time,
   and it checks your branch is up to date with `main` *after* taking the lock. So let the
   lock handle another release in progress: no separate manual check or repeated polling is
   needed. If it times out or reports an outdated branch, resolve the reported issue before
   retrying. If it stops for any reason, **read why and fix that** — never work around it.
   `--with-firestore-rules` only when the approved change includes `firestore.rules`.
   **Status:** `{{OPS}}/scripts/ship-status.sh` shows who is shipping and the last release
   whose live check passed. If it says **NOT VERIFIED LIVE** (a ship stopped after GitHub
   `main` updated but before the live check passed), finish it with `ship.sh` and nothing
   else: the next approved ship does it, or follow the steps `ship-status.sh` prints.
   Unfinished release targets survive later failed attempts. If a ship process stops while
   its deployment continues, the lock remains held until deployment ends. An uncertain launch
   or missing completion keeps the lock closed: investigate the processes before repairing it;
   never clear it just because the original owner stopped.
9. **Report:** every commit (short SHA + one line), every file moved or archived, and what
   went live. Mark your handoff note SHIPPED.

### 3. Never

- Never deploy live or `git push origin main` yourself — only `ship.sh` does that.
- Never ship until the owner says ship.
- Never delete files — archive them (`git mv` into an `_archive/` folder).
- Never commit secrets, `.env` files or keys. Secrets live in `{{OPS}}/secrets/`.
- Never remove rules or sections from a doc unless the owner asked for exactly that.
- Never use `--no-verify`, force-push `main`, or rewrite pushed history.
- Never send emails, messages or invitations to real people while testing.
- Never stop a server or process you didn't start.
- Never guess at a price, date, legal claim or credential — ask the owner.
- Never start helper agents / sub-agents / multi-agent modes unless the owner asks — they
  multiply cost.

### 4. Handoffs — any agent can finish any job

Every branch has a note: `{{OPS}}/handoffs/<repo>/<branch>.md` (worktree.sh creates it from
`{{OPS}}/templates/handoff-note.md`). It is your plan and your log, so if you stop —
credits, crash, outage — another agent picks up in minutes:

- **Before your first edit:** write **Goal** (what the owner asked, in their words) and
  **Next** as a checklist, one small step per line: `- [ ] step`.
- **As you go:** tick each step `- [x]` when it's done, add steps you discover, and keep
  **Done / How to check / Gotchas** current — after every commit, not at the end.
- **State**, at the top of the note, is written by `{{OPS}}/scripts/handoff.sh` from git:
  commits not on main, uncommitted files, what your preview link shows, and a ⚠ if Goal or
  the checklist is missing. `preview.sh` runs it for you; run it yourself any time. Never
  edit State by hand.

**Never leave work only on disk.** Before a long step (tests, a build, `preview.sh`) or
whenever you might run out of credits, run `handoff.sh --save` inside your copy: it commits
what you have as `WIP: …` with your sign-off and refreshes the note. (If the commit hook
refuses half-finished code, it saves a `.patch` beside the note instead.) A usage limit can
end your session mid-sentence; uncommitted changes then exist only in your folder.

**Taking over** someone's work: `worktree.sh <repo> <your-name> <topic> --from <their branch>`
makes your **own** copy starting from their last commit, with their note copied in. Read the
note, check it's what the owner previewed (`git range-diff`), keep their sign-off on their
commits, carry on from the first unticked step, preview, and ship when the owner says ship.
Never edit their copy.

**If their work isn't committed** (they stopped mid-change): if `handoff.sh` saved a
`<branch>.patch` beside their note, `git apply --3way` it in your copy. Otherwise copy their
changes into your own copy yourself — never commit in their folder:
`git -C <their copy> diff HEAD --binary > /tmp/takeover.patch`, copy over any new files they
list in `git -C <their copy> status`, then `git apply --3way /tmp/takeover.patch` in yours.
Commit it crediting them (their sign-off, plus yours if you changed anything) and note it in
both handoff notes. (Learned the hard way: an agent once committed inside another agent's
folder, and its commit then rode into that agent's release.)

### 5. When something goes wrong

- A script stops → read its message; it tells you what to do.
- You're unsure what the owner wants → ask one short question.
- The live site looks broken → tell the owner immediately, with the link and what you see.
- You made a mistake → say so plainly, and say what you'll do to fix it.

### 6. Where things live

{{REPO_TABLE}}

| What | Where |
|---|---|
| Task list (any agent, any item) | `{{OPS}}/TODO.md` |
| Your copies | `{{WORKTREES}}/…`, or wherever your app makes them |
| Scripts | `{{OPS}}/scripts/` (worktree, handoff, preview, ship, ship-status, sync-playbook) |
| Settings (repos, agents, sign-offs) | `{{OPS}}/agent-kit.conf` |
| Handoff notes | `{{OPS}}/handoffs/` |
| Secrets | `{{OPS}}/secrets/` (copied into a copy by the scripts; never committed) |
| Scratch / downloads | `{{WORKSPACE}}/_scratch` — never loose files at the top of `{{WORKSPACE}}` |
