using Revise
using IssueReviewWeb

begin
    IssueReviewWeb.terminate()
    port = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 8105
    IssueReviewWeb.serve(; host="0.0.0.0", revise=:lazy, port, async=true)
end
