# Mermaid oracle

Authoring and CI tooling for `package-mermaid/`. Nothing here is part of a
Roc package; the packages stay pure Roc.

The oracle renders Mermaid source in a pinned browser, with a pinned font
(`fonts/Inter-Regular.ttf`, OFL) and a fixed configuration, and records what
Mermaid understood (its parsed model) and where it put everything (the
input it handed its layout engine and the resulting geometry). Records are
keyed by a hash of everything that can change them: the source, the
Mermaid and Puppeteer versions, the font, the configuration and the
extractor version. A record is recomputed only when its key changes, and a
forced re-record reproduces it byte for byte.

```sh
npm ci --prefix tools/mermaid-oracle      # once; downloads the pinned browser

# Named cases: tests/mermaid/flowchart/<name>.mmd -> <name>.oracle.json
node tools/mermaid-oracle/oracle.mjs record tests/mermaid/flowchart
node tools/mermaid-oracle/oracle.mjs check tests/mermaid/flowchart   # stale records fail

# Regenerate the Roc conformance module, then test it
node tools/mermaid-oracle/golden.mjs tests/mermaid/flowchart package-mermaid/OracleFlowchart.roc
roc test package-mermaid/OracleFlowchart.roc
```

A case named `unsupported-*` must be accepted by Mermaid and reported as
`Unsupported` by the Roc reader; every other case must agree exactly.

## Differential fuzzing

`package-mermaid/fuzz_flowchart_parse.roc` takes raw bytes as the source
text, so its corpus files are ordinary Mermaid files:

```sh
roc build --fuzz package-mermaid/fuzz_flowchart_parse.roc --output=fuzz_flowchart_parse
./fuzz_flowchart_parse run corpus/ --time=600 --dictionary=tests/mermaid/fuzz/flowchart.dict

# Record the corpus with Mermaid (content-addressed, so reruns are incremental)
node tools/mermaid-oracle/oracle.mjs corpus corpus/ tests/mermaid/fuzz/corpus-cache

# Group disagreements by kind, using the native inspector
roc build tools/mermaid-oracle/inspect.roc --output=inspect
node tools/mermaid-oracle/triage.mjs ./inspect tests/mermaid/fuzz/corpus-cache corpus/
```

Each disagreement that survives triage becomes a named case in
`tests/mermaid/flowchart/` (recorded by the oracle) and a
`## fuzz regression:` expect where it exercises a specific rule.

`package-mermaid/fuzz_flowchart_scaling.roc` checks that reading 8 times the
text costs no more than about 8 times the allocations, and that reading
frees everything it allocates.

## Deliberate differences from Mermaid

The goal is Mermaid's output, except where Mermaid loses what the author
wrote. Each difference is documented in the module that makes it, pinned by
a unit test, and listed separately (not counted as error) by the comparison
scripts.

| Difference | Mermaid 12.2.0 (oracle config) | Here | Where |
|---|---|---|---|
| `>` in a label with no `<` | Dropped: `a -> b` is drawn `a - b` | Kept | `TextMeasure.roc` |
| `#quot;`-style entities | Drawn literally (`&quot;`) in SVG labels | Decoded, as Mermaid's default HTML labels show them | `FlowText.roc` |
| NUL in a label | Drawn as U+FFFD in SVG labels | Removed, as HTML parsing removes it | `FlowText.roc` |
| `(-text-)` ellipse shape | Fails to render ("No such shape: ellipse") | Drawn and sized as an ellipse | `FlowSize.roc`, `FlowDrawShape.roc` |

## Output stages

Each output stage is compared with Mermaid on its own, given Mermaid's
values for the stages before it, so errors do not compound.

