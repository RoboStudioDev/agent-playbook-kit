#!/usr/bin/env bash
# Short-lived deploy guardian, started by ship.sh. The owner may be SIGKILLed; this
# process still waits for the host's deploy. Never write completion from a
# signal/EXIT trap: an interrupted guardian cannot prove that its child stopped,
# so the lock must remain retained.
source "$(dirname "$0")/_agent-common.sh"
LOCK=$1 BUILD=$2 TARGETS=$3 PROJECT=$4 OWNER=$5
[ "$(cat "$LOCK/pid")" = "$OWNER" ] || exit 1
printf '%s\n' "$$" >"$LOCK/deploy.pid.tmp"
mv -f "$LOCK/deploy.pid.tmp" "$LOCK/deploy.pid"
set +e
(host_deploy "$BUILD" "$TARGETS" "$PROJECT")
rc=$?
set -e
printf '%s\n' "$rc" >"$LOCK/deploy.done.tmp"
mv -f "$LOCK/deploy.done.tmp" "$LOCK/deploy.done"
# Only clean an orphan's temporary build after its deploy has ended.
if ! process_alive "$OWNER"; then rm -rf "$BUILD"; fi
exit "$rc"
