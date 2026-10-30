using Documenter, AirDB

makedocs(;
    modules = [AirDB],
    sitename = "AirDB.jl",
    authors = "Noah C. Benson",
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
    # A `Remotes.GitHub` rather than a URL string, so the source links and the
    # "edit this page" links are derived from the repository (as in Air.jl).
    repo = Documenter.Remotes.GitHub("noahbenson", "AirDB.jl"),
)

deploydocs(;
    repo = "github.com/noahbenson/AirDB.jl",
    # Explicit rather than auto-detected: the CI and a local build behave the
    # same way, and a PR never tries to publish a preview.
    deploy_config = Documenter.GitHubActions(),
    push_preview = false,
    devbranch = "main",
)
