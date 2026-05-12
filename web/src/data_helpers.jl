# --- Async GitHub issue fetching ---

function _fetch_issue_discussion(url)
    issue_m = match(r"github\.com/([^/]+/[^/]+)/issues/(\d+)", url)
    pr_m = match(r"github\.com/([^/]+/[^/]+)/pull/(\d+)", url)
    m = !isnothing(issue_m) ? issue_m : pr_m
    isnothing(m) && return Dict("error" => "could not parse URL: $url")
    repo_slug, num = m.captures
    is_pr = !isnothing(pr_m) && isnothing(issue_m)
    cmd = is_pr ?
        `gh pr view $num --repo $repo_slug --json title,body,comments,author,createdAt,labels,reviews --comments` :
        `gh issue view $num --repo $repo_slug --json title,body,comments,author,createdAt,labels --comments`
    raw = strip(read(cmd, String))
    data = JSON.parse(raw)
    is_pr && (data["_is_pr"] = true)
    data
end

function _format_gh_time(s)
    isempty(s) && return ""
    m = match(r"(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})", s)
    isnothing(m) ? s : "$(m.captures[1]) $(m.captures[2])"
end

# Handle legacy cached string format
_render_issue_data(data::AbstractString) = h.div(class="markdown-body")(Markdown.html(Markdown.parse(data)))
_render_issue_data(data) = h.p(; class="u-text-muted")(string(data))
_gh_login(entry) = get(get(entry, "author", Dict()), "login", "unknown")

# Render one comment / review entry as a `<div class="disc-comment">` with the
# author + (time or state-badge) header and the markdown-rendered body.
function _disc_comment_node(author, header_extra, body)
    h.div(class="disc-comment")(
        h.div(class="disc-comment-header")(h.strong(author), header_extra),
        isempty(body) ? "" : h.div(class="disc-comment-body markdown-body")(Markdown.html(Markdown.parse(body))),
    )
end

# Map a PR-review `state` string to a small inline badge.
function _review_state_badge(state)
    state == "APPROVED" && return h.span(; class="ir-status-approved")(" ✓ approved")
    state == "CHANGES_REQUESTED" && return h.span(; class="ir-status-changes")(" ✎ changes requested")
    state == "COMMENTED" && return h.span(; class="ir-status-comment")(" commented")
    ""
end

const _LIGHT_LABEL_BGS = ("ffffff","f9d0c4","e4e669","fef2c0","d4c5f9","c5def5","bfd4f2","bfdadc","c2e0c6","fbca04")

function _label_node(l)
    bg = get(l, "color", "ddd")
    fg_cls = bg in _LIGHT_LABEL_BGS ? "ir-label-light" : "ir-label-dark"
    h.span(; class="ir-label $fg_cls", style="--ir-label-bg:#$bg")(get(l, "name", ""))
end

function _render_issue_data(data::AbstractDict)
    haskey(data, "error") && return h.p(; class="ir-error-sm")(data["error"])

    title = get(data, "title", "")
    body = get(data, "body", "")
    author = get(get(data, "author", Dict()), "login", "")
    created = _format_gh_time(get(data, "createdAt", ""))
    label_nodes = [_label_node(l) for l in get(data, "labels", [])]

    nodes = Any[
        # Issue header
        h.div(class="disc-header")(
            h.div(class="disc-title")(title),
            isempty(label_nodes) ? "" : h.div(; class="ir-label-row")(label_nodes...),
        ),
    ]

    # Issue body (OP)
    isempty(body) || push!(nodes, _disc_comment_node(author, h.span(class="disc-time")(created), body))

    # Comments
    for c in get(data, "comments", [])
        push!(nodes, _disc_comment_node(
            _gh_login(c),
            h.span(class="disc-time")(_format_gh_time(get(c, "createdAt", ""))),
            get(c, "body", ""),
        ))
    end

    # PR reviews (if present)
    for r in get(data, "reviews", [])
        rstate = get(r, "state", "")
        rbody = get(r, "body", "")
        isempty(rbody) && isempty(rstate) && continue
        push!(nodes, _disc_comment_node(_gh_login(r), _review_state_badge(rstate), rbody))
    end

    h.div()(nodes...)
