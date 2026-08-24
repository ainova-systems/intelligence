#!/bin/bash
# Negative-path and small-command e2e for the intelligence CLI: bad specs,
# unsatisfiable ranges, tagless registry packages, frozen-install refusals,
# doctor failures, migrate rollback / dirty-tree refusal, init/status modes,
# and registry bindings. Hermetic: file:// fixture repos only, no network.
set -euo pipefail
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
OUT="$(mktemp -d)"
EMPTY="$(mktemp -d)"
trap 'rm -rf "$OUT" "$EMPTY"' EXIT
CLI="$REPO/cli/intelligence"
fail=0
chk() { if ! "$@" >/dev/null 2>&1; then echo "FAIL: $*"; fail=1; fi; }
chknot() { if "$@" >/dev/null 2>&1; then echo "FAIL(not): $*"; fail=1; fi; }

# run_in <dir> <cli-args…> — run the CLI from <dir>, capturing combined
# output and exit code into OUTPUT / RC without tripping set -e.
RC=0
OUTPUT=""
run_in() {
    local d="$1"; shift
    RC=0
    OUTPUT="$( (cd "$d" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" "$@") 2>&1 )" || RC=$?
}

# xfail <fragment> <dir> <cli-args…> — must exit nonzero AND say why.
xfail() {
    local frag="$1" d="$2"; shift 2
    run_in "$d" "$@"
    if [ "$RC" -eq 0 ]; then echo "FAIL: expected nonzero rc: $*"; fail=1; fi
    if ! printf '%s\n' "$OUTPUT" | grep -qF -- "$frag"; then
        echo "FAIL: output of '$*' lacks '$frag'"
        printf '%s\n' "$OUTPUT" | head -6
        fail=1
    fi
}

# xok <fragment-or-empty> <dir> <cli-args…> — must exit 0 (fragment optional).
xok() {
    local frag="$1" d="$2"; shift 2
    run_in "$d" "$@"
    if [ "$RC" -ne 0 ]; then
        echo "FAIL: expected rc=0 (got $RC): $*"
        printf '%s\n' "$OUTPUT" | tail -8
        fail=1
    fi
    if [ -n "$frag" ] && ! printf '%s\n' "$OUTPUT" | grep -qF -- "$frag"; then
        echo "FAIL: output of '$*' lacks '$frag'"
        fail=1
    fi
}

ENGINE_VER="$(tr -d ' \t\r\n' < "$REPO/intelligence/sync/scripts/VERSION")"

echo "== fixtures =="
# Pack repo with only 1.x tags.
PACK="$OUT/pack"
mkdir -p "$PACK/rules"
printf '# Pack rule v1\n\nNEG_PACK_MARKER\n' > "$PACK/rules/pack-rule.md"
git -C "$PACK" init --quiet
git -C "$PACK" -c user.email=t@t -c user.name=t add -A
git -C "$PACK" -c user.email=t@t -c user.name=t commit --quiet -m v1
git -C "$PACK" tag v1.0.0
printf '# Pack rule v1.1\n\nNEG_PACK_MARKER_11\n' > "$PACK/rules/pack-rule.md"
git -C "$PACK" -c user.email=t@t -c user.name=t commit --quiet -am v11
git -C "$PACK" tag v1.1.0
PACK_URL="file://$PACK"

# Pack repo with NO version tags at all.
NOTAGS="$OUT/notags"
mkdir -p "$NOTAGS/rules"
printf '# Tagless rule\n\nTAGLESS_MARKER\n' > "$NOTAGS/rules/tagless.md"
git -C "$NOTAGS" init --quiet
git -C "$NOTAGS" -c user.email=t@t -c user.name=t add -A
git -C "$NOTAGS" -c user.email=t@t -c user.name=t commit --quiet -m head
NOTAGS_URL="file://$NOTAGS"

# Pack repo whose v1.0.0 tag will be force-moved later.
MOVE="$OUT/movepack"
mkdir -p "$MOVE/rules"
printf '# Mover rule\n\nMOVER_MARKER_V1\n' > "$MOVE/rules/mover-rule.md"
git -C "$MOVE" init --quiet
git -C "$MOVE" -c user.email=t@t -c user.name=t add -A
git -C "$MOVE" -c user.email=t@t -c user.name=t commit --quiet -m v1
git -C "$MOVE" tag v1.0.0
MOVE_URL="file://$MOVE"

