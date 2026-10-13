using Documenter, AirDB

makedocs(;
    modules = [AirDB],
    sitename = "AirDB.jl",
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", nothing) == "true",
        # The default branch, named explicitly: Documenter otherwise asks git for
        # the remote HEAD and falls back to a `master` this repository has not
        # had, leaving every "edit this page" link pointing at a missing branch.
        edit_link = "main",
        # `api.md` holds every public docstring, so it is large by construction;
        # the default thresholds are sized for prose pages.
        size_threshold_warn = 250 * 1024,
        size_threshold = 500 * 1024,
    ),
    pages = [
        "Home" => "index.md",
        "API Reference" => "api.md",
    ],
)

deploydocs(;
    repo = "github.com/noahbenson/AirDB.jl",
    devbranch = "main",
    push_preview = true,
)
