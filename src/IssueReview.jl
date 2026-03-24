module IssueReview

issues_root() = joinpath(homedir(), "github", "issues")

# Legacy single-dir (still works for backwards compat)
proposals_dir() = joinpath(issues_root(), "proposals")

# Discover all repo working dirs: any subdir of issues_root that contains a proposals/ folder
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