end

function _fetch_worktree_diff(worktree_path)
    isdir(worktree_path) || return "(worktree not found: $worktree_path)"
    # Resolve the upstream main branch; fall back to literal origin/main when
    # origin/HEAD isn't set.
    head_out = read(pipeline(ignorestatus(setenv(`git rev-parse --abbrev-ref origin/HEAD`; dir=worktree_path)); stderr=devnull), String)
    main_branch = strip(head_out)
    if isempty(main_branch) || startswith(main_branch, "fatal")
        main_branch = "origin/main"
    end
    base = strip(read(setenv(`git merge-base $main_branch HEAD`; dir=worktree_path), String))
    diff = read(setenv(`git diff $base`; dir=worktree_path), String)
    isempty(diff) && return "(no changes vs main)"
    diff
end

function _run_mwe_safe(script_path, run_dir)
    isfile(script_path) || return (; exit_code=-1, output="(script not found: $script_path)")
    isdir(run_dir) || return (; exit_code=-1, output="(directory not found: $run_dir)")

    mwe_dir = dirname(script_path)
    setup_sh = joinpath(mwe_dir, "setup.sh")
    project_toml = joinpath(mwe_dir, "Project.toml")
    label = _is_main_dir(run_dir) ? "main" : "worktree"
    # Use proposal's Project.toml if it exists, with a separate env per label
    # to avoid main/worktree sharing a Manifest.toml
    if isfile(project_toml)
        project_dir = joinpath(mwe_dir, ".env-$label")
        mkpath(project_dir)
        cp(project_toml, joinpath(project_dir, "Project.toml"); force=true)
    else
        project_dir = run_dir
    end

    # Stream output directly to the stable .out file so the UI can poll it live
    out_path = _mwe_output_path(script_path, run_dir)
    mkpath(dirname(out_path))
    open(out_path, "w") do f
        println(f, "# MWE: $(basename(script_path)) on $label")
        println(f, "# started: $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))")
        println(f, "# dir: $run_dir")
        println(f, "# project: $project_dir")
        println(f, "---")
        flush(f)
        # Run setup.sh if present
        if isfile(setup_sh)
            println(f, "==> Running setup.sh")
            flush(f)
            setup_cmd = setenv(`bash $setup_sh $run_dir $label`; dir=run_dir)
            setup_proc = run(pipeline(setup_cmd; stdout=f, stderr=f); wait=false)
            wait(setup_proc)
            flush(f)
            if setup_proc.exitcode != 0
                println(f, "\n# exit_code: $(setup_proc.exitcode)")
                println(f, "# status: FAIL (setup.sh)")
                return (; exit_code=setup_proc.exitcode, output=read(out_path, String))
            end
        end
        # Dev the worktree package into the proposal environment if using proposal's Project.toml
        # Only if the worktree is a Julia package (has Project.toml with a name field)
        run_dir_project = joinpath(run_dir, "Project.toml")
        if project_dir != run_dir && isfile(run_dir_project) && contains(read(run_dir_project, String), r"^name\s*="m)
            println(f, "==> Pkg.develop(path=\"$run_dir\")")
            flush(f)
            dev_cmd = setenv(`julia --project=$project_dir -e "using Pkg; Pkg.develop(path=\"$run_dir\")"`; dir=run_dir)
            dev_proc = run(pipeline(dev_cmd; stdout=f, stderr=f); wait=false)
            wait(dev_proc)
            flush(f)
            if dev_proc.exitcode != 0
                println(f, "\n# exit_code: $(dev_proc.exitcode)")
                println(f, "# status: FAIL (Pkg.develop)")
                return (; exit_code=dev_proc.exitcode, output=read(out_path, String))
            end
        end
        # Instantiate
        println(f, "==> Pkg.instantiate()")
        flush(f)
        inst = setenv(`julia --project=$project_dir -e "using Pkg; Pkg.instantiate()"`; dir=run_dir)
        inst_proc = run(pipeline(inst; stdout=f, stderr=f); wait=false)
        wait(inst_proc)
        flush(f)
        if inst_proc.exitcode != 0
            println(f, "\n# exit_code: $(inst_proc.exitcode)")
            println(f, "# status: FAIL (instantiate)")
            return (; exit_code=inst_proc.exitcode, output=read(out_path, String))
        end
        # Run script
        println(f, "==> Running $(basename(script_path))")
        flush(f)
        mwe_env = Dict("MWE_LABEL" => label, "MWE_RUN_DIR" => run_dir)
        cmd = setenv(addenv(`julia -tauto --project=$project_dir $script_path`, mwe_env); dir=run_dir)
        proc = run(pipeline(cmd; stdout=f, stderr=f); wait=false)
        wait(proc)
        flush(f)
        println(f, "\n# exit_code: $(proc.exitcode)")
        println(f, "# status: $(proc.exitcode == 0 ? "PASS" : "FAIL")")
        println(f, "# finished: $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))")
        (; exit_code=proc.exitcode, output=read(out_path, String))
    end
