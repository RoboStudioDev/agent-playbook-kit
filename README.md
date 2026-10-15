# Agent Playbook Kit

**How one person runs a team of AI coding agents, from several different apps, on the same
codebase, without them breaking each other's work or the live site.**

This kit is a working system, not a thought experiment. It's the cleaned-up version of a setup
that runs a small studio's products day to day with agents in Claude Code, Codex, Cursor,
Conductor, Antigravity and a local model, and it's built so the owner never has to open a
terminal. It's two things:

- **A Playbook** (`playbook/PLAYBOOK.md`): one page of rules every agent reads, stamped into
  each repo's `CLAUDE.md`, `AGENTS.md` and `GEMINI.md` so every app's agent gets the same text.
- **Eight shell scripts** (`scripts/`) that make those rules hard to break by accident.

## The problem

Give several AI agents the same repo and the same person to answer to, and the same things go
wrong:

- Two agents edit the same folder and overwrite each other's work, or one ships the other's
  half-finished change.
- An agent runs out of credits mid-task, and whatever it hadn't saved is gone, along with its
  plan.
- The owner gets five preview links and can't tell which one shows what.
- Someone deploys straight to production, or pushes over another agent's release.
- Nobody knows what's being worked on, so two agents start the same task and nobody starts
  the next one.

## Five rules, each one backed by a script

| Rule | What it means | Enforced by |
|---|---|---|
| **1. Own copy per agent** | Every agent works in its own copy of the repo (a git worktree) on its own branch, never in the shared folder and never in another agent's copy. | `worktree.sh` makes the copy. Every other script refuses to run in the shared folder. |
| **2. Plan-first handoff notes** | Before its first edit, an agent writes down the goal and a step-by-step checklist. It ticks steps as it goes, so if it stops, any other agent can pick up from the first unticked step. | `handoff.sh` writes the note's State section from git and flags a missing plan. `--save` commits unfinished work as WIP so nothing lives only on disk. |
| **3. One preview link per app** | Each app (Claude Code, Codex, Cursor…) has exactly one preview link, so the owner has one bookmark per app. Every preview page carries a small purple strip saying which app, branch and commit it shows. | `preview.sh` builds and deploys to that app's link, and records exactly what it shows. |
| **4. One guarded way to ship** | "Deploy" means the preview link. "Ship" means live, and only the owner says it. There is exactly one way to go live, and it checks everything first. | `ship.sh`, with `ship-status.sh` to see who is shipping and whether the last release really went live. |
| **5. One shared task list** | One list for every agent in every app. Any agent can take any ready item; it marks it taken first. Only the owner adds work. | `TODO.md` (start from `templates/TODO.md`). |

And one more: **one Playbook, everywhere.** `sync-playbook.sh` fills the Playbook's team and
repo tables from the same settings file the scripts use, so the rules agents read always match
what the scripts enforce.

## A job, start to finish

```
Owner asks (or the task list has a Ready item)
  └─ agent marks it taken in TODO.md
  └─ worktree.sh web-app codex pricing-copy     → its own copy + branch + handoff note
  └─ writes Goal + Next checklist in the note    → before the first edit
  └─ works, commits with its sign-off, ticks steps
  └─ preview.sh                                  → the "codex" preview link, purple strip on
Owner looks at the link: "change X" → agent changes, previews again
Owner: "ship"
  └─ ship.sh                                     → GitHub main + live site, checked to match
  └─ agent marks the task done in TODO.md
```

If the agent stops halfway (credits, crash), another agent, in any app, runs
`worktree.sh web-app opus pricing-copy --from codex/pricing-copy`, reads the note and carries on.

## What `ship.sh` checks before anything goes live

1. **No uncommitted changes**, and the branch already contains everything on GitHub `main`.
2. **One ship at a time per repo**: an atomic lock. A lock is only cleared when its owner process
   is provably gone *and* its deploy is known to have finished; a crashed ship can't let a
   second one race it.
3. **Only what the owner saw**: the app's preview link must show this exact work. If the agent
   changed anything after the preview, or another agent previewed over it, it refuses.
4. **Every sign-off is a known agent**: commits signed by an agent that isn't in the settings
   file are refused.
5. **Nothing deleted**: files get archived, not deleted (an explicit flag overrides it, and
   never for trial agents).
6. **Trial agents can't gut a doc**: an agent you're still trying out can edit any doc, but
   its own commits can't remove more than 10 lines from one.
7. **Server-side files are flagged**: database rules need an explicit flag; files the script
   doesn't deploy are listed so nobody thinks they went live.

Then it builds a **clean copy of exactly that commit** (never a working folder), pushes it to
GitHub `main` (fast-forward only, never forced), deploys that build, and checks that the live
site serves it. Every step is recorded. If a ship stops after GitHub `main` changed but before
the live check passed, `ship-status.sh` says **NOT VERIFIED LIVE**, and the next `ship.sh`
finishes it. The live site therefore always equals GitHub `main`.

