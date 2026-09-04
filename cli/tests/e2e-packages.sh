#!/bin/bash
# Hermetic e2e for the resolver stack: package add/list/remove, locked restore,
# planned updates and registries against file:// fixture repos.
set -euo pipefail
unset CI
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
REPO="$(cd "$REPO" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
CLI="$REPO/cli/intelligence"
fail=0
chk() { if ! "$@" >/dev/null 2>&1; then echo "FAIL: $*"; fail=1; fi; }
chknot() { if "$@" >/dev/null 2>&1; then echo "FAIL(not): $*"; fail=1; fi; }

# --- fixture pack repo with tags ---
PACK="$OUT/shared-intel"
mkdir -p "$PACK/rules" "$PACK/skills/pack-do-thing"
printf '# Pack rule v1\n\nPACK_RULE_MARKER\n' > "$PACK/rules/pack-rule.md"
printf -- '---\nname: pack-do-thing\ndescription: Do the pack thing\n---\nBody v1.\n' > "$PACK/skills/pack-do-thing/SKILL.md"
git -C "$PACK" init --quiet
git -C "$PACK" -c user.email=t@t -c user.name=t add -A
git -C "$PACK" -c user.email=t@t -c user.name=t commit --quiet -m v1
git -C "$PACK" tag v1.0.0
printf '# Pack rule v1.1\n\nPACK_RULE_MARKER_11\n' > "$PACK/rules/pack-rule.md"
git -C "$PACK" -c user.email=t@t -c user.name=t commit --quiet -am v11
git -C "$PACK" tag v1.1.0
PACK_URL="file://$PACK"

# --- Intelligence project ---
PROJ="$OUT/proj"
mkdir -p "$PROJ/intelligence/rules"
ENGINE_VER="$(tr -d ' \t\r\n' < "$REPO/engine/VERSION")"
cat > "$PROJ/intelligence.yaml" <<EOF
project:
  name: e2e

schema_version: "$ENGINE_VER"

sources:
  rules:
    - "intelligence/rules"
  agents:
  skills:

targets:
  agents: { enabled: true, output: "AGENTS.md" }
  claude: { enabled: true, output: ".claude" }