# Registry repo binding @acme names to the fixtures above.
REG="$OUT/registry"
mkdir -p "$REG"
cat > "$REG/index.yaml" <<EOF
packages:
  "@acme/pkg":
    url: "$PACK_URL"
  "@acme/notags":
    url: "$NOTAGS_URL"
EOF
git -C "$REG" init --quiet
git -C "$REG" -c user.email=t@t -c user.name=t add -A
git -C "$REG" -c user.email=t@t -c user.name=t commit --quiet -m idx

# v2 project.
PROJ="$OUT/proj"
mkdir -p "$PROJ/intelligence/rules"
cat > "$PROJ/intelligence.yaml" <<EOF
project:
  name: e2e-negative

sync_version: "$ENGINE_VER"

sources:
  rules:
    - "intelligence/rules"
    - ".intelligence/engine/rules"
  agents:
    - ".intelligence/engine/agents"
  skills:
    - ".intelligence/engine/skills"

targets:
  agents: { enabled: true, output: "AGENTS.md" }
  claude: { enabled: true, output: ".claude" }
EOF
printf '# Ctx\n\nproject context\n' > "$PROJ/intelligence/rules/context.md"
git -C "$PROJ" init --quiet

echo "== 1. garbage spec =="
cp "$PROJ/intelligence.yaml" "$OUT/manifest.s1"
xfail "expected @scope/name" "$PROJ" add not-a-spec
chk cmp -s "$OUT/manifest.s1" "$PROJ/intelligence.yaml"

echo "== 12a. registry add + list =="
xok "" "$PROJ" registry add @acme "file://$REG"
chk grep -q '"@acme": "file://' "$PROJ/intelligence.yaml"
xok "@acme -> file://" "$PROJ" registry list

echo "== 2. no tag satisfies the range =="
cp "$PROJ/intelligence.yaml" "$OUT/manifest.s2"
xfail "satisfies" "$PROJ" add @acme/pkg@^9.0.0
chk cmp -s "$OUT/manifest.s2" "$PROJ/intelligence.yaml"
chknot test -d "$PROJ/.intelligence/packages/@acme/pkg"
chknot test -f "$PROJ/intelligence.lock"

echo "== 3. registry package without version tags =="
xfail "must be versioned" "$PROJ" add @acme/notags
chknot test -d "$PROJ/.intelligence/packages/@acme/notags"
chknot test -f "$PROJ/intelligence.lock"

echo "== 4. remove a never-added package =="
xfail "not in the manifest" "$PROJ" remove @acme/never-added

echo "== 5. update a never-added package =="
xfail "not in the manifest" "$PROJ" update @acme/never-added

echo "== 6. install --frozen after the tag moved =="
xok "" "$PROJ" add "git+$MOVE_URL" --name @acme/mover --no-sync
chk test -d "$PROJ/.intelligence/packages/@acme/mover/rules"
chk grep -q 'resolved: "v1.0.0"' "$PROJ/intelligence.lock"
sha_before="$(grep 'sha:' "$PROJ/intelligence.lock" || true)"
chk test -n "$sha_before"
printf '# Mover rule\n\nMOVER_MARKER_V2\n' > "$MOVE/rules/mover-rule.md"
git -C "$MOVE" -c user.email=t@t -c user.name=t commit --quiet -am moved
git -C "$MOVE" tag -f v1.0.0 >/dev/null
rm -rf "$PROJ/.intelligence/packages"
xfail "refusing under --frozen" "$PROJ" install --frozen
sha_frozen="$(grep 'sha:' "$PROJ/intelligence.lock" || true)"
[ "$sha_before" = "$sha_frozen" ] || { echo "FAIL: --frozen modified the lock sha"; fail=1; }
# The refused fetch landed in the store — reset it so the plain install
# demonstrably re-fetches and re-locks the moved ref.
rm -rf "$PROJ/.intelligence/packages"
xok "" "$PROJ" install
sha_after="$(grep 'sha:' "$PROJ/intelligence.lock" || true)"
chk test -n "$sha_after"
[ "$sha_before" != "$sha_after" ] || { echo "FAIL: plain install did not update the moved sha"; fail=1; }
chk grep -q 'MOVER_MARKER_V2' "$PROJ/AGENTS.md"

