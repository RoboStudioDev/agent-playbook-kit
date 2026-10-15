#!/usr/bin/env bash
# handoff.sh — write a copy's current state into its handoff note, so any agent
# can take over if this one stops (credits, crash, outage).
#
#   handoff.sh                 inside your copy: refresh your note's State section
#   handoff.sh <copy folder>   the same for another agent's copy (reads it, never changes it)
#   handoff.sh --save          inside your OWN copy: first commit any unfinished work
#                              as "WIP: …" with your sign-off, then refresh the note
#
# The note is <kit>/handoffs/<repo>/<branch>.md. This script rewrites
# only the part between <!-- state:start --> and <!-- state:end -->, from git:
# commits not yet on main, uncommitted files, what the app's preview link shows,
# and whether the agent has written its Goal and Next checklist. Goal / Done /
# Next / Gotchas stay the agent's job. preview.sh runs this after every preview.
#
# If --save's commit is refused (half-finished code can fail the lint hook), the
# work is saved instead as <branch>.patch beside the note; the next agent applies
# it in their own copy with: git apply --3way <that file>
source "$(dirname "$0")/_agent-common.sh"

SAVE=""
COPY=""
for a in "$@"; do
  case "$a" in
    --save) SAVE=1 ;;
    -*) die "Unknown option '$a'. Usage: handoff.sh [<copy folder>] [--save]" ;;
    *) [ -z "$COPY" ] || die "Usage: handoff.sh [<copy folder>] [--save]"; COPY=$a ;;
  esac
done
# --save commits, so only ever in your own copy (learned the hard way: an agent
# committed in another agent's folder, and its commit rode into that agent's release).
[ -z "$SAVE" ] || [ -z "$COPY" ] || die "--save commits, so run it inside your OWN copy, without a folder name."
[ -z "$COPY" ] || cd "$COPY" 2>/dev/null || die "No folder '$COPY'."

repo_info "$(current_repo)"
require_own_copy
TOP=$(git rev-parse --show-toplevel)
cd "$TOP"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BRANCH" != HEAD ] || die "This copy is not on a branch, so it has no handoff note."
ensure_note "$BRANCH"
NOTE=$(note_path "$BRANCH")
PATCH="${NOTE%.md}.patch"

# Everything uncommitted, new files included, as one patch — built in a scratch
# index so the copy's own staging area is left exactly as it was.
make_patch() { # <output file>
  local idx
  idx=$(mktemp)
  GIT_INDEX_FILE=$idx git read-tree HEAD
  GIT_INDEX_FILE=$idx git add -A
  GIT_INDEX_FILE=$idx git diff --cached --binary HEAD >"$1"
  rm -f "$idx"
}

SAVED=""
if [ -n "$SAVE" ] && [ -n "$(git status --porcelain)" ]; then
  SIGN=$(trailer_for "$BRANCH")
  say "Committing your unfinished work as WIP…"
  git add -A
  if git commit -q -m "WIP: $BRANCH — handoff snapshot (unfinished; see the handoff note)${SIGN:+

