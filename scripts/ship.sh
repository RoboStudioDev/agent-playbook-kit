#!/usr/bin/env bash
# ship.sh — ship your branch: build → GitHub main → live site.
#
# Run inside your copy, ONLY after the owner has approved your preview. Any agent
# may ship, trial agents included, so the safety checks live HERE.
# Add --with-firestore-rules only when the approved release includes rules, and
# --allow-deletions only when the owner approved deleting files (never for trial
# agents). It:
#   1. refuses uncommitted changes, and a branch missing commits that are
#      already on main (rebase first: git fetch origin && git rebase origin/main;
#      a conflict is the owner's call, so stop and ask),
#   2. takes the repo's ship lock, so two agents never ship at the same time,
#   2b. GUARDRAILS: ships only what is on your app's preview link (what the owner
#      saw); every agent sign-off must be in the AGENTS list; no deleted files; a
#      trial agent's OWN commits may not gut a doc (>10 lines removed). Trial agents
#      may ship server changes like anyone,
#   3. builds a clean copy of exactly your commit, never a working folder,
#   4. pushes that commit to main (fast-forward only, never forced),
#   5. deploys that build live and checks the live site serves it.
# The live site therefore always equals GitHub main, and one agent can't erase
# another's shipped work or ship someone's unfinished changes.
#
# Every step is recorded (SHIP STATUS in _agent-common.sh): branch, copy,
# exact commit, deploy targets, phase, times, outcome. ship-status.sh shows who is
# shipping and the last release that passed its live check. If a ship stops after
# GitHub main has its commit but before that check passes, the next ship.sh says so
# and finishes it (asking for --with-firestore-rules if that release changed them).
source "$(dirname "$0")/_agent-common.sh"

DEPLOY_TARGETS=hosting
ALLOW_DELETIONS=""
for arg in "$@"; do
  case "$arg" in
    --with-firestore-rules) DEPLOY_TARGETS=hosting,firestore:rules ;;
    --allow-deletions) ALLOW_DELETIONS=1 ;;
    *) die "Usage: ship.sh [--with-firestore-rules] [--allow-deletions]" ;;
  esac
done

repo_info "$(current_repo)"
require_own_copy
TOP=$(git rev-parse --show-toplevel)
cd "$TOP"
check_project "$TOP"
[ -x "$SCRIPTS/ship-deploy.sh" ] || die "Missing executable deploy guardian: $SCRIPTS/ship-deploy.sh. Repair the script installation before shipping."

[ -z "$(git status --porcelain)" ] || die "You have uncommitted changes. Commit them (or set them aside) first."
[ -d node_modules ] || die "No node_modules here. Run: npm ci"

