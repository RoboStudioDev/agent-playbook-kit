# _agent-common.sh — shared by worktree.sh, preview.sh, handoff.sh, ship.sh and the
# rest. Sourced, never run.
#
# The multi-agent setup: every agent works in its OWN copy of a repo (a git
# worktree), previews on its app's ONE preview link, ships with ship.sh (which
# deploys only a clean build of what is on GitHub main), and hands unfinished
# work to another agent with handoff.sh. So agents can work, preview, ship and
# take over from each other without touching each other's files.
#
# Nothing in here names a person, project, path or host: those come from
# agent-kit.conf (one folder up), and deploying goes through host-<name>.sh.

set -euo pipefail

KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS="$KIT/scripts"
TEMPLATES="$KIT/templates"
CONF=${AGENT_KIT_CONF:-"$KIT/agent-kit.conf"}

die() { DIE_MSG=$*; printf '\n✖ %s\n' "$*" >&2; exit 1; } # DIE_MSG: ship.sh records why it stopped
say() { printf '→ %s\n' "$*"; }

[ -f "$CONF" ] || die "Missing the kit's settings file, $CONF."
# shellcheck source=../agent-kit.conf
source "$CONF"
[ "${KIT_CONFIGURED:-no}" = yes ] ||
  die "The kit isn't set up yet. Fill in $CONF, then set KIT_CONFIGURED=yes in it."
declare -p REPOS AGENTS >/dev/null 2>&1 || die "$CONF needs a REPOS list and an AGENTS list."
[ -n "${SIGN_EMAIL:-}" ] || die "$CONF needs SIGN_EMAIL (the address on agents' commit sign-offs)."

OWNER_NAME=${OWNER_NAME:-the owner}
WORKSPACE=${WORKSPACE:-"$HOME/Developer"}
WORKTREES=${WORKTREES:-"$WORKSPACE/_worktrees"}
SECRETS=${SECRETS:-"$KIT/secrets"}
LOCKS=${LOCKS:-"$KIT/locks"}
HANDOFFS=${HANDOFFS:-"$KIT/handoffs"}
SIGN_TAG=${SIGN_TAG:-agent}
BUILD_CMD=${BUILD_CMD:-npm run build}
BUILD_DIR=${BUILD_DIR:-dist}
BUNDLE_PATTERN=${BUNDLE_PATTERN:-'index-[A-Za-z0-9_-]*\.js'}
PREVIEW_DAYS=${PREVIEW_DAYS:-30}
HOST_ADAPTER=${HOST_ADAPTER:-firebase}
[ -f "$SCRIPTS/host-$HOST_ADAPTER.sh" ] ||
  die "No hosting adapter $SCRIPTS/host-$HOST_ADAPTER.sh (HOST_ADAPTER in $CONF)."
# shellcheck source=host-firebase.sh
source "$SCRIPTS/host-$HOST_ADAPTER.sh"

# "Opus", "family chat!" → "opus", "family-chat"
slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'; }

# A word list membership test: is_in <word> "<list>".
is_in() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# REPOS. repo_info <GitHub repo name>: sets REPO, FOLDER, PROJECT, LIVE_URL,
# ENV_SECRET from the REPOS list in agent-kit.conf. Add a repo there to bring it
# into the setup.
repo_names() { local row; for row in "${REPOS[@]}"; do printf '%s ' "${row%%|*}"; done; }
repo_info() {
  local row name
  for row in "${REPOS[@]}"; do
    IFS='|' read -r name FOLDER PROJECT LIVE_URL ENV_SECRET <<<"$row"
    if [ "$name" = "$1" ]; then REPO=$1; return 0; fi
  done
  die "Unknown repo '$1'. Known: $(repo_names)(add others to REPOS in $CONF)."
}

# The GitHub repo the current folder belongs to (the last part of its origin URL).
current_repo() {
  local url
  url=$(git remote get-url origin 2>/dev/null) || die "Not inside a git repo."
  url=${url%.git}
  printf '%s' "${url##*/}"
}

# Agents never work in the shared main folder: its working tree may hold
# another agent's unfinished changes, and a build there would ship them.
require_own_copy() {
  local top
  top=$(git rev-parse --show-toplevel)
  [ "$top" != "$WORKSPACE/$FOLDER" ] || die "This is the shared main folder ($top).
  Work in your own copy:  $SCRIPTS/worktree.sh $REPO <agent> <topic>"
}

# The hosting project the repo points at must be the one agent-kit.conf expects.
check_project() { host_check "$1"; } # <dir>

# Copy the repo's .env from the secrets folder, if the repo has one.
place_env() { # <dir>
  [ -n "$ENV_SECRET" ] || return 0
  [ -f "$SECRETS/$ENV_SECRET" ] || die "Missing $SECRETS/${ENV_SECRET}."
  cp "$SECRETS/$ENV_SECRET" "$1/.env"
}