EOF
printf '# Ctx\n\nproject context\n' > "$PROJ/intelligence/rules/context.md"
cat > "$PROJ/.gitignore" <<'EOF'
.intelligence/
CLAUDE.md
.claude/*
!.claude/settings.json
EOF
git -C "$PROJ" init --quiet

echo "== package add =="
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" package add "git+$PACK_URL" --name @acme/shared)
chk test -d "$PROJ/.intelligence/packages/@acme/shared/rules"
chk grep -q '"@acme/shared"' "$PROJ/intelligence.yaml"
chk grep -q 'version: "\^1.1.0"' "$PROJ/intelligence.yaml"
chknot grep -q '^[[:space:]]*url:' "$PROJ/intelligence.yaml"
chknot grep -q '^[[:space:]]*path:' "$PROJ/intelligence.yaml"
chk grep -q '\.intelligence/packages/@acme/shared/rules' "$PROJ/intelligence.yaml"
chk grep -q '\.intelligence/packages/@acme/shared/skills' "$PROJ/intelligence.yaml"
chk test -f "$PROJ/intelligence.lock"
chk grep -q 'resolved: "v1.1.0"' "$PROJ/intelligence.lock"
chk grep -q "url: \"$PACK_URL\"" "$PROJ/intelligence.lock"
chk grep -q 'sha: "' "$PROJ/intelligence.lock"
chk grep -q 'PACK_RULE_MARKER_11' "$PROJ/AGENTS.md"
chk grep -q 'pack-do-thing' "$PROJ/AGENTS.md"

echo "== package list =="
(cd "$PROJ" && bash "$CLI" package list)

echo "== fresh clone + sync restores the locked store =="
CLONE="$OUT/clone"
mkdir -p "$CLONE"
cp -r "$PROJ/intelligence" "$CLONE/intelligence"
cp "$PROJ/intelligence.yaml" "$PROJ/intelligence.lock" "$PROJ/.gitignore" "$CLONE/"
git -C "$CLONE" init --quiet
(cd "$CLONE" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync)
chk test -d "$CLONE/.intelligence/packages/@acme/shared/rules"
chk grep -q 'PACK_RULE_MARKER_11' "$CLONE/AGENTS.md"
sha_a="$(grep 'sha:' "$PROJ/intelligence.lock")"; sha_b="$(grep 'sha:' "$CLONE/intelligence.lock")"
[ "$sha_a" = "$sha_b" ] || { echo "FAIL: locked restore changed the lock sha"; fail=1; }

echo "== update (new tag) =="
printf '# Pack rule v1.2\n\nPACK_RULE_MARKER_12\n' > "$PACK/rules/pack-rule.md"
git -C "$PACK" -c user.email=t@t -c user.name=t commit --quiet -am v12
git -C "$PACK" tag v1.2.0
git -C "$PACK" tag v2.0.0   # out of ^1.1.0 range — must NOT be picked
preview12="$(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --preview)"
grep -q 'v1.1.0 -> v1.2.0' <<< "$preview12" \
    || { echo "FAIL: preview omitted the available update"; fail=1; }
if (cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update) >/dev/null 2>&1; then
    echo "FAIL: non-interactive update applied without --apply"; fail=1
fi
chk grep -q 'resolved: "v1.1.0"' "$PROJ/intelligence.lock"
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --apply)
chk grep -q 'resolved: "v1.2.0"' "$PROJ/intelligence.lock"
chknot grep -q 'resolved: "v2.0.0"' "$PROJ/intelligence.lock"
chk grep -q 'PACK_RULE_MARKER_12' "$PROJ/AGENTS.md"

echo "== update to a version that DROPPED a section dir =="
git -C "$PACK" rm -rq skills
git -C "$PACK" -c user.email=t@t -c user.name=t commit --quiet -m drop-skills
git -C "$PACK" tag v1.3.0
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --apply)
chk grep -q 'resolved: "v1.3.0"' "$PROJ/intelligence.lock"
chknot grep -q '\.intelligence/packages/@acme/shared/skills' "$PROJ/intelligence.yaml"
out13="$(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync)"
grep -q '^IS_STATUS=ok' <<< "$out13" || { echo "FAIL: sync after shape-changing update"; fail=1; }

echo "== update requested range when resolved tag stays unchanged =="
awk '{ gsub(/version: "\^1\.1\.0"/, "version: \"~1.3.0\""); print }' \
    "$PROJ/intelligence.yaml" > "$PROJ/intelligence.yaml.tmp"
mv "$PROJ/intelligence.yaml.tmp" "$PROJ/intelligence.yaml"
preview_req="$(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --preview)"
grep -q 'request \^1.1.0 -> ~1.3.0 (keeps v1.3.0)' <<< "$preview_req" \
    || { echo "FAIL: preview omitted request-only lock alignment"; fail=1; }
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --apply >/dev/null)
chk grep -q 'requested: "~1.3.0"' "$PROJ/intelligence.lock"
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" status --check >/dev/null)

echo "== ref pin: a moved branch is an update, not 'up to date' =="
# Until 0.11.6 a `ref:` pin compared the manifest's ref NAME against the lock's
# resolved column, which holds that same name — so a branch pin reported
# "up to date" forever while a fresh clone's frozen restore refused it as
# moved. The pin now compares commit to commit.
BR="$OUT/branchpack"
mkdir -p "$BR/rules"
printf '# Branch rule v1\n\nBRANCH_MARKER_ONE\n' > "$BR/rules/branch-rule.md"
git -C "$BR" init --quiet
git -C "$BR" -c user.email=t@t -c user.name=t add -A
git -C "$BR" -c user.email=t@t -c user.name=t commit --quiet -m b1
git -C "$BR" checkout -q -B pack-main
BR_URL="file://$BR"
BR_SHA1="$(git -C "$BR" rev-parse HEAD)"
lock_sha_of() {
    awk -v key="\"$1\":" '$1 == key { hit = 1; next }
        hit && $1 == "sha:" { gsub(/"/, "", $2); print $2; exit }' "$PROJ/intelligence.lock"
}
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" package add "git+$BR_URL@pack-main" --name @acme/branch)
chk grep -q 'ref: "pack-main"' "$PROJ/intelligence.yaml"
chk grep -q 'resolved: "pack-main"' "$PROJ/intelligence.lock"
[ "$(lock_sha_of @acme/branch)" = "$BR_SHA1" ] || { echo "FAIL: ref pin locked the wrong sha"; fail=1; }
chk grep -q 'BRANCH_MARKER_ONE' "$PROJ/AGENTS.md"
# an unmoved branch still reads as up to date, and now shows WHICH commit
pv_ref0="$(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --preview @acme/branch)"
grep -q "pack-main@${BR_SHA1:0:7} (up to date)" <<< "$pv_ref0" \
    || { echo "FAIL: unmoved ref pin lost its commit in the plan"; fail=1; }
# `package list` shows the same commit, so the pin is legible without a probe
list_ref="$(cd "$PROJ" && bash "$CLI" package list)"
grep -q "locked:pack-main@${BR_SHA1:0:7}" <<< "$list_ref" \
    || { echo "FAIL: package list hides the ref pin's commit"; fail=1; }

printf '# Branch rule v2\n\nBRANCH_MARKER_TWO\n' > "$BR/rules/branch-rule.md"
git -C "$BR" -c user.email=t@t -c user.name=t commit --quiet -am b2
BR_SHA2="$(git -C "$BR" rev-parse HEAD)"
pv_ref="$(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --preview @acme/branch)"
grep -q "pack-main ${BR_SHA1:0:7} -> ${BR_SHA2:0:7}" <<< "$pv_ref" \
    || { echo "FAIL: preview did not report the moved branch"; fail=1; }
grep -q 'updates available: 1 package' <<< "$pv_ref" \
    || { echo "FAIL: moved branch was not counted as an update"; fail=1; }
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --apply @acme/branch)
[ "$(lock_sha_of @acme/branch)" = "$BR_SHA2" ] || { echo "FAIL: apply did not move the locked sha"; fail=1; }
# the intent stays the branch; only the resolution moved
chk grep -q 'resolved: "pack-main"' "$PROJ/intelligence.lock"
chk grep -q 'BRANCH_MARKER_TWO' "$PROJ/AGENTS.md"
chknot grep -q 'BRANCH_MARKER_ONE' "$PROJ/AGENTS.md"

echo "== ref pin: the updated lock restores on a fresh clone =="
# The other half of the dead end: sync restores a missing store with --frozen,
# which dies when a ref pin's branch has moved past the lock. After the update
# above, the lock is the branch head again and the frozen restore must pass.
RCLONE="$OUT/refclone"
mkdir -p "$RCLONE"
cp -r "$PROJ/intelligence" "$RCLONE/intelligence"
cp "$PROJ/intelligence.yaml" "$PROJ/intelligence.lock" "$PROJ/.gitignore" "$RCLONE/"
git -C "$RCLONE" init --quiet
out_ref="$(cd "$RCLONE" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync)"
grep -q '^IS_STATUS=ok' <<< "$out_ref" || { echo "FAIL: frozen restore of a ref pin"; fail=1; }
chk grep -q 'BRANCH_MARKER_TWO' "$RCLONE/AGENTS.md"

echo "== ref pin: a commit sha never moves =="
awk '{ gsub(/ref: "pack-main"/, "ref: \"'"$BR_SHA1"'\""); print }' \
    "$PROJ/intelligence.yaml" > "$PROJ/intelligence.yaml.tmp"
mv "$PROJ/intelligence.yaml.tmp" "$PROJ/intelligence.yaml"
# the manifest now names a ref the lock never resolved: an ordinary move
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --apply @acme/branch >/dev/null)
[ "$(lock_sha_of @acme/branch)" = "$BR_SHA1" ] || { echo "FAIL: commit pin was not applied"; fail=1; }
chk grep -q 'BRANCH_MARKER_ONE' "$PROJ/AGENTS.md"
# once resolved, it is immutable however far the branch runs ahead
pv_pin="$(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --preview @acme/branch)"
grep -q "${BR_SHA1:0:7} (pinned commit)" <<< "$pv_pin" \
    || { echo "FAIL: a commit pin was not reported as pinned"; fail=1; }
grep -q 'updates available: 0 package' <<< "$pv_pin" \
    || { echo "FAIL: a commit pin was counted as an update"; fail=1; }
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" package remove @acme/branch >/dev/null)

echo "== ref pin: a deleted branch is reported, even when its name looks like a sha =="
# The commit-pin verdict reads the locked sha, not the ref's shape: a branch
# named like hex would otherwise pass for a pin and swallow its own deletion.
HEXB="$OUT/hexpack"
mkdir -p "$HEXB/rules"
printf '# Hex rule\n\nHEX_MARKER\n' > "$HEXB/rules/hex-rule.md"
git -C "$HEXB" init --quiet
git -C "$HEXB" -c user.email=t@t -c user.name=t add -A
git -C "$HEXB" -c user.email=t@t -c user.name=t commit --quiet -m h1
git -C "$HEXB" checkout -q -B deadbeef
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" package add "git+file://$HEXB@deadbeef" --name @acme/hex --no-sync)
git -C "$HEXB" checkout -q -B keeper
git -C "$HEXB" branch -D deadbeef >/dev/null
pv_gone="$(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --preview @acme/hex 2>/dev/null)"
grep -q 'deadbeef (unresolvable — gone upstream)' <<< "$pv_gone" \
    || { echo "FAIL: a deleted branch named like a sha was not reported"; fail=1; }
chknot grep -q 'pinned commit' <<< "$pv_gone"
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" package remove @acme/hex --no-sync >/dev/null)

echo "== project file overrides a same-named package file =="
printf '# Project override\n\nPROJECT_WINS\n' > "$PROJ/intelligence/rules/pack-rule.md"
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync >/dev/null)
chk grep -q 'PROJECT_WINS' "$PROJ/.claude/rules/pack-rule.md"
chknot grep -q 'PACK_RULE_MARKER' "$PROJ/.claude/rules/pack-rule.md"
rm -f "$PROJ/intelligence/rules/pack-rule.md"

echo "== registry binding =="
REG="$OUT/registry"
mkdir -p "$REG"
cat > "$REG/index.yaml" <<EOF
packages:
  "@acme/via-registry":
    url: "$PACK_URL"
    path: "skills"
EOF
git -C "$REG" init --quiet
git -C "$REG" -c user.email=t@t -c user.name=t add -A
git -C "$REG" -c user.email=t@t -c user.name=t commit --quiet -m idx
(cd "$PROJ" && bash "$CLI" registry add "file://$REG")
chk grep -q -- "- \"file://$REG\"" "$PROJ/intelligence.yaml"
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" package add @acme/via-registry --no-sync)
chk test -f "$PROJ/.intelligence/packages/@acme/via-registry/pack-do-thing/SKILL.md"
chk grep -q '"@acme/via-registry"' "$PROJ/intelligence.lock"
chk grep -q 'version: "\^2.0.0"' "$PROJ/intelligence.yaml"
chknot grep -q "url: \"$PACK_URL\"" "$PROJ/intelligence.yaml"
chk grep -q 'path: "skills"' "$PROJ/intelligence.lock"

echo "== package remove =="
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" package remove @acme/shared)
chknot grep -q '"@acme/shared"' "$PROJ/intelligence.yaml"
chknot test -d "$PROJ/.intelligence/packages/@acme/shared"
chknot grep -q '@acme/shared' "$PROJ/intelligence.lock"
chknot grep -q 'PACK_RULE_MARKER' "$PROJ/AGENTS.md"

echo "== idempotent second sync =="
out2="$(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync)"
grep -q '^IS_STATUS=ok' <<< "$out2" || { echo "FAIL: final sync not ok"; fail=1; }

[ "$fail" -eq 0 ] && echo "CLI-E2E: ALL OK"
exit "$fail"