end

function _mwe_output_path(script_path, run_dir)
    slug = replace(basename(script_path), ".jl" => "")
    label = _is_main_dir(run_dir) ? "main" : "worktree"
    joinpath(dirname(script_path), "$slug.$label.out")
end

function _is_main_dir(run_dir)
    # Heuristic: worktrees are under issues/worktrees/, main repos are not
    !contains(run_dir, "worktree")
end


# Find the repo root for a worktree (to run the MWE on main)
function _repo_main_dir(worktree_path)
    isdir(worktree_path) || return nothing
    isdir(joinpath(worktree_path, ".git")) || isfile(joinpath(worktree_path, ".git")) || return nothing
    root = strip(read(setenv(`git rev-parse --git-common-dir`; dir=worktree_path), String))
    main = dirname(root)
    isdir(main) ? main : nothing
end

@dynamicstruct struct AsyncIssueData
    discussion(issue_url) = _fetch_issue_discussion(issue_url)
    diff(worktree_path) = _fetch_worktree_diff(worktree_path)
    mwe(script_path, run_dir) = _run_mwe_safe(script_path, run_dir)
end
_async_issues = AsyncIssueData(; cache_type=:parallel)

# Discard the in-flight Task and return only the materialized result
_skip_pending(::Task, _) = nothing
_skip_pending(rv, _) = rv

# Read a field from a quick-comment entry (Dict) or fall back for non-Dict entries
_qc_msg(qc::AbstractDict) = get(qc, "msg", "")
_qc_msg(qc) = string(qc)
_qc_status(qc::AbstractDict) = get(qc, "status", "")
_qc_status(_) = ""

_issue_discussion(issue_url) = fetchindex(_skip_pending, _async_issues.discussion, issue_url)
_worktree_diff(worktree_path) = fetchindex(_skip_pending, _async_issues.diff, worktree_path)
_mwe_result(script_path, run_dir) = fetchindex(_skip_pending, _async_issues.mwe, script_path, run_dir)

# --- Responses config (editable via web UI) ---

