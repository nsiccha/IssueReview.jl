module IssueReview

"""
    issues_root() -> String

Return the root directory of the on-disk issue-review tree, `~/github/issues`.

This is the directory `IssueReviewWeb` scans for per-repo subdirectories (each
containing a `proposals/` folder). The path is returned unconditionally — no
existence check is performed.
"""
issues_root() = joinpath(homedir(), "github", "issues")

"""
    proposals_dir() -> String

Return the legacy flat `proposals/` directory directly under [`issues_root`](@ref),
i.e. `~/github/issues/proposals`.

Kept for backwards compatibility with the pre-multi-repo layout; new layouts
nest proposals under `~/github/issues/<Repo>/proposals/` and are discovered via
[`repo_dirs`](@ref).
"""
proposals_dir() = joinpath(issues_root(), "proposals")

"""
    repo_dirs() -> Vector{String}

Discover all per-repo working directories under [`issues_root`](@ref).

Returns every subdirectory of `~/github/issues/` that contains a `proposals/`
folder, plus the root itself if it has a top-level `proposals/` (legacy flat
layout). Returns an empty vector if `issues_root()` does not exist.

Consumed by `IssueReviewWeb` to populate its per-repo proposal browser.
"""
function repo_dirs()
    root = issues_root()
    isdir(root) || return String[]
    dirs = String[]
    for d in readdir(root; join=true)
        isdir(d) || continue
        isdir(joinpath(d, "proposals")) && push!(dirs, d)
    end
    # Also include root itself if it has a proposals/ dir (legacy flat structure)
    isdir(joinpath(root, "proposals")) && push!(dirs, root)
    unique(dirs)
end

end
