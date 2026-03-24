module IssueReviewWeb

using HTMXObjects
using IssueReview
using Markdown
using Dates
using JSON

proposals_dir() = IssueReview.proposals_dir()
config_dir() = IssueReview.issues_root()
repo_dirs() = IssueReview.repo_dirs()

# --- Async GitHub issue fetching ---

function _fetch_issue_discussion(url)
    issue_m = match(r"github\.com/([^/]+/[^/]+)/issues/(\d+)", url)
    pr_m = match(r"github\.com/([^/]+/[^/]+)/pull/(\d+)", url)
    m = !isnothing(issue_m) ? issue_m : pr_m
    isnothing(m) && return Dict("error" => "could not parse URL: $url")
    repo_slug, num = m.captures
    is_pr = !isnothing(pr_m) && isnothing(issue_m)
    try
        cmd = is_pr ?
            `gh pr view $num --repo $repo_slug --json title,body,comments,author,createdAt,labels,reviews --comments` :
            `gh issue view $num --repo $repo_slug --json title,body,comments,author,createdAt,labels --comments`
        raw = strip(read(cmd, String))
        data = JSON.parse(raw)
        is_pr && (data["_is_pr"] = true)
        data
    catch e
        Dict("error" => "gh CLI failed: $(sprint(showerror, e))")
    end
end

function _format_gh_time(s)
    isempty(s) && return ""
    m = match(r"(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})", s)
    isnothing(m) ? s : "$(m.captures[1]) $(m.captures[2])"
end

function _render_issue_data(data)
    # Handle legacy cached string format
    data isa AbstractString && return h.div(class="markdown-body")(Markdown.html(Markdown.parse(data)))
    data isa AbstractDict || return h.p(; style="color:#888")(string(data))
    haskey(data, "error") && return h.p(; style="color:#c00;font-size:0.85rem")(data["error"])

    title = get(data, "title", "")
    body = get(data, "body", "")
    author = get(get(data, "author", Dict()), "login", "")
    created = _format_gh_time(get(data, "createdAt", ""))
    labels = get(data, "labels", [])
    comments = get(data, "comments", [])

    label_nodes = [h.span(; style="display:inline-block;padding:0.1em 0.4em;border-radius:10px;background:#$(get(l,"color","ddd"));color:#$(get(l,"color","ddd") in ("ffffff","f9d0c4","e4e669","fef2c0","d4c5f9","c5def5","bfd4f2","bfdadc","c2e0c6","fbca04") ? "24292f" : "fff");font-size:0.75rem;margin-right:0.3rem")(
        get(l, "name", "")
    ) for l in labels]

    nodes = []

    # Issue header
    push!(nodes, h.div(class="disc-header")(
        h.div(class="disc-title")(title),
        !isempty(label_nodes) ? h.div(; style="margin-top:0.3rem")(label_nodes...) : "",
    ))

    # Issue body (OP)
    if !isempty(body)
        push!(nodes, h.div(class="disc-comment")(
            h.div(class="disc-comment-header")(
                h.strong(author),
                h.span(class="disc-time")(created),
            ),
            h.div(class="disc-comment-body markdown-body")(Markdown.html(Markdown.parse(body))),
        ))
    end

    # Comments
    for c in comments
        cauthor = get(get(c, "author", Dict()), "login", "unknown")
        ccreated = _format_gh_time(get(c, "createdAt", ""))
        cbody = get(c, "body", "")
        push!(nodes, h.div(class="disc-comment")(
            h.div(class="disc-comment-header")(
                h.strong(cauthor),
                h.span(class="disc-time")(ccreated),
            ),
            h.div(class="disc-comment-body markdown-body")(Markdown.html(Markdown.parse(cbody))),
        ))
    end

    # PR reviews (if present)
    reviews = get(data, "reviews", [])
    for r in reviews
        rauthor = get(get(r, "author", Dict()), "login", "unknown")
        rstate = get(r, "state", "")
        rbody = get(r, "body", "")
        isempty(rbody) && isempty(rstate) && continue
        state_badge = if rstate == "APPROVED"
            h.span(; style="color:#1a7f37;font-weight:600")(" ✓ approved")
        elseif rstate == "CHANGES_REQUESTED"
            h.span(; style="color:#d29922;font-weight:600")(" ✎ changes requested")
        elseif rstate == "COMMENTED"
            h.span(; style="color:#666")(" commented")
        else
            ""
        end
        push!(nodes, h.div(class="disc-comment")(
            h.div(class="disc-comment-header")(
                h.strong(rauthor), state_badge,
            ),
            !isempty(rbody) ? h.div(class="disc-comment-body markdown-body")(Markdown.html(Markdown.parse(rbody))) : "",
        ))
    end

    h.div()(nodes...)
end

function _fetch_worktree_diff(worktree_path)
    isdir(worktree_path) || return "(worktree not found: $worktree_path)"
    try
        # Diff against the main branch (where the worktree diverged from)
        # Use merge-base to find the common ancestor
        main_branch = strip(read(setenv(`git rev-parse --abbrev-ref origin/HEAD`; dir=worktree_path), String))
        if isempty(main_branch) || startswith(main_branch, "fatal")
            main_branch = "origin/main"
        end
        base = strip(read(setenv(`git merge-base $main_branch HEAD`; dir=worktree_path), String))
        diff = read(setenv(`git diff $base HEAD`; dir=worktree_path), String)
        isempty(diff) && return "(no changes vs main)"
        diff
    catch e
        # Fallback: try simple diff against origin/main
        try
            diff = read(setenv(`git diff origin/main...HEAD`; dir=worktree_path), String)
            isempty(diff) && return "(no changes vs main)"
            diff
        catch e2
            "Error reading diff: $(sprint(showerror, e2))"
        end
    end
end

function _run_mwe(script_path, run_dir)
    isfile(script_path) || return (; exit_code=-1, output="(script not found: $script_path)")
    isdir(run_dir) || return (; exit_code=-1, output="(directory not found: $run_dir)")
    try
        io = IOBuffer()
        cmd = setenv(`julia --project=$run_dir $script_path`; dir=run_dir)
        proc = run(pipeline(cmd; stdout=io, stderr=io); wait=true)
        (; exit_code=proc.exitcode, output=String(take!(io)))
    catch e
        if e isa ProcessFailedException
            io_out = try; String(take!(e.procs[1].out)); catch; ""; end
            (; exit_code=e.procs[1].exitcode, output=io_out)
        else
            (; exit_code=-1, output="Error: $(sprint(showerror, e))")
        end
    end
end

function _run_mwe_safe(script_path, run_dir)
    isfile(script_path) || return (; exit_code=-1, output="(script not found: $script_path)")
    isdir(run_dir) || return (; exit_code=-1, output="(directory not found: $run_dir)")
    # Stream output directly to the stable .out file so the UI can poll it live
    out_path = _mwe_output_path(script_path, run_dir)
    label = _is_main_dir(run_dir) ? "main" : "worktree"
    mkpath(dirname(out_path))
    result = try
        open(out_path, "w") do f
            println(f, "# MWE: $(basename(script_path)) on $label")
            println(f, "# started: $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))")
            println(f, "# dir: $run_dir")
            println(f, "---")
            flush(f)
            # Instantiate
            println(f, "==> Pkg.instantiate()")
            flush(f)
            inst = setenv(`julia --project=$run_dir -e "using Pkg; Pkg.instantiate()"`; dir=run_dir)
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
            cmd = setenv(`julia --project=$run_dir $script_path`; dir=run_dir)
            proc = run(pipeline(cmd; stdout=f, stderr=f); wait=false)
            wait(proc)
            flush(f)
            println(f, "\n# exit_code: $(proc.exitcode)")
            println(f, "# status: $(proc.exitcode == 0 ? "PASS" : "FAIL")")
            println(f, "# finished: $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))")
            (; exit_code=proc.exitcode, output=read(out_path, String))
        end
    catch e
        output = isfile(out_path) ? read(out_path, String) : ""
        open(out_path, "a") do f
            println(f, "\n# exit_code: -1")
            println(f, "# status: ERROR")
            println(f, "# error: $(sprint(showerror, e))")
        end
        (; exit_code=-1, output=isempty(output) ? "Error: $(sprint(showerror, e))" : output)
    end
    result
end

function _mwe_output_path(script_path, run_dir)
    # e.g. proposals/411-rand-momentum-api.main.out or .worktree.out
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
    try
        # git worktree points back to the main repo
        root = strip(read(setenv(`git rev-parse --git-common-dir`; dir=worktree_path), String))
        # git-common-dir returns the .git dir; parent is the repo root
        main = dirname(root)
        isdir(main) ? main : nothing
    catch
        nothing
    end
end

@dynamicstruct struct AsyncIssueData
    discussion[issue_url] = _fetch_issue_discussion(issue_url)
    diff[worktree_path] = _fetch_worktree_diff(worktree_path)
    mwe[script_path, run_dir] = _run_mwe_safe(script_path, run_dir)
end
_async_issues = AsyncIssueData(; cache_type=:parallel)

function _issue_discussion(issue_url)
    fetchindex(_async_issues.discussion, issue_url) do rv, status
        rv isa Task ? nothing : rv
    end
end

