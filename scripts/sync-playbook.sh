#!/usr/bin/env bash
# sync-playbook.sh — stamp the shared Playbook into this copy's agent instructions.
#
# Run inside your copy (never the shared main folder). It:
#   1. fills in playbook/PLAYBOOK.md (the one source) from agent-kit.conf: the
#      {{OPS}}, {{WORKSPACE}} and {{WORKTREES}} paths, the {{SIGNOFF}} form, and
#      the {{AGENT_TABLE}} and {{REPO_TABLE}}, so the rules agents read always
#      match what the scripts enforce;
#   2. puts the result between <!-- playbook:start --> and <!-- playbook:end -->
#      in CLAUDE.md (templates/project-CLAUDE.md shows where), and
#   3. writes AGENTS.md (Codex, OpenCode, Cursor…) and GEMINI.md (Gemini) as exact
#      copies of CLAUDE.md, so every app's agent reads the same instructions.
# Then commit, preview and ship like any change.
source "$(dirname "$0")/_agent-common.sh"

repo_info "$(current_repo)"
require_own_copy
TOP=$(git rev-parse --show-toplevel)
SRC="$KIT/playbook/PLAYBOOK.md"
[ -f "$SRC" ] || die "Missing $SRC."
[ -f "$TOP/CLAUDE.md" ] || die "No CLAUDE.md in $TOP. Start one from $TEMPLATES/project-CLAUDE.md."
grep -q '<!-- playbook:start -->' "$TOP/CLAUDE.md" && grep -q '<!-- playbook:end -->' "$TOP/CLAUDE.md" ||
  die "CLAUDE.md has no <!-- playbook:start --> / <!-- playbook:end --> markers. Add them where the Playbook belongs."

AGENT_ROWS=$(printf '%s\n' "${AGENTS[@]}") REPO_ROWS=$(printf '%s\n' "${REPOS[@]}") \
OPS=$KIT WORKSPACE=$WORKSPACE WORKTREES=$WORKTREES SIGN_TAG=$SIGN_TAG SIGN_EMAIL=$SIGN_EMAIL node -e '
  const fs = require("fs");
  const [file, src] = process.argv.slice(1);
  const env = process.env, home = env.HOME;
  const tilde = (p) => (home && p.startsWith(home + "/") ? "~" + p.slice(home.length) : p);
  const rows = (v) => v.split("\n").filter(Boolean).map((r) => r.split("|"));
  const agents = rows(env.AGENT_ROWS).map(([name, app, signer, trial]) =>
    `| ${name} | \`${app}\` | ${signer ? "`" + signer + "-" + env.SIGN_TAG + "[bot]`" : "none — the house agent, git author"} | ${trial === "trial" ? "trial (stricter)" : "standard"} |`);
  const repos = rows(env.REPO_ROWS).map(([name, folder, project, url]) =>
    `| \`${name}\` | \`${tilde(env.WORKSPACE)}/${folder}\` | ${url} (project \`${project}\`) |`);
  const vars = {
    OPS: tilde(env.OPS), WORKSPACE: tilde(env.WORKSPACE), WORKTREES: tilde(env.WORKTREES),
    SIGNOFF: `Co-Authored-By: <you>-${env.SIGN_TAG}[bot] <${env.SIGN_EMAIL}>`,
    AGENT_TABLE: ["| Agent | App = preview link | Sign-off on its commits | Ship checks |",
      "|---|---|---|---|", ...agents].join("\n"),
    REPO_TABLE: ["| GitHub repo | Shared folder (main only — never edit) | Live site |",
      "|---|---|---|", ...repos].join("\n"),
  };
  const pb = fs.readFileSync(src, "utf8").trim()
    .replace(/\{\{([A-Z_]+)\}\}/g, (m, k) => (k in vars ? vars[k] : m));
  const s = fs.readFileSync(file, "utf8");
  const a = s.indexOf("<!-- playbook:start -->"), b = s.indexOf("<!-- playbook:end -->");
  if (b < a) { console.error("markers out of order"); process.exit(1); }
  fs.writeFileSync(file, s.slice(0, a) + "<!-- playbook:start -->\n" + pb + "\n" + s.slice(b));
' "$TOP/CLAUDE.md" "$SRC"

for f in AGENTS.md GEMINI.md; do
  {
    printf '<!-- Generated from CLAUDE.md by sync-playbook.sh — do not edit here. -->\n\n'
    cat "$TOP/CLAUDE.md"
  } >"$TOP/$f"
done

say "Playbook synced into CLAUDE.md, AGENTS.md and GEMINI.md in $TOP."
git -C "$TOP" status --short CLAUDE.md AGENTS.md GEMINI.md