```sh
# Sizing: our label boxes, line breaks and node sizes vs the recorded ones
roc build package-mermaid/measure_sizes.roc --output=measure_sizes
node tools/mermaid-oracle/measure_compare.mjs ./measure_sizes tests/mermaid/flowchart tests/mermaid/measure

# ...and the same agreement as Roc expectations, so `roc test` enforces it
node tools/mermaid-oracle/golden_sizes.mjs package-mermaid/OracleSizes.roc tests/mermaid/flowchart tests/mermaid/measure
roc test package-mermaid/OracleSizes.roc --main=package-mermaid/main.roc

# Layout: our geometry from Mermaid's measured sizes vs Mermaid's (ELK) layout
roc build package-mermaid/layout_dump.roc --output=layout_dump
node tools/mermaid-oracle/score.mjs --bin ./layout_dump [--cases] tests/mermaid/layout tests/mermaid/flowchart

# Drawing: our SVG from Mermaid's geometry vs Mermaid's SVG, pixel by pixel
roc build package-mermaid/draw_svg.roc --output=draw_svg
node tools/mermaid-oracle/visual.mjs ./draw_svg tests/mermaid/flowchart <out-dir> [case ...]
```

Mermaid 12.2.0 lays flowcharts out with ELK (its default `layout`), not
dagre; `FlowLayout.roc` reproduces the ELK settings Mermaid passes.
`score.mjs` aligns the two drawings and reports node displacement (relative
to the diagram's diagonal), layer and within-layer order agreement, edge
crossings, bounds ratios and subgraph-box overlap. `tests/mermaid/layout/` holds
larger, layout-focused cases.

`visual.mjs` writes Mermaid | Roc | difference images and `scores.json`. A
score is the share of inked pixels with no match within 1px in the other image.
Records carry `text.rows` (the rows Mermaid drew) and `text.box` (the text box at
unit scale, which is what Mermaid measured before any viewBox scaling).

## End to end

The stages above are each judged on Mermaid's inputs. `e2e.mjs` judges the
whole pipeline instead: Mermaid text to our final SVG through the public
`Mermaid.svg`, via the native `mermaid_svg` command, against Mermaid's
rendering of the same text.

```sh
roc build --opt=speed package-mermaid/mermaid_svg.roc --output=mermaid_svg
node tools/mermaid-oracle/e2e.mjs ./mermaid_svg <out-dir> [cases-dir ...] [--only name,name]
```

The cases default to `tests/mermaid/flowchart` and `tests/mermaid/layout`;
cases Mermaid rejects and cases we report as `Unsupported` are skipped and
counted. Both drawings are rendered at one CSS pixel per unit with their
view boxes' top left corners aligned, compared over the larger of the two,
and written as `<case>.png` (Mermaid | Roc | difference, plus the
difference after the best shift when that is not zero) with `scores.json`.
The table gives, per case, the score as in `visual.mjs`, the score after
translating our drawing by up to 4 pixels to best overlay Mermaid's (a
drawing displaced as a whole scores badly in place but well shifted), our
view box size relative to Mermaid's, and the native command's time (one
process per case). The summary adds the time for all cases in one process.

A case that scores well in `visual.mjs` but badly here differs before
drawing, in sizing or layout; `score.mjs` and `measure_compare.mjs` say
which.

## Other tools

- `measure_probe.mjs` sets up a browser page exactly like the oracle's, for
  probing how Chrome measures text.
- `font_subset.mjs` builds `package-mermaid/FontInter.ttf`, the metrics-only
  copy of Inter behind `TextMeasure.inter`, read with roc-font 0.1.0-rc1.

- `lexer_table.mjs` prints the flowchart lexer as the pinned Mermaid
  release compiled it. Jison rewrites some lookaheads, so the compiled table,
  not `flow.jison`, is what `FlowLexer.roc` must match.
- `unicode_text_ranges.mjs` and `html_entities.mjs` generate the lexer's
  letter ranges and `package-mermaid/HtmlEntities.roc`.

The sandbox is disabled when launching Chrome because common Linux hosts
block the unprivileged namespaces it needs; the page loads only the local
Mermaid bundle and font, and every network request is refused.

## Closing the loop for every family

