#!/usr/bin/env bash
# preview.sh — put your copy's current work on your APP's preview link.
#
# Run inside your copy (never the shared main folder). Builds the folder as it
# is, committed or not, and deploys it to the ONE preview link your app has
# (one bookmark per app for the owner — see AGENTS in agent-kit.conf). With
# Firebase that is https://<project>--<app>-<hash>.web.app.
# Every preview page carries a small strip at the bottom-left saying which app,
# branch and commit it shows, so the owner always knows what they're looking at
# (two workspaces in one app share the link; the latest preview wins). The strip
# is added to the preview build only — ship.sh builds separately and never has
# it. Links stay up PREVIEW_DAYS days after the last preview. This NEVER touches
# the live site.
source "$(dirname "$0")/_agent-common.sh"

repo_info "$(current_repo)"
require_own_copy
TOP=$(git rev-parse --show-toplevel)
cd "$TOP"
check_project "$TOP"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BRANCH" != HEAD ] || die "You are not on a branch. Check out your branch first."
LANE=$(lane_of "$TOP" "$BRANCH")
[ -n "$LANE" ] || die "Can't tell which app this copy belongs to (branch '$BRANCH').
  Make your copy with: $SCRIPTS/worktree.sh $REPO <agent> <topic>
  using your own agent name: $LANE_AGENTS"

[ -d node_modules ] || die "No node_modules here. Run: npm ci"
[ -z "$ENV_SECRET" ] || [ -f .env ] || place_env "$TOP"

SHA=$(git rev-parse HEAD)
SHORT=$(git rev-parse --short HEAD)
STATE=clean
[ -z "$(git status --porcelain)" ] || STATE=dirty
say "Building $BRANCH ($SHORT$([ "$STATE" = clean ] || echo ' + uncommitted changes'))…"
run_build

# The preview strip: fixed, tiny, click-through, on every page of this build only.
WHEN=$(date '+%b %-d %-I:%M %p')
LABEL="Preview · $LANE · $BRANCH · $SHORT$([ "$STATE" = clean ] || echo '+') · $WHEN"
node -e '
  const fs = require("fs"), path = require("path");
  const label = process.argv[2].replace(/&/g, "&amp;").replace(/</g, "&lt;");
  const strip = `<div style="position:fixed;left:8px;bottom:8px;z-index:2147483647;pointer-events:none;` +
    `font:600 11px/1.4 system-ui,sans-serif;color:#fff;background:rgba(91,33,182,.92);` +
    `padding:4px 8px;border-radius:6px;box-shadow:0 1px 4px rgba(0,0,0,.3)">${label}</div>`;
  const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).forEach((e) => {
    const p = path.join(d, e.name);
    if (e.isDirectory()) return walk(p);
    if (!e.name.endsWith(".html")) return;
    const html = fs.readFileSync(p, "utf8");
    if (html.includes("</body>")) fs.writeFileSync(p, html.replace("</body>", strip + "</body>"));
  });
  walk(process.argv[1]);
' "$TOP/$BUILD_DIR" "$LABEL"

say "Deploying to your app's preview link ('$LANE') on ${PROJECT}…"
URL=$(host_preview "$LANE" "$TOP")

# What this link shows now — ship.sh checks it, so only what the owner saw can ship.
mkdir -p "$HANDOFFS/$REPO"
printf '%s %s %s %s %s\n' "$SHA" "$STATE" "$BRANCH" "$URL" "$(date '+%Y-%m-%dT%H:%M')" >"$(lane_record "$LANE")"

# Every preview leaves a current snapshot in the branch's handoff note.
"$SCRIPTS/handoff.sh" >/dev/null || say "Couldn't update the handoff note — run $SCRIPTS/handoff.sh to see why."

cat <<EOF

✓ Preview ready (live site untouched):
  $URL
  App link '$LANE' · now showing $BRANCH @ $SHORT · stays up $PREVIEW_DAYS days · rerun preview.sh after every change
  Handoff note: $(note_path "$BRANCH") (State refreshed; keep Goal / Next current)
EOF
[ "$STATE" = clean ] || echo "  ⚠ Includes uncommitted changes — commit, then preview again before shipping."
