# Audit checks

Apply these checks to the source groups resolved by the review skill.

| Check | What it is | Proposed action |
|---|---|---|
| **Duplicate content** | Two artifacts cover overlapping scope, or their descriptions share trigger phrases | `MERGE` — present both, propose one |
| **Misplaced content** | A checklist or procedure in an agent body; a convention in an agent; a workflow in a rule; expertise in a skill (the *Pick the right artifact* table in `intelligence-authoring`) | `MOVE` — a move, not a rewrite: both files change together |
| **Over the budget** | `SKILL.md` over 1,500 words, rule over 2,000, agent over 500, skill reference over 3,000, or a paragraph, list item or table row over 150 (`R7`) | `SPLIT` - two artifacts, detail into `references/<topic>.md`, or a long paragraph into the thoughts it holds |
| **Rule repeats a gate** | A rule sentence restating what a script, test or sync already checks or refuses | `DELETE` - the gate holds the decision; a second copy in prose drifts from it and costs context in every session |
| **Shared instruction budget** | The measured shared agents output, or `agents-md` in sync's `CONTEXT:` summary, is over 32 KiB (32,768 bytes) | `COMPACT` — this is Intelligence's recommended maximum, not an adapter rejection threshold; use the compaction procedure in `intelligence-review-context` to reduce the owning sources without teaching terse output |
| **Rule links to a rule** | A markdown link from one rule to another (`R1`) | `UNLINK` — name the rule instead: always-on rules are inlined into `AGENTS.md` and the scoped channels carry only scoped rules, so the link is dead in at least one output |
| **Machine facts in a rule** | OS, shell, editor or a local absolute path (`R2`) | `MOVE` — these belong in a local rule, `<content-dir>/rules/<name>.local.md`, which Git ignores and sync keeps out of committed output; a rule is committed and read by everyone, including whoever is on another platform |
| **Literal path or command in a skill** | A path *outside the skill's own folder* baked into a procedure (`R3`) | `PARAMETERIZE` — a skill is *executed*, so a literal path breaks the moment the layout moves; resolve it from a rule or from `<manifest>`. **Exempt:** the skill's own bundle (`references/`, `scripts/`, `assets/` — content is co-located with its skill by default); rules and agents (describing the repository is their job); an example inside an output-format block; the resolution step itself |
| **Skill with no verification** | Nothing at the end proves the procedure worked (`R4`) | `FLAG` — a procedure that proves nothing is a note, or just the work: give it a verification, or delete it |
| **Pressure marker** | A heading or section named CRITICAL / MANDATORY / HARD RULE / READ FIRST, or a density of `MUST` / `NEVER` / `ALWAYS` with no reason beside it (`R5`) | `REWRITE` - plain heading, one reason per constraint; when several instructions are each marked critical the marker stops carrying information, so keep emphasis for the one instruction demonstrably under-weighted without it |
| **History narrative** | A PR number, incident id, commit SHA, date or "this session" inside a rule body (`R6`) | `REWRITE` - keep the causal sentence, drop the archaeology; a rule's authority is the behaviour it prescribes, and git history keeps the date |
| **Name collision** | A project artifact named `intelligence-*` or like an installed package artifact it does not mean to override, or a skill named like a built-in command or bundled skill of an enabled tool ([Claude Code commands](https://code.claude.com/docs/en/commands)) | `RENAME` - the project artifact renders in the package's place, and a Claude Code skill replaces the command of its name but not that command's aliases, so one request runs different procedures depending on the name typed |
| **Naming** | A skill that is not `<domain>-<verb>-<noun>`, or a domain invented rather than reused | `RENAME` — or introduce the new domain deliberately |
| **Stale** | No edits in 6+ months and nothing cross-references it | `ARCHIVE` — move to `<content-dir>/_archive/` |
| **Negative-framed judgement call** | "Never do X" where a positive default fits, outside safety / security / output-format | `REWRITE` — state the default; reserve NEVER for true must-nots |
| **Unbacked reason** | A rule asserts a *why* — a number, a measurement, a tool's behaviour — that nothing in the repo or in that tool's documentation supports | `FLAG` — an invented reason is worse than none: it sounds like evidence. Surface it with a draft; never rewrite the meaning yourself |
| **Always-on rule that should be scoped** | A concern that only matters in one area, loaded into every session and inlined into `AGENTS.md` | `SCOPE` — add `paths:`, or justify the cost out loud |
| **Weak / duplicate description** | Identical to a sibling, or too vague to choose between them | `DIFFERENTIATE` — add the distinguishing trigger |
| **Description over budget** | Over ~250 characters (the shared registry budget); over **1024** the tools reject the artifact outright | `TRIM` — keep the distinguishing trigger, drop the rest |
| **Missing frontmatter field** | `name` or `description` absent | `PATCH` — add it |
| **Dead skill field** | `agent:` or `model:` in a `SKILL.md` without `context: fork`, or `tier:` in one (`R8`) | `PATCH` - delete the field: without the fork `agent:` selects nothing and `model:` switches the session model and drops the prompt cache, and only an agent reads `tier:`; or fork the skill when the authoring conventions say it should |
| **Forked skill editing beside its caller** | A `SKILL.md` with `context: fork` and no `background: false` whose agent can edit: no `agent:`, `agent: general-purpose`, or a source agent whose `access:` is neither `readonly` nor `runner` (`R9`) | `PATCH` - add `background: false`: in the background the caller's turn goes on, so the caller and the fork change one checkout at the same time; or keep the skill inline when its job is editing alongside the caller |
| **Orphan rule** | Nothing points at it and nothing loads it | `FLAG` — intentional, or dead? |

Detection commands, portable on purpose — no `\b` and no `-P`, so the same command works in Git Bash on Windows, on macOS (BSD grep) and on Linux. Run each over the source directories resolved in step 2, never over generated output:

```sh
# Shared instruction budget — resolve this output path from <manifest>
wc -c "<agents-output>"

# R1 — a markdown link from one rule to another
grep -rnE '\]\([^)]*\.md\)' <rule-dirs>

# R2 — machine facts in a rule (a shell, someone's home directory, a drive letter)
grep -rinE 'powershell|cmd\.exe|/Users/|/home/|[A-Za-z]:[\\]' <rule-dirs>

# R3 — a path baked into a skill's steps, excluding the skill's own bundle
grep -rnE --include=SKILL.md '[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+\.[A-Za-z0-9]+' <skill-dirs> \
  | grep -vE '(^|[^A-Za-z0-9._/-])(references|scripts|assets)/'

# R4 — skills whose body never mentions verifying anything (-L lists files with NO match)
grep -riLE --include=SKILL.md 'verif|expect|assert|check|test|IS_STATUS' <skill-dirs>

# R5 - pressure markers: a heading or label named for urgency, then absolute-language density per file
grep -rnE '^#+ .*(CRITICAL|MANDATORY|HARD RULE|READ FIRST)|\((CRITICAL|MANDATORY|HARD RULE)\)' <rule-dirs> <agent-dirs> <skill-dirs>
grep -rcE '(MUST|NEVER|ALWAYS)' <rule-dirs> <agent-dirs> <skill-dirs> | grep -vE ':0$'

# R6 - history narrative in a rule body: PR numbers, incident ids, dates, "this session", commit SHAs
grep -rniE -e '(#|PR )[0-9]{3,}' -e '[0-9]{4}-[0-9]{2}-[0-9]{2}' -e 'this session|origin session' \
  -e '`[0-9a-f]{7,40}`' <rule-dirs>

# R7 - words per file, then the longest paragraph; a list item or table row is its own paragraph
find <rule-dirs> <agent-dirs> <skill-dirs> -name '*.md' | while IFS= read -r f; do
  awk -v f="$f" 'BEGIN { fence = sprintf("%c%c%c", 96, 96, 96) }
    { sub(/\r$/, "") }
    NR == 1 && /^---[ \t\r]*$/ { fm = 1; next }
    fm { if (/^---[ \t\r]*$/) fm = 0; next }
    { w += NF }
    index($1, fence) == 1 { code = !code; p = 0; next }
    code || NF == 0 { p = 0; next }
    /^[ \t]*(#|[-*] |[0-9]+\. |\|)/ { p = 0 }
    { p += NF; if (p > max) max = p }
    END { printf "%6d %4d %s\n", w, max, f }' "$f"
done | sort -rn

# R9 - a forked skill without background: false whose agent can edit; fmv prints one frontmatter
# value without quotes or a trailing comment, and the later agent source wins, as in sync
fmv() { awk -v k="$2" 'NR == 1 { f = /^---/; next } !f || /^---/ { exit }
  index($0, k ":") == 1 { v = substr($0, length(k) + 2); sub(/[ \t]+#.*$/, "", v)
    gsub(/["\047 \t\r]/, "", v); print v; exit }' "$1"; }
grep -rl --include=SKILL.md '^context:' <skill-dirs> | while IFS= read -r f; do
  [ "$(fmv "$f" context)" = fork ] && [ "$(fmv "$f" background)" != false ] || continue
  a=$(fmv "$f" agent); a=${a:-general-purpose}
  if [ "$a" != general-purpose ]; then
    src=; for d in <agent-dirs>; do [ -f "$d/$a.md" ] && src="$d/$a.md"; done
    [ -n "$src" ] || continue
    case "$(fmv "$src" access)" in readonly|runner) continue ;; esac
  fi
  echo "$f: agent $a can edit while its caller works"
done
```

`R8` has no command of its own: every sync checks it over every source, packages included, and prints one `WARNING:` line per field naming the file and line. Read those lines from `intelligence sync` output.

`R9` judges `general-purpose` and the agents in the agent sources. A fork that names any other agent, a tool's built-in or a plugin's, is skipped: whether that agent edits is in its own documentation.

Every sync also makes the `R7` count over the project's own rules, agents and `SKILL.md` files, and prints a `WARNING:` line for a file over its budget and one for its longest paragraph over the paragraph budget. The command above still measures a package source and a skill reference.

`R4` is a coarse net, not a verdict: a skill that merely *mentions* a verification command anywhere passes it. Read the final step of every skill regardless — the question is whether something at the end **proves the work landed**, not whether the word appears. So are `R5` and `R6`: a `NEVER` that carries its reason and a date inside a frontmatter template are both legitimate hits, and the row's action applies only where the marker or the id is doing no work.
