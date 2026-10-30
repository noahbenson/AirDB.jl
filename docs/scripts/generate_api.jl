#!/usr/bin/env julia
################################################################################
# generate_api.jl
#
# Generates `docs/api/*.md` from the docstrings registered in AirDB, using only
# `Base.Docs` (no Documenter, no third-party Markdown renderer). The curated
# groups live in `api_groups.jl`.
#
#   julia --project=. docs/scripts/generate_api.jl [--strict]
#
# `--strict` fails on: an exported name that is missing from the groups or
# listed twice, an entry with no docstring, a duplicate anchor, an unresolved
# `@ref`, a page without the review marker, or a `myst.yml` file reference that
# does not exist. The output is deterministic: curated order, docstring
# definition order, fixed anchors, no timestamps or absolute paths.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

using AirDB

const META = Base.Docs.meta(AirDB; autoinit = false)

include(joinpath(@__DIR__, "api_groups.jl"))

const DOCS_DIR = normpath(joinpath(@__DIR__, ".."))
const API_DIR = joinpath(DOCS_DIR, "api")
const STRICT = "--strict" in ARGS

const REVIEW = """
<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::
"""

# The four documented qualified functions the guide uses; they are not exported.
const QUALIFIED = [:sync, :status, Symbol("load!"), :close]

const PROBLEMS = String[]

problem(msg) = push!(PROBLEMS, msg)

# ---- names and anchors -------------------------------------------------------

entry_symbol(e) = e isa Symbol ? e : e.name
group_kind(g) = hasproperty(g, :kind) ? g.kind : :page

function entry_display(e)
    e isa Symbol && return String(e)
    return something(get(e, :display, nothing), String(e.name))
end

function anchor(display)
    a = lowercase(display)
    a = replace(a, r"[^a-z0-9]+" => "-")
    return "api-" * strip(a, '-')
end

# ---- docstrings --------------------------------------------------------------

function doc_texts(name::Symbol)
    b = Base.Docs.Binding(AirDB, name)
    haskey(META, b) || return String[]
    m = META[b]
    return String[m.docs[sig].text[1] for sig in m.order]
end

# Split a leading four-space-indented block (the signature) from the prose.
function split_signature(text::String)
    lines = split(text, '\n'; keepempty = true)
    i = 1
    while i <= length(lines) && isempty(strip(lines[i]))
        i += 1
    end
    i > length(lines) && return String[], ""
    sig = String[]
    j = i
    while j <= length(lines) && startswith(lines[j], "    ")
        push!(sig, lines[j][5:end])
        j += 1
    end
    prose = isempty(sig) ? join(lines[i:end], '\n') :
                           (j <= length(lines) ? join(lines[j+1:end], '\n') : "")
    return sig, strip(prose)
end

# A name a `@ref` may point at, normalized: explicit targets win; otherwise the
# label minus backticks and a trailing argument list.
function ref_name(label::AbstractString, target::AbstractString)
    name = isempty(strip(target)) ? label : target
    name = replace(name, "`" => "")
    name = strip(replace(name, r"\(.*\)$" => ""))
    return name
end

function rewrite_refs(line::AbstractString, api_map, page_slug)
    out = IOBuffer()
    pos = 1
    for m in eachmatch(r"\[([^\]]*)\]\(@ref\s*([^)]*)\)", line)
        write(out, line[pos:prevind(line, m.offset)])
        label, target = m.captures[1], m.captures[2]
        name = ref_name(label, target)
        if haskey(api_map, name)
            slug, anc = api_map[name]
            href = slug == page_slug ? "#$anc" : "$slug.md#$anc"
            write(out, "[", label, "](", href, ")")
        elseif name == "getindex"
            write(out, "[", label, "](../forms/reading-and-paths.md)")
        else
            # Not part of the public reference: keep the code, drop the link.
            write(out, "`", replace(label, "`" => ""), "`")
        end
        pos = m.offset + ncodeunits(m.match)
    end
    pos <= ncodeunits(line) && write(out, line[pos:end])
    return String(take!(out))
end

# Rewrite `@ref` links and demote headings outside code fences, so a docstring's
# `# Examples` nests under the entry's `##` heading.
function transform_prose(prose::AbstractString, api_map, page_slug)
    out = String[]
    fence = false
    for ln in split(prose, '\n'; keepempty = true)
        if occursin(r"^\s*(```|~~~)", ln)
            fence = !fence
            push!(out, ln)
            continue
        end
        if !fence && startswith(ln, "#")
            ln = "##" * ln
        end
        !fence && (ln = rewrite_refs(ln, api_map, page_slug))
        push!(out, ln)
    end
    return strip(join(out, '\n'))
end

# ---- rendering ---------------------------------------------------------------

