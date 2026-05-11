# IssueReview.jl

Local web tooling that drives Niko's GitHub-issue review pipeline. The
library proper is a tiny pair of path helpers; almost everything lives in
the [`IssueReviewWeb`](https://github.com/nsiccha/IssueReview.jl/tree/dev/web)
HTMXObjects app, which reads `~/github/issues/<Repo>/proposals/*.md`,
renders the proposal + MWE + diff for each issue, and orchestrates draft-PR
creation against repos such as `AdvancedHMC.jl` and `Mooncake.jl`.

See [`issue-review-workflow.md`](https://github.com/nsiccha/Claude/blob/main/issue-review-workflow.md)
in the Claude knowledge base for the directory layout, status lifecycle, and
the per-proposal conventions the web app expects.

## Library API

The package exports two helpers that locate the on-disk review tree:

```julia
using IssueReview

IssueReview.issues_root()       # ~/github/issues
IssueReview.proposals_dir()     # legacy single-dir layout
IssueReview.repo_dirs()         # all <repo>/ subdirs that contain proposals/
```

These are consumed by `IssueReviewWeb` to discover per-repo proposal
directories. See the [API reference](api.md) for full docstrings.

## Gallery (TODO)

A live `HTMXObjects.Gallery` of self-contained `IssueReviewWeb` demo routes
would let the docs embed snapshots of the proposal viewer / MWE diff /
PR-status panels via the `<div class="htmxo-embed" data-hx-base="…">`
pattern from the [`/htmxo-gallery`](https://github.com/nsiccha/Claude/blob/main/skills/htmxo-gallery/SKILL.md)
skill. The app today is built around a single live `AppContext` reading the
real `~/github/issues/` tree, so producing reproducible demo fixtures (a
sample proposal dir, a recorded `gh` issue payload) is a prerequisite.

When that fixture work lands, follow the `/htmxo-gallery` checklist to
add a `web/gallery/` directory of `.jl` items, an `@get gallery()` route,
and an `@include record_gallery = RecordingRoutes(...)` mount; then add a
`docs/src/gallery.md` page with the `htmxo-embed` div pointing at
`live-issuereview/gallery`.
