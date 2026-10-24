# Site build

Build the site from the repository root and preview it:

```sh
blueprint run site    # writes dist/site
blueprint run serve   # builds, then serves under /roc-graph-layout/
```

The site holds the static guides generated from `content/` by the released
basic-ssg platform in `main.roc`, and the API reference that `roc docs` writes
for the working tree under `docs/main/`. `SITE_OUTPUT` selects another output
directory, `SITE_VERSION` the API reference version, and `SITE_PORT` the
preview port. With `FETCH_RELEASE_DOCS=1` and an authenticated `gh`, the API
reference of every earlier release is restored from its release asset beside
it; `docs/` leads to the newest final release. A release builds the site this
way and deploys it to GitHub Pages.

The guides are ordinary HTML and do not need JavaScript to read.

Keep guide Markdown files directly under `content/`. Navigation and content
links are relative to that shared output directory so the pages work under a
GitHub Pages project prefix as well as at a domain root. Adding nested guides
requires making navigation relative to each page's output depth.

Only repository-authored Markdown enters the raw HTML slot in the page
template. Use the basic-ssg `Html` builders for additional template content.
