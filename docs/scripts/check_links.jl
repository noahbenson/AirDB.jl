#!/usr/bin/env julia
################################################################################
# check_links.jl
#
# Checks the internal links and anchors of a built MyST site.
#
#   julia --project=. docs/scripts/check_links.jl [--root docs/_build/html]
#
# It walks every `.html` file, resolves each local `href`/`src`, and verifies
# that the target file exists and, when a fragment is present, that the target
# contains a matching `id`/`name`. External URLs are ignored. Exits nonzero when
# anything is missing.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

const DOCS_DIR = normpath(joinpath(@__DIR__, ".."))

function parse_args(args)
    root = joinpath(DOCS_DIR, "_build", "html")
    base = "/AirDB.jl"
    i = 1
    while i <= length(args)
        if args[i] == "--root"
            i == length(args) && error("--root needs a directory")
            root = args[i + 1]
            i += 2
        elseif args[i] == "--base"
            i == length(args) && error("--base needs a path")
            base = args[i + 1]
            i += 2
        else
            error("unknown argument: $(args[i])")
        end
    end
    return root, base
end

external(url) = occursin(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", url) || startswith(url, "//")

function unescape(url)
    url = replace(url, "%20" => " ")
    return replace(url, r"%([0-9A-Fa-f]{2})" => s -> string(Char(parse(UInt8, s[2:3]; base = 16))))
end

function html_files(root)
    out = String[]
    for (dir, _, files) in walkdir(root)
        for f in files
            endswith(f, ".html") && push!(out, joinpath(dir, f))
        end
    end
    return sort(out)
end

# Every fragment the file can be linked to.
function anchors(path)
    text = read(path, String)
    out = Set{String}()
    for m in eachmatch(r"""(?:id|name)\s*=\s*["']([^"']+)["']""", text)
        push!(out, m.captures[1])
    end
    return out
end

function check_target(file, href, root, prefix)
    url = unescape(href)
    hashparts = split(url, '#'; limit = 2)
    base = hashparts[1]
    frag = length(hashparts) > 1 ? hashparts[2] : ""
    base = split(base, '?'; limit = 2)[1]
    if startswith(base, "/")
        # A site-root-relative URL; strip the deployment base path.
        rel = base
        if !isempty(prefix) && (rel == prefix || startswith(rel, prefix * "/"))
            rel = rel[length(prefix)+1:end]
        end
        rel = lstrip(rel, '/')
        target = isempty(rel) ? joinpath(root, "index.html") :
                                normpath(joinpath(root, rel))
    else
        target = isempty(base) ? file : normpath(joinpath(dirname(file), base))
    end
    if isdir(target) || isempty(splitext(target)[2])
        target = joinpath(target, "index.html")
    end
    if !isfile(target)
        return "missing file: $(relpath(target, dirname(file)))"
    end
    if !isempty(frag)
        frag = unescape(frag)
        if !(frag in anchors(target))
            return "missing anchor #$(frag) in $(relpath(target, dirname(file)))"
        end
    end
    return nothing
end

function main()
    root, prefix = parse_args(ARGS)
    isdir(root) || error("no built site at $root (run the MyST build first)")
    problems = String[]
    checked = 0
    for file in html_files(root)
        text = read(file, String)
        for m in eachmatch(r"""\b(?:href|src)\s*=\s*["']([^"']+)["']""", text)
            href = m.captures[1]
            (isempty(href) || startswith(href, "#") || external(href)) && continue
            # Same-file `#frag` links are checked in the loop below.
            startswith(href, "#") && continue
            checked += 1
            err = check_target(file, href, root, prefix)
            err === nothing || push!(problems, "$(relpath(file, root)): $err")
        end
        # Same-file `href="#..."` links were skipped above; check them here.
        for m in eachmatch(r"""\bhref\s*=\s*["'](#[^"']+)["']""", text)
            checked += 1
            err = check_target(file, m.captures[1], root, prefix)
            err === nothing || push!(problems, "$(relpath(file, root)): $err")
        end
    end
    println("checked $checked internal link(s) in $(length(html_files(root))) page(s)")
    if !isempty(problems)
        println("broken links:")
        for p in unique(problems)
            println("  - ", p)
        end
        exit(1)
    end
end

main()