_default_responses() = [
    Dict("label"=>"Open PR", "status"=>"", "comment"=>"", "style"=>"approve", "confirm"=>false, "prompt"=>false, "action"=>"pr_preview"),
    Dict("label"=>"Revise", "status"=>"changes-requested", "comment"=>"", "style"=>"changes", "confirm"=>false, "prompt"=>true),
    Dict("label"=>"Reject", "status"=>"rejected", "comment"=>"REJECTED. Do not pursue this issue. Do not open a PR.", "style"=>"reject", "confirm"=>true, "prompt"=>false),
    Dict("label"=>"Skip", "status"=>"skipped", "comment"=>"SKIPPED. Move on to the next issue. Do not spend more time on this.", "style"=>"skip", "confirm"=>false, "prompt"=>false),
    Dict("label"=>"Reset", "status"=>"review", "comment"=>"", "style"=>"", "confirm"=>true, "prompt"=>false),
]

_default_quick_comments() = [
    Dict("msg"=>"Looks good but needs tests.", "status"=>"changes-requested"),
    Dict("msg"=>"Simplify — this can be a one-liner.", "status"=>"changes-requested"),
    Dict("msg"=>"Check PR comments and address feedback.", "status"=>"changes-requested"),
    Dict("msg"=>"Check if there's an existing PR for this.", "status"=>""),
    Dict("msg"=>"Not urgent, deprioritize.", "status"=>"skipped"),
    Dict("msg"=>"Add a docstring for the new export.", "status"=>"changes-requested"),
    Dict("msg"=>"Missing MWE. Add a minimal example that fails on main but passes with your changes.", "status"=>"changes-requested"),
]

function _config_path()
    joinpath(config_dir(), "review-config.json")
end

function _load_config()
    path = _config_path()
    isfile(path) && return JSON.parsefile(path)
    cfg = Dict("responses" => _default_responses(), "quick_comments" => _default_quick_comments())
    mkpath(dirname(path))
    open(path, "w") do io; JSON.print(io, cfg, 2); end
    cfg
end

function _save_config(cfg)
    path = _config_path()
    mkpath(dirname(path))
    open(path, "w") do io; JSON.print(io, cfg, 2); end
end

function _responses()
    get(_load_config(), "responses", _default_responses())
end

function _quick_comments()
    get(_load_config(), "quick_comments", _default_quick_comments())
end

# --- Proposal parsing ---

function _split_frontmatter(content)
    m = match(r"^---\n(.*?)\n---\n(.*)"s, content)
    isnothing(m) && return (nothing, content)
    m.captures
end

function parse_proposal(path)
    content = read(path, String)
    yaml_str, body = _split_frontmatter(content)
    if isnothing(yaml_str)
        return (; yaml=OrderedDict{String,Any}(), body=content, raw=content, path)
    end
    yaml = YAML.load(yaml_str; dicttype=OrderedDict{String,Any})
    # Normalize scalar nothings (YAML null) to "" for compatibility
    for (k, v) in yaml
        isnothing(v) && (yaml[k] = "")
    end
    (; yaml, body, raw=content, path)
end

# Walk all proposal.md files across all repo dirs. When `include_meta` is true,
# directories whose names start with `_` (triage dirs etc.) are included; the
# list-page renderer filters them out, the hash sentinel does not.
function _proposal_paths(; include_meta=false)
    files = String[]
    for rd in repo_dirs()
        pdir = joinpath(rd, "proposals")
        isdir(pdir) || continue
        for d in readdir(pdir; join=true)
            isdir(d) || continue
            (!include_meta && startswith(basename(d), "_")) && continue
            pf = joinpath(d, "proposal.md")
            isfile(pf) && push!(files, pf)
        end
    end
    files
end

function list_proposals()
    files = _proposal_paths()
    sort!(files; by=mtime, rev=true)
    [parse_proposal(f) for f in files]
end

function _write_frontmatter!(path, yaml, body)
    buf = IOBuffer()
    YAML.write(buf, yaml)
    write(path, "---\n" * String(take!(buf)) * "---\n" * body)
end

