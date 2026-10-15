#!/usr/bin/env bash
# smoke-test.sh — run the whole kit end to end in a throwaway sandbox, offline.
#
#   bash tests/smoke-test.sh          (KEEP=1 keeps the sandbox to look at)
#
# Nothing real is touched. GitHub is a local bare repo, the host is a stand-in
# `firebase` command that copies builds into folders, and the live site is a
# stand-in `curl` that reads the "live" folder. It uses its own settings file
# (AGENT_KIT_CONF), so your agent-kit.conf doesn't need to be filled in.
# Needs: bash, git, node, npm.
set -euo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
S="$KIT/scripts"
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/agent-kit-test-XXXXXX")" && pwd -P)
if [ -n "${KEEP:-}" ]; then echo "Sandbox: $T"; else trap 'rm -rf "$T"' EXIT; fi

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ✗ %s\n' "$1"; printf '%s\n' "${2:-}" | tail -n 15 | sed 's/^/      │ /'; }
# run <dir> <command…>: run a command inside a folder, output into $OUT.
run() { local d=$1; shift; OUT=$(cd "$d" && "$@" 2>&1); }
expect_ok() { # <what> <dir> <command…>
  local what=$1; shift
  if run "$@"; then ok "$what"; else bad "$what" "$OUT"; fi
}
expect_fail() { # <what> <text the refusal must contain> <dir> <command…>
  local what=$1 want=$2; shift 2
  if run "$@"; then bad "$what — it was allowed" "$OUT"
  elif printf '%s' "$OUT" | grep -qF -- "$want"; then ok "$what"
  else bad "$what — refused for another reason" "$OUT"; fi
}
check() { if eval "$2"; then ok "$1"; else bad "$1" "failed: $2"; fi; } # <what> <test>
commit() { # <dir> <message> [sign-off line]
  git -C "$1" add -A
  if [ -n "${3:-}" ]; then git -C "$1" commit -q -m "$2" -m "$3"; else git -C "$1" commit -q -m "$2"; fi
}
sign() { printf 'Co-Authored-By: %s-test[bot] <agents@example.invalid>' "$1"; }

# ── The sandbox ───────────────────────────────────────────────────────────────
mkdir -p "$T/bin" "$T/host" "$T/ops/secrets" "$T/ws"
export FAKE_HOST="$T/host" PATH="$T/bin:$PATH"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/gitconfig"
git config --file "$T/gitconfig" user.name "House Agent"
git config --file "$T/gitconfig" user.email "house@example.invalid"
git config --file "$T/gitconfig" init.defaultBranch main

cat >"$T/bin/firebase" <<'EOF'
#!/usr/bin/env bash
# Stand-in for the Firebase CLI: "deploys" by copying dist/ into $FAKE_HOST.
case "$1" in
  hosting:channel:deploy)
    rm -rf "$FAKE_HOST/preview-$2"; mkdir -p "$FAKE_HOST/preview-$2"; cp -R dist/. "$FAKE_HOST/preview-$2/"
    printf '{"status":"success","result":{"demo-project":{"url":"https://demo-project--%s.example.invalid"}}}\n' "$2" ;;
  deploy)
    rm -rf "$FAKE_HOST/live"; mkdir -p "$FAKE_HOST/live"; cp -R dist/. "$FAKE_HOST/live/"; echo "deployed $3" ;;
  *) echo "stand-in firebase: unexpected '$*'" >&2; exit 1 ;;
esac
EOF
cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Stand-in for curl: the live site is whatever the last "deploy" copied in.
cat "$FAKE_HOST/live/index.html"
EOF
chmod +x "$T/bin/firebase" "$T/bin/curl"

