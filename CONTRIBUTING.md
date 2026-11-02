# Contributing to roc-graph-layout

Use issues for bugs and design discussion, and pull requests for changes.
Install the Blueprint release named in `Blueprint.roc` and a current Roc nightly
on `PATH` as `roc`. Blueprint locks the independent repository tooling compiler.

```sh
blueprint run check
blueprint run examples
blueprint run examples -- --update
blueprint run serve
blueprint run bench -- smoke
```

`tests/examples.json` records expected output. Review every changed drawing and
recorded output before committing. The manual is authored in `docs/index.adoc`
and its included chapters; `blueprint run serve` builds a local preview.

## Write documentation

Write for a current user or contributor task. Delete superseded or duplicated
material and follow the [shared documentation guidance](https://lukewilliamboswell.github.io/roc-automation/documentation.html#write-project-documentation).
Implementation history belongs in Git, pending work in issues and release
changes in the release record.
