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

# stage_vendored <umbrella-dir> - build a v1 project fixture. v2 ships no v1
# engine (it is archived) and migrate no longer runs one, so the module is a
# STUB: detect_project only needs scripts/sync.sh + scripts/VERSION to classify
# the project as legacy. The content beside it is what the v1 sources point at.
stage_vendored() {
    mkdir -p "$1/sync/scripts"
    printf '#!/bin/bash\necho "archived v1 engine"\n' > "$1/sync/scripts/sync.sh"
    tr -d ' \t\r\n' < "$REPO/engine/VERSION" > "$1/sync/scripts/VERSION"
    cp -r "$REPO/packages/sync/rules" "$REPO/packages/sync/agents" \
        "$REPO/packages/sync/skills" "$1/sync/"
}

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

ENGINE_VER="$(tr -d ' \t\r\n' < "$REPO/engine/VERSION")"

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
  agents:
  skills:

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

echo "== 12a. registry add + list (trust list, no scope labels) =="
xok "package(s)" "$PROJ" registry add "file://$REG"
chk grep -q -- "- \"file://" "$PROJ/intelligence.yaml"
xok "file://" "$PROJ" registry list
# idempotent: adding the same URL twice records it once
xok "" "$PROJ" registry add "file://$REG"
n="$(grep -c -- "- \"file://$REG\"" "$PROJ/intelligence.yaml" || true)"
[ "$n" = "1" ] || { echo "FAIL: expected 1 registry entry, got $n"; fail=1; }

echo "== 12c. registry add refuses a url with no index.yaml, --force overrides =="
# $PACK is a package repo, not a registry — the mistake the refusal exists for.
cp "$PROJ/intelligence.yaml" "$OUT/manifest.reg"
xfail "no index.yaml found" "$PROJ" registry add "file://$PACK"
chk cmp -s "$OUT/manifest.reg" "$PROJ/intelligence.yaml"
xok "file://" "$PROJ" registry add "file://$PACK" --force
chk grep -q -- "$PACK\"" "$PROJ/intelligence.yaml"
xok "removed" "$PROJ" registry remove "file://$PACK"
chknot grep -q -- "$PACK\"" "$PROJ/intelligence.yaml"
# a scope argument is guided to the right command
xfail "added by URL" "$PROJ" registry add @acme

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

echo "== 3b. a name NO trusted registry declares is refused (no guessing) =="
xfail "no trusted registry declares" "$PROJ" add @nobody/nothing
chknot test -d "$PROJ/.intelligence/packages/@nobody"

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
# The refused content must NOT be committed to the store: a second --frozen
# would otherwise see the directory, skip verification, and sync it.
chknot test -d "$PROJ/.intelligence/packages/@acme/mover"
xfail "refusing under --frozen" "$PROJ" install --frozen

echo "== 6b. --frozen refuses manifest/lock drift =="
cp "$PROJ/intelligence.yaml" "$OUT/manifest.6b"
# portable in-place edit (BSD sed -i differs) — awk to temp, then move
awk '{ gsub(/version: "\^1\.0\.0"/, "version: \"^2.0.0\""); print }' \
    "$PROJ/intelligence.yaml" > "$PROJ/intelligence.yaml.tmp" && mv "$PROJ/intelligence.yaml.tmp" "$PROJ/intelligence.yaml"
xfail "requests" "$PROJ" install --frozen
cp "$OUT/manifest.6b" "$PROJ/intelligence.yaml"

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
xfail "not installed" "$CLONE" doctor
xok "" "$CLONE" install
xok "all good." "$CLONE" doctor

echo "== 8. migrate rollback on a CLI-refused target output =="
LEG1="$OUT/leg1"
mkdir -p "$LEG1"
stage_vendored "$LEG1/intelligence"
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
# .gitignore is part of the transaction: the fixture had none, rollback must
# not leave one behind.
chknot test -f "$LEG1/.gitignore"

echo "== 9. migrate dirty-tree refusal + --force =="
LEG2="$OUT/leg2"
mkdir -p "$LEG2"
stage_vendored "$LEG2/intelligence"
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
chk test -d "$LEG2/.intelligence/packages/@ainova-systems/sync"
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
xok "removed" "$PROJ" registry remove "file://$REG"
chknot grep -q -- "- \"file://$REG\"" "$PROJ/intelligence.yaml"
xok "(none)" "$PROJ" registry list
if printf '%s\n' "$OUTPUT" | grep -qF -- "file://$REG —"; then
    echo "FAIL: registry list still shows the registry after remove"
    fail=1
