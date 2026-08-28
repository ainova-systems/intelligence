#!/bin/bash
# Negative-path and small-command e2e for the intelligence CLI: bad specs,
# unsatisfiable ranges, tagless registry packages, frozen-restore refusals,
# status failures, migration rollback / dirty-tree refusal, init modes,
# and registry bindings. Hermetic: file:// fixture repos only, no network.
set -euo pipefail
# Hosted CI exports CI=true for the whole process. Most cases exercise normal
# local behavior; the two refusal cases below opt into CI explicitly.
unset CI
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
REPO="$(cd "$REPO" && pwd)"
OUT="$(mktemp -d)"
EMPTY="$(mktemp -d)"
trap 'rm -rf "$OUT" "$EMPTY"' EXIT
CLI="$REPO/cli/intelligence"
fail=0
chk() { if ! "$@" >/dev/null 2>&1; then echo "FAIL: $*"; fail=1; fi; }
chknot() { if "$@" >/dev/null 2>&1; then echo "FAIL(not): $*"; fail=1; fi; }

# stage_vendored <umbrella-dir> - build a legacy Intelligence Sync fixture.
# engine (it is archived) and migrate no longer runs one, so the module is a
# STUB: detect_project only needs scripts/sync.sh + scripts/VERSION to classify
# the project as legacy. The content beside it is what its sources point at.
stage_vendored() {
    mkdir -p "$1/sync/scripts"
    printf '#!/bin/bash\necho "legacy Intelligence Sync engine"\n' > "$1/sync/scripts/sync.sh"
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

# Intelligence project.
PROJ="$OUT/proj"
mkdir -p "$PROJ/intelligence/rules"
cat > "$PROJ/intelligence.yaml" <<EOF
project:
  name: e2e-negative

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

echo "== 1. garbage spec =="
cp "$PROJ/intelligence.yaml" "$OUT/manifest.s1"
xfail "expected @scope/name" "$PROJ" package add not-a-spec
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
xfail "satisfies" "$PROJ" package add @acme/pkg@^9.0.0
chk cmp -s "$OUT/manifest.s2" "$PROJ/intelligence.yaml"
chknot test -d "$PROJ/.intelligence/packages/@acme/pkg"
chknot test -f "$PROJ/intelligence.lock"

echo "== 3. registry package without version tags =="
xfail "must be versioned" "$PROJ" package add @acme/notags
chknot test -d "$PROJ/.intelligence/packages/@acme/notags"
chknot test -f "$PROJ/intelligence.lock"

echo "== 3a. explicit tagless package records a HEAD intent, source only in lock =="
xok "@acme/tagless-direct@HEAD" "$PROJ" package add "git+$NOTAGS_URL" --name @acme/tagless-direct --no-sync
chk grep -q 'ref: "HEAD"' "$PROJ/intelligence.yaml"
chknot grep -q "url: \"$NOTAGS_URL\"" "$PROJ/intelligence.yaml"
chk grep -q "url: \"$NOTAGS_URL\"" "$PROJ/intelligence.lock"
chk grep -q 'resolved: "HEAD"' "$PROJ/intelligence.lock"
xok "" "$PROJ" package remove @acme/tagless-direct --no-sync

echo "== 3b. a name NO trusted registry declares is refused (no guessing) =="
xfail "no trusted registry declares" "$PROJ" package add @nobody/nothing
chknot test -d "$PROJ/.intelligence/packages/@nobody"

echo "== 4. remove a never-added package =="
xfail "not in the manifest" "$PROJ" package remove @acme/never-added

echo "== 5. update a never-added package =="
xfail "not in the manifest" "$PROJ" update @acme/never-added --preview
xfail "choose either" "$PROJ" update --preview --apply

echo "== 6. sync frozen-restore after the tag moved =="
xok "" "$PROJ" package add "git+$MOVE_URL" --name @acme/mover --no-sync
chk test -d "$PROJ/.intelligence/packages/@acme/mover/rules"
chk grep -q 'resolved: "v1.0.0"' "$PROJ/intelligence.lock"
sha_before="$(grep 'sha:' "$PROJ/intelligence.lock" || true)"
chk test -n "$sha_before"
printf '# Mover rule\n\nMOVER_MARKER_V2\n' > "$MOVE/rules/mover-rule.md"
git -C "$MOVE" -c user.email=t@t -c user.name=t commit --quiet -am moved
git -C "$MOVE" tag -f v1.0.0 >/dev/null
rm -rf "$PROJ/.intelligence/packages"
xfail "refusing under --frozen" "$PROJ" sync --compact
sha_frozen="$(grep 'sha:' "$PROJ/intelligence.lock" || true)"
[ "$sha_before" = "$sha_frozen" ] || { echo "FAIL: --frozen modified the lock sha"; fail=1; }
# The refused content must NOT be committed to the store: a second --frozen
# would otherwise see the directory, skip verification, and sync it.
chknot test -d "$PROJ/.intelligence/packages/@acme/mover"
xfail "refusing under --frozen" "$PROJ" sync

echo "== 6b. --frozen refuses manifest/lock drift =="
cp "$PROJ/intelligence.yaml" "$OUT/manifest.6b"
# portable in-place edit (BSD sed -i differs) — awk to temp, then move
awk '{ gsub(/version: "\^1\.0\.0"/, "version: \"^2.0.0\""); print }' \
    "$PROJ/intelligence.yaml" > "$PROJ/intelligence.yaml.tmp" && mv "$PROJ/intelligence.yaml.tmp" "$PROJ/intelligence.yaml"
xfail "requests" "$PROJ" sync
cp "$OUT/manifest.6b" "$PROJ/intelligence.yaml"

# Frozen restore deliberately has no public bypass. Remove the compromised
# dependency from the manifest before continuing with unrelated scenarios.
xok "" "$PROJ" package remove @acme/mover --no-sync
# Keep one immutable package so the fresh-clone scenario has a lock/store to
# restore, without accepting the force-moved tag above.
xok "" "$PROJ" package add @acme/pkg@^1.0.0 --no-sync

echo "== 7. status --check and sync restore on a fresh clone =="
CLONE="$OUT/clone"
mkdir -p "$CLONE"
cp -r "$PROJ/intelligence" "$CLONE/intelligence"
cp "$PROJ/intelligence.yaml" "$PROJ/intelligence.lock" "$PROJ/.gitignore" "$CLONE/"
git -C "$CLONE" init --quiet
xfail "not installed" "$CLONE" status --check
xok "" "$CLONE" sync
xok "all good." "$CLONE" status --check
cp "$CLONE/intelligence.yaml" "$OUT/manifest.7"
awk '{ gsub(/version: "\^1\.0\.0"/, "version: \"^9.0.0\""); print }' \
    "$CLONE/intelligence.yaml" > "$CLONE/intelligence.yaml.tmp" && mv "$CLONE/intelligence.yaml.tmp" "$CLONE/intelligence.yaml"
xfail "requests '^9.0.0'" "$CLONE" status --check
cp "$OUT/manifest.7" "$CLONE/intelligence.yaml"

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
xfail "rolled back" "$LEG1" init --apply
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

# Pre-existing Intelligence state is never consumed, nested, overwritten or removed by
# migration. In particular, a leftover ignored store must fail closed.
mkdir -p "$LEG1/.intelligence"
printf 'keep\n' > "$LEG1/.intelligence/pre-existing"
xfail ".intelligence already exists" "$LEG1" init --apply --force
chk grep -q 'keep' "$LEG1/.intelligence/pre-existing"
chk test -f "$LEG1/intelligence/config.yaml"
rm -rf "$LEG1/.intelligence"

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
cp "$LEG2/intelligence/config.yaml" "$OUT/leg2-config.safe"
cat >> "$LEG2/intelligence/config.yaml" <<EOF

packs:
  destructive:
    url: "$PACK_URL"
    ref: "v1.0.0"
    mirror: "intelligence"
EOF
xfail "contains the legacy content directory" "$LEG2" init --apply --force
chk test -f "$LEG2/intelligence/config.yaml"
chk test -d "$LEG2/intelligence/sync"
cp "$OUT/leg2-config.safe" "$LEG2/intelligence/config.yaml"
touch "$LEG2/wip.txt"
xfail "commit or stash" "$LEG2" init --apply
chknot test -f "$LEG2/intelligence.yaml"
xok "" "$LEG2" init --apply --force
chk test -f "$LEG2/intelligence.yaml"
chk test -f "$LEG2/intelligence.lock"
chknot test -f "$LEG2/intelligence/config.yaml"
chknot test -d "$LEG2/intelligence/sync"
chk test -d "$LEG2/.intelligence/packages/@ainova-systems/sync"
chk test -f "$LEG2/.intelligence/backup/config.yaml"
chk test -f "$LEG2/AGENTS.md"

echo "== 10. init is idempotent; failed legacy migration remains previewable =="
xok "" "$PROJ" init
xok "dry run" "$LEG1" init --preview
xok "would omit the bundled sync-content package" "$EMPTY" init --preview --bare --no-sync
xfail "unsafe content directory '.git'" "$EMPTY" init --dir .git
mkdir -p "$OUT/outside-content"
ln -s "$OUT/outside-content" "$EMPTY/linked-content"
xfail "resolves outside the repository" "$EMPTY" init --dir linked-content
rm -f "$EMPTY/linked-content"
xfail "invalid target name" "$EMPTY" init --targets ../escape
xfail "adapter 'missing' not found" "$EMPTY" init --targets missing
chknot test -f "$EMPTY/intelligence.yaml"

# A failed first sync leaves a complete recoverable project state, restores the
# original AGENTS.md, and points directly at the context-learning recovery skill.
PFAIL="$OUT/init-failure"
mkdir -p "$PFAIL/intelligence/adapters"
printf '# Original agents\nINITIAL_AGENTS_SURVIVES\n' > "$PFAIL/AGENTS.md"
cat > "$PFAIL/intelligence/adapters/broken.sh" <<'EOF'
adapter_contract_broken() {
    adapter_contract_version 1
    adapter_contract_owned "${1%/}/state"
    adapter_contract_ignore "${1%/}/state/"
}
sync_to_broken() {
    mkdir -p "$3/state"
    printf 'partial\n' > "$3/state/partial.txt"
    return 29
}
EOF
git -C "$PFAIL" init --quiet
xfail "Intelligence setup needs recovery" "$PFAIL" init --targets agents,broken
printf '%s\n' "$OUTPUT" | grep -q '^=== Sync started ===$' \
    || { echo "FAIL: failed init did not announce sync start"; fail=1; }
if printf '%s\n' "$OUTPUT" | grep -q '^=== Sync completed ===$'; then
    echo "FAIL: failed init falsely announced sync completion"
    fail=1
fi
printf '%s\n' "$OUTPUT" | grep -q 'intelligence-learn-from-repository/SKILL.md' \
    || { echo "FAIL: failed init did not expose the recovery skill path"; fail=1; }
chk grep -q 'INITIAL_AGENTS_SURVIVES' "$PFAIL/AGENTS.md"
chk grep -Fqx $'state\tinitial-onboarding' "$PFAIL/intelligence/_backup/manifest.tsv"
chknot test -e "$PFAIL/.broken/state"
chk test -f "$PFAIL/intelligence.yaml"

echo "== 11. status in all three modes =="
xok "Intelligence project" "$PROJ" status
xok "vendored" "$LEG1" status
xfail "--compact is unavailable for a legacy Intelligence Sync project" "$LEG1" sync --compact
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
chknot test -e "$P13/.vscodeignore"
chknot test -e "$P13/.npmignore"
chknot test -e "$P13/.dockerignore"
chknot grep -q '^[[:space:]]*url:' "$P13/intelligence.yaml"
chknot grep -q '^[[:space:]]*path:' "$P13/intelligence.yaml"
chk grep -q 'url: "https://github.com/ainova-systems/intelligence.git"' "$P13/intelligence.lock"
chk test -d "$P13/.intelligence/packages/@ainova-systems/sync/skills/intelligence-sync"
chk test -d "$P13/.claude/skills/intelligence-update"
chk test -d "$P13/.claude/skills/intelligence-learn-from-repository"
# Keep a second package in the lock so the missing-lock refusal proves an
# alignment cannot silently replace a multi-package lock with sync content.
xok "@acme/extra" "$P13" package add "git+$PACK_URL" --name @acme/extra --no-sync
chk grep -q '"@acme/extra"' "$P13/intelligence.lock"
# A missing lock is not an upgrade signal. Refuse before manufacturing a
# partial sync-only lock, then prove the committed lock restores the store.
cp "$P13/intelligence.lock" "$OUT/p13.lock"
rm -rf "$P13/.intelligence/packages"
rm -f "$P13/intelligence.lock"
xfail "intelligence.lock is absent" "$P13" sync
xfail "intelligence.lock is absent" "$P13" init --preview
xfail "intelligence.lock is absent" "$P13" update --preview
xfail "intelligence.lock is absent" "$P13" update --apply
xok "Lockfile: MISSING" "$P13" status
xok "lock missing" "$P13" package list
chknot test -f "$P13/intelligence.lock"
cp "$OUT/p13.lock" "$P13/intelligence.lock"
xok "restoring package store" "$P13" sync
chk test -f "$P13/intelligence.lock"
chk test -d "$P13/.intelligence/packages/@ainova-systems/sync"
chk test -d "$P13/.intelligence/packages/@acme/extra"
# A stale pre-package directory is removed even when source entries were
# already migrated in an earlier interrupted RC alignment.
mkdir -p "$P13/.intelligence/engine/rules"
xok "removed stale .intelligence/engine" "$P13" init --apply
chknot test -d "$P13/.intelligence/engine"
# Early RC manifests duplicated resolved source fields. Alignment removes
# them for every package while preserving lock-only source state.
awk '
    { print }
    /^    version: "0\.11\.0"/ {
        print "    url: \"https://github.com/ainova-systems/intelligence.git\""
        print "    path: \"packages/sync\""
    }
' "$P13/intelligence.yaml" > "$P13/intelligence.yaml.tmp"
mv "$P13/intelligence.yaml.tmp" "$P13/intelligence.yaml"
xok "package url/path -> intelligence.lock" "$P13" init --apply
if grep -nE '^[[:space:]]*(url|path):' "$P13/intelligence.yaml"; then
    echo "FAIL: RC package source fields survived lifecycle alignment"
    fail=1
fi
chk grep -q 'url: "https://github.com/ainova-systems/intelligence.git"' "$P13/intelligence.lock"
xok "engine content follows" "$P13" update --preview
xfail "--force" "$P13" package remove @ainova-systems/sync
chk grep -q '"@ainova-systems/sync"' "$P13/intelligence.yaml"
xok "" "$P13" package remove @ainova-systems/sync --force
chknot grep -q '"@ainova-systems/sync"' "$P13/intelligence.yaml"
chknot test -d "$P13/.intelligence/packages/@ainova-systems/sync"

B13="$OUT/b13"
mkdir -p "$B13"
git -C "$B13" init --quiet
xok "bare setup" "$B13" init --bare
chknot grep -q '"@ainova-systems/sync"' "$B13/intelligence.yaml"

# A pre-package manifest is upgraded automatically before sync. CI refuses
# that tracked schema/content mutation and points to an explicit local init.
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
CI=true xfail "intelligence init --apply" "$U13" sync
CI=true xfail "intelligence init --apply" "$U13" update --apply
CI=True xfail "intelligence init --apply" "$U13" sync
CI=on xfail "intelligence init --apply" "$U13" sync
CI=true xok "project alignment" "$U13" init --apply
chknot grep -q '^sync_version:' "$U13/intelligence.yaml"
chk grep -q "^schema_version: \"$ENGINE_VER\"" "$U13/intelligence.yaml"
chknot grep -q '\.intelligence/engine' "$U13/intelligence.yaml"
chknot test -d "$U13/.intelligence/engine"
chk grep -q '"@ainova-systems/sync"' "$U13/intelligence.yaml"
chk test -d "$U13/.intelligence/packages/@ainova-systems/sync/rules"
xok "IS_STATUS=ok" "$U13" sync

# Conflicting old/new schema keys are ambiguous and remain byte-for-byte
# untouched instead of being partially rewritten.
D13="$OUT/d13"
mkdir -p "$D13"
cat > "$D13/intelligence.yaml" <<EOF
project:
  name: d13

schema_version: "$ENGINE_VER"
sync_version: "0.10.0"

sources:
  rules:
  agents:
  skills:

targets:
  agents: { enabled: true, output: "AGENTS.md" }
EOF
git -C "$D13" init --quiet
cp "$D13/intelligence.yaml" "$OUT/d13.before"
xfail "conflicting schema_version" "$D13" init --apply
chk cmp -s "$OUT/d13.before" "$D13/intelligence.yaml"

echo "== 14. hostile inputs: lock keys, option-shaped urls, dispatcher =="
H14="$OUT/h14"
mkdir -p "$H14/intelligence/rules"
printf '# C\n\nctx\n' > "$H14/intelligence/rules/context.md"
cat > "$H14/intelligence.yaml" <<EOF
project:
  name: h14

schema_version: "$ENGINE_VER"

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
xfail "invalid package name" "$H14" sync
xfail "invalid package name" "$H14" update --preview
# option-shaped url must never reach git argv
cat > "$H14/intelligence.yaml" <<EOF
project:
  name: h14

schema_version: "$ENGINE_VER"

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
cat > "$H14/intelligence.lock" <<EOF
lockfile_version: 1
engine_version: "$ENGINE_VER"
packages:
  "@acme/evil":
    requested: "1.0.0"
    url: "--upload-pack=touch $OUT/pwned;git-upload-pack"
    resolved: "v1.0.0"
    sha: "0000000000000000000000000000000000000000"
EOF
xfail "unsafe source url" "$H14" sync
chknot test -e "$OUT/pwned"                       # the RCE payload never ran
chknot test -d "$H14/.intelligence/packages/@acme"

# dispatcher: a path-shaped command word cannot exec a neighbouring script
run_in "$H14" ../../../etc/x
[ "$RC" -ne 0 ] || { echo "FAIL: dispatcher accepted a path-shaped command"; fail=1; }
printf '%s\n' "$OUTPUT" | grep -qF "unknown command" || { echo "FAIL: dispatcher did not reject path-shaped command"; fail=1; }

echo "== 15. unified adapter commands =="
# Missing project, invalid shell/path names, missing adapters and targets all
# fail before a write.
xfail "Use the singular command: intelligence adapter list" "$PROJ" adapters list
xfail "adapter action comes first - run: intelligence adapter enable codex" "$PROJ" adapter codex enable
xfail "no intelligence project" "$EMPTY" adapter create myide
xfail "no intelligence project" "$EMPTY" adapter enable claude
xfail "usage: intelligence adapter remove" "$PROJ" adapter remove
xfail "invalid target name" "$PROJ" adapter create ../escape
xfail "invalid target name" "$PROJ" adapter enable my-ide
xfail "adapter 'missing' not found" "$PROJ" adapter enable missing
xfail "target 'missing' is not in the manifest" "$PROJ" adapter disable missing

xok "created: intelligence/adapters/myide.sh" "$PROJ" adapter create myide
chk test -f "$PROJ/intelligence/adapters/myide.sh"
chk grep -q '^sync_to_myide()' "$PROJ/intelligence/adapters/myide.sh"
chknot grep -q '<name>' "$PROJ/intelligence/adapters/myide.sh"
chknot grep -q 'dirname.*BASH_SOURCE' "$PROJ/intelligence/adapters/myide.sh"
xfail "already exists" "$PROJ" adapter create myide

cp "$PROJ/intelligence/adapters/myide.sh" "$OUT/myide-template.sh"
cat > "$PROJ/intelligence/adapters/myide.sh" <<'EOF'
adapter_contract_myide() {
    adapter_contract_version 1
    adapter_contract_owned "${1%/}/*"
}
sync_to_myide() { :; }
EOF
xfail "invalid ownership contract" "$PROJ" adapter enable myide
chknot grep -q '^  myide:' "$PROJ/intelligence.yaml"
cp "$OUT/myide-template.sh" "$PROJ/intelligence/adapters/myide.sh"

printf '# existing VSIX rule\nout/**\n' > "$PROJ/.vscodeignore"
xok "enabled: myide" "$PROJ" adapter enable myide
chk grep -q 'myide: { enabled: true, output: ".myide" }' "$PROJ/intelligence.yaml"
chk grep -Fqx '.myide/rules/' "$PROJ/.gitignore"
chk grep -Fqx '.myide/**' "$PROJ/.vscodeignore"
grep -Fvx '.myide/rules/' "$PROJ/.gitignore" > "$PROJ/.gitignore.tmp"
mv "$PROJ/.gitignore.tmp" "$PROJ/.gitignore"
xok "IS_STATUS=ok" "$PROJ" init
chk grep -Fqx '.myide/rules/' "$PROJ/.gitignore"
xok "disabled: myide" "$PROJ" adapter disable myide
chk grep -q 'myide: { enabled: false, output: ".myide" }' "$PROJ/intelligence.yaml"
xfail "Adapter 'myide' is disabled" "$PROJ" sync myide
xfail "Enable it first: intelligence adapter enable myide" "$PROJ" sync --compact myide
xfail "unknown option '--loud'" "$PROJ" sync --loud
xfail "usage: intelligence sync" "$PROJ" sync agents claude --compact

# A failure in a later adapter rolls every earlier output back, and adapter
# enable also restores its manifest/Git-policy mutation.
cp "$PROJ/AGENTS.md" "$OUT/agents-before-failed-sync.md"
cp "$PROJ/.vscodeignore" "$OUT/vscodeignore-before-failed-sync"
mkdir -p "$PROJ/intelligence/rules"
printf '# Rollback probe\n\nROLLBACK_RULE_MUST_NOT_REACH_OUTPUT\n' > "$PROJ/intelligence/rules/rollback-probe.md"
cat > "$PROJ/intelligence/adapters/myide.sh" <<'EOF'
adapter_contract_myide() {
    adapter_contract_version 1
    adapter_contract_owned "${1%/}/state"
    adapter_contract_ignore "${1%/}/state/"
}
sync_to_myide() {
    mkdir -p "$3/state"
    printf 'partial\n' > "$3/state/partial.txt"
    return 23
}
EOF
xfail "all adapter-owned paths were restored" "$PROJ" adapter enable myide
chk cmp -s "$OUT/agents-before-failed-sync.md" "$PROJ/AGENTS.md"
chknot test -e "$PROJ/.myide/state"
chk grep -q 'myide: { enabled: false, output: ".myide" }' "$PROJ/intelligence.yaml"
chknot grep -Fqx '.myide/state/' "$PROJ/.gitignore"
chk cmp -s "$OUT/vscodeignore-before-failed-sync" "$PROJ/.vscodeignore"

# Existing output is preserved byte-for-byte when a target is toggled.
xok "disabled: claude" "$PROJ" adapter disable claude
chk grep -q 'claude: { enabled: false, output: ".claude" }' "$PROJ/intelligence.yaml"
xok "enabled: claude" "$PROJ" adapter enable claude
chk grep -q 'claude: { enabled: true, output: ".claude" }' "$PROJ/intelligence.yaml"
chk grep -Fqx '.claude/*' "$PROJ/.gitignore"
chk grep -Fqx '!.claude/settings.json' "$PROJ/.gitignore"

# AGENTS.md-dependent targets cannot be enabled into a manifest the engine
# would reject, and agents cannot be disabled while one remains enabled.
xok "disabled: claude" "$PROJ" adapter disable claude
xok "disabled: agents" "$PROJ" adapter disable agents
xfail "requires target 'agents'" "$PROJ" adapter enable cursor
xok "enabled: agents" "$PROJ" adapter enable agents
xok "enabled: cursor" "$PROJ" adapter enable cursor
chk grep -Fqx '.cursor/*' "$PROJ/.gitignore"
chk grep -Fqx '!.cursor/settings.json' "$PROJ/.gitignore"
xfail "required by enabled target 'cursor'" "$PROJ" adapter disable agents
xok "disabled: cursor" "$PROJ" adapter disable cursor
xok "disabled: agents" "$PROJ" adapter disable agents
xok "myide" "$PROJ" adapter list
xok "removed: intelligence/adapters/myide.sh" "$PROJ" adapter remove myide --apply
chknot test -f "$PROJ/intelligence/adapters/myide.sh"

echo "== 16. removed public commands stay removed =="
for old in install upgrade migrate outdated target doctor add remove list search; do
    xfail "unknown command" "$PROJ" "$old"
done
run_in "$PROJ" help
[ "$RC" -eq 0 ] || { echo "FAIL: help failed"; fail=1; }
printf '%s\n' "$OUTPUT" | grep -qF -- "--targets a,b --dir name --bare --no-sync" \
    || { echo "FAIL: init options missing from help"; fail=1; }
printf '%s\n' "$OUTPUT" | grep -qF -- "sync [adapter] [--compact]" \
    || { echo "FAIL: compact sync missing from help"; fail=1; }

[ "$fail" -eq 0 ] && echo "E2E-NEGATIVE: ALL OK"
exit "$fail"
