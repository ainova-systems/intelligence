# Decisions

One file per decision that would otherwise be re-litigated: `NNNN-short-slug.md`, holding
Context / Decision / Consequences / Rejected. Append-only — a superseded decision keeps its file
and gains a `Superseded by NNNN` line.

This is repo governance, not shipped documentation, which is why it sits outside `docs/`:
`docs/` is content of the `@ainova-systems/sync` package and lands in every project that installs
it. The CHANGELOG says *what* changed, in one line per change; the *why* lives here.
