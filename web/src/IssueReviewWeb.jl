module IssueReviewWeb

using HTMXObjects
using IssueReview
using Markdown
using Dates
using JSON

proposals_dir() = IssueReview.proposals_dir()
config_dir() = dirname(proposals_dir())

# --- Async GitHub issue fetching ---

function _fetch_issue_discussion(issue_url)
    m = match(r"github\.com/([^/]+/[^/]+)/issues/(\d+)", issue_url)
    isnothing(m) && return Dict("error" => "could not parse issue URL")
    repo_slug, issue_num = m.captures
    try
        raw = strip(read(`gh issue view $issue_num --repo $repo_slug --json title,body,comments,author,createdAt,labels --comments`, String))
        JSON.parse(raw)
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

    h.div()(nodes...)
end

function _fetch_worktree_diff(worktree_path)
    isdir(worktree_path) || return "(worktree not found: $worktree_path)"
    try
        diff = read(setenv(`git diff HEAD`; dir=worktree_path), String)
        isempty(diff) && return "(no changes in worktree)"
        diff
    catch e
        "Error reading diff: $(sprint(showerror, e))"
    end
end

@dynamicstruct struct AsyncIssueData
    discussion[issue_url] = _fetch_issue_discussion(issue_url)
    diff[worktree_path] = _fetch_worktree_diff(worktree_path)
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

# --- Responses config (editable via web UI) ---

_default_responses() = [
    Dict("label"=>"Open PR", "status"=>"open-pr", "comment"=>"APPROVED. Open a DRAFT PR (gh pr create --draft). Include a concise but accurate description of all changes in the PR body. Do NOT merge — do NOT mark as ready for review — I will review the PR on GitHub and merge myself.", "style"=>"approve", "confirm"=>false, "prompt"=>false),
    Dict("label"=>"Open PR + note", "status"=>"open-pr", "comment"=>"", "style"=>"approve", "confirm"=>false, "prompt"=>true),
    Dict("label"=>"Revise", "status"=>"changes-requested", "comment"=>"", "style"=>"changes", "confirm"=>false, "prompt"=>true),
    Dict("label"=>"Reject", "status"=>"rejected", "comment"=>"REJECTED. Do not pursue this issue. Do not open a PR.", "style"=>"reject", "confirm"=>true, "prompt"=>false),
    Dict("label"=>"Skip", "status"=>"skipped", "comment"=>"SKIPPED. Move on to the next issue. Do not spend more time on this.", "style"=>"skip", "confirm"=>false, "prompt"=>false),
    Dict("label"=>"Reset", "status"=>"pending", "comment"=>"", "style"=>"", "confirm"=>true, "prompt"=>false),
]