function _worktree_diff(worktree_path)
    fetchindex(_async_issues.diff, worktree_path) do rv, status
        rv isa Task ? nothing : rv
    end
end

function _mwe_result(script_path, run_dir)
    fetchindex(_async_issues.mwe, script_path, run_dir) do rv, status
        rv isa Task ? nothing : rv
    end
end

# --- Responses config (editable via web UI) ---

_default_responses() = [
    Dict("label"=>"Open PR", "status"=>"", "comment"=>"", "style"=>"approve", "confirm"=>false, "prompt"=>false, "action"=>"pr_preview"),
    Dict("label"=>"Revise", "status"=>"changes-requested", "comment"=>"", "style"=>"changes", "confirm"=>false, "prompt"=>true),
    Dict("label"=>"Reject", "status"=>"rejected", "comment"=>"REJECTED. Do not pursue this issue. Do not open a PR.", "style"=>"reject", "confirm"=>true, "prompt"=>false),
    Dict("label"=>"Skip", "status"=>"skipped", "comment"=>"SKIPPED. Move on to the next issue. Do not spend more time on this.", "style"=>"skip", "confirm"=>false, "prompt"=>false),
    Dict("label"=>"Reset", "status"=>"pending", "comment"=>"", "style"=>"", "confirm"=>true, "prompt"=>false),
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
    if isfile(path)
        try; return JSON.parsefile(path); catch; end
    end
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

function parse_proposal(path)
    content = read(path, String)
    m = match(r"^---\n(.*?)\n---\n(.*)"s, content)
    isnothing(m) && return (; yaml=Dict{String,String}(), body=content, raw=content, path)
    yaml_str, body = m.captures
    yaml = Dict{String,String}()
    for line in eachline(IOBuffer(yaml_str))
        km = match(r"^(\w+):\s*(.*)", line)
        isnothing(km) && continue
        yaml[km.captures[1]] = strip(km.captures[2])
    end
    (; yaml, body, raw=content, path)
end

function list_proposals()
    files = String[]
    for rd in repo_dirs()
        pdir = joinpath(rd, "proposals")
        isdir(pdir) || continue
        for f in readdir(pdir; join=true)
            endswith(f, ".md") && !startswith(basename(f), "_") && push!(files, f)
        end
    end
    sort!(files; by=mtime, rev=true)
    [parse_proposal(f) for f in files]
end

function update_yaml!(path, key, value)
    content = read(path, String)
    m = match(r"^---\n(.*?)\n---\n(.*)"s, content)
    isnothing(m) && return
    yaml_str, body = m.captures
    lines = split(yaml_str, '\n')
    found = false
    for (i, line) in enumerate(lines)
        if startswith(line, "$key:")
            lines[i] = "$key: $value"
            found = true
            break
        end
    end
    !found && push!(lines, "$key: $value")
    new_content = "---\n" * join(lines, "\n") * "\n---\n" * body
    write(path, new_content)
end

function add_comment!(path, comment)
    content = read(path, String)
    m = match(r"^---\n(.*?)\n---\n(.*)"s, content)
    isnothing(m) && return
    yaml_str, body = m.captures
    lines = split(yaml_str, '\n')
    comment_idx = findfirst(l -> startswith(l, "comments:"), lines)
    timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM")
    new_entry = "  - \"[$timestamp] $comment\""
    if isnothing(comment_idx)
        push!(lines, "comments:")
        push!(lines, new_entry)
    else
        insert_at = comment_idx + 1
        while insert_at <= length(lines) && startswith(lines[insert_at], "  - ")
            insert_at += 1
        end
        insert!(lines, insert_at, new_entry)
    end
    new_content = "---\n" * join(lines, "\n") * "\n---\n" * body
    write(path, new_content)
end

function parse_comments(yaml)
    comments = String[]
    path = get(yaml, "_path", "")
    isempty(path) && return comments
    content = read(path, String)
    m = match(r"^---\n(.*?)\n---\n"s, content)
    isnothing(m) && return comments
    in_comments = false
    for line in split(m.captures[1], '\n')
        if startswith(line, "comments:")
            in_comments = true
            continue
        end
        if in_comments
            cm = match(r"^\s+-\s+\"(.*)\"$", line)
            if !isnothing(cm)
                push!(comments, cm.captures[1])
            elseif !startswith(line, "  ")
                break
            end
        end
    end
    comments
end

function status_badge(status)
    color = if status in ("open-pr", "approved")
        "#2da44e"
    elseif status == "rejected"
        "#cf222e"
    elseif status == "changes-requested"
        "#d29922"
    elseif status == "pr-open"
        "#8250df"
    elseif status == "skipped"
        "#666"
    else
        "#888"
    end
    h.span(; style="display:inline-block;padding:0.15em 0.5em;border-radius:3px;background:$color;color:white;font-size:0.8em;font-weight:600")(status)
end

function _html_escape(s)
    replace(s, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
end

function _prism_lang(filename)
    ext = splitext(filename)[2]
    ext == ".jl" ? "julia" :
    ext == ".toml" ? "toml" :
    ext == ".md" ? "markdown" :
    ext == ".yml" || ext == ".yaml" ? "yaml" :
    ext == ".json" ? "json" :
    ext == ".sh" ? "bash" :
    ext == ".py" ? "python" :
    ext == ".js" ? "javascript" :
    ext == ".ts" ? "typescript" :
    ext == ".html" ? "html" :
    ext == ".css" ? "css" :
    "none"
end

function _diff_code_cell(text, lang)
    lang == "none" ?
        h.td(class="diff-code")(_html_escape(text)) :
        h.td(class="diff-code")(h.code(; class="language-$lang")(_html_escape(text)))
end

function render_diff_html(diff_text)
    startswith(diff_text, "(") && return h.p(; style="color:#888;font-size:0.85rem")(diff_text)
    lines = split(diff_text, '\n')
    files = []  # Vector of (filename, lang, rows)
    current_file = ""
    current_lang = "none"
    current_rows = []
    old_ln = 0
    new_ln = 0

    for line in lines
        if startswith(line, "diff --git")
            if !isempty(current_file)
                push!(files, (current_file, current_lang, copy(current_rows)))
            end
            m = match(r"b/(.+)$", line)
            current_file = isnothing(m) ? line : m.captures[1]
            current_lang = _prism_lang(current_file)
            current_rows = []
            old_ln = 0; new_ln = 0
        elseif startswith(line, "@@")
            m = match(r"@@ -(\d+)", line)
            if !isnothing(m)
                old_ln = parse(Int, m.captures[1]) - 1
                nm = match(r"\+(\d+)", line)
                new_ln = isnothing(nm) ? old_ln : parse(Int, nm.captures[1]) - 1
            end
            push!(current_rows, h.tr(class="diff-hunk")(
                h.td(; class="diff-ln", colspan="2")("..."),
                h.td(; class="diff-sign")(),
                h.td(class="diff-code")(_html_escape(line)),
            ))
        elseif startswith(line, "---") || startswith(line, "+++") ||
               startswith(line, "index ") || startswith(line, "new file") ||
               startswith(line, "old mode") || startswith(line, "new mode") ||
               startswith(line, "deleted file")
            # Skip diff metadata lines
        elseif startswith(line, "+")
            new_ln += 1
            push!(current_rows, h.tr(class="diff-add")(
                h.td(class="diff-ln")(""),
                h.td(class="diff-ln")("$new_ln"),
                h.td(class="diff-sign")("+"),
                _diff_code_cell(line[2:end], current_lang),
            ))
        elseif startswith(line, "-")
            old_ln += 1
            push!(current_rows, h.tr(class="diff-del")(
                h.td(class="diff-ln")("$old_ln"),
                h.td(class="diff-ln")(""),
                h.td(class="diff-sign")("-"),
                _diff_code_cell(line[2:end], current_lang),
            ))
        elseif !isempty(current_file)
            old_ln += 1; new_ln += 1
            push!(current_rows, h.tr(class="diff-ctx")(
                h.td(class="diff-ln")("$old_ln"),
                h.td(class="diff-ln")("$new_ln"),
                h.td(class="diff-sign")(),
                _diff_code_cell(startswith(line, " ") ? line[2:end] : line, current_lang),
            ))
        end
    end
    !isempty(current_file) && push!(files, (current_file, current_lang, current_rows))

    isempty(files) && return h.p(; style="color:#888;font-size:0.85rem")("(empty diff)")

    h.div()(
        [h.div(class="diff-file")(
            h.div(class="diff-file-header")(fname),
            h.table(class="diff-table")(h.tbody(rows...)),
        ) for (fname, _lang, rows) in files]...
    )
end

@htmx struct AppContext
    req = nothing

    css = """
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; background: #f6f8fa; }
    .container { max-width: 1600px; margin: 0 auto; padding: 2rem; }
    h1 { margin-bottom: 1.5rem; }
    h1 small { font-weight: 400; font-size: 0.6em; color: #666; }
    .proposal-card { background: white; border: 1px solid #d0d7de; border-radius: 6px; padding: 1.5rem; margin-bottom: 1rem; border-left: 4px solid #d0d7de; }
    .proposal-card.status-pending { border-left-color: #888; }
    .proposal-card.status-open-pr { border-left-color: #2da44e; }
    .proposal-card.status-pr-open { border-left-color: #8250df; }
    .proposal-card.status-approved { border-left-color: #2da44e; }
    .proposal-card.status-changes-requested { border-left-color: #d29922; }
    .proposal-card.status-rejected { border-left-color: #cf222e; }
    .proposal-card.status-skipped { border-left-color: #666; }
    .proposal-card > summary { cursor: pointer; list-style: none; }
    .proposal-card > summary::-webkit-details-marker { display: none; }
    .proposal-card > summary::marker { display: none; content: ""; }
    .card-body { display: grid; grid-template-columns: 1fr 1fr; grid-template-rows: auto auto; gap: 0 1.5rem; margin-top: 0.75rem; }
    .card-body .card-left { min-width: 0; }
    .card-body .card-right { min-width: 0; overflow-y: auto; max-height: 80vh; }
    .card-body .card-footer { grid-column: 1 / -1; }
    @media (max-width: 1000px) { .card-body { grid-template-columns: 1fr; } .card-body .card-right { max-height: none; } }
    @keyframes status-flash { 0% { background: #fef3c7; } 100% { background: white; } }
    .proposal-card.just-updated { animation: status-flash 1.5s ease-out; }
    .htmx-request .btn { opacity: 0.6; pointer-events: none; }
    .proposal-header { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 0.75rem; }
    .proposal-title { font-size: 1.2rem; font-weight: 600; }
    .proposal-title a { color: #0969da; text-decoration: none; }
    .proposal-title a:hover { text-decoration: underline; }
    .proposal-meta { font-size: 0.85rem; color: #666; margin-bottom: 0.75rem; }
    .proposal-meta a { color: #0969da; text-decoration: none; }
    .proposal-meta a:hover { text-decoration: underline; }
    .proposal-body { line-height: 1.6; font-size: 0.95rem; }
    .proposal-body h2 { font-size: 1.1rem; margin: 0.75rem 0 0.4rem; }
    .proposal-body h3 { font-size: 1rem; margin: 0.75rem 0 0.4rem; }
    .proposal-body p { margin: 0.4rem 0; }
    .proposal-body pre { background: #f6f8fa; padding: 0.75rem; border-radius: 4px; overflow-x: auto; margin: 0.5rem 0; }
    .proposal-body code { font-family: "SFMono-Regular", Consolas, monospace; font-size: 0.85em; background: #f0f0f0; padding: 0.15em 0.3em; border-radius: 3px; }
    .proposal-body pre code { background: none; padding: 0; }
    .proposal-body ul, .proposal-body ol { margin: 0.4rem 0 0.4rem 1.5rem; }
    .actions { margin-top: 1rem; padding-top: 0.75rem; border-top: 1px solid #eee; }
    .actions-row { display: flex; gap: 0.5rem; align-items: center; flex-wrap: wrap; margin-bottom: 0.5rem; }
    .actions-row:last-child { margin-bottom: 0; }
    .btn { padding: 0.3rem 0.8rem; border: 1px solid #ccc; border-radius: 4px; font-size: 0.85rem; cursor: pointer; text-decoration: none; display: inline-block; background: #f6f8fa; color: #333; }
    .btn:hover { background: #e8e8e8; }
    .btn-approve { background: #2da44e; color: white; border-color: #2da44e; }
    .btn-approve:hover { background: #268a3e; }
    .btn-reject { background: #cf222e; color: white; border-color: #cf222e; }
    .btn-reject:hover { background: #a41e28; }
    .btn-changes { background: #d29922; color: white; border-color: #d29922; }
    .btn-changes:hover { background: #b3831e; }
    .btn-skip { background: #666; color: white; border-color: #666; }
    .btn-skip:hover { background: #555; }
    .btn-quick { background: white; border-color: #d0d7de; font-size: 0.8rem; color: #555; border-left: 3px solid #d0d7de; }
    .btn-quick:hover { background: #f0f0f0; color: #333; }
    .btn-quick-changes { border-left-color: #d29922; }
    .btn-quick-skip { border-left-color: #666; }
    .btn-quick-approve { border-left-color: #2da44e; }
    .btn-quick-reject { border-left-color: #cf222e; }
    .comment-form { display: flex; gap: 0.5rem; flex: 1; min-width: 300px; }
    .comment-form input { flex: 1; padding: 0.3rem 0.6rem; border: 1px solid #ccc; border-radius: 4px; font-size: 0.85rem; }
    .comment-form button { white-space: nowrap; }
    .comments { margin-top: 0.75rem; padding-top: 0.75rem; border-top: 1px solid #eee; }
    .comment { font-size: 0.85rem; color: #444; padding: 0.3rem 0; border-bottom: 1px solid #f0f0f0; }
    .comment:last-child { border-bottom: none; }
    .filter-bar { margin-bottom: 1rem; display: flex; gap: 0.5rem; flex-wrap: wrap; }
    .filter-bar a { padding: 0.3rem 0.8rem; border: 1px solid #d0d7de; border-radius: 20px; font-size: 0.85rem; text-decoration: none; color: #333; background: white; }
    .filter-bar a:hover { background: #f0f0f0; }
    .filter-bar a.active { background: #0969da; color: white; border-color: #0969da; }
    .agent-instructions { font-size: 0.8rem; color: #888; margin-top: 0; margin-bottom: 1rem; padding: 0.5rem; background: #fafbfc; border-radius: 4px; border: 1px dashed #ddd; }
    .agent-instructions code { font-size: 0.75rem; }
    .config-section { background: white; border: 1px solid #d0d7de; border-radius: 6px; padding: 1.5rem; margin-bottom: 1rem; }
    .config-section h3 { margin-bottom: 0.75rem; }
    .config-section textarea { width: 100%; min-height: 200px; font-family: monospace; font-size: 0.85rem; padding: 0.5rem; border: 1px solid #ccc; border-radius: 4px; }
    .config-section .btn { margin-top: 0.5rem; }
    .nav-links { margin-bottom: 1rem; }
    .nav-links a { font-size: 0.85rem; color: #0969da; text-decoration: none; margin-right: 1rem; }
    .nav-links a:hover { text-decoration: underline; }
    .issue-discussion { font-size: 0.85rem; }
    .issue-loading { color: #888; font-style: italic; font-size: 0.85rem; }
    .disc-header { margin-bottom: 0.75rem; }
    .disc-title { font-size: 1.05rem; font-weight: 600; color: #24292f; }
    .disc-comment { border: 1px solid #d0d7de; border-radius: 6px; margin-bottom: 0.5rem; overflow: hidden; }
    .disc-comment-header { background: #f6f8fa; padding: 0.4rem 0.75rem; font-size: 0.8rem; border-bottom: 1px solid #d0d7de; display: flex; justify-content: space-between; align-items: center; }
    .disc-comment-header strong { color: #24292f; }
    .disc-time { color: #8b949e; font-size: 0.75rem; }
    .disc-comment-body { padding: 0.5rem 0.75rem; }
    .disc-comment-body.markdown-body { line-height: 1.5; }
    .disc-comment-body.markdown-body p { margin: 0.3rem 0; }
    .disc-comment-body.markdown-body h2 { font-size: 0.95rem; margin: 0.5rem 0 0.3rem; }
    .disc-comment-body.markdown-body h3 { font-size: 0.9rem; margin: 0.4rem 0 0.2rem; }
    .disc-comment-body.markdown-body pre { font-size: 0.8rem; padding: 0.5rem; }
    .disc-comment-body.markdown-body ul, .disc-comment-body.markdown-body ol { margin: 0.3rem 0 0.3rem 1.5rem; }
    .mwe-section { margin-top: 0.75rem; }
    .mwe-section summary { cursor: pointer; font-size: 0.85rem; font-weight: 600; color: #0969da; padding: 0.3rem 0; }
    .mwe-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0.75rem; margin-top: 0.5rem; }
    @media (max-width: 1000px) { .mwe-grid { grid-template-columns: 1fr; } }
    .mwe-panel { border: 1px solid #d0d7de; border-radius: 6px; overflow: hidden; }
    .mwe-panel-header { padding: 0.4rem 0.75rem; font-size: 0.8rem; font-weight: 600; border-bottom: 1px solid #d0d7de; }
    .mwe-panel-header.mwe-pass { background: #dafbe1; color: #1a7f37; }
    .mwe-panel-header.mwe-fail { background: #ffebe9; color: #cf222e; }
    .mwe-panel-header.mwe-loading { background: #f6f8fa; color: #888; }
    .mwe-panel pre { padding: 0.5rem 0.75rem; font-size: 0.75rem; max-height: 300px; overflow-y: auto; margin: 0; background: #fafbfc; white-space: pre-wrap; word-wrap: break-word; }
    .mwe-script-wrap { display: flex; margin-top: 0.3rem; background: #f6f8fa; border-radius: 4px; font-size: 0.75rem; }
    .mwe-line-nums { padding: 0.5rem 0.5rem 0.5rem 0.5rem; text-align: right; color: #8b949e; user-select: none; border-right: 1px solid #d0d7de; line-height: 1.4; font-family: "SFMono-Regular", Consolas, monospace; white-space: pre; }
    .mwe-script-wrap pre { margin: 0; padding: 0.5rem 0.75rem; background: none; flex: 1; overflow-x: auto; line-height: 1.4; }
    .diff-viewer { margin-bottom: 0.75rem; }
    .diff-viewer summary { cursor: pointer; font-size: 0.85rem; font-weight: 600; color: #0969da; padding: 0.3rem 0; }
    .diff-file { border: 1px solid #d0d7de; border-radius: 6px; margin-bottom: 0.5rem; overflow: hidden; }
    .diff-file-header { background: #f6f8fa; padding: 0.4rem 0.75rem; font-size: 0.8rem; font-weight: 600; font-family: monospace; border-bottom: 1px solid #d0d7de; color: #24292f; }
    .diff-table { width: 100%; border-collapse: collapse; font-family: "SFMono-Regular", Consolas, monospace; font-size: 0.75rem; line-height: 1.4; }
    .diff-table td { padding: 0 0.5rem; vertical-align: top; white-space: pre-wrap; word-wrap: break-word; }
    .diff-ln { width: auto; text-align: right; color: #8b949e; user-select: none; padding-right: 0.5rem !important; border-right: 1px solid #d0d7de; white-space: nowrap !important; word-wrap: normal !important; }
    .diff-sign { width: 16px; min-width: 16px; text-align: center; user-select: none; }
    .diff-code { overflow-x: auto; }
    .diff-add { background: #dafbe1; }
    .diff-add .diff-ln { background: #ccffd8; color: #1a7f37; }
    .diff-add .diff-sign { color: #1a7f37; }
    .diff-del { background: #ffebe9; }
    .diff-del .diff-ln { background: #ffd7d5; color: #cf222e; }
    .diff-del .diff-sign { color: #cf222e; }
    .diff-hunk { background: #ddf4ff; }
    .diff-hunk td { color: #0969da; font-weight: 600; padding-top: 0.3rem; padding-bottom: 0.3rem; }
    .diff-ctx { background: white; }
    .diff-ctx .diff-ln { background: #fafbfc; }
    """

    proposals = list_proposals()

    _render_discussion(issue_url) = begin
        data = _issue_discussion(issue_url)
        if isnothing(data)
            h.div(class="issue-discussion")(
                h.span(; class="issue-loading",
                    hx_get=@query_url(issue_discussion(; url=issue_url)),
                    hx_trigger="every 2s",
                    hx_swap="outerHTML",
                )("Loading issue discussion..."),
            )
        else
            h.div(class="issue-discussion")(_render_issue_data(data))
        end
    end

    @get issue_discussion(; url="") = begin
        isempty(url) && return h.span()("No issue URL")
        data = _issue_discussion(url)
        if isnothing(data)
            h.span(; class="issue-loading",
                hx_get=@query_url(issue_discussion(; url)),
                hx_trigger="every 2s",
                hx_swap="outerHTML",
            )("Loading issue discussion...")
        else
            h.div(class="issue-discussion")(_render_issue_data(data))
        end
    end

    @post refresh_discussion(; url="") = begin
        isempty(url) && return h.span()("No URL")
        # Evict cache and re-fetch
        fetchindex(_async_issues.discussion, url; force=true) do rv, _
            rv isa Task ? nothing : rv
        end
        # Return loading state — polling will pick up the result
        h.div(class="issue-discussion")(
            h.span(; class="issue-loading",
                hx_get=@query_url(issue_discussion(; url)),
                hx_trigger="every 2s",
                hx_swap="outerHTML",
            )("Refreshing..."),
        )
    end

    _render_mwe_panel(label, result, script_path, run_dir) = begin
        out_path = _mwe_output_path(script_path, run_dir)
        if isnothing(result)
            # Task running — stream from the .out file
            live_output = isfile(out_path) ? read(out_path, String) : ""
            h.div(class="mwe-panel")(
                h.div(class="mwe-panel-header mwe-loading")("$label — running..."),
                h.pre(; hx_get=@query_url(mwe_stream(; script=script_path, dir=run_dir, label)),
                    hx_trigger="every 2s", hx_swap="outerHTML",
                )(_html_escape(isempty(live_output) ? "Starting..." : live_output)),
            )
        else
            pass = result.exit_code == 0
            # Extract timestamp from .out file
            ts = ""
            if isfile(out_path)
                for line in eachline(out_path)
                    m = match(r"^# finished: (.+)", line)
                    !isnothing(m) && (ts = m.captures[1]; break)
                end
            end
            ts_label = isempty(ts) ? "" : " ($ts)"
            h.div(class="mwe-panel")(
                h.div(class="mwe-panel-header $(pass ? "mwe-pass" : "mwe-fail")")(
                    "$label — $(pass ? "PASS" : "FAIL (exit $(result.exit_code))")$ts_label"
                ),
                h.pre(_html_escape(result.output)),
            )
        end
    end

    # Streaming endpoint: returns current .out file content or final result
    @get mwe_stream(; script="", dir="", label="") = begin
        result = _mwe_result(script, dir)
        out_path = _mwe_output_path(script, dir)
        if isnothing(result)
            # Still running — return current file content with continued polling
            live_output = isfile(out_path) ? read(out_path, String) : "Starting..."
            h.pre(; hx_get=@query_url(mwe_stream(; script, dir, label)),
                hx_trigger="every 2s", hx_swap="outerHTML",
            )(_html_escape(live_output))
        else
            # Done — return final panel (no more polling)
            pass = result.exit_code == 0
            ts = ""
            if isfile(out_path)
                for line in eachline(out_path)
                    m = match(r"^# finished: (.+)", line)
                    !isnothing(m) && (ts = m.captures[1]; break)
                end
            end
            ts_label = isempty(ts) ? "" : " ($ts)"
            h.div(class="mwe-panel")(
                h.div(class="mwe-panel-header $(pass ? "mwe-pass" : "mwe-fail")")(
                    "$label — $(pass ? "PASS" : "FAIL (exit $(result.exit_code))")$ts_label"
                ),
                h.pre(_html_escape(result.output)),
            )
        end
    end

    _find_mwe_scripts(slug, proposals_path) = begin
        dir = dirname(proposals_path)
        isdir(dir) || return String[]
        # Match <slug>.jl, <slug>-foo.jl, <slug>_bar.jl etc.
        [f for f in readdir(dir; join=true) if endswith(f, ".jl") && startswith(basename(f), slug)]
    end

    _render_single_mwe(script, worktree, main_dir) = begin
        sname = basename(script)
        main_result = isnothing(main_dir) ? nothing : _mwe_result(script, main_dir)
        worktree_result = _mwe_result(script, worktree)
        # Three states: idle (never run), running (result is nothing but triggered), done
        main_out = _mwe_output_path(script, isnothing(main_dir) ? "" : main_dir)
        wt_out = _mwe_output_path(script, worktree)
        was_triggered = isfile(main_out) || isfile(wt_out)
        has_results = !isnothing(main_result) || !isnothing(worktree_result)
        is_running = was_triggered && !has_results
        show_panels = was_triggered || has_results

        btn_style = "font-size:0.75rem;padding:0.15rem 0.5rem"
        h.div(; style="margin-bottom:0.75rem")(
            h.div(; style="display:flex;align-items:center;gap:0.5rem;margin-bottom:0.3rem")(
                h.strong(; style="font-size:0.85rem")(sname),
                !show_panels ? post_form("/run_mwe";
                    label="Run", btn_class="btn btn-approve", hx_target="#proposals-list", hx_swap="innerHTML",
                    script, worktree,
                ) : "",
                show_panels ? post_form("/rerun_mwe";
                    label="Rerun", btn_class="btn", hx_target="#proposals-list", hx_swap="innerHTML",
                    script, worktree,
                ) : "",
            ),
            begin
                script_lines = split(read(script, String), '\n')
                nlines = length(script_lines)
                h.div(class="mwe-script-wrap")(
                    h.div(class="mwe-line-nums")(join(1:nlines, "\n")),
                    h.pre()(h.code(; class="language-julia")(_html_escape(join(script_lines, '\n')))),
                )
            end,
            show_panels ? h.div(class="mwe-grid"; style="margin-top:0.5rem")(
                !isnothing(main_dir) ? _render_mwe_panel("main", main_result, script, main_dir) : "",
                _render_mwe_panel("worktree", worktree_result, script, worktree),
            ) : "",
        )
    end

    _render_mwe(slug, worktree, proposals_path, status="pending") = begin
        scripts = _find_mwe_scripts(slug, proposals_path)
        isempty(scripts) && return ""
        main_dir = _repo_main_dir(worktree)
        any_results = any(scripts) do s
            r1 = isnothing(main_dir) ? nothing : _mwe_result(s, main_dir)
            r2 = _mwe_result(s, worktree)
            !isnothing(r1) || !isnothing(r2)
        end

        closed_statuses = ("approved", "rejected", "skipped")
        should_open = status ∉ closed_statuses
        mwe_details = should_open ? h.details(class="mwe-section"; open="") : h.details(class="mwe-section")
        mwe_details(
            h.summary("MWE ($(length(scripts)) script$(length(scripts) == 1 ? "" : "s"))"),
            [_render_single_mwe(s, worktree, main_dir) for s in scripts]...,
            # Run all button
            !any_results && length(scripts) > 1 ? post_form("/run_all_mwe";
                label="Run All", btn_class="btn btn-approve", hx_target="#proposals-list", hx_swap="innerHTML",
                slug, worktree, proposals_path,
            ) : "",
        )
    end

    @post run_mwe(; script="", worktree="", _filter="all") = begin
        main_dir = _repo_main_dir(worktree)
        !isnothing(main_dir) && _mwe_result(script, main_dir)
        !isempty(worktree) && _mwe_result(script, worktree)
        _render_list(_filter) |> to_response
    end

    @post rerun_mwe(; script="", worktree="", _filter="all") = begin
        main_dir = _repo_main_dir(worktree)
        # Write marker files so streaming shows "Restarting..."
        for d in [main_dir, worktree]
            isnothing(d) && continue
            isempty(d) && continue
            p = _mwe_output_path(script, d)
            open(p, "w") do f; println(f, "# Restarting MWE..."); end
        end
        # Evict cache + restart computation synchronously.
        # fetchindex with force=true pops old entry and spawns a new Task internally,
        # returning immediately. _render_list then sees in-progress Tasks → "running..." panels.
        !isnothing(main_dir) && fetchindex(_async_issues.mwe, script, main_dir; force=true) do rv, _; rv isa Task ? nothing : rv; end
        !isempty(worktree) && fetchindex(_async_issues.mwe, script, worktree; force=true) do rv, _; rv isa Task ? nothing : rv; end
        _render_list(_filter) |> to_response
    end

    @post run_all_mwe(; slug="", worktree="", proposals_path="", _filter="all") = begin
        scripts = _find_mwe_scripts(slug, proposals_path)
        for s in scripts
            main_dir = _repo_main_dir(worktree)
            !isnothing(main_dir) && _mwe_result(s, main_dir)
            !isempty(worktree) && _mwe_result(s, worktree)
        end
        _render_list(_filter) |> to_response
    end

    _render_diff(worktree, status="pending") = begin
        diff_text = _worktree_diff(worktree)
        # Auto-refresh stale diffs (cached from old code or empty)
        if !isnothing(diff_text) && startswith(diff_text, "(")
            fetchindex(_async_issues.diff, worktree; force=true) do rv, _; rv isa Task ? nothing : rv; end
            diff_text = nothing  # show loading state
        end
        closed_statuses = ("approved", "rejected", "skipped")
        should_open = status ∉ closed_statuses
        if isnothing(diff_text)
            h.div(class="diff-viewer")(
                h.span(; class="issue-loading",
                    hx_get=@query_url(worktree_diff(; path=worktree)),
                    hx_trigger="every 2s",
                    hx_swap="outerHTML",
                )("Loading diff..."),
            )
        else
            nfiles = count(l -> startswith(l, "diff --git"), eachline(IOBuffer(diff_text)))
            diff_details = should_open ? h.details(class="diff-viewer"; open="") : h.details(class="diff-viewer")
            diff_details(
                h.summary("Diff ($nfiles file$(nfiles == 1 ? "" : "s"))"),
                render_diff_html(diff_text),
            )
        end
    end

    @get worktree_diff(; path="") = begin
        isempty(path) && return h.span()("No worktree path")
        diff_text = _worktree_diff(path)
        if isnothing(diff_text)
            h.span(; class="issue-loading",
                hx_get=@query_url(worktree_diff(; path)),
                hx_trigger="every 2s",
                hx_swap="outerHTML",
            )("Loading diff...")
        else
            nfiles = count(l -> startswith(l, "diff --git"), eachline(IOBuffer(diff_text)))
            h.details(class="diff-viewer"; open="")(
                h.summary("Diff ($nfiles file$(nfiles == 1 ? "" : "s"))"),
                render_diff_html(diff_text),
            )
        end
    end

    @post refresh_diff(; path="") = begin
        isempty(path) && return h.span()("No path")
        fetchindex(_async_issues.diff, path; force=true) do rv, _
            rv isa Task ? nothing : rv
        end
        h.div(class="diff-viewer")(
            h.span(; class="issue-loading",
                hx_get=@query_url(worktree_diff(; path)),
                hx_trigger="every 2s",
                hx_swap="outerHTML",
            )("Refreshing diff..."),
        )
    end

    _render_proposal(p) = begin
        fname = basename(p.path)
        slug = replace(fname, ".md" => "")
        status = get(p.yaml, "status", "pending")
        issue = get(p.yaml, "issue", "")
        pr = get(p.yaml, "pr", "")
        pr = pr in ("null", "") ? nothing : pr
        worktree = get(p.yaml, "worktree", "")
        body_html = Markdown.html(Markdown.parse(p.body))
        # Derive repo name from path: .../RepoName/proposals/slug.md
        repo_name = basename(dirname(dirname(p.path)))

        p.yaml["_path"] = p.path
        comments = parse_comments(p.yaml)

        meta_parts = []
        !isempty(issue) && push!(meta_parts, h.span()("Issue: ", h.a(; href=issue, target="_blank")(issue)))
        !isnothing(pr) && push!(meta_parts, h.span()(" | PR: ", h.a(; href=pr, target="_blank")(pr)))
        !isempty(worktree) && push!(meta_parts, h.span()(" | Worktree: ", h.code(worktree)))

        # Build action buttons from config
        action_buttons = map(_responses()) do resp
            label = get(resp, "label", "?")
            new_status = get(resp, "status", "pending")
            cmt = get(resp, "comment", "")
            style = get(resp, "style", "")
            confirm = get(resp, "confirm", false)
            prompt = get(resp, "prompt", false)
            action = get(resp, "action", "")

            cls = isempty(style) ? "" : "btn-$style"
            if action == "pr_preview"
                # Load PR form inline in the card
                h.button(; class="btn $cls",
                    hx_get="/pr_form/$slug",
                    hx_target="#pr-form-$slug",
                    hx_swap="innerHTML",
                )(label)
            elseif prompt
                # "prompt" buttons: hx-include grabs the text input (name=msg) as formdata
                base_url = "/respond/$slug/$new_status"
                h.button(; class="btn $cls", hx_post=base_url,
                    hx_target="#proposals-list", hx_swap="innerHTML",
                    hx_include="#comment-input-$slug",
                )(label)
            else
                base_url = "/respond/$slug/$new_status"
                post_form(base_url;
                    label, btn_class="btn $cls",
                    hx_target="#proposals-list", hx_swap="innerHTML",
                    confirm=confirm ? "$label this proposal?" : "",
                    msg=cmt,
                )
            end
        end

        # Quick comment buttons
        quick_buttons = map(_quick_comments()) do qc
            msg = qc isa AbstractDict ? get(qc, "msg", "") : string(qc)
            qstatus = qc isa AbstractDict ? get(qc, "status", "") : ""
            color_cls = if contains(qstatus, "changes")
                "btn-quick-changes"
            elseif contains(qstatus, "skip")
                "btn-quick-skip"
            elseif contains(qstatus, "approve") || contains(qstatus, "open")
                "btn-quick-approve"
            elseif contains(qstatus, "reject")
                "btn-quick-reject"
            else
                ""
            end
            post_url = isempty(qstatus) ? "/add_comment/$slug" : "/respond/$slug/$qstatus"
            post_form(post_url;
                label=msg, btn_class="btn btn-quick $color_cls",
                hx_target="#proposals-list", hx_swap="innerHTML",
                msg,
            )
        end

        h.details(; class="proposal-card status-$status", id="proposal-$slug", open="")(
            h.summary(class="card-header")(
                h.div(class="proposal-header")(
                    h.div(class="proposal-title")(
                        h.span(; style="font-size:0.75em;color:#666;font-weight:400;margin-right:0.5em")(repo_name),
                        h.a(; href="/proposal/$slug")(fname),
                    ),
                    h.div(; style="display:flex;align-items:center;gap:0.5rem")(
                        h.button(; class="btn", style="font-size:0.7rem;padding:0.1rem 0.4rem",
                            hx_post="/refresh_card/$slug",
                            hx_target="#proposals-list",
                            hx_swap="innerHTML",
                            onclick="event.stopPropagation()",
                        )("↻"),
                        status_badge(status),
                    ),
                ),
                !isempty(meta_parts) ? h.div(class="proposal-meta")(meta_parts...) : "",
            ),
            h.div(class="card-body")(
                # Left column — summary + actions
                h.div(class="card-left")(
                    h.div(class="proposal-body")(body_html),
                    !isempty(comments) ? h.div(class="comments")(
                        h.strong("Comments:"),
                        [h.div(class="comment")(c) for c in comments]...,
                    ) : "",
                    h.div(class="actions")(
                        h.div(class="actions-row")(action_buttons...),
                        h.div(class="actions-row")(
                            post_form("/add_comment/$slug",
                                h.input(; type="text", name="msg", id="comment-input-$slug",
                                    placeholder="Add a note...");
                                label="Comment", form_class="comment-form",
                                hx_target="#proposals-list", hx_swap="innerHTML",
                            ),
                        ),
                        h.div(class="actions-row")(quick_buttons...),
                    ),
                ),
                # Right column — issue discussion + PR discussion
                h.div(class="card-right")(
                    !isempty(issue) ? _render_discussion(issue) : "",
                    !isnothing(pr) ? h.div(; style="margin-top:0.75rem;padding-top:0.75rem;border-top:1px solid #d0d7de")(
                        h.div(; style="font-size:0.85rem;font-weight:600;margin-bottom:0.5rem")(
                            "Pull Request ",
                            h.a(; href=pr, target="_blank", style="font-weight:400;font-size:0.8rem")(pr),
                        ),
                        _render_discussion(pr),
                    ) : "",
                ),
                # Footer — PR form + diff spans full width
                h.div(class="card-footer")(
                    h.div(; id="pr-form-$slug")(),
                    !isempty(worktree) ? h.div()(
                        _render_mwe(slug, worktree, p.path, status),
                        _render_diff(worktree, status),
                    ) : "",
                ),
            ),
        )
    end

    _render_list(filter_val) = begin
        ps = proposals
        if filter_val != "all"
            ps = [p for p in ps if get(p.yaml, "status", "pending") == filter_val]
        end

        all_statuses = ["all", "pending", "open-pr", "pr-open", "approved", "changes-requested", "rejected", "skipped"]
        filter_links_list = []
        for f in all_statuses
            n = f == "all" ? length(proposals) : count(p -> get(p.yaml, "status", "pending") == f, proposals)
            (n == 0 && f != "all" && f != filter_val) && continue
            push!(filter_links_list, h.a(;
                href=@query_url(index(; filter=f)),
                hx_get=@query_url(index(; filter=f)),
                hx_target="#proposals-list", hx_swap="innerHTML",
                hx_push_url=@query_url(index(; filter=f)),
                class=(f == filter_val ? "active" : ""),
            )("$f ($n)"))
        end

        vcat(
            [h.input(; type="hidden", id="current-filter", name="_filter", value=filter_val)],
            [h.div(class="filter-bar")(filter_links_list...)],
            isempty(ps) ? [h.p("No proposals with status: $filter_val")] :
                [_render_proposal(p) for p in ps],
        )
    end

    _page(content_node) = htmx(
        h.head(
            h.title("Issue Review"),
            h.meta(; charset="utf-8"),
            h.meta(; name="viewport", content="width=device-width, initial-scale=1"),
            h.style(css),
            h.link(; rel="stylesheet", href="https://cdn.jsdelivr.net/npm/prismjs@1.29.0/themes/prism.min.css"),
            h.style("""
                .diff-table code[class*="language-"] { background: none; padding: 0; font-size: inherit; }
                .diff-add code[class*="language-"] { background: none; }
                .diff-del code[class*="language-"] { background: none; }
                .diff-table .token.comment { color: #6a737d; }
                .diff-table .token.string { color: #032f62; }
                .diff-table .token.keyword { color: #d73a49; }
                .diff-table .token.function { color: #6f42c1; }
                .diff-table .token.number { color: #005cc5; }
                .diff-table .token.operator { color: #d73a49; }
                .diff-table .token.punctuation { color: #24292e; }
            """),
        ),
        h.body(
            h.div(class="container")(content_node),
            h.script(; src="https://cdn.jsdelivr.net/npm/prismjs@1.29.0/prism.min.js")(),
            h.script(; src="https://cdn.jsdelivr.net/npm/prismjs@1.29.0/components/prism-julia.min.js")(),
            h.script(; src="https://cdn.jsdelivr.net/npm/prismjs@1.29.0/components/prism-toml.min.js")(),
            h.script(; src="https://cdn.jsdelivr.net/npm/prismjs@1.29.0/components/prism-bash.min.js")(),
            h.script(; src="https://cdn.jsdelivr.net/npm/prismjs@1.29.0/components/prism-yaml.min.js")(),
            h.script(; src="https://cdn.jsdelivr.net/npm/prismjs@1.29.0/components/prism-json.min.js")(),
            h.script("""
                function highlightCode() {
                    document.querySelectorAll('code[class*="language-"]:not([data-highlighted])').forEach(function(code) {
                        code.dataset.highlighted = '1';
                        Prism.highlightElement(code);
                    });
                }
                highlightCode();
                document.body.addEventListener('htmx:afterSettle', function(evt) {
                    highlightCode();
                    // Only flash after user actions (POST), not background polling (GET)
                    var verb = evt.detail && evt.detail.requestConfig && evt.detail.requestConfig.verb;
                    if (verb === 'post') {
                        document.querySelectorAll('.proposal-card').forEach(function(card) {
                            card.classList.add('just-updated');
                            card.addEventListener('animationend', function() {
                                card.classList.remove('just-updated');
                            }, {once: true});
                        });
                    }
                });
                document.body.addEventListener('toggle', function(e) {
                    if (e.target.open) setTimeout(highlightCode, 10);
                }, true);
            """),
        );
        htmx_version="2.0.8", hyperscript_version=nothing, pico_version=nothing,
    )

    _agent_instructions_md = begin
        parts = String[]
        # Root-level CLAUDE.md (shared instructions)
        root_md = joinpath(config_dir(), "CLAUDE.md")
        isfile(root_md) && push!(parts, read(root_md, String))
        # Per-repo CLAUDE.md files
        for rd in repo_dirs()
            rd == config_dir() && continue  # skip root, already included
            repo_md = joinpath(rd, "CLAUDE.md")
            if isfile(repo_md)
                push!(parts, "---\n\n# $(basename(rd))\n\n" * read(repo_md, String))
            end
        end
        join(parts, "\n\n")
    end

    @get instructions = begin
        md = _agent_instructions_md
        if wants_markdown(req)
            markdown_response(md)
        else
            _page(h.div(class="container")(
                h.div(class="nav-links")(
                    h.a(; href="/")("← Back to reviews"),
                ),
                h.div(class="proposal-body")(Markdown.html(Markdown.parse(md))),
            )) |> to_response
        end
    end

    @get proposal(slug) = begin
        path = _find_proposal(slug)
        isnothing(path) && return to_response(h.p("Not found: $slug"))
        p = parse_proposal(path)
        content = h.div()(
            h.h1("Issue Review ", h.small("proposals → review → PR")),
            h.div(class="nav-links")(
                h.a(; href="/")("← All proposals"),
            ),
            h.div(; id="proposals-list", hx_include="#current-filter")(
                h.input(; type="hidden", id="current-filter", name="_filter", value="all"),
                _render_proposal(p),
            ),
        )
        _page(content) |> to_response
    end

    @get index(; filter="all") = begin
        md = _agent_instructions_md
        content = h.div()(
            h.h1("Issue Review ", h.small("proposals → review → PR")),
            h.div(class="nav-links")(
                h.a(; href="/config", hx_get="/config", hx_target="#proposals-list",
                    hx_push_url="/config")("Configure responses"),
                h.a(; href="/instructions")("Agent instructions"),
            ),
            !isempty(md) ? h.details(class="agent-instructions")(
                h.summary(h.strong("Agent workflow"), " ", h.span(; style="font-weight:normal;font-size:0.8em;color:#666")("(click to expand)")),
                h.div(; id="instructions-content")(
                    h.div(; style="margin-bottom:0.5rem;display:flex;gap:0.5rem")(
                        h.button(; class="btn", style="font-size:0.75rem;padding:0.15rem 0.5rem",
                            onclick="var c=document.getElementById('instructions-content'); var md=c.querySelector('.instructions-md'); var html=c.querySelector('.instructions-html'); if(md.style.display==='none'){md.style.display='';html.style.display='none';this.textContent='Show rendered'}else{md.style.display='none';html.style.display='';this.textContent='Show markdown'}")("Show rendered"),
                        h.button(; class="btn", style="font-size:0.75rem;padding:0.15rem 0.5rem",
                            onclick="var md=document.getElementById('instructions-content').querySelector('.instructions-md'); navigator.clipboard.writeText(md.textContent).then(function(){this.textContent='Copied!';setTimeout(function(){this.textContent='Copy markdown'}.bind(this),1500)}.bind(this))")("Copy markdown"),
                    ),
                    h.pre(; class="instructions-md", style="font-size:0.8rem;background:#f6f8fa;padding:0.75rem;border-radius:4px;white-space:pre-wrap;word-wrap:break-word;user-select:all")(_html_escape(md)),
                    h.div(; class="instructions-html proposal-body", style="display:none")(Markdown.html(Markdown.parse(md))),
                ),
            ) : "",
            h.div(; id="proposals-list", hx_include="#current-filter")(_render_list(filter)...),
            # Poll for file changes; show banner when updates available
            h.div(; id="poll-sentinel",
                hx_get=@query_url(proposals_hash(; current_hash=_proposals_hash)),
                hx_trigger="every 5s",
                hx_swap="outerHTML",
                data_hash=_proposals_hash,
                style="display:none",
            )(),
        )
        if is_htmx(req)
            h.div(; id="proposals-list")(_render_list(filter)...) |> to_response
        else
            _page(content) |> to_response
        end
    end

    _proposals_hash = begin
        files = String[]
        for rd in repo_dirs()
            pdir = joinpath(rd, "proposals")
            isdir(pdir) || continue
            for f in readdir(pdir; join=true)
                endswith(f, ".md") && push!(files, f)
            end
        end
        sort!(files)
        parts = [string(f, ":", filesize(f), ":", mtime(f)) for f in files]
        string(hash(join(parts, "|")))
    end

    @get proposals_hash(; current_hash="") = begin
        new_hash = _proposals_hash
        changed = !isempty(current_hash) && current_hash != new_hash
        if changed
            # Show update banner — clicking it refreshes the list
            h.div(; id="poll-sentinel",
                hx_get=@query_url(proposals_hash(; current_hash=new_hash)),
                hx_trigger="every 5s",
                hx_swap="outerHTML", data_hash=new_hash,
            )(
                h.div(; id="update-banner",
                    style="position:fixed;top:0;left:0;right:0;background:#0969da;color:white;padding:0.5rem 1rem;text-align:center;cursor:pointer;z-index:100;font-size:0.9rem;",
                    hx_get=@query_url(index(; filter="all")),
                    hx_target="#proposals-list", hx_swap="innerHTML",
                    onclick="this.parentElement.style.display='none'",
                )("Proposals updated — click to refresh"),
            )
        else
            h.div(; id="poll-sentinel",
                hx_get=@query_url(proposals_hash(; current_hash=new_hash)),
                hx_trigger="every 5s",
                hx_swap="outerHTML",
                data_hash=new_hash,
                style="display:none",
            )()
        end
    end

    # --- Config page ---

    @get config = begin
        cfg = _load_config()
        cfg_json = sprint(io -> JSON.print(io, cfg, 2))
        content = h.div(class="config-section")(
            h.h3("Response Buttons & Quick Comments"),
            h.div(class="nav-links")(
                h.a(; href="/", hx_get="/", hx_target="body", hx_push_url="/")("← Back to reviews"),
            ),
            h.p(; style="font-size:0.85rem;color:#666;margin-bottom:0.75rem")(
                "Edit the JSON below. Each response has: ",
                h.code("label"), ", ", h.code("status"), " (set on click), ",
                h.code("comment"), " (written to YAML), ", h.code("style"), " (approve/reject/changes/skip), ",
                h.code("confirm"), " (ask before acting), ", h.code("prompt"), " (use the text input as comment).",
            ),
            h.form(; hx_post="/save_config", hx_target="body", hx_swap="innerHTML")(
                h.textarea(; name="config_json", rows="25")(cfg_json),
                h.br(),
                h.button(; class="btn btn-approve", type="submit")("Save"),
                " ",
                h.button(; class="btn",
                    hx_post="/config_reset", hx_target="body", hx_swap="innerHTML",
                    hx_confirm="Reset to defaults?",
                )("Reset to defaults"),
            ),
        )
        if is_htmx(req)
            content |> to_response
        else
            _page(h.div(class="container")(content)) |> to_response
        end
    end

    @post save_config(; config_json="") = begin
        if isempty(config_json)
            return to_response(h.p(; style="color:red")("Empty config"))
        end
        cfg = try; JSON.parse(config_json); catch e
            return to_response(h.p(; style="color:red")("Invalid JSON: $(sprint(showerror, e))"))
        end
        _save_config(cfg)
        hx_response(""; redirect="/config")
    end

    @post config_reset = begin
        cfg = Dict("responses" => _default_responses(), "quick_comments" => _default_quick_comments())
        _save_config(cfg)
        hx_response(""; redirect="/config")
    end

    # --- Action endpoints ---

    _find_proposal(slug) = begin
        for rd in repo_dirs()
            path = joinpath(rd, "proposals", "$slug.md")
            isfile(path) && return path
        end
        nothing
    end

    @post refresh_card(slug) = begin
        path = _find_proposal(slug)
        isnothing(path) && return to_response(h.p("Not found: $slug"))
        p = parse_proposal(path)
        issue = get(p.yaml, "issue", "")
        pr_val = get(p.yaml, "pr", "")
        pr_val = pr_val in ("null", "") ? nothing : pr_val
        worktree = get(p.yaml, "worktree", "")
        # Evict all caches for this card
        !isempty(issue) && fetchindex(_async_issues.discussion, issue; force=true) do rv, _; rv isa Task ? nothing : rv; end
        !isnothing(pr_val) && fetchindex(_async_issues.discussion, pr_val; force=true) do rv, _; rv isa Task ? nothing : rv; end
        !isempty(worktree) && fetchindex(_async_issues.diff, worktree; force=true) do rv, _; rv isa Task ? nothing : rv; end
        @info "REFRESH_CARD evicted caches for $slug"
        # Re-render just the card body — need to call _render_proposal and extract the card-body
        # Simpler: re-render the whole list
        _render_list("all") |> to_response
    end

    _do_respond(slug, new_status, msg, _filter) = begin
        path = _find_proposal(slug)
        isnothing(path) && return to_response(h.p("Not found: $slug"))
        update_yaml!(path, "status", new_status)
        !isempty(msg) && add_comment!(path, msg)
        _render_list(_filter) |> to_response
    end

    @post respond(slug, new_status; msg="", _filter="all") = _do_respond(slug, new_status, msg, _filter)

    @post add_comment(slug; msg="", _filter="all") = begin
        path = _find_proposal(slug)
        isnothing(path) && return to_response(h.p("Not found: $slug"))
        !isempty(msg) && add_comment!(path, msg)
        _render_list(_filter) |> to_response
    end

    # --- PR creation ---

    _generate_pr_body_claude(p) = begin
        slug = replace(basename(p.path), ".md" => "")
        issue = get(p.yaml, "issue", "")
        worktree = get(p.yaml, "worktree", "")
        lines = String[]

        # Proposal description
        push!(lines, p.body)
        push!(lines, "")

        # MWE section
        scripts = _find_mwe_scripts(slug, p.path)
        if !isempty(scripts)
            push!(lines, "## MWE")
            push!(lines, "")
            for script in scripts
                sname = basename(script)
                push!(lines, "### `$sname`")
                push!(lines, "")
                push!(lines, "````julia")
                push!(lines, read(script, String))
                push!(lines, "````")
                push!(lines, "")
                # Include outputs
                for label in ["main", "worktree"]
                    out_path = _mwe_output_path(script, label == "main" ? _repo_main_dir(worktree) : worktree)
                    isnothing(out_path) && continue
                    if isfile(out_path)
                        push!(lines, "**$label output:**")
                        push!(lines, "````")
                        push!(lines, read(out_path, String))
                        push!(lines, "````")
                        push!(lines, "")
                    end
                end
            end
        end

        # Issue link
        !isempty(issue) && push!(lines, "Fixes $issue")
        push!(lines, "")

        join(lines, "\n")
    end

    _generate_pr_title(p) = begin
        # Extract a short title from the proposal filename or first heading
        slug = replace(basename(p.path), ".md" => "")
        issue_num = match(r"^(\d+)", slug)
        # Try to get title from first ## heading in body
        title_m = match(r"^##\s+(.+)"m, p.body)
        title = isnothing(title_m) ? replace(slug, "-" => " ") : title_m.captures[1]
        isnothing(issue_num) ? title : "Fix #$(issue_num.captures[1]): $title"
    end

    @get pr_form(slug) = begin
        @info "PR_FORM GET" slug
        path = _find_proposal(slug)
        isnothing(path) && return to_response(h.p("Not found: $slug"))
        p = parse_proposal(path)
        worktree = get(p.yaml, "worktree", "")
        issue = get(p.yaml, "issue", "")
        existing_pr = get(p.yaml, "pr", "")
        existing_pr = existing_pr in ("null", "") ? nothing : existing_pr
        is_update = !isnothing(existing_pr)

        pr_title = _generate_pr_title(p)
        claude_body = _generate_pr_body_claude(p)

        repo_m = match(r"github\.com/([^/]+/[^/]+)", issue)
        repo_slug = isnothing(repo_m) ? "" : repo_m.captures[1]

        branch = ""
        if !isempty(worktree) && isdir(worktree)
            try; branch = strip(read(setenv(`git rev-parse --abbrev-ref HEAD`; dir=worktree), String)); catch; end
        end

        action_label = is_update ? "Update PR Description" : "Create Draft PR"

        h.div(; style="border:1px solid #d0d7de;border-radius:6px;padding:1rem;margin-bottom:0.75rem;background:white")(
            h.div(; style="display:flex;justify-content:space-between;align-items:center;margin-bottom:0.75rem")(
                h.h3(; style="margin:0")(is_update ? "Update PR" : "Create Draft PR"),
                h.button(; class="btn", style="font-size:0.75rem",
                    onclick="this.closest('[id^=\"pr-form-\"]').innerHTML=''")("Cancel"),
            ),
            is_update ? h.p(; style="font-size:0.85rem;color:#666;margin-bottom:0.5rem")(h.a(; href=existing_pr, target="_blank")(existing_pr)) : "",
            !isempty(repo_slug) ? h.p(; style="font-size:0.8rem;color:#888;margin-bottom:0.5rem")("Repo: ", h.code(repo_slug), !isempty(branch) ? h.span()(" | Branch: ", h.code(branch)) : "") : "",
            h.form(; hx_post="/create_pr/$slug", hx_target="#pr-form-$slug", hx_swap="innerHTML")(
                h.label(; style="font-size:0.85rem;font-weight:600")("Title"),
                h.input(; type="text", name="pr_title", value=pr_title,
                    style="width:100%;padding:0.3rem;font-size:0.9rem;border:1px solid #ccc;border-radius:4px;margin:0.3rem 0 0.75rem"),
                h.label(; style="font-size:0.85rem;font-weight:600")("Your comment ", h.small(; style="font-weight:400;color:#888")("(top of PR body)")),
                h.textarea(; name="human_comment", rows="3",
                    style="width:100%;padding:0.3rem;font-family:inherit;font-size:0.85rem;border:1px solid #ccc;border-radius:4px;margin:0.3rem 0 0.75rem",
                    placeholder="Optional: add context, notes for reviewers...")("I'll check the changes before marking it as ready for review."),
                h.div(; style="margin-bottom:0.75rem")(
                    h.label(; style="font-size:0.85rem;font-weight:600")("Auto-generated content ", h.small(; style="font-weight:400;color:#888")("(will appear below divider on GitHub)")),
                    h.pre(; style="border:1px solid #d0d7de;border-radius:4px;padding:0.75rem;background:#fafbfc;margin-top:0.3rem;font-size:0.8rem;white-space:pre-wrap;word-wrap:break-word;max-height:400px;overflow-y:auto")(_html_escape(claude_body)),
                ),
                h.textarea(; name="claude_body", style="display:none")(claude_body),
                h.input(; type="hidden", name="repo_slug", value=repo_slug),
                h.input(; type="hidden", name="worktree", value=worktree),
                h.input(; type="hidden", name="branch", value=branch),
                h.input(; type="hidden", name="existing_pr", value=isnothing(existing_pr) ? "" : existing_pr),
                h.div(; style="display:flex;gap:0.5rem")(
                    h.button(; class="btn btn-approve", type="submit")(action_label),
                ),
            ),
        )
    end

    @get pr_preview(slug) = begin
        path = _find_proposal(slug)
        isnothing(path) && return to_response(h.p("Not found: $slug"))
        p = parse_proposal(path)
        worktree = get(p.yaml, "worktree", "")
        issue = get(p.yaml, "issue", "")
        existing_pr = get(p.yaml, "pr", "")
        existing_pr = existing_pr in ("null", "") ? nothing : existing_pr
        is_update = !isnothing(existing_pr)

        pr_title = _generate_pr_title(p)
        claude_body = _generate_pr_body_claude(p)

        # Detect repo for gh command
        repo_m = match(r"github\.com/([^/]+/[^/]+)", issue)
        repo_slug = isnothing(repo_m) ? "" : repo_m.captures[1]

        # Detect branch name from worktree
        branch = ""
        if !isempty(worktree) && isdir(worktree)
            try
                branch = strip(read(setenv(`git rev-parse --abbrev-ref HEAD`; dir=worktree), String))
            catch; end
        end

        action_label = is_update ? "Update PR Description" : "Create Draft PR"
        heading = is_update ? h.h2("Update PR: ", h.a(; href=existing_pr, target="_blank")(existing_pr)) :
                              h.h2("Create Draft PR: ", h.code(slug))

        content = h.div()(
            h.div(class="nav-links")(
                h.a(; href="/", hx_get="/", hx_target="body", hx_push_url="/")("← Back to reviews"),
            ),
            heading,
            !isempty(repo_slug) ? h.p(; style="font-size:0.85rem;color:#666")("Repo: ", h.code(repo_slug), !isempty(branch) ? h.span()(" | Branch: ", h.code(branch)) : "") : "",
            h.div(class="config-section")(
                h.h3("PR Title"),
                h.form(; hx_post="/create_pr/$slug", hx_target="body", hx_swap="innerHTML")(
                    h.input(; type="text", name="pr_title", value=pr_title,
                        style="width:100%;padding:0.4rem;font-size:0.95rem;border:1px solid #ccc;border-radius:4px;margin-bottom:0.75rem"),
                    h.h3("Your comment ", h.small(; style="font-weight:400;color:#888")("(appears at the top of the PR body)")),
                    h.textarea(; name="human_comment", rows="4",
                        style="width:100%;padding:0.5rem;font-family:inherit;font-size:0.9rem;border:1px solid #ccc;border-radius:4px;margin-bottom:0.75rem",
                        placeholder="Optional: add context, notes for reviewers...")("I'll check the changes before marking it as ready for review."),
                    h.h3("Auto-generated content ", h.small(; style="font-weight:400;color:#888")("(preview — appears below the divider)")),
                    h.div(; style="border:1px solid #d0d7de;border-radius:6px;padding:1rem;background:#fafbfc;margin-bottom:1rem")(
                        h.div(class="proposal-body")(Markdown.html(Markdown.parse(claude_body))),
                    ),
                    h.textarea(; name="claude_body", style="display:none")(_html_escape(claude_body)),
                    h.input(; type="hidden", name="repo_slug", value=repo_slug),
                    h.input(; type="hidden", name="worktree", value=worktree),
                    h.input(; type="hidden", name="branch", value=branch),
                    h.input(; type="hidden", name="existing_pr", value=isnothing(existing_pr) ? "" : existing_pr),
                    h.div(; style="display:flex;gap:0.5rem")(
                        h.button(; class="btn btn-approve", type="submit")(action_label),
                        h.a(; href="/", class="btn")("Cancel"),
                    ),
                ),
            ),
        )
        _page(h.div(class="container")(content)) |> to_response
    end

    _build_pr_body(human_comment, claude_body) = begin
        body_parts = String[]
        if !isempty(human_comment)
            push!(body_parts, human_comment)
            push!(body_parts, "")
        end
        push!(body_parts, "*Human content above*")
        push!(body_parts, "")
        push!(body_parts, "---")
        push!(body_parts, "")
        push!(body_parts, "*Claude content below*")
        push!(body_parts, "")
        push!(body_parts, claude_body)
        join(body_parts, "\n")
    end

    @post create_pr(slug; pr_title="", human_comment="", claude_body="", repo_slug="", worktree="", branch="", existing_pr="") = begin
        @info "CREATE_PR" slug pr_title existing_pr repo_slug branch worktree length(claude_body)
        path = _find_proposal(slug)
        isnothing(path) && return to_response(h.p("Not found: $slug"))
        is_update = !isempty(existing_pr)
        @info "CREATE_PR" is_update path

        full_body = _build_pr_body(human_comment, claude_body)
        @info "CREATE_PR step 2: body built" length(full_body)

        # Push branch if needed (skip for updates — branch already on remote)
        result_msg = ""
        if !is_update && !isempty(worktree) && isdir(worktree)
            @info "CREATE_PR pushing branch" branch
            try
                proc = run(pipeline(setenv(`git push -u origin $branch`; dir=worktree); stdout=devnull, stderr=devnull); wait=false)
                # Timeout after 30 seconds
                t = Timer(30)
                @async begin; wait(t); process_running(proc) && kill(proc); end
                wait(proc)
                close(t)
                @info "CREATE_PR push done" proc.exitcode
                proc.exitcode != 0 && (result_msg = "Warning: git push exited with $(proc.exitcode)\n")
            catch e
                @info "CREATE_PR push failed" sprint(showerror, e)
                result_msg = "Warning: git push failed: $(sprint(showerror, e))\n"
            end
        end

        @info "CREATE_PR step 4: is_update=$is_update"
        if is_update
            # Update existing PR description
            pr_m = match(r"/pull/(\d+)", existing_pr)
            if !isnothing(pr_m) && !isempty(repo_slug)
                pr_num = pr_m.captures[1]
                try
                    body_file = tempname()
                    write(body_file, full_body)
                    @info "CREATE_PR running gh pr edit" pr_num repo_slug pr_title body_file
                    output = read(`gh pr edit $pr_num --repo $repo_slug --title $pr_title --body-file $body_file`, String)
                    @info "CREATE_PR gh pr edit output" output
                    rm(body_file; force=true)
                    add_comment!(path, "PR description updated")
                    result_msg *= "PR description updated: $existing_pr"
                catch e
                    @info "CREATE_PR gh pr edit FAILED" sprint(showerror, e)
                    result_msg *= "Error updating PR: $(sprint(showerror, e))"
                end
            else
                result_msg *= "Could not parse PR number from: $existing_pr"
            end
        elseif !isempty(repo_slug) && !isempty(branch)
            # Create new draft PR
            try
                body_file = tempname()
                write(body_file, full_body)
                pr_url = strip(read(setenv(`gh pr create --draft --repo $repo_slug --title $pr_title --body-file $body_file --head $branch`; dir=worktree), String))
                rm(body_file; force=true)
                update_yaml!(path, "pr", pr_url)
                update_yaml!(path, "status", "pr-open")
                add_comment!(path, "Draft PR created: $pr_url")
                result_msg *= "Draft PR created: $pr_url"
            catch e
                result_msg *= "Error creating PR: $(sprint(showerror, e))"
            end
        else
            result_msg = "Missing repo_slug or branch — cannot create PR"
        end

        # Inline result
        success = !contains(result_msg, "Error") && !contains(result_msg, "Missing") && !contains(result_msg, "Could not")
        color = success ? "#1a7f37" : "#cf222e"
        h.div(; style="padding:0.75rem;border:1px solid $(success ? "#2da44e" : "#cf222e");border-radius:6px;background:$(success ? "#dafbe1" : "#ffebe9");margin-bottom:0.75rem")(
            h.p(; style="font-size:0.9rem;color:$color;margin:0")(result_msg),
            success ? h.p(; style="font-size:0.8rem;color:#666;margin:0.3rem 0 0")(
                "Reload the page to see updated status.",
            ) : "",
        ) |> to_response
    end
end

function __init__()
    route!(AppContext())
end

end # module IssueReviewWeb
