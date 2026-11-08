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

## Release versions

A release must name a canonical three-component version. Components fit in
`U64`, contain no leading zeroes, and prerelease identifiers are nonempty;
numeric prerelease identifiers also have no leading zeroes. The version check
validates the latest final release and its bundle URLs before deciding how to
compare APIs. It accepts a strictly greater major version, or a strictly greater
minor version when both majors are zero, as sufficient for any API change.
Releases within that boundary still run `roc bump`; an unreadable previous API
cannot satisfy that comparison. There is no manual switch to bypass it.

This prevents malformed metadata, a downgrade, or a different repository's bundle
from being used to justify publication. Pure release tests cover those rejected
inputs and the pre-1.0 boundary. The proof establishes the version's compatibility
promise, not that the package or its archived examples work; all existing build,
example, oracle and archive checks remain required.
