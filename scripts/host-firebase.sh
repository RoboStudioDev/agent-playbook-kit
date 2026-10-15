# host-firebase.sh — the hosting adapter for Firebase Hosting. Sourced by
# _agent-common.sh, never run.
#
# This is the only file that knows how the site is hosted. To use another host,
# copy it to host-<name>.sh, rewrite the three functions below (same names, same
# job) and set HOST_ADAPTER=<name> in agent-kit.conf. Everything else — own
# copies, preview records, the ship lock, guardrails, live check — stays as is.
#
# Needs the Firebase CLI (`npm install -g firebase-tools`), signed in once with
# `firebase login` on the machine that previews and ships.

# host_check <repo dir>: refuse to run when the repo points at a different
# project than agent-kit.conf says (a copied .firebaserc, a typo).
host_check() {
  local rc
  rc=$(node -e 'const fs = require("fs");
    console.log(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).projects.default)' \
    "$1/.firebaserc" 2>/dev/null) ||
    die "Could not read $1/.firebaserc."
  [ "$rc" = "$PROJECT" ] || die ".firebaserc says '$rc', expected '$PROJECT' for ${REPO}."
}

# host_preview <lane> <repo dir>: deploy the build already in <repo dir>/$BUILD_DIR
# to the lane's preview link (a Firebase preview channel named after the lane,
# kept PREVIEW_DAYS days) and print the link. Never touches the live site.
host_preview() {
  local out url
  out=$(mktemp)
  (cd "$2" && firebase hosting:channel:deploy "$1" --project "$PROJECT" --expires "${PREVIEW_DAYS}d" --json) >"$out" ||
    { cat "$out" >&2; rm -f "$out"; die "Preview deploy failed."; }
  url=$(node -e '
    const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const sites = Object.values(d.result || {});
    console.log((sites[0] && sites[0].url) || "");
  ' "$out")
  [ -n "$url" ] || { cat "$out" >&2; rm -f "$out"; die "Deployed, but no URL came back."; }
  rm -f "$out"
  printf '%s' "$url"
}

# host_deploy <build dir> <targets> <project>: deploy a clean build LIVE, in the
# foreground (ship-deploy.sh waits for it to end). <targets> is "hosting", or
# "hosting,firestore:rules" when ship.sh got --with-firestore-rules.
host_deploy() {
  cd "$1" && exec firebase deploy --only "$2" --project "$3"
}