SHA=$(git rev-parse HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
LANE=$(lane_of "$TOP" "$BRANCH")
LOCK="$LOCKS/$REPO-ship"
BUILD=""

# The status record (SHIP STATUS in _agent-common.sh), kept from the moment this run
# holds the lock. Diagnostic writes warn; recovery writes must succeed before mutation.
S_FILE=$(ship_file latest.status)
V_FILE=$(ship_file verified.status)
P_FILE=$(ship_file pending.status)
P_CREATED=""
S_STARTED=$(date '+%Y-%m-%dT%H:%M:%S%z')
S_LOCKED="" S_PHASE="" S_OUTCOME="" S_MAIN=no S_MAIN_BEFORE="" S_AHEAD="" S_BUNDLE="" S_FINISHED="" S_NOTE=""
write_record() { # <destination>; always serialize this run, never copy latest.status
  local dest=$1 now note=""
  now=$(date '+%Y-%m-%dT%H:%M:%S%z')
  [ -z "$S_NOTE" ] || note=$(printf '%s' "$S_NOTE" | tr '\n' ' ' | tr -s ' ' | cut -c1-300)
  printf '%s=%s\n' repo "$REPO" project "$PROJECT" live_url "$LIVE_URL" branch "$BRANCH" \
      lane "$LANE" copy "$TOP" pid "$$" sha "$SHA" main_before "$S_MAIN_BEFORE" commits "$S_AHEAD" \
      targets "$DEPLOY_TARGETS" phase "$S_PHASE" outcome "$S_OUTCOME" main_updated "$S_MAIN" \
      bundle "$S_BUNDLE" started "$S_STARTED" lock_acquired "$S_LOCKED" updated "$now" \
      finished "$S_FINISHED" note "$note" >"$dest.$$" 2>/dev/null &&
    mv -f "$dest.$$" "$dest" 2>/dev/null
}
record() { # <phase> <outcome>: diagnostics are best effort
  S_PHASE=$1 S_OUTCOME=$2
  [ "$2" = running ] || S_FINISHED=$(date '+%Y-%m-%dT%H:%M:%S%z')
  if write_record "$S_FILE"; then :
  else say "⚠ Couldn't write the ship status record $S_FILE (shipping carries on)."; fi
  printf '%s %s %s %s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${SHA:0:7}" "$BRANCH" "$S_PHASE" "$S_OUTCOME" \
    >>"$(ship_file history.log)" 2>/dev/null || true
}
# Unlike diagnostics, recovery state must be durable BEFORE any push/deploy. Keep
# the earliest unresolved baseline and all required targets across later failures.
prepare_pending() {
  local base=$MAIN_SHA anchor=$SHA targets=$DEPLOY_TARGETS updated=unknown phase=pushing
  if [ -f "$P_FILE" ]; then
    base=$(field main_before "$P_FILE")
    anchor=$(field sha "$P_FILE")
    updated=$(field main_updated "$P_FILE")
    if [ "$(field targets "$P_FILE")" = hosting,firestore:rules ]; then targets=hosting,firestore:rules; fi
  elif [ -n "$UNVERIFIED_FROM" ]; then
    base=$UNVERIFIED_FROM anchor=$MAIN_SHA updated=yes
  else
    P_CREATED=1
    [ "$AHEAD" -gt 0 ] || updated=already
  fi
  # An interrupted redeploy remains unresolved across retries too.
  [ "$updated" != already ] || phase=deploying
  if printf '%s=%s\n' repo "$REPO" sha "$anchor" main_before "$base" targets "$targets" \
      phase "$phase" outcome running main_updated "$updated" >"$P_FILE.$$" 2>/dev/null &&
    mv -f "$P_FILE.$$" "$P_FILE" 2>/dev/null; then :
  else die "Couldn't preserve recovery state ($P_FILE). No push or deploy was started."; fi
}
# " — opus/x @ 1a2b3c4, deploying since 16:51", when the record belongs to <pid>.
holder() { # <pid>
  [ -n "$1" ] && [ "$(field pid "$S_FILE")" = "$1" ] || return 0
  printf ' — %s @ %s, %s since %s' "$(field branch "$S_FILE")" "$(field sha "$S_FILE" | cut -c1-7)" \
    "$(field phase "$S_FILE")" "$(field updated "$S_FILE" | cut -c12-16)"
}

cleanup() {
  local rc=$?
  if [ "$S_OUTCOME" = running ]; then # stopped part-way: record how, while still holding the lock
    if [ "$rc" -gt 128 ]; then
      S_NOTE="stopped by signal $((rc - 128))${S_NOTE:+; $S_NOTE}"
      record "$S_PHASE" interrupted
    else
      S_NOTE=${DIE_MSG:-"a step failed (exit $rc)"}
      record "$S_PHASE" failed
    fi
    if [ "$(unverified_main "$S_FILE")" != no ]; then
      printf '\n⚠ GitHub main has %s, but the live site never passed its check. Do not work around it:\n  ship.sh again finishes it. Details and steps: %s/ship-status.sh %s\n' \
        "${SHA:0:7}" "$SCRIPTS" "$REPO" >&2
    fi
  fi
  # A killed owner can leave its guardian/Firebase child alive. Keep its build and
  # lock until the guardian has observed Firebase exit and written deploy.done.
  if [ -f "$LOCK/deploy.started" ] && [ ! -f "$LOCK/deploy.done" ]; then
    say "Deployment completion is not recorded; retaining $LOCK and its build. See ship-status.sh $REPO."
    return "$rc"
  fi
  [ -z "$BUILD" ] || rm -rf "$BUILD"
  [ ! -f "$LOCK/pid" ] || [ "$(cat "$LOCK/pid" 2>/dev/null)" != "$$" ] || rm -rf "$LOCK"
}
trap cleanup EXIT
# A signal still runs cleanup. Bash lets a running build or deploy finish first, so the
# lock is never freed while a firebase deploy is still going.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# 2. Atomic directory lock. Dead owners are recoverable only after deploy completion.
mkdir -p "$LOCKS" "$HANDOFFS/$REPO"
waited=0
until mkdir "$LOCK" 2>/dev/null; do
  owner=$(cat "$LOCK/pid" 2>/dev/null || true)
  # Clear it only under a second lock, and only if it still names that dead process:
  # otherwise two waiters could both clear it, the second removing the lock the first
  # had just taken, and both ship at once (found by a contention test harness).
  if [ -n "$owner" ] && ! process_alive "$owner" && mkdir "$LOCK.clearing" 2>/dev/null; then
    if [ "$(cat "$LOCK/pid" 2>/dev/null || true)" = "$owner" ] &&
      { [ ! -f "$LOCK/deploy.started" ] || [ -f "$LOCK/deploy.done" ]; }; then
      say "Clearing a stale ship lock (process $owner is gone$(holder "$owner"))."
      rm -rf "$LOCK"
    fi
    rmdir "$LOCK.clearing" 2>/dev/null || true
    [ -d "$LOCK" ] || continue
  fi
  # A waiter killed mid-clear would leave that second lock; free it after a minute.
  find "$LOCK.clearing" -maxdepth 0 -mmin +1 -exec rmdir {} + 2>/dev/null || true
  [ "$waited" -lt 600 ] || die "Another $REPO ship has held the lock for 10 minutes$(holder "$owner") ($LOCK).
  An unfinished deployment keeps its lock even if the owner died. See why before shipping: $SCRIPTS/ship-status.sh $REPO"
  [ "$waited" -gt 0 ] || say "Another agent is shipping $REPO right now$(holder "$owner"); waiting…"
  sleep 10
  waited=$((waited + 10))
done
echo $$ >"$LOCK/pid"
# The previous record, kept (inside the lock) for the unverified-release check below.
PREV="$LOCK/previous.status"
cp "$S_FILE" "$PREV" 2>/dev/null || true
# Preserve any older-format unresolved release before replacing latest.status,
# even when this attempt will fail its freshness/build/approval checks.
if [ ! -f "$P_FILE" ] && ! record_verified "$PREV" "$V_FILE" &&
  [ "$(unverified_main "$PREV")" != no ]; then
  cp "$PREV" "$P_FILE.$$" && mv -f "$P_FILE.$$" "$P_FILE" || die "Couldn't preserve unfinished release."
fi
S_LOCKED=$(date '+%Y-%m-%dT%H:%M:%S%z')
record checking running

# 1. Up to date with main? Checked under the lock, so nobody pushes in between.
git fetch -q origin main
MAIN_SHA=$(git rev-parse origin/main)
S_MAIN_BEFORE=$MAIN_SHA
git merge-base --is-ancestor "$MAIN_SHA" "$SHA" ||
  die "main has commits your branch doesn't. Run: git rebase origin/main
  (a conflict → stop and ask $OWNER_NAME), check it still works, then ship again."
AHEAD=$(git rev-list --count "$MAIN_SHA..$SHA")
S_AHEAD=$AHEAD
if [ "$AHEAD" -eq 0 ]; then
  S_MAIN=already
  say "main is already at $(git rev-parse --short "$SHA"); redeploying it."
else
  say "Shipping $AHEAD commit(s):"
  git log --oneline "$MAIN_SHA..$SHA" | sed 's/^/    /'
fi

# 1b. Did an earlier ship reach GitHub main without passing its live check (crash,
#     failed deploy or check)? This ship contains that commit (checked just above), so
#     it finishes it, and must deploy what it needed. Judged against the last verified
#     release when there is one (main should equal it), else from the previous record.
if [ "$(field outcome "$PREV")" = running ]; then
  printf '%s %s %s %s interrupted — process %s gone\n' "$S_LOCKED" "$(field sha "$PREV" | cut -c1-7)" \
    "$(field branch "$PREV")" "$(field phase "$PREV")" "$(field pid "$PREV")" >>"$(ship_file history.log)" 2>/dev/null || true
fi
V_SHA=""
if verified_record "$V_FILE"; then V_SHA=$(field sha "$V_FILE"); fi
UNVERIFIED_FROM=""
if [ -n "$V_SHA" ]; then
  if [ "$V_SHA" != "$MAIN_SHA" ]; then
    if git merge-base --is-ancestor "$V_SHA" "$MAIN_SHA" 2>/dev/null; then UNVERIFIED_FROM=$V_SHA
    else say "⚠ GitHub main doesn't contain the last verified release (${V_SHA:0:7}). Tell $OWNER_NAME."; fi
  fi
fi
if [ -f "$P_FILE" ]; then
  if [ "$(unverified_main "$P_FILE" "$MAIN_SHA")" = yes ]; then
    UNVERIFIED_FROM=$(field main_before "$P_FILE")
  else
    # The durable intent was written before a push that never reached main.
    # Fresh main under the lock is the only authority that can dismiss it.
    rm -f "$P_FILE"
  fi
elif ! record_verified "$PREV" "$V_FILE" &&
  [ "$(unverified_main "$PREV" "$MAIN_SHA")" = yes ] && [ -z "$UNVERIFIED_FROM" ]; then
  UNVERIFIED_FROM=$(field main_before "$PREV")
  # Migrate the previous format before any later diagnostic overwrites it.
  cp "$PREV" "$P_FILE.$$" && mv -f "$P_FILE.$$" "$P_FILE" || die "Couldn't preserve unfinished release."
fi
if [ -n "$UNVERIFIED_FROM" ]; then
  P_OUT=$(field outcome "$PREV")
  [ "$P_OUT" != running ] || P_OUT="interrupted (process $(field pid "$PREV") gone)"
  say "⚠ GitHub main ($(git rev-parse --short "$MAIN_SHA")) never passed a live check; the last verified release is ${UNVERIFIED_FROM:0:7}."
  [ ! -f "$PREV" ] || say "  Last ship: $(field branch "$PREV") @ $(field sha "$PREV" | cut -c1-7), $P_OUT while $(field phase "$PREV")."
  say "  This ship contains it, so it finishes it."
  if [ "$DEPLOY_TARGETS" = hosting ] &&
    { [ "$(field targets "$P_FILE")" = hosting,firestore:rules ] ||
      [ -n "$(git diff --name-only "$UNVERIFIED_FROM" "$MAIN_SHA" -- firestore.rules)" ]; }; then
    die "That unfinished release changed firestore.rules (approved when it shipped).
  Ship again with --with-firestore-rules to finish it."
  fi
  S_NOTE="finishes unverified ${UNVERIFIED_FROM:0:7}..${MAIN_SHA:0:7}"
fi

# 2b. GUARDRAILS. Checked under the lock, against exactly the commits this ship
#     adds to main.
if [ "$AHEAD" -gt 0 ]; then
  RANGE="$MAIN_SHA..$SHA"
  [ -n "$LANE" ] || die "Can't tell which app this copy belongs to (branch '$BRANCH'). See preview.sh."

  # Sign-offs: every <who>-<SIGN_TAG>[bot] trailer must be a row in AGENTS, and
  # any trailer using the agents' email must be in that exact form.
  SIGNERS=""
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$t" in *"$SIGN_EMAIL"*) ;; *) continue ;; esac
    name=$(signer_of "$t")
    [ -n "$name" ] || die "A commit is signed '$t' — not the kit's form.
  Sign as: Co-Authored-By: <your-name>-$SIGN_TAG[bot] <$SIGN_EMAIL>"
    is_in "$name" "$KNOWN_SIGNERS" || die "A commit is signed by '$name', who isn't in the AGENTS list.
  Ask $OWNER_NAME for a row first (AGENTS in $CONF)."
    is_in "$name" "$SIGNERS" || SIGNERS="$SIGNERS $name"
  done < <(git log --format='%(trailers:key=Co-Authored-By,valueonly)' "$RANGE")
  TRIAL=""
  for n in $SIGNERS; do
    if is_in "$n" "$TRIAL_SIGNERS"; then TRIAL="$TRIAL $n"; fi
  done

  # No deleted files (rule: archive first). Renames/moves are fine.
  DELETED=$(git diff --name-only --diff-filter=D -M "$MAIN_SHA" "$SHA")
  if [ -n "$DELETED" ]; then
    [ -n "$ALLOW_DELETIONS" ] && [ -z "$TRIAL" ] || die "This ship deletes files:
$(printf '%s\n' "$DELETED" | sed 's/^/    /')
  The rule is archive, never delete: git mv them into an _archive folder instead.
  (Only a non-trial agent, with $OWNER_NAME's OK, may pass --allow-deletions.)"
  fi

  CHANGED=$(git diff --name-only -M "$MAIN_SHA" "$SHA")
  SERVER=$(printf '%s\n' "$CHANGED" | grep -E '^(functions/|firestore\.rules$|firestore\.indexes\.json$|storage\.rules$)' || true)
  if [ -n "$TRIAL" ]; then
    # Docs are free range: update any fact the owner asks for. What's refused is
    # gutting one — more than 10 lines removed from a single doc — and only in a
    # trial agent's OWN commits (checking the whole release once let one small
    # trial commit block other agents' work, so nobody could ship it).
    BIG=""
    while IFS= read -r c; do
      own=""
      for n in $(signers_in "$c"); do
        if is_in "$n" "$TRIAL_SIGNERS"; then own=1; fi
      done
      [ -n "$own" ] || continue
      out=$(git show --numstat --format= -M "$c" -- '*.md' \
        | awk -v c="$(git rev-parse --short "$c")" '$2 != "-" && $2 > 10 {print "    " $3 " (" $2 " lines removed in " c ")"}')
      if [ -n "$out" ]; then BIG="$BIG$out"$'\n'; fi
    done < <(git rev-list "$RANGE")
    [ -z "$BIG" ] || die "Trial agent(s)$TRIAL removed large parts of these docs:
$BIG
  Small edits are fine; removing sections needs $OWNER_NAME's explicit OK and a non-trial agent."
    # NO server-code rule for trial agents: one once stalled a release only because it
    # carried another agent's firestore.rules change. Rules still need
    # --with-firestore-rules below, for every agent; functions/ is never deployed by ship.sh.
  fi
  if printf '%s\n' "$SERVER" | grep -qE '^firestore\.rules$' && [ "$DEPLOY_TARGETS" = hosting ]; then
    die "firestore.rules changed. If $OWNER_NAME approved the rules too, ship with --with-firestore-rules."
  fi
  if printf '%s\n' "$SERVER" | grep -qE '^(functions/|firestore\.indexes\.json$|storage\.rules$)'; then
    say "⚠ This ship includes server files that ship.sh does NOT deploy (website only):"
    printf '%s\n' "$SERVER" | grep -vE '^firestore\.rules$' | sed 's/^/    /'
    say "  GitHub main will be ahead of what's running. Tell $OWNER_NAME — they need their own deploy."
  fi

  # Ship only what the owner saw: your app's preview link must show this work.
  REC=$(lane_record "$LANE")
  [ -f "$REC" ] || die "Nothing from you is on the '$LANE' preview link yet.
  Run $SCRIPTS/preview.sh, show $OWNER_NAME the link, and ship after they approve."
  read -r P_SHA P_STATE P_BRANCH P_URL P_WHEN <"$REC"
  [ "$P_BRANCH" = "$BRANCH" ] || die "The '$LANE' link now shows '$P_BRANCH' (previewed $P_WHEN), not your branch.
  Another workspace previewed after you. Run preview.sh again and have $OWNER_NAME look before shipping."
  [ "$P_STATE" = clean ] || die "Your last preview included uncommitted changes. Commit, preview again, then ship."
  if [ "$P_SHA" != "$SHA" ]; then
    git cat-file -e "$P_SHA^{commit}" 2>/dev/null || die "Your last preview ($P_SHA) isn't in this copy's history. Preview again."
    # A rebase that only brought in other people's (already live) work is fine;
    # a change to YOUR files since the preview is not.
    # shellcheck disable=SC2086
    git diff --quiet "$P_SHA" "$SHA" -- $CHANGED ||
      die "Your work changed since the preview $OWNER_NAME saw ($(git rev-parse --short "$P_SHA") → $(git rev-parse --short "$SHA")).
  Run preview.sh again and have $OWNER_NAME look before shipping."
  fi
  say "Checks passed: signed by${SIGNERS:- the house agent}; preview '$LANE' matches ($P_WHEN)."
fi

# 3. A clean copy of exactly this commit, built with this copy's dependencies
#    (same commit, same lockfile) and the repo's .env.
record building running
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/ship-$REPO-XXXXXX")
git archive "$SHA" | tar -x -C "$BUILD"
ln -s "$TOP/node_modules" "$BUILD/node_modules"
place_env "$BUILD"
say "Building $(git rev-parse --short "$SHA") from a clean copy…"
(cd "$BUILD" && run_build)
BUILT=$(bundle_of <"$BUILD/$BUILD_DIR/index.html")
[ -n "$BUILT" ] || die "The build has no index-*.js bundle; not shipping."
S_BUNDLE=$BUILT

# 4. GitHub first: it is the only off-machine copy.
prepare_pending
if [ "$AHEAD" -gt 0 ]; then
  S_MAIN=unknown
  record pushing running
  say "Pushing to GitHub main…"
  if ! git push origin "$SHA:refs/heads/main"; then
    # Refused, or did it land before the error? The record says which.
    REMOTE=$(git ls-remote origin refs/heads/main 2>/dev/null | cut -f1) || true
    if [ "$REMOTE" = "$SHA" ]; then S_MAIN=yes; elif [ -n "$REMOTE" ]; then S_MAIN=no; fi
    # A confirmed unchanged remote rules out mutation by this new intent. An
    # older unresolved baseline is never discarded by a later rejected push.
    if [ "$REMOTE" = "$MAIN_SHA" ] && [ -n "$P_CREATED" ]; then rm -f "$P_FILE"; fi
    die "Push refused (someone shipped first?). Rebase onto origin/main and ship again."
  fi
fi
REMOTE=$(git ls-remote origin refs/heads/main | cut -f1)
[ "$REMOTE" = "$SHA" ] || die "GitHub main is $REMOTE, not $SHA. Not deploying."
[ "$AHEAD" -eq 0 ] || S_MAIN=yes

# 5. Live.
record deploying running
say "Deploying to $LIVE_URL ($PROJECT)…"
# Mark the launch before a child can exist. Missing completion is deliberately
# fail-closed, including a crash in the tiny launch/registration window.
: >"$LOCK/deploy.started"
"$SCRIPTS/ship-deploy.sh" "$LOCK" "$BUILD" "$DEPLOY_TARGETS" "$PROJECT" "$$"
record verifying running
LIVE=""
for _ in 1 2 3 4 5 6; do
  LIVE=$(curl -fsS "$LIVE_URL/?ship=$SHA" 2>/dev/null | bundle_of || true)
  [ "$LIVE" != "$BUILT" ] || break
  sleep 5
done
[ "$LIVE" = "$BUILT" ] || die "Deployed, but $LIVE_URL serves '$LIVE', not '$BUILT'. Check it."
record done shipped
# The last verified release: what ship-status.sh shows and what the next ship checks main against.
if write_record "$V_FILE"; then
  rm -f "$P_FILE"
else
  say "⚠ Couldn't record this as the last verified release ($V_FILE); recovery state retained."
fi

cat <<EOF

✓ Shipped. All three places match:
  Your copy    $(git rev-parse --short "$SHA")
  GitHub main  $(git rev-parse --short "$REMOTE")
  $LIVE_URL  $LIVE
EOF