echo "== 7. doctor on a fresh clone =="
CLONE="$OUT/clone"
mkdir -p "$CLONE"
cp -r "$PROJ/intelligence" "$CLONE/intelligence"
cp "$PROJ/intelligence.yaml" "$PROJ/intelligence.lock" "$CLONE/"
git -C "$CLONE" init --quiet
xfail "engine content not staged" "$CLONE" doctor
xok "" "$CLONE" install
xok "all good." "$CLONE" doctor

echo "== 8. migrate rollback on a CLI-refused target output =="
LEG1="$OUT/leg1"
mkdir -p "$LEG1"
cp -r "$REPO/intelligence" "$LEG1/intelligence"
mkdir -p "$LEG1/intelligence/rules"
printf '# Ctx\n\nleg1 context\n' > "$LEG1/intelligence/rules/context.md"
cat > "$LEG1/intelligence/config.yaml" <<EOF
project:
  name: leg1-fixture

sync_version: "$ENGINE_VER"

sources:
  rules:
    - "intelligence/rules"
    - "intelligence/sync/rules"
  agents:
    - "intelligence/sync/agents"
  skills:
    - "intelligence/sync/skills"

targets:
  agents: { enabled: true, output: "AGENTS.md" }
  claude: { enabled: true, output: ".intelligence/out" }
EOF
git -C "$LEG1" init --quiet
git -C "$LEG1" -c core.autocrlf=false -c user.email=t@t -c user.name=t add -A
git -C "$LEG1" -c core.autocrlf=false -c user.email=t@t -c user.name=t commit --quiet -m base
xfail "rolled back" "$LEG1" migrate
if ! printf '%s\n' "$OUTPUT" | grep -qF -- "protected"; then
    echo "FAIL: rollback output does not name the protected directory"
    fail=1
fi
chk test -f "$LEG1/intelligence/config.yaml"
chk test -d "$LEG1/intelligence/sync"
chknot test -f "$LEG1/intelligence.yaml"
chknot test -f "$LEG1/intelligence.lock"
chknot test -d "$LEG1/.intelligence"

echo "== 9. migrate dirty-tree refusal + --force =="
LEG2="$OUT/leg2"
mkdir -p "$LEG2"
cp -r "$REPO/intelligence" "$LEG2/intelligence"
mkdir -p "$LEG2/intelligence/rules"
printf '# Ctx\n\nleg2 context\n' > "$LEG2/intelligence/rules/context.md"
cat > "$LEG2/intelligence/config.yaml" <<EOF
project:
  name: leg2-fixture

sync_version: "$ENGINE_VER"

sources:
  rules:
    - "intelligence/rules"
    - "intelligence/sync/rules"
  agents:
    - "intelligence/sync/agents"
  skills:
    - "intelligence/sync/skills"

targets:
  agents: { enabled: true, output: "AGENTS.md" }
  claude: { enabled: true, output: ".claude" }
EOF
git -C "$LEG2" init --quiet
git -C "$LEG2" -c core.autocrlf=false -c user.email=t@t -c user.name=t add -A
git -C "$LEG2" -c core.autocrlf=false -c user.email=t@t -c user.name=t commit --quiet -m base
touch "$LEG2/wip.txt"
xfail "commit or stash" "$LEG2" migrate
chknot test -f "$LEG2/intelligence.yaml"
xok "" "$LEG2" migrate --force
chk test -f "$LEG2/intelligence.yaml"
chk test -f "$LEG2/intelligence.lock"
chknot test -f "$LEG2/intelligence/config.yaml"
chknot test -d "$LEG2/intelligence/sync"
chk test -d "$LEG2/.intelligence/engine"
chk test -f "$LEG2/.intelligence/backup/config.yaml"
chk test -f "$LEG2/AGENTS.md"

echo "== 10. init refusals =="
xfail "already set up" "$PROJ" init
xfail "migrate" "$LEG1" init

echo "== 11. status in all three modes =="
xok "CLI setup" "$PROJ" status
xok "vendored" "$LEG1" status
xok "No intelligence project" "$EMPTY" status

echo "== 12b. registry remove =="
xok "unbound" "$PROJ" registry remove @acme
chknot grep -q '"@acme": ' "$PROJ/intelligence.yaml"
xok "(none)" "$PROJ" registry list
if printf '%s\n' "$OUTPUT" | grep -qF -- "@acme -> "; then
    echo "FAIL: registry list still shows @acme after remove"
    fail=1
fi

[ "$fail" -eq 0 ] && echo "E2E-NEGATIVE: ALL OK"
exit "$fail"
