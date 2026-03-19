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
    # Extract owner/repo and issue number from URL
    m = match(r"github\.com/([^/]+/[^/]+)/issues/(\d+)", issue_url)
    isnothing(m) && return "(could not parse issue URL)"
    repo_slug, issue_num = m.captures
    try
        raw = strip(read(`gh issue view $issue_num --repo $repo_slug --json title,body,comments --comments`, String))
        parsed = JSON.parse(raw)
        parts = String[]
        title = get(parsed, "title", "")
        body = get(parsed, "body", "")
        !isempty(title) && push!(parts, "## $title\n")
        !isempty(body) && push!(parts, body)
        comments = get(parsed, "comments", [])
        if !isempty(comments)
            push!(parts, "\n---\n### Comments ($(length(comments)))\n")
            for c in comments
                author = get(c, "author", Dict())
                login = get(author, "login", "unknown")
                created = get(c, "createdAt", "")
                cbody = get(c, "body", "")
                push!(parts, "**$login** ($created):\n$cbody\n")
            end
        end
        join(parts, "\n")
    catch e
        "Error fetching issue: $(sprint(showerror, e))"
    end
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
    Dict("label"=>"Open PR", "status"=>"open-pr", "comment"=>"LGTM. Open a PR for this — do NOT merge, I'll review the PR separately.", "style"=>"approve", "confirm"=>false, "prompt"=>false),
    Dict("label"=>"Open PR + note", "status"=>"open-pr", "comment"=>"", "style"=>"approve", "confirm"=>false, "prompt"=>true),
    Dict("label"=>"Revise", "status"=>"changes-requested", "comment"=>"", "style"=>"changes", "confirm"=>false, "prompt"=>true),
    Dict("label"=>"Reject", "status"=>"rejected", "comment"=>"Rejected — not worth pursuing.", "style"=>"reject", "confirm"=>true, "prompt"=>false),
    Dict("label"=>"Skip", "status"=>"skipped", "comment"=>"Skipping this issue for now.", "style"=>"skip", "confirm"=>false, "prompt"=>false),
]