cat >"$T/test.conf" <<EOF
KIT_CONFIGURED=yes
OWNER_NAME="the owner"
WORKSPACE="$T/ws"
WORKTREES="$T/ws/_worktrees"
HANDOFFS="$T/ops/handoffs"
LOCKS="$T/ops/locks"
SECRETS="$T/ops/secrets"
REPOS=("demo|Demo|demo-project|https://live.example.invalid|demo.env")
AGENTS=("opus|claude||" "codex|codex|codex|" "gemini|antigravity|gemini|trial")
LANE_PATHS=()
SIGN_TAG=test
SIGN_EMAIL=agents@example.invalid
BUILD_CMD="node build.js"
BUILD_DIR=dist
HOST_ADAPTER=firebase
EOF
export AGENT_KIT_CONF="$T/test.conf"
echo "DEMO_SETTING=1" >"$T/ops/secrets/demo.env"

# A tiny project: build.js turns src/app.txt into dist/ with a hashed bundle.
git init -q --bare "$T/origin/demo.git"
P="$T/seed"
mkdir -p "$P/src" "$P/docs"
cat >"$P/package.json" <<'EOF'
{ "name": "demo", "version": "1.0.0", "private": true, "scripts": { "build": "node build.js" } }
EOF
cat >"$P/package-lock.json" <<'EOF'
{ "name": "demo", "version": "1.0.0", "lockfileVersion": 3, "requires": true,
  "packages": { "": { "name": "demo", "version": "1.0.0" } } }
EOF
cat >"$P/build.js" <<'EOF'
const fs = require("fs"), crypto = require("crypto");
const src = fs.readFileSync("src/app.txt", "utf8");
const h = crypto.createHash("sha1").update(src).digest("hex").slice(0, 8);
fs.rmSync("dist", { recursive: true, force: true });
fs.mkdirSync("dist");
fs.writeFileSync(`dist/index-${h}.js`, `console.log(${JSON.stringify(src)});`);
fs.writeFileSync("dist/index.html", `<!doctype html><html><body><script src="/index-${h}.js"></script></body></html>\n`);
EOF
echo "version one" >"$P/src/app.txt"
for i in $(seq 1 20); do echo "Guide line $i"; done >"$P/docs/guide.md"
echo '{ "projects": { "default": "demo-project" } }' >"$P/.firebaserc"
printf 'node_modules/\ndist/\n.env\n' >"$P/.gitignore"
cp "$KIT/templates/project-CLAUDE.md" "$P/CLAUDE.md"
git -C "$P" init -q
commit "$P" "Start the demo project"
git -C "$P" push -q "$T/origin/demo.git" main
git clone -q "$T/origin/demo.git" "$T/ws/Demo"
mkdir -p "$T/ws/Demo/node_modules"
echo '{ "packages": {} }' >"$T/ws/Demo/node_modules/.package-lock.json"

C="$T/ws/_worktrees/Demo"
NOTES="$T/ops/handoffs/demo"
live_bundle() { grep -o 'index-[a-z0-9]*\.js' "$FAKE_HOST/live/index.html" 2>/dev/null || true; }

# ── Settings ──────────────────────────────────────────────────────────────────
echo "Settings"
sed 's/^KIT_CONFIGURED=yes/KIT_CONFIGURED=no/' "$T/test.conf" >"$T/off.conf"
expect_fail "refuses to run until the settings are filled in" "isn't set up yet" \
  "$T" env AGENT_KIT_CONF="$T/off.conf" "$S/worktree.sh" demo opus x
expect_fail "refuses an agent that isn't in AGENTS" "Unknown agent 'bob'" "$T" "$S/worktree.sh" demo bob x
expect_fail "refuses a repo that isn't in REPOS" "Unknown repo 'nope'" "$T" "$S/worktree.sh" nope opus x

# ── Own copy per agent ────────────────────────────────────────────────────────
echo "Own copy per agent"
expect_ok "worktree.sh makes the house agent's copy" "$T" "$S/worktree.sh" demo opus first-change
expect_ok "worktree.sh makes a second agent's copy" "$T" "$S/worktree.sh" demo codex wording
check "each copy is on its own branch" \
  '[ "$(git -C "$C/opus-first-change" branch --show-current)" = opus/first-change ] && [ "$(git -C "$C/codex-wording" branch --show-current)" = codex/wording ]'
