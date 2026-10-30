# Building the AirDB documentation

The documentation is one [Jupyter Book 2](https://jupyterbook.org/) site,
rendered by the [MyST](https://mystmd.org/) engine from the pages under
`docs/`. It includes the written guide and the generated API reference; there is
no separate Documenter site.

## Generate the API reference

The API pages are generated from the package's own docstrings and are not
committed. Generate them before previewing or building:

```bash
julia --project=. docs/scripts/generate_api.jl --strict
```

`--strict` fails if an exported name is missing from the curated groups in
`docs/scripts/api_groups.jl`, if an entry has no docstring, if an anchor is
duplicated, or if a page is missing from `myst.yml`.

## Preview and build

`myst` is a Node tool, so Node 20+ is required. From `docs/`:

```bash
npx -y mystmd@1.12.0 start          # live preview at http://localhost:3000
BASE_URL=/AirDB.jl npx -y mystmd@1.12.0 build --html
```

`BASE_URL` is required for a static build because the site is served from
`https://nben.net/AirDB.jl/`; do not set it for `myst start`.

After a build, check the internal links and anchors:

```bash
julia --project=. docs/scripts/check_links.jl
```

## Review status

Every page that has not been reviewed by a human carries a visible warning and
a machine-readable marker. To list the unreviewed pages:

```bash
grep -rl 'review-status: unreviewed' docs --include='*.md' | grep -v '^docs/README.md$'
```

(`docs/README.md` contains the marker only as part of this command.)

When you review a page, change its marker to `review-status: reviewed` and
remove or update the warning. Generated API pages get the marker
automatically; to mark the whole reference reviewed, change `REVIEW` in
`docs/scripts/generate_api.jl`.

## Deployment

`.github/workflows/docs.yml` generates the API, builds the site on every push
and pull request, and deploys `docs/_build/html` to GitHub Pages on `main` only.
The site is the latest documentation; there are no versioned subdirectories.