_default_quick_comments() = [
    "Looks good but needs tests.",
    "Simplify — this can be a one-liner.",
    "Check if there's an existing PR for this.",
    "Not urgent, deprioritize.",
    "Add a docstring for the new export.",
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

@htmx struct AppContext
    req = nothing

    css = """
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; background: #f6f8fa; }
    .container { max-width: 900px; margin: 0 auto; padding: 2rem; }
    h1 { margin-bottom: 1.5rem; }
    h1 small { font-weight: 400; font-size: 0.6em; color: #666; }
    .proposal-card { background: white; border: 1px solid #d0d7de; border-radius: 6px; padding: 1.5rem; margin-bottom: 1rem; }
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
    .issue-discussion { margin-top: 0.75rem; padding: 0.75rem; background: #fafbfc; border: 1px solid #eee; border-radius: 4px; font-size: 0.85rem; max-height: 400px; overflow-y: auto; }
    .issue-discussion .markdown-body h2 { font-size: 1rem; margin: 0.5rem 0 0.3rem; }
    .issue-discussion .markdown-body h3 { font-size: 0.95rem; margin: 0.5rem 0 0.3rem; }
    .issue-discussion .markdown-body p { margin: 0.3rem 0; }
    .issue-loading { color: #888; font-style: italic; font-size: 0.85rem; }
    .diff-viewer { margin-top: 0.75rem; }
    .diff-viewer summary { cursor: pointer; font-size: 0.85rem; font-weight: 600; color: #0969da; }
    .diff-viewer pre { background: #1e1e1e; color: #d4d4d4; padding: 0.75rem; border-radius: 4px; overflow-x: auto; font-size: 0.75rem; max-height: 500px; overflow-y: auto; white-space: pre-wrap; word-wrap: break-word; }
    .diff-add { color: #3fb950; }
    .diff-del { color: #f85149; }
    .diff-hunk { color: #58a6ff; }
    .diff-file { color: #d29922; font-weight: bold; }
    """

    proposals = list_proposals()

    _render_discussion(issue_url) = begin
        disc = _issue_discussion(issue_url)
        if isnothing(disc)
            h.div(class="issue-discussion")(
                h.span(; class="issue-loading",
                    hx_get=query_url("/issue_discussion"; url=issue_url),
                    hx_trigger="every 2s",
                    hx_swap="outerHTML",
                )("Loading issue discussion..."),
            )
        else
            h.div(class="issue-discussion")(
                h.div(class="markdown-body")(Markdown.html(Markdown.parse(disc))),
            )
        end
    end

    # GET /issue_discussion?url=... — returns just the discussion fragment (for HTMX polling)
    @get issue_discussion(; url="") = begin
        isempty(url) && return h.span()("No issue URL")
        disc = _issue_discussion(url)
        if isnothing(disc)
            h.span(; class="issue-loading",
                hx_get=query_url("/issue_discussion"; url),
                hx_trigger="every 2s",
                hx_swap="outerHTML",
            )("Loading issue discussion...")
        else
            h.div(class="issue-discussion")(
                h.div(class="markdown-body")(Markdown.html(Markdown.parse(disc))),
            )
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
            h.details(class="diff-viewer")(
                h.summary("Diff ($(count(==('\n'), diff_text)) lines)"),
                h.pre(diff_text),
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
            h.details(class="diff-viewer"; open="")(
                h.summary("Diff ($(count(==('\n'), diff_text)) lines)"),
                h.pre(diff_text),
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
            # hx-vals sends JSON as form data (works with POST kwargs)
            vals = isempty(cmt) ? nothing : """{"msg": $(JSON.json(cmt))}"""
            btn_attrs = if prompt
                # "prompt" buttons: hx-include grabs the text input (name=msg) as formdata
                (; class="btn $cls", hx_post=base_url,
                    hx_target="#proposals-list", hx_swap="innerHTML",
                    hx_include="#comment-input-$slug")
            elseif !isnothing(vals) && confirm
                (; class="btn $cls", hx_post=base_url,
                    hx_target="#proposals-list", hx_swap="innerHTML",
                    hx_vals=vals, hx_confirm="$label this proposal?")
            elseif !isnothing(vals)
                (; class="btn $cls", hx_post=base_url,
                    hx_target="#proposals-list", hx_swap="innerHTML",
                    hx_vals=vals)
            elseif confirm
                (; class="btn $cls", hx_post=base_url,
                    hx_target="#proposals-list", hx_swap="innerHTML",
                    hx_confirm="$label this proposal?")
            else
                (; class="btn $cls", hx_post=base_url,
                    hx_target="#proposals-list", hx_swap="innerHTML")
            end
            h.button(; btn_attrs...)(label)
        end

        # Quick comment buttons
        quick_buttons = map(_quick_comments()) do qc
            h.button(; class="btn btn-quick",
                hx_post="/add_comment/$slug",
                hx_target="#proposals-list", hx_swap="innerHTML",
                hx_vals="""{"msg": $(JSON.json(qc))}""",
            )(qc)
        end

        h.div(; class="proposal-card", id="proposal-$slug")(
            h.div(class="proposal-header")(
                h.div(class="proposal-title")(
                    !isempty(issue) ? h.a(; href=issue, target="_blank")(fname) : fname
                ),
                status_badge(status),
            ),
            !isempty(meta_parts) ? h.div(class="proposal-meta")(meta_parts...) : "",
            h.div(class="proposal-body")(body_html),
            # Inline GitHub issue discussion (async)
            !isempty(issue) ? _render_discussion[issue] : "",
            !isempty(worktree) ? _render_diff[worktree] : "",
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

    diff_js = """
    function colorizeDiffs() {
        document.querySelectorAll('.diff-viewer pre').forEach(function(pre) {
            if (pre.dataset.colorized) return;
            pre.dataset.colorized = '1';
            var html = pre.innerHTML;
            pre.innerHTML = html.split('\\n').map(function(line) {
                if (/^\\+[^+]/.test(line)) return '<span class="diff-add">' + line + '</span>';
                if (/^-[^-]/.test(line)) return '<span class="diff-del">' + line + '</span>';
                if (/^@@/.test(line)) return '<span class="diff-hunk">' + line + '</span>';
                if (/^diff --git/.test(line)) return '<span class="diff-file">' + line + '</span>';
                return line;
            }).join('\\n');
        });
    }
    colorizeDiffs();
    document.body.addEventListener('htmx:afterSettle', colorizeDiffs);
    // Also colorize when <details> is opened
    document.body.addEventListener('toggle', function(e) {
        if (e.target.open) colorizeDiffs();
    }, true);
    """

    _page(content_node) = htmx(
        h.head(
            h.meta(; charset="utf-8"),
            h.meta(; name="viewport", content="width=device-width, initial-scale=1"),
            h.style(css),
        ),
        h.body(
            h.div(class="container")(content_node),
            h.script(diff_js),
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
                "Status lifecycle: ", h.code("pending → open-pr → pr-open → approved/changes-requested/rejected"), ". ",
                "When status is ", h.code("open-pr"), ", open a PR and set ", h.code("pr:"), " + ", h.code("status: pr-open"), ". ",
                h.strong("Never merge — "), "only Niko merges after reviewing the PR on GitHub.",
            ),
            h.div(; id="proposals-list")(_render_list[filter]...),
        )
        if is_htmx(req)
            h.div(; id="proposals-list")(_render_list[filter]...) |> to_response
        else
            _page[content] |> to_response
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