_default_quick_comments() = [
    Dict("msg"=>"Looks good but needs tests.", "status"=>"changes-requested"),
    Dict("msg"=>"Simplify — this can be a one-liner.", "status"=>"changes-requested"),
    Dict("msg"=>"Check if there's an existing PR for this.", "status"=>""),
    Dict("msg"=>"Not urgent, deprioritize.", "status"=>"skipped"),
    Dict("msg"=>"Add a docstring for the new export.", "status"=>"changes-requested"),
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
    dir = proposals_dir()
    isdir(dir) || return []
    files = [f for f in readdir(dir; join=true) if endswith(f, ".md")]
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
    .proposal-card { background: white; border: 1px solid #d0d7de; border-radius: 6px; padding: 1.5rem; margin-bottom: 1rem; display: grid; grid-template-columns: 1fr 1fr; grid-template-rows: auto 1fr auto; gap: 0 1.5rem; border-left: 4px solid #d0d7de; }
    .proposal-card.status-pending { border-left-color: #888; }
    .proposal-card.status-open-pr { border-left-color: #2da44e; }
    .proposal-card.status-pr-open { border-left-color: #8250df; }
    .proposal-card.status-approved { border-left-color: #2da44e; }
    .proposal-card.status-changes-requested { border-left-color: #d29922; }
    .proposal-card.status-rejected { border-left-color: #cf222e; }
    .proposal-card.status-skipped { border-left-color: #666; }
    .proposal-card .card-header { grid-column: 1 / -1; }
    .proposal-card .card-left { min-width: 0; }
    .proposal-card .card-right { min-width: 0; overflow-y: auto; max-height: 80vh; }
    .proposal-card .card-footer { grid-column: 1 / -1; }
    @media (max-width: 1000px) { .proposal-card { grid-template-columns: 1fr; } .proposal-card .card-right { max-height: none; } }
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
    .btn-quick { background: white; border-color: #d0d7de; font-size: 0.8rem; color: #555; }
    .btn-quick:hover { background: #f0f0f0; color: #333; }
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
    .diff-viewer { margin-bottom: 0.75rem; }
    .diff-viewer summary { cursor: pointer; font-size: 0.85rem; font-weight: 600; color: #0969da; padding: 0.3rem 0; }
    .diff-file { border: 1px solid #d0d7de; border-radius: 6px; margin-bottom: 0.5rem; overflow: hidden; }
    .diff-file-header { background: #f6f8fa; padding: 0.4rem 0.75rem; font-size: 0.8rem; font-weight: 600; font-family: monospace; border-bottom: 1px solid #d0d7de; color: #24292f; }
    .diff-table { width: 100%; border-collapse: collapse; font-family: "SFMono-Regular", Consolas, monospace; font-size: 0.75rem; line-height: 1.4; table-layout: fixed; }
    .diff-table td { padding: 0 0.5rem; vertical-align: top; white-space: pre-wrap; word-wrap: break-word; }
    .diff-ln { width: 45px; min-width: 45px; text-align: right; color: #8b949e; user-select: none; padding-right: 0.5rem !important; border-right: 1px solid #d0d7de; }
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
                    hx_get=query_url("/issue_discussion"; url=issue_url),
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
                hx_get=query_url("/issue_discussion"; url),
                hx_trigger="every 2s",
                hx_swap="outerHTML",
            )("Loading issue discussion...")
        else
            h.div(class="issue-discussion")(_render_issue_data(data))
        end
    end

    _render_diff(worktree) = begin
        diff_text = _worktree_diff(worktree)
        if isnothing(diff_text)
            h.div(class="diff-viewer")(
                h.span(; class="issue-loading",
                    hx_get=query_url("/worktree_diff"; path=worktree),
                    hx_trigger="every 2s",
                    hx_swap="outerHTML",
                )("Loading diff..."),
            )
        else
            nfiles = count(l -> startswith(l, "diff --git"), eachline(IOBuffer(diff_text)))
            h.details(class="diff-viewer")(
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
                hx_get=query_url("/worktree_diff"; path),
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

    _render_proposal(p) = begin
        fname = basename(p.path)
        slug = replace(fname, ".md" => "")
        status = get(p.yaml, "status", "pending")
        issue = get(p.yaml, "issue", "")
        pr = get(p.yaml, "pr", "")
        pr = pr in ("null", "") ? nothing : pr
        worktree = get(p.yaml, "worktree", "")
        body_html = Markdown.html(Markdown.parse(p.body))

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

            cls = isempty(style) ? "" : "btn-$style"
            base_url = "/respond/$slug/$new_status"
            if prompt
                # "prompt" buttons: hx-include grabs the text input (name=msg) as formdata
                h.button(; class="btn $cls", hx_post=base_url,
                    hx_target="#proposals-list", hx_swap="innerHTML",
                    hx_include="#comment-input-$slug",
                )(label)
            else
                # Use a mini form with hidden input to avoid hx-vals quote escaping issues
                form_attrs = confirm ?
                    (; hx_post=base_url, hx_target="#proposals-list", hx_swap="innerHTML",
                       hx_confirm="$label this proposal?", style="display:inline") :
                    (; hx_post=base_url, hx_target="#proposals-list", hx_swap="innerHTML",
                       style="display:inline")
                h.form(; form_attrs...)(
                    h.input(; type="hidden", name="msg", value=cmt),
                    h.button(; class="btn $cls", type="submit")(label),
                )
            end
        end

        # Quick comment buttons
        quick_buttons = map(_quick_comments()) do qc
            # Support both old string format and new dict format
            msg = qc isa AbstractDict ? get(qc, "msg", "") : string(qc)
            qstatus = qc isa AbstractDict ? get(qc, "status", "") : ""
            if isempty(qstatus)
                h.form(; hx_post="/add_comment/$slug",
                    hx_target="#proposals-list", hx_swap="innerHTML",
                    style="display:inline",
                )(
                    h.input(; type="hidden", name="msg", value=msg),
                    h.button(; class="btn btn-quick", type="submit")(msg),
                )
            else
                h.form(; hx_post="/respond/$slug/$qstatus",
                    hx_target="#proposals-list", hx_swap="innerHTML",
                    style="display:inline",
                )(
                    h.input(; type="hidden", name="msg", value=msg),
                    h.button(; class="btn btn-quick", type="submit")(msg),
                )
            end
        end

        h.div(; class="proposal-card status-$status", id="proposal-$slug")(
            # Header — spans both columns
            h.div(class="card-header")(
                h.div(class="proposal-header")(
                    h.div(class="proposal-title")(
                        !isempty(issue) ? h.a(; href=issue, target="_blank")(fname) : fname
                    ),
                    status_badge(status),
                ),
                !isempty(meta_parts) ? h.div(class="proposal-meta")(meta_parts...) : "",
            ),
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
                        h.form(; class="comment-form",
                            hx_post="/add_comment/$slug", hx_target="#proposals-list", hx_swap="innerHTML",
                        )(
                            h.input(; type="text", name="msg", id="comment-input-$slug",
                                placeholder="Add a note..."),
                            h.button(; class="btn", type="submit")("Comment"),
                        ),
                    ),
                    h.div(class="actions-row")(quick_buttons...),
                ),
            ),
            # Right column — issue discussion
            h.div(class="card-right")(
                !isempty(issue) ? _render_discussion[issue] : "",
            ),
            # Footer — diff spans full width
            !isempty(worktree) ? h.div(class="card-footer")(_render_diff[worktree]) : "",
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
                href=query_url("/"; filter=f),
                hx_get=query_url("/"; filter=f),
                hx_target="#proposals-list", hx_swap="innerHTML",
                hx_push_url=query_url("/"; filter=f),
                class=(f == filter_val ? "active" : ""),
            )("$f ($n)"))
        end

        vcat(
            [h.div(class="filter-bar")(filter_links_list...)],
            isempty(ps) ? [h.p("No proposals with status: $filter_val")] :
                [_render_proposal[p] for p in ps],
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
                function highlightDiffs() {
                    document.querySelectorAll('.diff-code:not([data-highlighted])').forEach(function(td) {
                        td.dataset.highlighted = '1';
                        var code = td.querySelector('code');
                        if (code) Prism.highlightElement(code);
                    });
                }
                highlightDiffs();
                document.body.addEventListener('htmx:afterSettle', function() {
                    highlightDiffs();
                    // Flash cards that were just updated
                    document.querySelectorAll('.proposal-card').forEach(function(card) {
                        card.classList.add('just-updated');
                        card.addEventListener('animationend', function() {
                            card.classList.remove('just-updated');
                        }, {once: true});
                    });
                });
                document.body.addEventListener('toggle', function(e) {
                    if (e.target.open) setTimeout(highlightDiffs, 10);
                }, true);
            """),
        );
        htmx_version="2.0.8", hyperscript_version=nothing, pico_version=nothing,
    )

    @get index(; filter="all") = begin
        content = h.div()(
            h.h1("Issue Review ", h.small("proposals → review → PR")),
            h.div(class="nav-links")(
                h.a(; href="/config", hx_get="/config", hx_target="#proposals-list",
                    hx_push_url="/config")("Configure responses"),
            ),
            h.div(class="agent-instructions")(
                h.strong("Agent workflow: "),
                "Write proposals to ", h.code(proposals_dir()), ". ",
                "Each proposal must have a concise, accurate description of the proposed changes — this is what Niko reviews. ",
                "Status lifecycle: ", h.code("pending → open-pr → pr-open → approved/changes-requested/rejected"), ". ",
                "When status is ", h.code("open-pr"), ", open a ", h.strong("draft"), " PR (", h.code("gh pr create --draft"), ") and set ", h.code("pr:"), " + ", h.code("status: pr-open"), ". ",
                h.strong("Never merge — "), "only Niko merges after reviewing the PR on GitHub.",
            ),
            h.div(; id="proposals-list")(_render_list[filter]...),
            # Poll for file changes; show banner when updates available
            h.div(; id="poll-sentinel",
                hx_get=query_url("/proposals_hash"; current_hash=_proposals_hash),
                hx_trigger="every 5s",
                hx_swap="outerHTML",
                data_hash=_proposals_hash,
                style="display:none",
            )(),
        )
        if is_htmx(req)
            h.div(; id="proposals-list")(_render_list[filter]...) |> to_response
        else
            _page[content] |> to_response
        end
    end

    _proposals_hash = begin
        dir = proposals_dir()
        files = isdir(dir) ? sort([f for f in readdir(dir; join=true) if endswith(f, ".md")]) : String[]
        parts = [string(basename(f), ":", filesize(f), ":", mtime(f)) for f in files]
        string(hash(join(parts, "|")))
    end

    @get proposals_hash(; current_hash="") = begin
        new_hash = _proposals_hash
        changed = !isempty(current_hash) && current_hash != new_hash
        if changed
            # Show update banner — clicking it refreshes the list
            h.div(; id="poll-sentinel",
                hx_get=query_url("/proposals_hash"; current_hash=new_hash),
                hx_trigger="every 5s",
                hx_swap="outerHTML", data_hash=new_hash,
            )(
                h.div(; id="update-banner",
                    style="position:fixed;top:0;left:0;right:0;background:#0969da;color:white;padding:0.5rem 1rem;text-align:center;cursor:pointer;z-index:100;font-size:0.9rem;",
                    hx_get=query_url("/"; filter="all"),
                    hx_target="#proposals-list", hx_swap="innerHTML",
                    onclick="this.parentElement.style.display='none'",
                )("Proposals updated — click to refresh"),
            )
        else
            h.div(; id="poll-sentinel",
                hx_get=query_url("/proposals_hash"; current_hash=new_hash),
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
            _page[h.div(class="container")(content)] |> to_response
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

    _do_respond(slug, new_status, msg) = begin
        path = joinpath(proposals_dir(), "$slug.md")
        isfile(path) || return to_response(h.p("Not found: $slug"))
        update_yaml!(path, "status", new_status)
        !isempty(msg) && add_comment!(path, msg)
        _render_list["all"] |> to_response
    end

    @post respond(slug, new_status; msg="") = _do_respond[slug, new_status, msg]

    @post add_comment(slug; msg="") = begin
        path = joinpath(proposals_dir(), "$slug.md")
        isfile(path) || return to_response(h.p("Not found: $slug"))
        !isempty(msg) && add_comment!(path, msg)
        _render_list["all"] |> to_response
    end
end

function __init__()
    route!(AppContext())
end

end # module IssueReviewWeb
