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
# is <label> <want> <got>
is() { [ "$2" = "$3" ] || { echo "FAIL: $1 — want '$2', got '$3'"; fail=1; }; }
# joined <manifest> <section> — sources.<section> as written, comma-joined.
joined() {
    awk -v sec="$2" '
        { sub(/\r$/, "") }
        /^sources:[ \t]*$/ { ins = 1; next }
        ins && /^[^ #]/ { ins = 0; f = 0 }
        ins && $0 ~ "^  " sec ":[ \t]*$" { f = 1; next }
        ins && /^  [A-Za-z_]/ { f = 0 }
        f && /^[ \t]*-/ { v = $0; sub(/^[ \t]*-[ \t]*/, "", v); gsub(/["\047]/, "", v); print v }
    ' "$1" | paste -sd, -
}

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
intelligence/rules/*.local.md
intelligence/agents/*.local.md
intelligence/skills/*.local/
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
# AGENTS.md is committed and the store is not: package content is listed by
# name, project content keeps its link.
chk grep -Fqx '| pack-do-thing | Do the pack thing |' "$PROJ/AGENTS.md"
chk grep -Fqx -- '- pack-rule (global)' "$PROJ/AGENTS.md"
chk grep -Fqx -- '- [context](intelligence/rules/context.md) (global)' "$PROJ/AGENTS.md"
chknot grep -Fq '](.intelligence/' "$PROJ/AGENTS.md"

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
# The range is a ceiling too: v2.0.0 is excluded, and a plan that reported only
# the move would read as "current" while a whole major went unmentioned.
grep -q "2.0.0 available outside '\^1.1.0'" <<< "$preview12" \
    || { echo "FAIL: preview hid the version outside the range"; fail=1; }
# The note is only useful if it names a command that runs.
grep -q 'follow it: intelligence update @acme/shared --latest' <<< "$preview12" \
    || { echo "FAIL: preview named no command for the excluded version"; fail=1; }
# Counted apart from the move the range does allow.
grep -q '^updates available: 1 package(s)' <<< "$preview12" \
    || { echo "FAIL: the outside-range package leaked into the update counter"; fail=1; }
grep -q '^outside the requested range: 1 package(s)' <<< "$preview12" \
    || { echo "FAIL: preview omitted the outside-range summary"; fail=1; }
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
# The section the new version drops is spelled through the package's alias and
# the one it keeps by its full name (decision 0019): an update recognises its
# own entries in every spelling, drops the lost one and leaves the kept one as
# written instead of wiring the store path beside it.
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" package alias @acme/shared shared >/dev/null)
chk grep -qx '    alias: "shared"' "$PROJ/intelligence.yaml"
awk '{ sub(/"\.intelligence\/packages\/@acme\/shared\/skills"/, "\"shared:skills\"")
       sub(/"\.intelligence\/packages\/@acme\/shared\/rules"/, "\"@acme/shared/rules\""); print }' \
    "$PROJ/intelligence.yaml" > "$PROJ/intelligence.yaml.tmp"
mv "$PROJ/intelligence.yaml.tmp" "$PROJ/intelligence.yaml"
is "spellings before the shape-changing update" "shared:skills" "$(joined "$PROJ/intelligence.yaml" skills)"
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --apply)
chk grep -q 'resolved: "v1.3.0"' "$PROJ/intelligence.lock"
chknot grep -q '\.intelligence/packages/@acme/shared/skills' "$PROJ/intelligence.yaml"
chknot grep -q 'shared:skills' "$PROJ/intelligence.yaml"
is "the kept section after the update" "@acme/shared/rules,intelligence/rules" "$(joined "$PROJ/intelligence.yaml" rules)"
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

echo "== --latest crosses a named package's range =="
# ~1.3.0 holds the project at v1.3.0 while v2.0.0 exists — the shape of every
# range that has fallen behind. Crossing it is the named, deliberate move.
pv_out="$(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --preview)"
grep -q "2.0.0 available outside '~1.3.0'" <<< "$pv_out" \
    || { echo "FAIL: preview hid the version outside the range"; fail=1; }
grep -q 'follow it: intelligence update @acme/shared --latest' <<< "$pv_out" \
    || { echo "FAIL: preview named no command for the excluded version"; fail=1; }
grep -q '^outside the requested range: 1 package(s)' <<< "$pv_out" \
    || { echo "FAIL: preview omitted the outside-range summary"; fail=1; }
# Counted apart: no ordinary mode installs it.
grep -q '^updates available: 0 package(s)' <<< "$pv_out" \
    || { echo "FAIL: the outside-range package leaked into the update counter"; fail=1; }
# The summary names the sweep beside the per-package command.
grep -q "or 'intelligence update --latest' for all of them$" <<< "$pv_out" \
    || { echo "FAIL: the outside-range summary did not name the sweep"; fail=1; }
pv_latest="$(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update @acme/shared --latest --preview)"
grep -q 'v1.3.0 -> v2.0.0 (range ~1.3.0 -> \^2.0.0)' <<< "$pv_latest" \
    || { echo "FAIL: --latest preview did not report the crossing and the new range"; fail=1; }
chk grep -q 'version: "~1.3.0"' "$PROJ/intelligence.yaml"
chk grep -q 'resolved: "v1.3.0"' "$PROJ/intelligence.lock"
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update @acme/shared --latest --apply >/dev/null)
# Requested intent moves with the content: the manifest still records what the
# project asked for, so the next boundary stays a decision.
chk grep -q 'version: "\^2.0.0"' "$PROJ/intelligence.yaml"
chk grep -q 'requested: "\^2.0.0"' "$PROJ/intelligence.lock"
chk grep -q 'resolved: "v2.0.0"' "$PROJ/intelligence.lock"
# Nothing is excluded now, so the note and its counter are gone.
pv_after="$(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --preview)"
chknot grep -q 'available outside' <<< "$pv_after"
chknot grep -q '^outside the requested range' <<< "$pv_after"
grep -q 'v2.0.0 (up to date)' \
    <<< "$(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update @acme/shared --latest --preview)" \
    || { echo "FAIL: --latest on the newest version did not report it as current"; fail=1; }
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" status --check >/dev/null)

# A newest version INSIDE the range is not a crossing, but it is still a move:
# --latest must install it rather than call the behind lock "newest".
# On v2.0.0's own commit: the later cases resolve the highest tag of this repo
# and still need the shape v2.0.0 has.
git -C "$PACK" tag v2.1.0 v2.0.0
pv_in="$(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update @acme/shared --latest --preview)"
grep -q 'v2.0.0 -> v2.1.0' <<< "$pv_in" \
    || { echo "FAIL: --latest skipped an in-range move the lock was behind on"; fail=1; }
chknot grep -q 'range \^2.0.0' <<< "$pv_in"
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update @acme/shared --latest --apply >/dev/null)
chk grep -q 'resolved: "v2.1.0"' "$PROJ/intelligence.lock"
# The range already permitted it, so requested intent is untouched.
chk grep -q 'version: "\^2.0.0"' "$PROJ/intelligence.yaml"

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
# A ref pin has no range to cross: it is frozen by intent, and --latest must
# say so rather than quietly turning it into a version range.
if (cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update @acme/branch --latest --preview) >/dev/null 2>&1; then
    echo "FAIL: --latest converted a ref pin"; fail=1
fi

printf '# Branch rule v2\n\nBRANCH_MARKER_TWO\n' > "$BR/rules/branch-rule.md"
git -C "$BR" -c user.email=t@t -c user.name=t commit --quiet -am b2
BR_SHA2="$(git -C "$BR" rev-parse HEAD)"

echo "== fresh clone restores the old commit after a branch advances =="
OLDCLONE="$OUT/old-refclone"
mkdir -p "$OLDCLONE"
cp -r "$PROJ/intelligence" "$OLDCLONE/intelligence"
cp "$PROJ/intelligence.yaml" "$PROJ/intelligence.lock" "$PROJ/.gitignore" "$OLDCLONE/"
git -C "$OLDCLONE" init --quiet
(cd "$OLDCLONE" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync --compact)
chk cmp -s "$PROJ/intelligence.yaml" "$OLDCLONE/intelligence.yaml"
chk cmp -s "$PROJ/intelligence.lock" "$OLDCLONE/intelligence.lock"
chk grep -q 'BRANCH_MARKER_ONE' "$OLDCLONE/.intelligence/packages/@acme/branch/rules/branch-rule.md"
chk grep -q 'BRANCH_MARKER_ONE' "$OLDCLONE/AGENTS.md"
chknot grep -q 'BRANCH_MARKER_TWO' "$OLDCLONE/AGENTS.md"
cp "$OLDCLONE/AGENTS.md" "$OUT/old-refclone.agents"
(cd "$OLDCLONE" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync --compact)
chk cmp -s "$OUT/old-refclone.agents" "$OLDCLONE/AGENTS.md"

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
# After an explicit update, fresh clones restore the newly locked commit.
RCLONE="$OUT/refclone"
mkdir -p "$RCLONE"
cp -r "$PROJ/intelligence" "$RCLONE/intelligence"
cp "$PROJ/intelligence.yaml" "$PROJ/intelligence.lock" "$PROJ/.gitignore" "$RCLONE/"
git -C "$RCLONE" init --quiet
out_ref="$(cd "$RCLONE" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync)"
grep -q '^IS_STATUS=ok' <<< "$out_ref" || { echo "FAIL: frozen restore of a ref pin"; fail=1; }
chk grep -q 'BRANCH_MARKER_TWO' "$RCLONE/AGENTS.md"
# The restore wires every package it installs, and recognises the one whose
# rules the manifest names by full name: no store path is written back.
chk cmp -s "$PROJ/intelligence.yaml" "$RCLONE/intelligence.yaml"
chk grep -q 'PACK_RULE_MARKER' "$RCLONE/AGENTS.md"

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

echo "== update keeps a package's sources where they stand =="
# @acme/branch was added after @acme/shared, so it sits first and shared's
# same-named files override it. Updating shared changes its content, never which
# package wins: an update used to unwire the package and wire it first again,
# which reversed that order.
is "order before the update" ".intelligence/packages/@acme/branch/rules,@acme/shared/rules,intelligence/rules" \
    "$(joined "$PROJ/intelligence.yaml" rules)"
git -C "$PACK" tag v2.2.0 v2.0.0
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update @acme/shared --apply >/dev/null)
chk grep -q 'resolved: "v2.2.0"' "$PROJ/intelligence.lock"
is "order after the update" ".intelligence/packages/@acme/branch/rules,@acme/shared/rules,intelligence/rules" \
    "$(joined "$PROJ/intelligence.yaml" rules)"
is "a kept section after the update" ".intelligence/packages/@acme/shared/skills" "$(joined "$PROJ/intelligence.yaml" skills)"
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" package remove @acme/branch >/dev/null)
is "survivors after a remove" "@acme/shared/rules,intelligence/rules" "$(joined "$PROJ/intelligence.yaml" rules)"

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
# A project skill of the package skill's name, in a project source added last.
mkdir -p "$PROJ/intelligence/skills/pack-do-thing"
printf -- '---\nname: pack-do-thing\ndescription: Project thing\n---\nPROJECT_SKILL\n' > "$PROJ/intelligence/skills/pack-do-thing/SKILL.md"
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" source add skills intelligence/skills >/dev/null 2>&1) \
    || { echo "FAIL: source add of the project skills"; fail=1; }
ov_sync="$(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync 2>&1)"
chk grep -q 'PROJECT_WINS' "$PROJ/.claude/rules/pack-rule.md"
chknot grep -q 'PACK_RULE_MARKER' "$PROJ/.claude/rules/pack-rule.md"
chk grep -q 'PROJECT_SKILL' "$PROJ/.claude/skills/pack-do-thing/SKILL.md"
grep -Fqx "WARNING: 2 package artifact(s) never render: a later source overrides them by name — 'intelligence status --check' names them" <<< "$ov_sync" \
    || { echo "FAIL: sync did not count the overridden package rule and skill"; grep '^WARNING' <<< "$ov_sync"; fail=1; }
is "the line sync ends on" '=== Sync complete ===' "$(tail -1 <<< "$ov_sync" | sed 's/ in [^=]*===$/ ===/')"
# status --check names the package and the version its lock pins, and the
# exit stays what the project's checks decide.
ov_rc=0
ov_check="$(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" status --check 2>&1)" || ov_rc=$?
grep -Fqx "  ! rule 'pack-rule': intelligence/rules/pack-rule.md overrides @acme/shared v2.2.0, so a change to the hidden copy never renders" <<< "$ov_check" \
    || { echo "FAIL: status --check did not name the overridden package rule"; printf '%s\n' "$ov_check" | tail -5; fail=1; }
grep -Fqx "  ! skill 'pack-do-thing': intelligence/skills/pack-do-thing overrides @acme/shared v2.2.0, so a change to the hidden copy never renders" <<< "$ov_check" \
    || { echo "FAIL: status --check did not name the overridden package skill"; printf '%s\n' "$ov_check" | tail -5; fail=1; }
rm -rf "$PROJ/intelligence/rules/pack-rule.md" "$PROJ/intelligence/skills"
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" source remove skills intelligence/skills >/dev/null 2>&1) \
    || { echo "FAIL: source remove of the project skills"; fail=1; }
ov_rc2=0
ov_check2="$(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" status --check 2>&1)" || ov_rc2=$?
is "status --check exit with and without the override" "$ov_rc2" "$ov_rc"
chknot grep -Fq ' overrides ' <<< "$ov_check2"

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

echo "== <package-dir> names the package an artifact came from, in every tool =="
# The package ships references/labels.md beside its rules; only rules, agents
# and skills render, so its artifacts reach the file through the store, wired
# here by alias.
TPK="$OUT/token-pack"
mkdir -p "$TPK/references" "$TPK/rules" "$TPK/agents" "$TPK/skills/tok-skill/references"
printf 'labels\n' > "$TPK/references/labels.md"
printf '# Tok\n\nTOK_ALWAYS <package-dir>/references/labels.md and \\<package-dir>\n' > "$TPK/rules/tok-always.md"
printf -- '---\npaths:\n  - "src/**"\n  - "<package-dir>/**"\n---\n\nTOK_SCOPED <package-dir>/references/labels.md\n' > "$TPK/rules/tok-scoped.md"
printf -- '---\nexclude_targets: [agents]\n---\n\nTOK_SOLO <package-dir>/references/labels.md\n' > "$TPK/rules/tok-solo.md"
printf -- '---\nname: tok-agent\ndescription: Reads <package-dir>/references/labels.md\ntier: standard\naccess: readonly\n---\n\nTOK_AGENT <package-dir>/references/labels.md\n' \
    > "$TPK/agents/tok-agent.md"
printf -- '---\nname: tok-skill\ndescription: Reads <package-dir>/references/labels.md\n---\n\nTOK_SKILL <package-dir>/references/labels.md\n' \
    > "$TPK/skills/tok-skill/SKILL.md"
printf 'TOK_REF <package-dir>/references/labels.md\n' > "$TPK/skills/tok-skill/references/use.md"
# The word-budget case below reads this sync: a rule of 2,001 words and a
# SKILL.md with a list item of 151, in the package and in the project alike.
long_words() { local i out=""; for ((i = 1; i <= $1; i++)); do out+="w$i "; done; printf '%s' "${out% }"; }
budget_sources() {
    mkdir -p "$1/rules" "$1/skills/long-skill"
    { for ((p = 0; p < 20; p++)); do printf '%s\n\n' "$(long_words 100)"; done; printf 'one\n'; } > "$1/rules/long-rule.md"
    printf -- '---\nname: long-skill\ndescription: Long item\n---\n\n- %s\n' "$(long_words 150)" > "$1/skills/long-skill/SKILL.md"
}
budget_sources "$TPK"
git -C "$TPK" init --quiet
git -C "$TPK" -c user.email=t@t -c user.name=t -c core.autocrlf=false add -A
git -C "$TPK" -c user.email=t@t -c user.name=t commit --quiet -m v1
git -C "$TPK" tag v1.0.0
TP="$OUT/token-proj"
mkdir -p "$TP"
git -C "$TP" init --quiet
git -C "$TP" config core.autocrlf false
(cd "$TP" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init --bare --targets agents,claude,cursor,codex,copilot,opencode) >/dev/null 2>&1
(cd "$TP" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" adapter enable antigravity) >/dev/null 2>&1
(cd "$TP" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" adapter enable pi) >/dev/null 2>&1
mkdir -p "$TP/intelligence/rules"
printf '# Own\n\nTOK_OWN <package-dir>/rules\n' > "$TP/intelligence/rules/own.md"
budget_sources "$TP/intelligence"
(cd "$TP" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" package add "git+file://$TPK" --name @acme/tok --alias tok --no-sync) >/dev/null 2>&1
awk '{ sub(/"\.intelligence\/packages\/@acme\/tok\//, "\"tok:"); print }' "$TP/intelligence.yaml" > "$TP/manifest.tmp"
mv "$TP/manifest.tmp" "$TP/intelligence.yaml"
chk grep -Fq '"tok:rules"' "$TP/intelligence.yaml"
tok_out="$(cd "$TP" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync 2>&1)" || { echo "FAIL: sync of <package-dir> content"; fail=1; }
grep -q '^IS_STATUS=ok' <<< "$tok_out" || { echo "FAIL: sync of <package-dir> content not ok"; fail=1; }
root='.intelligence/packages/@acme/tok'
outputs=(AGENTS.md AGENTS.override.md .claude .cursor .codex .github .agents .opencode .pi)
# Every channel carries the package's path; only the escaped token is left.
is "paths the token rendered as" "$root/references/labels.md" \
    "$(cd "$TP" && grep -rhoE '[^ "]*references/labels\.md' "${outputs[@]}" 2>/dev/null | LC_ALL=C sort -u)"
is "lines holding the token" "TOK_ALWAYS $root/references/labels.md and <package-dir>" \
    "$(cd "$TP" && grep -rhF '<package-dir>' "${outputs[@]}" 2>/dev/null | LC_ALL=C sort -u)"
chk grep -Fqx "TOK_ALWAYS $root/references/labels.md and <package-dir>" "$TP/AGENTS.md"
chk grep -Fqx "| tok-agent | standard | readonly | Reads $root/references/labels.md |" "$TP/AGENTS.md"
chk grep -Fqx "| tok-skill | Reads $root/references/labels.md |" "$TP/AGENTS.md"
chk grep -Fqx "TOK_SOLO $root/references/labels.md" "$TP/AGENTS.override.md"
chk grep -Fqx "TOK_SCOPED $root/references/labels.md" "$TP/.claude/rules/tok-scoped.md"
chk grep -Fqx "TOK_AGENT $root/references/labels.md" "$TP/.claude/agents/tok-agent.md"
chk grep -Fqx "TOK_REF $root/references/labels.md" "$TP/.claude/skills/tok-skill/references/use.md"
chk grep -Fqx "TOK_SOLO $root/references/labels.md" "$TP/.cursor/rules/tok-solo.mdc"
chk grep -Fqx "TOK_SKILL $root/references/labels.md" "$TP/.cursor/skills/tok-skill/SKILL.md"
chk grep -Fqx "TOK_SOLO $root/references/labels.md" "$TP/.github/instructions/tok-solo.instructions.md"
chk grep -Fqx "description: \"Reads $root/references/labels.md\"" "$TP/.github/agents/tok-agent.agent.md"
chk grep -Fqx "description = \"Reads $root/references/labels.md\"" "$TP/.codex/agents/tok-agent.toml"
chk grep -Fqx "TOK_REF $root/references/labels.md" "$TP/.agents/skills/tok-skill/references/use.md"
chk grep -Fqx "TOK_SCOPED $root/references/labels.md" "$TP/.agents/rules/tok-scoped.md"
chk grep -Fqx "description: \"Reads $root/references/labels.md\"" "$TP/.opencode/commands/tok-skill.md"
chk grep -Fq "body: \"TOK_SOLO $root/references/labels.md\"" "$TP/.pi/extensions/intelligence-sync-rules.ts"
chk grep -Fqx "TOK_SCOPED $root/references/labels.md" "$TP/.pi/intelligence-sync/rules/tok-scoped.md"
# A scoped rule's patterns, in its own copies and where several rules share one file.
chk grep -Fqx "  - \"$root/**\"" "$TP/.claude/rules/tok-scoped.md"
chk grep -Fqx "  - \"$root/**\"" "$TP/.cursor/rules/tok-scoped.mdc"
chk grep -Fqx "applyTo: \"src/**,$root/**\"" "$TP/.github/instructions/tok-scoped.instructions.md"
chk grep -Fq "patterns: [\"src/**\", \"$root/**\"]" "$TP/.pi/extensions/intelligence-sync-rules.ts"
chk grep -Fq "\`\"src/**\" \"$root/**\"\` → [tok-scoped]" "$TP/AGENTS.override.md"
# A project artifact takes the content directory, as <content-dir> does.
chk grep -Fqx 'TOK_OWN intelligence/rules' "$TP/AGENTS.md"

echo "== word budgets: sync warns about the project's own sources, never a package's =="
is "budget warnings" "$(printf 'WARNING: %s\n' \
    'intelligence/rules/long-rule.md is 2001 words, over the rule budget of 2000' \
    'intelligence/skills/long-skill/SKILL.md:6 has a 151-word paragraph, over the budget of 150')" \
    "$(grep -E '^WARNING: .*(budget|-word)' <<< "$tok_out")"

echo "== --latest with no package crosses every range in one plan =="
# Two packages behind their ranges, one already on its newest version and a
# branch pin: the sweep (decision 0032) crosses both ranges, leaves the newest
# one alone and lets the branch follow its ref as a plain update does.
SW="$OUT/sweep"
mkdir -p "$SW/intelligence/rules"
cat > "$SW/intelligence.yaml" <<EOF
project:
  name: sweep

schema_version: "$ENGINE_VER"

sources:
  rules:
    - "intelligence/rules"
  agents:
  skills:

targets:
  agents: { enabled: true, output: "AGENTS.md" }
EOF
printf '# Ctx\n\nsweep context\n' > "$SW/intelligence/rules/context.md"
printf '.intelligence/\n' > "$SW/.gitignore"
git -C "$SW" init --quiet
# sweep_release <repo> <marker> [tag] — one rule named after the repo; the
# first call creates the repo.
sweep_release() {
    mkdir -p "$1/rules"
    printf '# Sweep\n\n%s\n' "$2" > "$1/rules/$(basename "$1").md"
    [ -d "$1/.git" ] || git -C "$1" init --quiet
    git -C "$1" -c user.email=t@t -c user.name=t add -A
    git -C "$1" -c user.email=t@t -c user.name=t commit --quiet -m "$2"
    [ -z "${3:-}" ] || git -C "$1" tag "$3"
}
sweep_release "$OUT/sw-one" SW_ONE_100 v1.0.0
sweep_release "$OUT/sw-two" SW_TWO_040 v0.4.0
sweep_release "$OUT/sw-three" SW_THREE_100 v1.0.0
sweep_release "$OUT/sw-branch" SW_BRANCH_ONE
git -C "$OUT/sw-branch" checkout -q -B trunk
SWB_SHA1="$(git -C "$OUT/sw-branch" rev-parse HEAD)"
for p in one two three; do
    (cd "$SW" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" package add "git+file://$OUT/sw-$p" --name "@sw/$p" --no-sync >/dev/null)
done
(cd "$SW" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" package add "git+file://$OUT/sw-branch@trunk" --name @sw/branch --no-sync >/dev/null)
sweep_release "$OUT/sw-one" SW_ONE_110 v1.1.0
sweep_release "$OUT/sw-one" SW_ONE_200 v2.0.0
sweep_release "$OUT/sw-two" SW_TWO_061 v0.6.1
sweep_release "$OUT/sw-branch" SW_BRANCH_TWO
SWB_SHA2="$(git -C "$OUT/sw-branch" rev-parse HEAD)"
cp "$SW/intelligence.yaml" "$OUT/sweep.yaml.before"
cp "$SW/intelligence.lock" "$OUT/sweep.lock.before"

sw_plain="$(cd "$SW" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --preview)"
grep -q '^outside the requested range: 2 package(s)' <<< "$sw_plain" \
    || { echo "FAIL: the plain plan did not count both packages behind their ranges"; fail=1; }
sw_pv="$(cd "$SW" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --latest --preview)"
for want in \
    '  @sw/one: v1.0.0 -> v2.0.0 (range ^1.0.0 -> ^2.0.0)' \
    '  @sw/two: v0.4.0 -> v0.6.1 (range ^0.4.0 -> ^0.6.1)' \
    '  @sw/three: v1.0.0 (up to date)' \
    "  @sw/branch: trunk ${SWB_SHA1:0:7} -> ${SWB_SHA2:0:7}" \
    'updates available: 3 package(s)'; do
    grep -Fqx -- "$want" <<< "$sw_pv" || { echo "FAIL: the sweep plan lacks '$want'"; fail=1; }
done
# Nothing is left outside a range once the sweep crosses them all.
chknot grep -q 'outside the requested range' <<< "$sw_pv"
chknot grep -q 'follow it:' <<< "$sw_pv"
# One confirmation covers the sweep, and a shell that cannot give it refuses.
if (cd "$SW" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --latest </dev/null) >/dev/null 2>&1; then
    echo "FAIL: a non-interactive sweep applied without --apply"; fail=1
fi
chk cmp -s "$OUT/sweep.yaml.before" "$SW/intelligence.yaml"
chk cmp -s "$OUT/sweep.lock.before" "$SW/intelligence.lock"

(cd "$SW" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --latest --apply >/dev/null)
# sw_field <file> <package> <field> — one field of one package's entry.
sw_field() {
    awk -v key="\"$2\":" -v f="$3:" '
        $1 == key { hit = 1; next }
        hit && /^  "/ { exit }
        hit && $1 == f { gsub(/"/, "", $2); print $2; exit }' "$1"
}
is "@sw/one range" "^2.0.0" "$(sw_field "$SW/intelligence.yaml" @sw/one version)"
is "@sw/two range" "^0.6.1" "$(sw_field "$SW/intelligence.yaml" @sw/two version)"
is "@sw/three range" "^1.0.0" "$(sw_field "$SW/intelligence.yaml" @sw/three version)"
is "@sw/one lock" "^2.0.0 v2.0.0" "$(sw_field "$SW/intelligence.lock" @sw/one requested) $(sw_field "$SW/intelligence.lock" @sw/one resolved)"
is "@sw/two lock" "^0.6.1 v0.6.1" "$(sw_field "$SW/intelligence.lock" @sw/two requested) $(sw_field "$SW/intelligence.lock" @sw/two resolved)"
is "@sw/three lock" "v1.0.0" "$(sw_field "$SW/intelligence.lock" @sw/three resolved)"
# The branch pin stays a ref: the sweep moved its commit, not its intent.
is "@sw/branch intent" "trunk " "$(sw_field "$SW/intelligence.yaml" @sw/branch ref) $(sw_field "$SW/intelligence.yaml" @sw/branch version)"
is "@sw/branch lock" "trunk $SWB_SHA2" "$(sw_field "$SW/intelligence.lock" @sw/branch resolved) $(sw_field "$SW/intelligence.lock" @sw/branch sha)"
for want in SW_ONE_200 SW_TWO_061 SW_THREE_100 SW_BRANCH_TWO; do
    chk grep -q "$want" "$SW/AGENTS.md"
done
grep -Fqx 'updates available: 0 package(s)' \
    <<< "$(cd "$SW" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --latest --preview)" \
    || { echo "FAIL: a second sweep found more to move"; fail=1; }
# Naming a ref pin still asks for a conversion the sweep never makes.
if (cd "$SW" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update @sw/branch --latest --preview) >/dev/null 2>&1; then
    echo "FAIL: --latest on a named ref pin was accepted"; fail=1
fi

[ "$fail" -eq 0 ] && echo "CLI-E2E: ALL OK"
exit "$fail"