`oracle_dump.roc` is a native authoring tool, excluded from the public package
exports. Its inspectors observe the production parser and layout phases;
`Mermaid.svg_with` supplies the public end-to-end SVG.

```sh
roc build package-mermaid/oracle_dump.roc --output=/tmp/mermaid-oracle-dump
node --test tools/mermaid-oracle/validate.test.mjs
node tools/mermaid-oracle/validate.mjs /tmp/mermaid-oracle-dump /tmp/mermaid-oracle-results
```

The report separates exact source semantics, native measurement and placement,
placement with oracle-measured input sizes, and public SVG pixel differences.
The sized control replaces only node and layout-label dimensions: it never
copies reference positions, routes, or output container bounds. Pixel scores
use the pinned font/browser, one CSS pixel of spatial tolerance, and no image
rescaling. Strict and best-translation scores remain visible separately.
Missing/stale records, crashes, unsupported accepted sources outside the explicit
scope list, semantic differences, invalid geometry and unconsumed size overrides
fail. Every family must include an accepted rendered comparison. Oracle-sized
node and group boxes must agree within one CSS pixel. Flowchart layers, ranks
and ordering must agree, with no additional crossings. New-family public SVGs
must have at most 5% unmatched ink and view dimensions within one CSS pixel;
these limits are fixed independently of the current results. Raw flowchart
pixels remain visible separately because the documented text-preservation
extensions and host font measurements can change end-to-end geometry.

Use `--families=sequence,entity,class,state` to narrow an investigation and
`--report-only` to collect every failure without a failing process exit. The
latter must never be used as a CI acceptance gate. Reports include every
attempted source and all failures rather than silently skipping unsupported
or unrendered diagrams.

Theme defaults now target the pinned renderer. Typography retains role-specific
sizes (for example, sequence actors are 16px at the shared 14px base).
`wrapping: FamilyDefault` follows each diagram role; `Wrap` explicitly uses
`max_label_width`, and `NoWrap` disables wrapping. `corners` similarly separates
family defaults from explicit rounded or square nodes. An empty `node_palette`
selects the family's reference palette; a one-entry list selects flat actor,
table or state-composite colors. Sequence-specific colors are supplied through
`message_colors`; transition/relationship backings use
`transition_label_background`.

Reference records must be refreshed intentionally. A refresh on another host
can expose differences in glyph bounds and system fallback fonts even with
Inter and Chrome pinned. Do not regenerate numerical expectations or widen
thresholds solely to make such a refresh green; use the sized control and
inspect the drift first. The older generated flowchart sizing expectations
retain their original reference observations while this cross-host audit runs.

CI generates fresh references independently on the Linux runner before checking
freshness and comparing native results. This is a live oracle gate, not a
comparison against implementation-generated golden images. Committed records
retain their host provenance for inspection and local reproducibility. The CI
artifact contains the complete JSON report, both SVGs and image differences,
and is uploaded on failure too.

The recorder creates a fresh browser page for each source. Mermaid memoizes
text measurements; reusing a page made diagnostic traces depend on earlier
cases even when the final SVG was unchanged. Reordering and independently
re-recording flow, sequence, class and state samples is checked byte for byte.

Raster cells are padded to integer dimensions while the SVG view-box extent
is expanded by that same padding, preserving exactly one CSS pixel per SVG
unit. Content is clipped to its original extent. The comparator asserts the
root transformation has unit scale; it never rounds only the viewport and
silently rescales the image. A fractional-view-box integration test guards it.
The report retains the native binary hash and comparison-tool hashes.

`validate.integration.test.mjs` exercises missing/stale/zero coverage, native
read/profile failures, serialized null geometry, unconsumed dimensions and
missing rendered text. Its dishonest renderers can supply the exact oracle
SVG, demonstrating that model/geometry checks are independent of image scores.
Run it with `ORACLE_DUMP=/tmp/mermaid-oracle-dump node --test
 tools/mermaid-oracle/validate.integration.test.mjs` after building the probe.
