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

The release workflow's optional `nightly-tag` selects an exact compiler. Empty
resolves the official latest once; an explicit value must be a canonical
`nightly-YYYY-MM-DD-<7..40 lowercase hex>` tag with a valid calendar date. Inputs
are environment data and are validated before becoming a workflow output. That
one value feeds the build, archived-example tests and post-publication Site;
standalone documentation, CI and benchmarks keep using latest. Release notes
record the selected compiler, and compatibility evidence retains its actual tag.

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
errors stop the gate. Source downloads use the authenticated official asset-ID
API after validating the immutable release, canonical public URL, size and digest.
This avoids browser-route delivery failures without changing the admitted bytes.
Authentication stays in the environment, debug header tracing is disabled, and
byte, stderr and deadline bounds terminate failed download process groups. Errors
retain a bounded reason, return code and redacted diagnostic; no failed download
can satisfy the proof. There is no manual switch to bypass validation.
The reader signals its owned process group once during cleanup, with a separate
five-second reap bound. Nested cleanup closes the selector and pipes even when
signalling or reaping fails. Permission and cleanup errors still stop the proof;
they cannot turn an incomplete download into accepted bytes.

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

## Admit fixed build inputs

The nightly compiler fetches package URLs without GitHub authentication. Producer
jobs therefore admit the fixed Blueprint Core, Font, basic-cli 0.27 and its HTTP
input through the official asset-ID API before the first Blueprint evaluation.
Core, Font and basic-cli have fixed immutable release descriptors: repository,
version, asset ID, canonical URL, size and SHA-256. The separately named legacy
HTTP input is authorized by the verified immutable basic-cli archive's measured
`main.roc` and sole exact content-addressed dependency edge. Every HTTP admission
rechecks that raw parent archive, its inventory and header before verifying HTTP's
own fixed bytes and inventory. HTTP's mutable release metadata grants no authority.

The public API transport is token-free, bounded to 60 active seconds, and does not
read curl configuration or recover credentials. A transport or integrity failure
stops the job; it never substitutes another asset or an old candidate.
`scripts/admit_release_sources.py` verifies compressed bytes and bounded archive
inventories, then asks the installed Roc compiler to unbundle each bare content-hash
filename. That compiler validates BLAKE3 and package paths. The helper compares the
extracted regular files with the admitted inventory before atomically inserting
only an absent package directory, with no existing dependency sidecar. It preserves
the caller's XDG cache root, HOME and Blueprint provider store. It copies no source
cache, dependency sidecar or compiled state. The platform's native libraries are
the exact original published platform payload, verified as part of that inventory.

Each deliberately empty bundle or archive cache freshly unbundles Font, basic-cli
and its HTTP dependency from verified raw archives, rechecking raw bytes each time.
Candidate bundles still have to be fetched and exercised by the original cold
checks. The shared nightly runner uses its existing setup-command argv to admit
that example dependency closure into its managed empty cache; it supplies the
compiler through `RA_COMPILER` and blanks credentials. That hook does not evaluate
Blueprint or move the managed cache. These controls admit only the four fixed
inputs; other package and provider downloads retain their existing contracts and
availability assumptions.