# Succeeds when <dir>/node_modules holds exactly what <dir>/package-lock.json asks
# for (npm's own install record, node_modules/.package-lock.json, is the evidence).
# Fails after a rebase or pull that changed dependencies: then run `npm ci`.
deps_match() { # <dir>
  node -e '
    const fs = require("fs"), dir = process.argv[1];
    const read = (f) => JSON.parse(fs.readFileSync(dir + "/" + f, "utf8")).packages || {};
    let want, have;
    try { want = read("package-lock.json"); have = read("node_modules/.package-lock.json"); }
    catch { process.exit(1); }
    const off = Object.keys(want).filter((k) => k && !want[k].optional && !want[k].devOptional &&
      !want[k].link && (have[k] || {}).version !== want[k].version);
    process.exit(off.length ? 1 : 0);
  ' "$1" 2>/dev/null
}

# AGENTS. Each model family works in its own app, and each app has ONE preview
# link the owner can bookmark. The app ("lane") is read from where the copy lives
# (LANE_PATHS) or from the agent name that starts the branch (copies made by
# worktree.sh are on <agent>/<topic>), so an agent can't pick the wrong link.
LANE_AGENTS="" KNOWN_SIGNERS="" TRIAL_SIGNERS=""
for _row in "${AGENTS[@]}"; do
  IFS='|' read -r _name _lane _signer _trial <<<"$_row"
  LANE_AGENTS="${LANE_AGENTS:+$LANE_AGENTS }$_name"
  [ -z "$_signer" ] || KNOWN_SIGNERS="${KNOWN_SIGNERS:+$KNOWN_SIGNERS }$_signer"
  [ -z "$_signer" ] || [ "$_trial" != trial ] || TRIAL_SIGNERS="${TRIAL_SIGNERS:+$TRIAL_SIGNERS }$_signer"
done
unset _row _name _lane _signer _trial

# agent_row <name>: sets A_LANE, A_SIGNER, A_TRIAL from the AGENTS list; fails if unknown.
agent_row() {
  local row name
  for row in "${AGENTS[@]}"; do
    IFS='|' read -r name A_LANE A_SIGNER A_TRIAL <<<"$row"
    [ "$name" != "$1" ] || return 0
  done
  return 1
}