## What's in here

```
agent-kit.conf            the ONE file you edit: repos, agents, sign-offs, build, host
playbook/PLAYBOOK.md      the rules every agent reads ({{…}} parts are filled from agent-kit.conf)
scripts/
  worktree.sh             give an agent its own copy (or take over another agent's branch)
  handoff.sh              refresh a handoff note from git; --save commits unfinished work
  preview.sh              build and deploy to the app's one preview link
  ship.sh                 the only way to go live, with the checks above
  ship-deploy.sh          small guardian ship.sh starts so a killed ship can't free its lock mid-deploy
  ship-status.sh          who is shipping, and the last release that passed its live check
  sync-playbook.sh        stamp the Playbook into a repo's CLAUDE.md / AGENTS.md / GEMINI.md
  _agent-common.sh        shared helpers (sourced, not run)
  host-firebase.sh        the hosting adapter: the only file that knows about the host
templates/
  TODO.md                 the blank shared task list, with its rules
  handoff-note.md         what every new handoff note starts from
  project-CLAUDE.md       a repo's agent instructions, with the Playbook markers in place
tests/smoke-test.sh       runs the whole kit end to end in a throwaway sandbox, offline
```

## Setting it up

You need: a Mac or Linux machine, `git`, Node.js 18 or newer, a GitHub repo per project, and a
static site build (Vite works out of the box). The included host is Firebase Hosting; see
"Another host" below.

1. **Put this folder beside your repos**, for example `~/Developer/_ops` (the underscore keeps
   it apart from project folders). Each repo should be cloned at `~/Developer/<Folder>`; that
   shared folder only ever follows `main`.
2. **Fill in `agent-kit.conf`**: your repos, your agents and which app each runs in, your
   sign-off address, your build command. Then set `KIT_CONFIGURED=yes`. Until you do, every
   script refuses to run.
3. **Start the task list:** copy `templates/TODO.md` to `TODO.md` in this folder.
4. **Secrets:** if a repo needs a `.env`, put it in `secrets/` under the name you gave it in
   `agent-kit.conf`. The scripts copy it into each agent's copy; it is never committed.
5. **Stamp the Playbook into each repo:** add `templates/project-CLAUDE.md` as the repo's
   `CLAUDE.md` (or add its two `playbook` marker lines to yours), make a copy with
   `worktree.sh`, run `sync-playbook.sh` inside it, then preview and ship like any change.
6. **Tell your agents:** from then on, every agent in every app reads the Playbook from the
   repo. Point them at a task in `TODO.md`, or just ask for something.

Run `bash tests/smoke-test.sh` to watch the whole flow work in a sandbox first. It fakes GitHub,
the host and the live site, touches nothing real, and needs no settings filled in.

## Another host

Everything host-specific is in `scripts/host-firebase.sh`: three small functions that check
the repo points at the right project, deploy a preview, and deploy live. To use Netlify,
Vercel, Cloudflare Pages or your own server, copy it to `host-<name>.sh`, rewrite those three,
and set `HOST_ADAPTER=<name>`. The locks, records, guardrails and live check don't change.

(Two Firebase-specific checks remain in `ship.sh`: the `--with-firestore-rules` flag and the
list of server files it won't deploy. They do nothing on a site without those files.)

## Why it's built this way

- **The owner never types a command.** Agents run every script and explain in plain words;
  the owner decides by looking at a link and saying "ship".
- **Rules live in scripts, not just in prompts.** A model can misread a rule; it can't talk
  its way past `ship.sh`. The Playbook explains the why, the scripts make the mistake hard.
- **Any agent can finish any job.** Apps change, models get pulled, subscriptions lapse, credits
  run out mid-sentence. Plans and progress live in a note outside the agent, so the work
  doesn't depend on any one of them.
- **Trial agents get the same tools, checked harder.** A new or cheaper model follows the same
  steps and can ship; the guardrails just watch its commits more closely.
- **Every rule came from something going wrong.** An agent committed inside another agent's
  folder and its commit rode into that agent's release, so `--save` only runs in your own copy.
  A killed ship could free its lock while its deploy kept running, so the lock now waits for the
  deploy guardian. Each of those lessons is written beside the code it changed.
- **Small, plain, inspectable.** Bash and a little Node, no service to run, no database. Every
  record is a text file you can open.

## Limits

- Tested on macOS with its built-in bash 3.2; it should run on Linux too (copies of
  `node_modules` fall back to `npm ci` there).
- One release branch, `main`, per repo.
- Built for static sites whose `index.html` loads one hashed main script; that file name is
  how `ship.sh` proves which build is live.

## License

MIT — free to use, change and share; keep the copyright line. See `LICENSE`.
