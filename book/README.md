# Building the AirDB book

These pages are a [Jupyter Book 2](https://jupyterbook.org/) site, rendered by the
[MyST](https://mystmd.org/) engine. The configuration is `myst.yml`; the table of
contents lists the pages. (The package's own API reference, built by
[Documenter](https://documenter.juliadocs.org/), lives in `../docs`.)

```bash
npm install -g mystmd      # or use `npx mystmd` below
cd book
myst start                 # live preview at http://localhost:3000
myst build --html          # static site into _build/html
```

`myst` is a Node tool, so Node 18+ is required. With `npx` you can skip the global
install:

```bash
cd book
npx -y mystmd@latest start
```

The examples in these pages are shown as code with their results in comments; they
are not executed during the build, so no Julia kernel or running PostgreSQL is
needed to render the site.
