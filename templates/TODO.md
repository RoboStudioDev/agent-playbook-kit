# To do — one list for every agent

Everything the owner has asked for that isn't finished, for every project. **There are no
lanes:** any agent, in any app, can take any item. If one model is pulled or a subscription
lapses, the work carries on with whoever is left.

<!-- Copy this file to TODO.md in the kit's folder (beside agent-kit.conf) and replace
the example items. -->

## How to use it

1. **The owner's ask in chat comes first.** With no ask, take the top item under **Ready**
   that you can finish.
2. **Take it:** re-read this file, then change `- [ ]` to `- [~]` and add
   `— taken by <you>, <date>, branch <branch>`. Already `[~]`? Take another one.
3. **Work it** the Playbook way: your own copy, handoff note first, preview.
4. **Preview ready:** add `— preview <link>, waiting for the owner`. Never ship until the
   owner says ship.
5. **Shipped / done:** change it to `- [x]`, add `— <short SHA or what happened>, <date>`,
   and move it to **Done** (keep the last ten).
6. **Stopped part-way** (credits, crash)? Leave the `[~]`; your handoff note says where you
   stopped. A `[~]` item whose handoff note hasn't changed in a day is free to take over
   (Playbook §4, "Taking over").
7. **Only the owner adds work.** When they ask for something that won't be finished this
   session, add it under **Ready** in their words, with the date. Never move a **Later** item
   up, and never add your own ideas — tell the owner instead.

Detail lives where each item points (a project's backlog file, its Current state file).

## Ready — the owner said go

### <Project A>

- [ ] **Short name of the task** (owner, YYYY-MM-DD: "their words"). What done looks like,
  in a sentence or two. Where the detail lives.

### <Project B>

- [ ] **Short name of the task** (owner, YYYY-MM-DD: "their words"). What done looks like.

## Waiting on a reply — nothing to do until it arrives

- **Who** — what was asked, YYYY-MM-DD.

## Later — the owner said later; don't start until they say go

- **Short name** — why it's parked, in the owner's words (YYYY-MM-DD).

## Done (last ten)

- [x] **Short name** — `abc1234`, YYYY-MM-DD (agent). What went live, how it was checked.
