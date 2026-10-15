#!/usr/bin/env bash
# ship-status.sh [<repo>] — who is shipping now, and the last release that passed
# its live check. No name: every repo in agent-kit.conf.
#
# Read-only: run it anywhere, any time. It never fetches, builds, deploys or clears a
# lock, so it can't get in a ship's way. It reads what ship.sh records (SHIP STATUS in
# _agent-common.sh) and flags a release that reached GitHub main but never passed its
# live check, with how to finish it: through ship.sh, which re-checks everything.
source "$(dirname "$0")/_agent-common.sh"

[ $# -le 1 ] || die "Usage: ship-status.sh [<repo>]"
when() { printf '%s' "$1" | sed -E 's/^([0-9-]+)T([0-9]{2}:[0-9]{2}).*/\1 \2/'; } # ISO time → "2026-10-14 16:51"
alive() { process_alive "$1"; }

show() { # <repo>
  repo_info "$1"
  local L V P H D deploy_pid lock_pid main pid running="" unv target="" base sha livewas
  L=$(ship_file latest.status)
  V=$(ship_file verified.status)
  P=$(ship_file pending.status)
  H=$(ship_file history.log)
  D="$LOCKS/$REPO-ship"
  deploy_pid=$(cat "$D/deploy.pid" 2>/dev/null || true)
  lock_pid=$(cat "$LOCKS/$REPO-ship/pid" 2>/dev/null || true)
  # GitHub main as of the last fetch by any copy (all copies share the main folder's git store).
  main=$(git -C "$WORKSPACE/$FOLDER" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null || true)
  pid=$(field pid "$L")
  printf '%s · %s\n' "$REPO" "$LIVE_URL"

  if [ "$(field outcome "$L")" = running ] && [ "$lock_pid" = "$pid" ] && alive "$pid"; then
    running=1
    printf '  Shipping now   %s @ %s · %s · %s since %s (pid %s)\n                 copy %s\n' \
      "$(field branch "$L")" "$(field sha "$L" | cut -c1-7)" "$(field targets "$L")" \
      "$(field phase "$L")" "$(when "$(field updated "$L")")" "$pid" "$(field copy "$L")"
  elif alive "$lock_pid"; then
    running=1
    printf '  Shipping now   process %s holds the ship lock (just starting, or an older ship.sh)\n' "$lock_pid"
  elif [ -f "$D/deploy.started" ] && [ ! -f "$D/deploy.done" ]; then
    running=1
    if alive "$deploy_pid"; then
      printf '  Shipping now   deployment guardian %s still holds exclusion; owner %s stopped\n' "$deploy_pid" "$lock_pid"
    else
      printf '  Shipping now   deployment completion uncertain; lock retained (owner %s)\n' "$lock_pid"
      printf '                 Confirm deployment processes have stopped before an operator repairs this lock.\n'
    fi
    printf '  ⚠ NOT VERIFIED LIVE: this deployment has not completed its live check.\n'
  else
    printf '  Shipping now   nobody\n'
    [ -z "$lock_pid" ] ||
      printf '                 stale lock from process %s, which is gone; the next ship.sh clears it\n' "$lock_pid"
  fi

  if verified_record "$V"; then
    printf '  Last verified  %s %s · %s · live check passed %s · %s\n' "$(field sha "$V" | cut -c1-7)" \
      "$(field branch "$V")" "$(field targets "$V")" "$(when "$(field finished "$V")")" "$(field bundle "$V")"
  else
    printf '  Last verified  none recorded yet (the next ship sets it)\n'
  fi

  if [ -f "$L" ] && [ -z "$running" ] && [ "$(field outcome "$L")" != shipped ]; then
    local outcome
    outcome=$(field outcome "$L")
    [ "$outcome" != running ] || outcome="interrupted (process $pid gone)"
    printf '  Latest ship    %s %s · %s · %s while %s, %s\n' "$(field sha "$L" | cut -c1-7)" "$(field branch "$L")" \
      "$(field targets "$L")" "$outcome" "$(field phase "$L")" "$(when "$(field updated "$L")")"
    [ -z "$(field note "$L")" ] || printf '                 "%s"\n' "$(field note "$L")"
  fi

  # The flag. Not while a ship runs: it contains main, so it finishes any unverified release.
  if [ -z "$running" ] && { [ -f "$P" ] || [ -f "$L" ]; }; then
    # Pending intent survives failed later attempts; latest is only diagnostics.
    local recovery=$L
    [ ! -f "$P" ] || recovery=$P
    # Our origin/main may be stale, so it can confirm a mid-push stop reached main, never rule it out.
    unv=$(unverified_main "$recovery")
    if [ "$unv" = maybe ] && [ -n "$main" ] &&
      git -C "$WORKSPACE/$FOLDER" merge-base --is-ancestor "$(field sha "$recovery")" "$main" 2>/dev/null; then unv=yes; fi
    sha=""
    if verified_record "$V"; then sha=$(field sha "$V"); fi
    # A failed latest-status write cannot override a valid successful result.
    if [ ! -f "$P" ] && record_verified "$L" "$V"; then unv=no; fi
    if [ "$unv" = yes ]; then
      target=$(field sha "$recovery")
    elif [ -n "$sha" ] && [ -n "$main" ] && [ "$main" != "$sha" ] &&
      git -C "$WORKSPACE/$FOLDER" merge-base --is-ancestor "$sha" "$main" 2>/dev/null; then
      target=$main # main moved past the last verified release, as of the last fetch
    fi
    if [ -n "$target" ]; then
      base=${sha:-$(field main_before "$recovery")}
      livewas="the release before it"
      [ -z "$sha" ] || livewas=${sha:0:7}
      printf '  ⚠ NOT VERIFIED LIVE: GitHub main has %s, but its live check never passed.\n' "${target:0:7}"
      printf '    The live site may still be on %s, or partly updated. Finish it with ship.sh, nothing else:\n' "$livewas"
      printf '      · the next ship %s approves finishes it (ship.sh requires its branch to contain %s), or\n' "$OWNER_NAME" "${target:0:7}"
      printf '      · now, unchanged: %s/worktree.sh %s <you> finish-%s, then ship.sh inside that copy\n' \
        "$SCRIPTS" "$REPO" "${target:0:7}"
      printf '        (a copy at main has nothing new, so ship.sh just rebuilds, redeploys and checks it)\n'
      if [ "$(field targets "$P")" = hosting,firestore:rules ] ||
        { [ -n "$base" ] && [ -n "$(git -C "$WORKSPACE/$FOLDER" diff --name-only "$base" "$target" -- firestore.rules 2>/dev/null)" ]; }; then
        printf '      ship.sh will ask for --with-firestore-rules: firestore.rules changed since %s.\n' "${base:0:7}"
      fi
    elif [ "$unv" = maybe ]; then
      printf '  ? It stopped while pushing, so GitHub main may or may not have %s. The next ship.sh\n' "$(field sha "$recovery" | cut -c1-7)"
      printf '    fetches first, says which, and finishes it if main has it.\n'
    elif [ "$(field outcome "$L")" != shipped ]; then
      printf '    Nothing to finish: GitHub main and the live site were not changed by it.\n'
    fi
  fi

  if [ -f "$H" ]; then
    printf '  History (newest last)\n'
    tail -n 3 "$H" | sed 's/^/    /'
  fi
}

WHICH=${1:-$(repo_names)}
first=1
for r in $WHICH; do
  [ -n "$first" ] || echo
  first=""
  show "$r"
done