# Load frontmatter+body from a proposal path, apply `f(yaml)` in place, then
# write back. `caller` is used in the error message when the file has no
# frontmatter to mutate.
function _mutate_frontmatter!(f, path, caller)
    content = read(path, String)
    yaml_str, body = _split_frontmatter(content)
    isnothing(yaml_str) && throw(ArgumentError("$caller: no YAML frontmatter in $path"))
    yaml = YAML.load(yaml_str; dicttype=OrderedDict{String,Any})
    f(yaml)
    _write_frontmatter!(path, yaml, body)
end

update_yaml!(path, key, value) = _mutate_frontmatter!(path, "update_yaml!") do yaml
    yaml[key] = value
end

add_comment!(path, comment) = _mutate_frontmatter!(path, "add_comment!") do yaml
    timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM")
    push!(get!(yaml, "comments", String[]), "[$timestamp] $comment")
end

function parse_comments(yaml)
    comments = get(yaml, "comments", String[])
    [string(c) for c in comments]
end

# YAML null / empty-string scalars come back from YAML.jl in a few shapes
# (`nothing`, the literal string `"null"`, or `""`). Normalize to either the
# stripped string or `nothing`.
function _parse_pr_val(v)
    isnothing(v) && return nothing
    v in ("null", "") ? nothing : v
end
_yaml_pr(yaml) = _parse_pr_val(get(yaml, "pr", ""))

# Resolve the current branch in a worktree dir, returning "" if not a git dir.
function _worktree_branch(worktree)
    isempty(worktree) && return ""
    isdir(worktree) || return ""
    ispath(joinpath(worktree, ".git")) || return ""
    strip(read(setenv(`git rev-parse --abbrev-ref HEAD`; dir=worktree), String))
end

# Locate `<repo>/proposals/<slug>/proposal.md` across all known repo dirs.
function find_proposal(slug)
    for rd in repo_dirs()
        path = joinpath(rd, "proposals", slug, "proposal.md")
        isfile(path) && return path
    end
    nothing
end

# Locate + parse in one step. Returns `nothing` when the slug doesn't resolve.
function load_proposal(slug)
    path = find_proposal(slug)
    isnothing(path) ? nothing : parse_proposal(path)
end

# Tiny 404 widget used by every route that takes a `slug`.
not_found_node(slug) = h.p("Not found: $slug")

# Status buckets used to decide whether MWE/diff `<details>` panels default to open.
const _CLOSED_STATUSES = ("rejected", "skipped", "pr-merged")
should_auto_open(status) = status ∉ _CLOSED_STATUSES

# Standard "loading + poll-this-URL every 2s" placeholder span used by every
# async cache route (issue discussion, worktree diff, MWE stream...).
loading_span(label, poll_url; cls="issue-loading", interval="every 2s") = h.span(;
    class=cls, hx_get=poll_url, hx_trigger=interval, hx_swap="outerHTML",
)(label)

# --- MWE panel helpers ---

# Scan a `.out` file for the `# finished: ...` marker that `_run_mwe_safe` writes
# at the bottom. Returns "" when not present (still running or no file yet).
function _mwe_finished_ts(out_path)
    isfile(out_path) || return ""
    for line in eachline(out_path)
        m = match(r"^# finished: (.+)", line)
        isnothing(m) || return m.captures[1]
    end
    ""
end

# Header label for a completed MWE run, e.g. "main — PASS (2026-05-11 22:14:01)".
function _mwe_done_label(label, result, out_path)
    pass = result.exit_code == 0
    verdict = pass ? "PASS" : "FAIL (exit $(result.exit_code))"
    ts = _mwe_finished_ts(out_path)
    ts_label = isempty(ts) ? "" : " ($ts)"
    (; pass, text="$label — $verdict$ts_label")
end

# Both `main` (when discoverable) and `worktree` dirs in run order, with empty
# / nothing entries dropped — every MWE route iterates exactly this list.
function _mwe_run_dirs(worktree)
    dirs = String[]
    main_dir = _repo_main_dir(worktree)
    isnothing(main_dir) || push!(dirs, main_dir)
    isempty(worktree) || push!(dirs, worktree)
    dirs
end
