# <Project name> — instructions for every AI agent

<!-- Put this file at the top of each repo as CLAUDE.md. Your project's own facts
go above or below the Playbook block. sync-playbook.sh rewrites ONLY what sits
between the two playbook markers, and copies the whole file to AGENTS.md and
GEMINI.md so every app's agent reads the same thing. -->

## What this is

One paragraph: what the project does, who it's for, what it's built with.

## Current state

See `STATE.md`: what is true right now. Updated in the same change whenever the
owner changes direction.

## Run it

- Install: `npm ci`
- Develop: `npm run dev`
- Checks that must pass: `npm run typecheck`, `npm run lint`

<!-- playbook:start -->
(run sync-playbook.sh inside your copy to fill this in)
<!-- playbook:end -->