check "the .env is copied in from secrets/" 'grep -q DEMO_SETTING "$C/opus-first-change/.env"'
expect_fail "preview.sh refuses the shared main folder" "shared main folder" "$T/ws/Demo" "$S/preview.sh"

# ── Plan-first handoff notes ──────────────────────────────────────────────────
echo "Plan-first handoff notes"
NOTE="$NOTES/opus-first-change.md"
check "worktree.sh starts a handoff note from the template" '[ -f "$NOTE" ] && grep -q "^## Goal" "$NOTE" && ! grep -q "{{" "$NOTE"'
expect_ok "handoff.sh fills in State" "$C/opus-first-change" "$S/handoff.sh"
check "a note without a plan gets a warning" 'grep -q "Goal is blank" "$NOTE" && grep -q "Next is blank" "$NOTE"'
node -e '
  const fs = require("fs"), f = process.argv[1];
  fs.writeFileSync(f, fs.readFileSync(f, "utf8")
    .replace(/## Goal\n.*\n/, "## Goal\nChange the app text to version two.\n")
    .replace(/(## Next[^\n]*\n).*\n/, "$1- [x] Edit src/app.txt\n- [ ] Preview\n"));' "$NOTE"
echo "version two" >"$C/opus-first-change/src/app.txt"
commit "$C/opus-first-change" "Show version two"
expect_ok "handoff.sh after a plan and a commit" "$C/opus-first-change" "$S/handoff.sh"
check "the warnings clear and State lists the commit" '! grep -q "is blank" "$NOTE" && grep -q "Show version two" "$NOTE"'

# ── One preview link per app ──────────────────────────────────────────────────
echo "One preview link per app"
expect_fail "ship.sh refuses work that was never previewed" "Nothing from you is on the 'claude' preview link" \
  "$C/opus-first-change" "$S/ship.sh"
expect_ok "preview.sh deploys to the app's link" "$C/opus-first-change" "$S/preview.sh"
check "the link is named after the app, with the strip on it" 'grep -q "Preview · claude · opus/first-change" "$FAKE_HOST/preview-claude/index.html"'
check "the live site was not touched" '[ ! -e "$FAKE_HOST/live" ]'

# ── One guarded ship script ───────────────────────────────────────────────────
echo "One guarded ship script"
expect_ok "ship.sh ships the previewed work" "$C/opus-first-change" "$S/ship.sh"
check "GitHub main equals the shipped commit" \
  '[ "$(git --git-dir="$T/origin/demo.git" rev-parse main)" = "$(git -C "$C/opus-first-change" rev-parse HEAD)" ]'
check "the live site serves that build, without the preview strip" \
  '[ -n "$(live_bundle)" ] && ! grep -q "Preview ·" "$FAKE_HOST/live/index.html"'
expect_ok "ship-status.sh runs" "$T" "$S/ship-status.sh"
check "ship-status.sh shows the verified release" \
  'printf "%s" "$OUT" | grep -q "Last verified  $(git -C "$C/opus-first-change" rev-parse --short=7 HEAD)"'

W="$C/codex-wording"
echo "more words" >>"$W/docs/guide.md"
commit "$W" "Add to the guide" "$(sign mallory)"
expect_ok "preview.sh (codex)" "$W" "$S/preview.sh"
expect_fail "refuses a branch behind main" "main has commits your branch doesn't" "$W" "$S/ship.sh"
git -C "$W" fetch -q origin && git -C "$W" rebase -q origin/main
expect_ok "preview.sh after the rebase" "$W" "$S/preview.sh"
expect_fail "refuses a sign-off that isn't in AGENTS" "isn't in the AGENTS list" "$W" "$S/ship.sh"
git -C "$W" commit -q --amend -m "Add to the guide" -m "$(sign codex)"
echo "an unpreviewed change" >>"$W/docs/guide.md"
commit "$W" "Change after the preview" "$(sign codex)"
expect_fail "refuses work that changed since the preview" "changed since the preview" "$W" "$S/ship.sh"
expect_ok "preview.sh again" "$W" "$S/preview.sh"
(exit 0) & DEAD=$!
wait "$DEAD" || true
mkdir -p "$T/ops/locks/demo-ship" && echo "$DEAD" >"$T/ops/locks/demo-ship/pid"
expect_ok "ship.sh clears a dead process's lock and ships" "$W" "$S/ship.sh"
check "…and said so" 'printf "%s" "$OUT" | grep -q "Clearing a stale ship lock"'

# ── Trial agents get stricter checks ──────────────────────────────────────────
echo "Trial agents"
expect_ok "worktree.sh (trial agent)" "$T" "$S/worktree.sh" demo gemini cleanup
G="$C/gemini-cleanup"
git -C "$G" rm -q docs/guide.md
commit "$G" "Remove the guide" "$(sign gemini)"
expect_ok "preview.sh (trial agent)" "$G" "$S/preview.sh"
expect_fail "refuses a deleted file" "This ship deletes files" "$G" "$S/ship.sh"
git -C "$G" reset -q --hard origin/main
head -n 3 "$G/docs/guide.md" >"$G/guide.tmp" && mv "$G/guide.tmp" "$G/docs/guide.md"
commit "$G" "Trim the guide" "$(sign gemini)"
expect_ok "preview.sh (trial agent, trimmed doc)" "$G" "$S/preview.sh"
expect_fail "refuses a trial agent gutting a doc" "removed large parts of these docs" "$G" "$S/ship.sh"

# ── Saving and taking over ────────────────────────────────────────────────────
echo "Saving and taking over"
echo "half-finished" >>"$G/src/app.txt"
expect_ok "handoff.sh --save commits unfinished work" "$G" "$S/handoff.sh" --save
check "…as WIP, with the agent's sign-off" \
  'git -C "$G" log -1 --format=%B | grep -q "^WIP:" && git -C "$G" log -1 --format=%B | grep -qF "$(sign gemini)"'
expect_ok "worktree.sh --from takes over another agent's branch" "$T" "$S/worktree.sh" demo codex finish-cleanup --from gemini/cleanup
check "the new copy starts from their last commit, with their note" \
  '[ "$(git -C "$C/codex-finish-cleanup" rev-parse HEAD)" = "$(git -C "$G" rev-parse HEAD)" ] && head -1 "$NOTES/codex-finish-cleanup.md" | grep -q "Taken over from"'
expect_fail "handoff.sh --save refuses someone else's folder" "OWN copy" "$T" "$S/handoff.sh" "$G" --save

# ── One Playbook, everywhere ──────────────────────────────────────────────────
echo "One Playbook, everywhere"
expect_ok "worktree.sh (playbook change)" "$T" "$S/worktree.sh" demo opus playbook
B="$C/opus-playbook"
expect_ok "sync-playbook.sh stamps the Playbook in" "$B" "$S/sync-playbook.sh"
check "every placeholder is filled from the settings" \
  'grep -q "PLAYBOOK — how every agent works here" "$B/CLAUDE.md" && ! grep -q "{{" "$B/CLAUDE.md"'
check "the team table comes from AGENTS" 'grep -qF "| gemini | \`antigravity\` | \`gemini-test[bot]\` | trial (stricter) |" "$B/CLAUDE.md"'
check "AGENTS.md and GEMINI.md are copies of CLAUDE.md" \
  'tail -n +3 "$B/AGENTS.md" | cmp -s - "$B/CLAUDE.md" && tail -n +3 "$B/GEMINI.md" | cmp -s - "$B/CLAUDE.md"'
commit "$B" "Sync the Playbook"
expect_ok "preview.sh (playbook change)" "$B" "$S/preview.sh"
expect_ok "ship.sh (playbook change)" "$B" "$S/ship.sh"

echo
if [ "$FAIL" -eq 0 ]; then echo "All $PASS checks passed."; else echo "$FAIL of $((PASS + FAIL)) checks failed."; exit 1; fi
