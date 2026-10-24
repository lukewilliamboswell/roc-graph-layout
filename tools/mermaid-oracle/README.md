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

# Drawing: our SVG from Mermaid's geometry vs Mermaid's SVG, pixel by pixel
roc build package-mermaid/draw_svg.roc --output=draw_svg
node tools/mermaid-oracle/visual.mjs ./draw_svg tests/mermaid/flowchart <out-dir> [case ...]
```

`visual.mjs` writes Mermaid | Roc | difference images and `scores.json`. A
score is the share of inked pixels with no match within 1px in the other image.
Records carry `text.rows` (the rows Mermaid drew) and `text.box` (the text box at
unit scale, which is what Mermaid measured before any viewBox scaling).

## Other tools

- `measure_probe.mjs` sets up a browser page exactly like the oracle's, for
  probing how Chrome measures text.
- `font_subset.mjs` builds `package-mermaid/FontInter.ttf`, the metrics-only
  copy of Inter behind `Font.inter`.

- `lexer_table.mjs` prints the flowchart lexer as the pinned Mermaid
  release compiled it. Jison rewrites some lookaheads, so the compiled table,
  not `flow.jison`, is what `FlowLexer.roc` must match.
- `unicode_text_ranges.mjs` and `html_entities.mjs` generate the lexer's
  letter ranges and `package-mermaid/HtmlEntities.roc`.

The sandbox is disabled when launching Chrome because common Linux hosts
block the unprivileged namespaces it needs; the page loads only the local
Mermaid bundle and font, and every network request is refused.
