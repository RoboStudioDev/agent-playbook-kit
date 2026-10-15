#!/usr/bin/env bash
# worktree.sh <repo> <agent> <topic> [--from <branch>] — give an agent its own copy of a repo.
#
#   worktree.sh web-app opus family-chat
#   worktree.sh marketing-site codex pricing-copy
#   worktree.sh web-app opus invoices-tab --from codex/landing-downloads
#
# Makes $WORKTREES/<Folder>/<agent>-<topic> on a new branch <agent>/<topic>,
# started from the latest GitHub main — or, with --from, from another agent's
# branch (taking over its work; see handoff.sh) — with its .env, node_modules,
# git hooks and handoff note in place. Work, commit, preview.sh and ship.sh all
# happen there.
#
# Apps that already give each chat its own copy (Conductor, Codex, Claude Code
# worktrees) don't need this; preview.sh, ship.sh and handoff.sh work there too.
source "$(dirname "$0")/_agent-common.sh"

FROM=""
if [ $# -eq 5 ] && [ "$4" = "--from" ]; then FROM=$5; set -- "$1" "$2" "$3"; fi
[ $# -eq 3 ] || die "Usage: worktree.sh <$(repo_names | sed 's/ $//; s/ /|/g')> <agent> <topic> [--from <branch>]"
repo_info "$1"
AGENT=$(slug "$2")
TOPIC=$(slug "$3")
[ -n "$AGENT" ] && [ -n "$TOPIC" ] || die "Agent and topic need letters or numbers."
# The agent name decides which app's preview link the copy uses (AGENTS in agent-kit.conf).
is_in "$AGENT" "$LANE_AGENTS" || die "Unknown agent '$AGENT'. Use your own name, one of:
  $LANE_AGENTS
  (A new agent needs a row in AGENTS in $CONF first — $OWNER_NAME's OK.)"

MAIN="$WORKSPACE/$FOLDER"
BRANCH="$AGENT/$TOPIC"
DEST="$WORKTREES/$FOLDER/$AGENT-$TOPIC"

[ ! -e "$DEST" ] || die "$DEST already exists — cd into it and carry on."
git -C "$MAIN" show-ref --verify -q "refs/heads/$BRANCH" && die "Branch $BRANCH already exists."

say "Fetching the latest main${FROM:+ and $FROM}…"
git -C "$MAIN" fetch -q origin main
START=origin/main
if [ -n "$FROM" ]; then
  # Every copy on this machine shares one git store, so another agent's branch is
  # usually right here; GitHub is only the fallback.
  if git -C "$MAIN" show-ref --verify -q "refs/heads/$FROM"; then
    START="$FROM"
  else
    git -C "$MAIN" fetch -q origin "$FROM" ||
      die "No branch '$FROM' on this machine or on GitHub. Check the name: git -C $MAIN branch --list"
    START="origin/$FROM"
  fi
fi
mkdir -p "$(dirname "$DEST")"
# --no-track: a plain `git push` from here must never go to main by accident.
git -C "$MAIN" worktree add -q --no-track -b "$BRANCH" "$DEST" "$START"
place_env "$DEST"

# node_modules: an instant copy-on-write clone of the main folder's when it is
# up to date and the lockfiles match (macOS APFS), otherwise a clean install.
if [ -d "$MAIN/node_modules" ] && cmp -s "$MAIN/package-lock.json" "$DEST/package-lock.json" &&
  deps_match "$MAIN" && cp -cR "$MAIN/node_modules" "$DEST/node_modules" 2>/dev/null; then
  say "node_modules cloned from the main folder."
  # A clone skips npm's prepare step, which installs the git hooks (husky).
  (cd "$DEST" && npm run prepare --if-present >/dev/null 2>&1) || true
else
  rm -rf "$DEST/node_modules"
  say "Installing dependencies…"
  (cd "$DEST" && npm ci --no-audit --no-fund)
fi

# The handoff note: a taken-over branch starts from its previous agent's note.
if [ -n "$FROM" ] && [ -f "$(note_path "$FROM")" ] && [ ! -f "$(note_path "$BRANCH")" ]; then
  mkdir -p "$(dirname "$(note_path "$BRANCH")")"
  { printf '> Taken over from `%s` on %s.\n\n' "$FROM" "$(date '+%Y-%m-%d %H:%M')"
    cat "$(note_path "$FROM")"; } >"$(note_path "$BRANCH")"
else
  ensure_note "$BRANCH"
fi

cat <<EOF

✓ Your copy is ready.
  Folder:  $DEST
  Branch:  $BRANCH (from $START $(git -C "$DEST" rev-parse --short HEAD))
  Note:    $(note_path "$BRANCH")   ← write Goal + Next before your first edit

  Preview: $SCRIPTS/preview.sh    (run inside the folder → your app's link: $(lane_of "$DEST" "$BRANCH"))
  Ship:    $SCRIPTS/ship.sh       (after $OWNER_NAME approves the preview)
  Handoff: $SCRIPTS/handoff.sh    (if you have to stop before it ships)
EOF
