---
name: dev-update-model-defaults
description: "Move tier model defaults to current vendor models"
---

# Update the model defaults

This repository-only skill moves the engine's built-in tier defaults to the models
each tool offers today. A consuming project never needs it: an unpinned tier follows
the engine through `intelligence update`, and a pin is one `models.<tool>.<tier>`
line that sync reports once it differs from the default.

1. Read the defaults table, `get_model_default_var` in the engine library, and the
   decisions its comments cite. Each tool's entry cites the page that backs it and
   the date it was last checked; the table's header names every copy that moves
   with it.

2. Re-read each cited page now. Memory and cached catalogs are not evidence, and a
   third-party post is only a lead to confirm on the vendor's page. Record what each
   alias resolves to, or which models the page recommends or lists as generally
   available, and any minimum client version or access restriction it states. A
   model the vendor's page does not list is not a default, however widely reported.

3. Classify each tier:
   - **unchanged** - the value, or the alias it is, already names the newest model
     of its line;
   - **bump** - a newer model of the same line, the mapping's shape unchanged;
   - **remap** - the tier would change line, start or stop sharing a model with
     another tier, or take a value a cited decision rejected. A remap is the owner's
     decision: propose it with the evidence, and once accepted record it in profile
     `decisions_dir`, amending the decision it changes, before implementing it.
     Never fold a remap into a bump.

4. Edit the table, every copy its header names, and the check date of every page
   re-read in step 2, unchanged entries included. Cite a page's new address when the
   vendor moved it.

5. Pick the pending version by the release rule and move its lockstep files. Add one
   changelog line per changed tool naming the new models and the
   `models.<tool>.<tier>` override that keeps the earlier one.

6. Run the profile `verify` gate: the engine unit suite pins the table
   independently and checks the published copy against it, so a copy left behind
   fails there instead of in a project. Deliver through `git-commit-push` and
   `git-open-pr`.

7. Report each tool and tier as unchanged, bumped (old → new) or a proposed remap,
   with the page and check date behind it, and name every model the pages offer
   that the table leaves unused, with the reason.