function render_entry(e, page_slug, api_map)
    name = entry_symbol(e)
    display = entry_display(e)
    texts = doc_texts(name)
    if isempty(texts)
        problem("no docstring for entry `$name`")
        return ""
    end
    buf = IOBuffer()
    println(buf, "(", anchor(display), ")=")
    println(buf, "## ", display)
    for (i, text) in enumerate(texts)
        sig, prose = split_signature(text)
        if !isempty(sig)
            println(buf)
            println(buf, "```julia")
            for l in sig
                println(buf, l)
            end
            println(buf, "```")
        end
        p = transform_prose(prose, api_map, page_slug)
        if !isempty(p)
            println(buf)
            println(buf, p)
        end
        i < length(texts) && println(buf)
    end
    return String(take!(buf))
end

function index_page(groups)
    buf = IOBuffer()
    println(buf, "# API reference")
    println(buf)
    println(buf, REVIEW)
    println(buf)
    println(buf, """
    Every exported name in AirDB, plus the documented qualified functions the
    guide uses (`AirDB.sync`, `AirDB.status`, `AirDB.load!`, and `Base.close`),
    grouped by topic. Each entry shows its signature and the docstring that is
    installed when AirDB is loaded; this page is generated at build time, so it
    always matches the package.
    """)
    println(buf)
    println(buf, "## Groups")
    println(buf)
    for g in groups
        group_kind(g) === :index && continue
        println(buf, "- [", g.title, "](", g.slug, ".md)")
    end
    println(buf)
    println(buf, "## Errors")
    println(buf)
    println(buf, "| error | when |")
    println(buf, "| --- | --- |")
    println(buf, "| `DatabaseError` | a database operation failed; under `:abort` it fails the whole database |")
    println(buf, "| `FormNotFound` | a form id is not in the database |")
    println(buf, "| `ExternError` | an extern operation used a dead or unregistered extern, or a registration is inconsistent |")
    println(buf, "| `FailedObjectError` | loading an object whose write was quarantined |")
    return String(take!(buf))
end

function page_text(g, api_map, groups)
    group_kind(g) === :index && return index_page(groups)
    buf = IOBuffer()
    println(buf, "# ", g.title)
    println(buf)
    println(buf, REVIEW)
    println(buf)
    intro = strip(g.intro)
    !isempty(intro) && (println(buf, intro); println(buf))
    for e in g.entries
        println(buf, render_entry(e, g.slug, api_map))
        println(buf)
    end
    return String(take!(buf))
end

# ---- the API map and the checks ---------------------------------------------

function build_api_map(groups)
    api_map = Dict{String,Tuple{String,String}}()
    seen = Dict{Symbol,String}()
    for g in groups
        group_kind(g) === :index && continue
        for e in g.entries
            name = entry_symbol(e)
            haskey(seen, name) && problem("entry `$name` is listed twice (in `$(seen[name])` and `$(g.slug)`)")
            seen[name] = g.slug
            display = entry_display(e)
            anc = anchor(display)
            haskey(api_map, display) && problem("duplicate anchor `$anc` for `$display`")
            api_map[display] = (g.slug, anc)
            # Labels in docstrings may name the symbol directly.
            api_map[String(name)] = (g.slug, anc)
        end
    end
    return api_map
end

function check_exports(groups)
    listed = Set{Symbol}()
    for g in groups, e in g.entries
        push!(listed, entry_symbol(e))
    end
    expected = Set{Symbol}(n for n in names(AirDB) if n !== :AirDB)
    union!(expected, QUALIFIED)
    for n in sort(collect(setdiff(expected, listed)))
        problem("exported name `$n` is missing from the API groups")
    end
    for n in sort(collect(setdiff(listed, expected)))
        problem("entry `$n` is not exported and is not a documented qualified name")
    end
end

function check_myst(pages)
    text = read(joinpath(DOCS_DIR, "myst.yml"), String)
    for m in eachmatch(r"file:\s*(\S+)", text)
        f = m.captures[1]
        endswith(f, ".md") || continue
        isfile(joinpath(DOCS_DIR, f)) ||
            problem("myst.yml refers to a missing file `$f`")
    end
    for p in pages
        occursin("file: api/$(p).md", text) ||
            problem("myst.yml does not list `api/$(p).md`")
    end
end

# ---- main --------------------------------------------------------------------

function main()
    groups = api_groups()
    api_map = build_api_map(groups)
    mkpath(API_DIR)

    pages = String[]
    for g in groups
        text = page_text(g, api_map, groups)
        occursin("review-status: unreviewed", text) ||
            problem("generated page `api/$(g.slug).md` has no review marker")
        open(joinpath(API_DIR, "$(g.slug).md"), "w") do io
            write(io, text)
        end
        push!(pages, g.slug)
    end

    for p in pages
        text = read(joinpath(API_DIR, "$p.md"), String)
        occursin("](@ref", text) && problem("unresolved `@ref` in api/$p.md")
    end

    check_exports(groups)
    check_myst(pages)

    if isempty(PROBLEMS)
        println("generated $(length(pages)) API pages in $API_DIR")
    else
        println("API generation found $(length(PROBLEMS)) problem(s):")
        for p in PROBLEMS
            println("  - ", p)
        end
        STRICT && error("API generation failed in --strict mode")
    end
end

main()