lane_of() { # <copy dir> <branch> → app lane name, or nothing
  local row pattern
  for row in ${LANE_PATHS[@]+"${LANE_PATHS[@]}"}; do
    pattern=${row%|*}
    # shellcheck disable=SC2254 # the pattern is a glob on purpose
    case "$1" in $pattern) echo "${row##*|}"; return ;; esac
  done
  if agent_row "$(slug "${2%%/*}")"; then echo "$A_LANE"; else echo ""; fi
}
# What the lane's link shows right now: "<sha> <clean|dirty> <branch> <url> <when>".
lane_record() { printf '%s/%s/_lane-%s.preview' "$HANDOFFS" "$REPO" "$1"; } # <lane>

# SIGN-OFFS. Every agent but the house agent ends its commits with
#   Co-Authored-By: <signs as>-<SIGN_TAG>[bot] <SIGN_EMAIL>
# TRIAL agents get the strict ship checks.
trailer_for() { # <branch> → the sign-off for the agent that starts it, or nothing
  if agent_row "$(slug "${1%%/*}")" && [ -n "$A_SIGNER" ]; then
    printf 'Co-Authored-By: %s-%s[bot] <%s>' "$A_SIGNER" "$SIGN_TAG" "$SIGN_EMAIL"
  fi
}
re_escape() { printf '%s' "$1" | sed 's/[][\.*^$/+?(){}|]/\\&/g'; } # literal text → sed -E pattern
SIGN_RE_NAME="([a-z0-9-]+)-$(re_escape "$SIGN_TAG")\\[bot\\]"
SIGN_RE_EMAIL="<$(re_escape "$SIGN_EMAIL")>"
# The <who> of an exact sign-off trailer value, or nothing if it isn't in the kit's form.
signer_of() { printf '%s\n' "$1" | sed -nE "s/^ *$SIGN_RE_NAME $SIGN_RE_EMAIL *\$/\\1/p"; }
# Every <who> named in a commit's sign-offs, loosely (one per line).
signers_in() { git log -1 --format='%(trailers:key=Co-Authored-By,valueonly)' "$1" | sed -nE "s/^ *$SIGN_RE_NAME.*/\\1/p"; } # <commit>

# Where a branch's handoff note is kept (outside git).
note_path() { printf '%s/%s/%s.md' "$HANDOFFS" "$REPO" "$(slug "$1")"; } # <branch>

# Start a branch's handoff note from templates/handoff-note.md if it has none.
# The agent keeps the Goal / Next / Done part current as it works; handoff.sh
# rewrites the State part from git.
ensure_note() { # <branch>
  local note
  note=$(note_path "$1")
  [ ! -f "$note" ] || return 0
  [ -f "$TEMPLATES/handoff-note.md" ] || die "Missing the note template $TEMPLATES/handoff-note.md."
  mkdir -p "$(dirname "$note")"
  node -e '
    const fs = require("fs");
    const [tpl, out, REPO, BRANCH, SCRIPTS, OWNER] = process.argv.slice(1);
    const vars = { REPO, BRANCH, SCRIPTS, OWNER };
    fs.writeFileSync(out, fs.readFileSync(tpl, "utf8")
      .replace(/\{\{(REPO|BRANCH|SCRIPTS|OWNER)\}\}/g, (_, k) => vars[k]));
  ' "$TEMPLATES/handoff-note.md" "$note" "$REPO" "$1" "$SCRIPTS" "$OWNER_NAME"
}

# Build the folder you're in with BUILD_CMD.
run_build() { sh -c "$BUILD_CMD"; }

# The hashed main bundle an index.html loads, e.g. index-BWIx0kRu.js.
bundle_of() { grep -o "$BUNDLE_PATTERN" | head -1 || true; }

# SHIP STATUS. ship.sh records every ship it runs beside the repo's handoff
# notes, as key=value lines (each record written whole, then renamed in):
#   _ship-latest.status    the latest ship: branch, copy, pid, exact commit, deploy
#                          targets, phase, outcome, times. "running" while it holds the lock.
#   _ship-verified.status  the last ship whose live site served the build it made
#   _ship-pending.status   durable earliest unresolved baseline + deploy targets;
#                          written before mutation, cleared only after verified write
#   _ship-history.log      one line per step, oldest first
# Phases in order: checking → building → pushing → deploying → verifying → done.
# ship-status.sh shows them. A release that reached GitHub main but never passed its
# live check is flagged, and the next ship.sh finishes it — there is no other way.
ship_file() { printf '%s/%s/_ship-%s' "$HANDOFFS" "$REPO" "$1"; } # <latest.status|verified.status|history.log>
field() { sed -n "s/^$1=//p" "$2" 2>/dev/null || true; }        # <key> <record file>

# Did the release in <record> reach GitHub main without passing its live check?
# Prints yes, no, or maybe: it stopped mid-push, and only a freshly fetched main sha
# (ship.sh passes one, under the lock) settles that. A record still "running" is
# judged like a stopped one: callers check its pid first.
unverified_main() { # <record file> [freshly fetched main sha]
  local sha
  case "$(field outcome "$1")" in shipped | "") echo no; return 0 ;; esac
  sha=$(field sha "$1")
  case "$(field main_updated "$1")" in
    yes) echo yes ;;
    already) # a redeploy: main had it before; only a deploy that started can leave live behind
      case "$(field phase "$1")" in deploying | verifying) echo yes ;; *) echo no ;; esac ;;
    unknown) # stopped while pushing
      if [ -z "${2:-}" ] || ! git cat-file -e "$sha^{commit}" 2>/dev/null; then echo maybe
      elif git merge-base --is-ancestor "$sha" "$2" 2>/dev/null; then echo yes
      else echo no; fi ;;
    *) echo no ;;
  esac
}

# A verified record must be a complete successful result, never an intermediate
# latest.status snapshot. Older malformed records are ignored by both callers.
verified_record() {
  [ "$(field outcome "$1")" = shipped ] && [ "$(field phase "$1")" = done ] &&
    [ -n "$(field sha "$1")" ] && [ -n "$(field bundle "$1")" ] &&
    [ -n "$(field finished "$1")" ]
}

# A complete result from this same commit supersedes an older diagnostic snapshot
# when its final latest.status rename failed. Durable pending intent takes priority.
record_verified() { # <latest> <verified>; match the attempt, not timestamps alone
  verified_record "$2" && [ "$(field sha "$1")" = "$(field sha "$2")" ] &&
    [ -n "$(field pid "$1")" ] && [ "$(field pid "$1")" = "$(field pid "$2")" ] &&
    [ -n "$(field started "$1")" ] && [ "$(field started "$1")" = "$(field started "$2")" ]
}

# A denied process probe is NOT proof of death (e.g. a sandbox inspecting an
# unrestricted ship). Only the OS's explicit absent-process result frees a lock.
process_alive() { # <pid>; unknown/denied probes retain exclusion
  [ -n "$1" ] || return 1
  local probe
  if probe=$(LC_ALL=C kill -0 "$1" 2>&1); then return 0; fi
  case "$probe" in *"No such process"*) return 1 ;; *) return 0 ;; esac
}
