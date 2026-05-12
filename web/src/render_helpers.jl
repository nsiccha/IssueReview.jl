# Extract `owner/repo` from a github issue/PR URL. Used to look up `gh` args.
function _repo_slug_from_url(url)
    isempty(url) && return ""
    m = match(r"github\.com/([^/]+/[^/]+)", url)
    isnothing(m) ? "" : replace(m.captures[1], r"\.git$" => "")
end

function status_badge(status)
    h.span(; class="u-badge ir-status-$status")(status)
end

function _html_escape(s)
    replace(s, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
end

function _linkify(s)
    replace(_html_escape(s), r"https?://[^\s<>\"')]*[^\s<>\"').,:;!?]" => m -> "<a href=\"$m\" target=\"_blank\">$m</a>")
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

function render_diff_html(diff_text)
    startswith(diff_text, "(") && return h.p(; class="ir-muted-sm")(diff_text)
    lines = split(diff_text, '\n')
    # Each file collects: (filename, lang, rows, code_lines)
    # code_lines: the raw text per code row (parallel to rows), or nothing for hunk rows
    files = []
    current_file = ""
    current_lang = "none"
    current_rows = []
    current_code = String[]  # raw code text per row (for highlighting)
    old_ln = 0
    new_ln = 0

    for line in lines
        if startswith(line, "diff --git")
            if !isempty(current_file)
                push!(files, (current_file, current_lang, copy(current_rows), copy(current_code)))
            end
            m = match(r"b/(.+)$", line)
            current_file = isnothing(m) ? line : m.captures[1]
            current_lang = _prism_lang(current_file)
            current_rows = []
            current_code = String[]
            old_ln = 0; new_ln = 0
        elseif startswith(line, "@@")
            m = match(r"@@ -(\d+)", line)
            if !isnothing(m)
                old_ln = parse(Int, m.captures[1]) - 1
                nm = match(r"\+(\d+)", line)
                new_ln = isnothing(nm) ? old_ln : parse(Int, nm.captures[1]) - 1
            end
            push!(current_rows, h.tr(class="diff-hunk", data_file=current_file)(
                h.td(; class="diff-ln", colspan="2")("..."),
                h.td(; class="diff-sign")(),
                h.td(class="diff-code")(_html_escape(line)),
            ))
            push!(current_code, "")
        elseif startswith(line, "---") || startswith(line, "+++") ||
               startswith(line, "index ") || startswith(line, "new file") ||
               startswith(line, "old mode") || startswith(line, "new mode") ||
               startswith(line, "deleted file")
            # Skip diff metadata lines
        elseif startswith(line, "+")
            new_ln += 1
            text = line[2:end]
            push!(current_rows, h.tr(class="diff-add", data_file=current_file, data_line="$new_ln")(
                h.td(class="diff-ln")(""),
                h.td(class="diff-ln")("$new_ln"),
                h.td(class="diff-sign")("+"),
                h.td(class="diff-code")(_html_escape(text)),
            ))
            push!(current_code, text)
        elseif startswith(line, "-")
            old_ln += 1
            text = line[2:end]
            push!(current_rows, h.tr(class="diff-del", data_file=current_file, data_line="$old_ln")(
                h.td(class="diff-ln")("$old_ln"),
                h.td(class="diff-ln")(""),
                h.td(class="diff-sign")("-"),
                h.td(class="diff-code")(_html_escape(text)),
            ))
            push!(current_code, text)
        elseif !isempty(current_file)
            old_ln += 1; new_ln += 1
            text = startswith(line, " ") ? line[2:end] : line
            push!(current_rows, h.tr(class="diff-ctx", data_file=current_file, data_line="$new_ln")(
                h.td(class="diff-ln")("$old_ln"),
                h.td(class="diff-ln")("$new_ln"),
                h.td(class="diff-sign")(),
                h.td(class="diff-code")(_html_escape(text)),
            ))
            push!(current_code, text)
        end
    end
    !isempty(current_file) && push!(files, (current_file, current_lang, current_rows, current_code))

    isempty(files) && return h.p(; class="ir-muted-sm")("(empty diff)")

    file_id = 0
    h.div()(
        [begin
            file_id += 1
            id = "diff-file-$file_id"
            # Hidden source block: Prism highlights the full code, then JS distributes to rows
            source_block = lang == "none" ? "" :
                h.pre(class="diff-hidden-source")(
                    h.code(; id="$id-source", class="language-$lang")(
                        _html_escape(join(code_lines, '\n'))
                    )
                )
            h.details(; class="diff-file", open="")(
                h.summary(class="diff-file-header")(fname),
                source_block,
                h.table(; class="diff-table", data_source_id="$id-source")(h.tbody(rows...)),
            )
        end for (fname, lang, rows, code_lines) in files]...
    )
end

_pr_state_cache = Dict{String, Tuple{Float64, String}}()  # url => (timestamp, state)
