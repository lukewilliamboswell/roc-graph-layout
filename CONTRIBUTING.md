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
Releases within that boundary require `roc bump` for the layout API, or a strict
content-identity proof for a later patch. The latter downloads both unique immutable
source assets with bounded size and verified digests, builds fresh candidates from
tracked current inputs, and requires exact layout bytes. Mermaid must retain its
member inventory, types, modes and payloads; only its one declared layout URL may
rebind to that byte-identical layout bundle in the new release. The proof records
source hashes, compiler, asset URLs, sizes and hashes, and binds both actual
producer bundles to those freshly proven bytes before upload. The version gate
runs after bundling; locally, build the bundles first in `OUTPUT_DIR` (default
`dist`) before `blueprint run check-version`. This does not add general
Mermaid API inspection. Genuine package changes still require the normal layout
API comparison; an unreadable previous API cannot satisfy it. Admission or freshness
errors stop the gate. There is no manual switch to bypass validation.

This prevents malformed metadata, a downgrade, or a different repository's bundle
from being used to justify publication. Pure release tests cover those rejected
inputs and the pre-1.0 boundary. The proof establishes the version's compatibility
promise, not that the package or its archived examples work; all existing build,
example, oracle and archive checks remain required.

## Test release archives

The canonical shared runner starts each application in its own directory. These
examples document suite-root paths, so their archive explicitly declares a Python 3
launcher through the existing `run` argv contract. Python 3 is already supplied by
the shared runner for archive admission. The launcher changes to the suite root
and replaces its process, forwarding arguments and standard streams without shell
interpolation. The exact launcher is an allowed archive entry, and its bytes and
metadata are checked before execution. Candidate checks retain the original root
harness and also run cold checks, native builds and the declared runtime argv from
application directories. Forwarding regressions and hostile bundle-identity tests
protect these boundaries. All execution remains in jobs with read-only tokens; the
privileged publisher handles only the tested artifact files.
