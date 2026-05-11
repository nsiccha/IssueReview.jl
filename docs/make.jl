using Documenter, DocumenterVitepress, IssueReview

makedocs(
    sitename = "IssueReview.jl",
    modules  = [IssueReview],
    format   = DocumenterVitepress.MarkdownVitepress(
        repo = "github.com/nsiccha/IssueReview.jl",
        devurl = "dev",
        devbranch = "dev",
    ),
    pages = [
        "Home" => "index.md",
        "API"  => "api.md",
    ],
    checkdocs = :none,
    warnonly = true,
)

# Ensure a root index.html redirect exists
let redirect = joinpath(@__DIR__, "build", "index.html")
    isfile(redirect) || write(redirect, """
    <!DOCTYPE html>
    <html><head>
    <meta http-equiv="refresh" content="0; url=dev/">
    </head><body>Redirecting to <a href="dev/">dev</a>...</body></html>
    """)
end

DocumenterVitepress.deploydocs(
    repo = "github.com/nsiccha/IssueReview.jl",
    devbranch = "dev",
    push_preview = true,
)