$SIGN}"; then
    SAVED="committed $(git rev-parse --short HEAD)"
    rm -f "$PATCH"
    # Only the house agent (blank "signs as" in AGENTS) commits without a sign-off.
    [ -n "$SIGN" ] || { agent_row "$(slug "${BRANCH%%/*}")" && [ -z "$A_SIGNER" ]; } ||
      say "No sign-off was added for '$BRANCH'. Add yours: git commit --amend (last line: your Co-Authored-By)."
  else
    git reset -q
    make_patch "$PATCH"
    SAVED="the commit hook refused, so it is saved as $PATCH"
    say "The commit hook refused the WIP commit. Saved your changes as $PATCH instead."
  fi
fi

# ── What git says ─────────────────────────────────────────────────────────────
HEAD_SHORT=$(git rev-parse --short HEAD)
MAIN_SHORT=$(git rev-parse --short origin/main 2>/dev/null || echo "?")
AHEAD=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "?")
BEHIND=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "?")
COMMITS=$(git log --format='  - `%h` %s (%ad)' --date=format:'%b %-d %-I:%M %p' -15 origin/main..HEAD 2>/dev/null || true)
DIRTY=$(git status --porcelain | sed 's/^/  /' | head -20 || true)
NDIRTY=$(git status --porcelain | wc -l | tr -d ' ')
if [ "$NDIRTY" -eq 0 ] && [ -z "$SAVE" ]; then rm -f "$PATCH"; fi

LANE=$(lane_of "$TOP" "$BRANCH")
PREVIEW="none recorded"
if [ -n "$LANE" ] && [ -f "$(lane_record "$LANE")" ]; then
  read -r P_SHA P_STATE P_BRANCH P_URL P_WHEN <"$(lane_record "$LANE")" || true
  if [ "${P_BRANCH:-}" = "$BRANCH" ]; then
    PREVIEW="$P_URL — this branch @ \`${P_SHA:0:7}\`$([ "$P_STATE" = clean ] || echo ' + uncommitted changes'), $P_WHEN"
    [ "${P_SHA:-}" = "$(git rev-parse HEAD)" ] && [ "$P_STATE" = clean ] ||
      PREVIEW="$PREVIEW (⚠ not the latest commit — run preview.sh again)"
  else
    PREVIEW="the '$LANE' link now shows ${P_BRANCH:-?}, not this branch — run preview.sh to put it back"
  fi
fi

# Has the agent written its plan? (Goal or Next still blank. The template's
# one-line <!-- hints --> don't count as written.)
section() {
  awk -v h="## $1" 'index($0, h) == 1 { f = 1; next } /^## / { f = 0 }
    f && NF && !/^[[:space:]]*<!--.*-->[[:space:]]*$/' "$NOTE"
}
WARN=""
GOAL=$(section Goal || true)
[ -n "$GOAL" ] || WARN="$WARN
- ⚠ **Goal is blank.** Write what $OWNER_NAME asked for, in their words."
NEXT=$(section Next || true)
if [ -z "$NEXT" ]; then
  WARN="$WARN
- ⚠ **Next is blank.** Write the plan as a checklist: \`- [ ] step\`, ticked \`- [x]\` when done."
elif ! printf '%s\n' "$NEXT" | grep -q -- '- \[[ xX]\]'; then
  WARN="$WARN
- ⚠ **Next has no checklist.** Write steps as \`- [ ] step\` and tick them \`- [x]\` when done."
fi

if [ "$NDIRTY" -eq 0 ]; then
  UNCOMMITTED="none"
elif [ -f "$PATCH" ]; then
  UNCOMMITTED="$NDIRTY file(s), also saved as \`$PATCH\`:
$DIRTY"
else
  UNCOMMITTED="$NDIRTY file(s) — **on disk only**; the agent should commit (\`handoff.sh --save\`):
$DIRTY"
fi

STATE_FILE=$(mktemp)
trap 'rm -f "$STATE_FILE"' EXIT
cat >"$STATE_FILE" <<EOF
**State** — written by \`handoff.sh\`, $(date '+%Y-%m-%d %H:%M'). Don't edit by hand.
- Copy: \`$TOP\` · branch \`$BRANCH\` @ \`$HEAD_SHORT\`
- GitHub main is \`$MAIN_SHORT\` (as of the last fetch): this branch is $AHEAD commit(s) ahead, $BEHIND behind
- Commits not on main yet:
${COMMITS:-  - none}
- Uncommitted: $UNCOMMITTED${SAVED:+
- Just saved: $SAVED}
- Preview: $PREVIEW${WARN}
- To take over: \`$SCRIPTS/worktree.sh $REPO <you> <topic> --from $BRANCH\`
EOF

node -e '
  const fs = require("fs");
  const [file, stateFile] = process.argv.slice(1);
  const state = fs.readFileSync(stateFile, "utf8").trimEnd();
  let s = fs.readFileSync(file, "utf8");
  const a = s.indexOf("<!-- state:start -->"), b = s.indexOf("<!-- state:end -->");
  const block = "<!-- state:start -->\n" + state + "\n<!-- state:end -->";
  if (a >= 0 && b > a) s = s.slice(0, a) + block + s.slice(b + "<!-- state:end -->".length);
  else {
    // An older note without the markers: put the State block under its title.
    const nl = s.indexOf("\n");
    s = nl < 0 ? s + "\n\n" + block + "\n" : s.slice(0, nl + 1) + "\n" + block + "\n" + s.slice(nl + 1);
  }
  fs.writeFileSync(file, s);
' "$NOTE" "$STATE_FILE"

say "Handoff note updated: $NOTE"
[ -z "$WARN" ] || printf '%s\n' "$WARN" | sed '/^$/d; s/\*\*//g; s/`//g; s/^- /  /'