fi

echo "== 13. engine-content package: auto-add, guards, upgrade migration =="
P13="$OUT/p13"
mkdir -p "$P13"
printf "# Claude marker
" > "$P13/CLAUDE.md"
git -C "$P13" init --quiet
xok "engine content installed" "$P13" init
chk grep -q '"@ainova-systems/sync"' "$P13/intelligence.yaml"
chk test -d "$P13/.intelligence/packages/@ainova-systems/sync/skills/intelligence-sync"
chk test -d "$P13/.claude/skills/intelligence-update"
xok "owns it" "$P13" update
xfail "--force" "$P13" remove @ainova-systems/sync
chk grep -q '"@ainova-systems/sync"' "$P13/intelligence.yaml"
xok "" "$P13" remove @ainova-systems/sync --force
chknot grep -q '"@ainova-systems/sync"' "$P13/intelligence.yaml"
chknot test -d "$P13/.intelligence/packages/@ainova-systems/sync"

B13="$OUT/b13"
mkdir -p "$B13"
git -C "$B13" init --quiet
xok "bare setup" "$B13" init --bare
chknot grep -q '"@ainova-systems/sync"' "$B13/intelligence.yaml"

# A pre-package manifest (staged .intelligence/engine sources): sync fails
# closed with the upgrade hint; upgrade migrates it onto the package.
U13="$OUT/u13"
mkdir -p "$U13/intelligence/rules" "$U13/.intelligence/engine/rules"
printf '# Ctx\n\nu13 context\n' > "$U13/intelligence/rules/context.md"
cat > "$U13/intelligence.yaml" <<EOF
project:
  name: u13

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
git -C "$U13" init --quiet
xfail "intelligence upgrade" "$U13" sync
xok "" "$U13" upgrade
chknot grep -q '\.intelligence/engine' "$U13/intelligence.yaml"
chknot test -d "$U13/.intelligence/engine"
chk grep -q '"@ainova-systems/sync"' "$U13/intelligence.yaml"
chk test -d "$U13/.intelligence/packages/@ainova-systems/sync/rules"
xok "IS_STATUS=ok" "$U13" sync

echo "== 14. hostile inputs: lock keys, option-shaped urls, dispatcher =="
H14="$OUT/h14"
mkdir -p "$H14/intelligence/rules"
printf '# C\n\nctx\n' > "$H14/intelligence/rules/context.md"
cat > "$H14/intelligence.yaml" <<EOF
project:
  name: h14

sync_version: "$ENGINE_VER"

sources:
  rules:
    - "intelligence/rules"
  agents:
  skills:

targets:
  agents: { enabled: true, output: "AGENTS.md" }

packages:
  "@x/../../../escape":
    version: "1.0.0"
    url: "$PACK_URL"
EOF
git -C "$H14" init --quiet
# a traversal key in the manifest must be refused before any filesystem work
xfail "invalid package name" "$H14" install
xfail "invalid package name" "$H14" update
# option-shaped url must never reach git argv
cat > "$H14/intelligence.yaml" <<EOF
project:
  name: h14

sync_version: "$ENGINE_VER"

sources:
  rules:
    - "intelligence/rules"
  agents:
  skills:

targets:
  agents: { enabled: true, output: "AGENTS.md" }

packages:
  "@acme/evil":
    version: "1.0.0"
    url: "--upload-pack=touch $OUT/pwned;git-upload-pack"
EOF
xfail "unsafe source url" "$H14" install
chknot test -e "$OUT/pwned"                       # the RCE payload never ran
chknot test -d "$H14/.intelligence/packages/@acme"

# dispatcher: a path-shaped command word cannot exec a neighbouring script
run_in "$H14" ../../../etc/x
[ "$RC" -ne 0 ] || { echo "FAIL: dispatcher accepted a path-shaped command"; fail=1; }
printf '%s\n' "$OUTPUT" | grep -qF "unknown command" || { echo "FAIL: dispatcher did not reject path-shaped command"; fail=1; }

[ "$fail" -eq 0 ] && echo "E2E-NEGATIVE: ALL OK"
exit "$fail"
