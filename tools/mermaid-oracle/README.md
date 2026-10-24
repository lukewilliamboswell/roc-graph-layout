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

## Other tools

- `lexer_table.mjs` prints the flowchart lexer as the pinned Mermaid
  release compiled it. Jison rewrites some lookaheads, so the compiled table,
  not `flow.jison`, is what `FlowLexer.roc` must match.
- `unicode_text_ranges.mjs` and `html_entities.mjs` generate the lexer's
  letter ranges and `package-mermaid/HtmlEntities.roc`.

The sandbox is disabled when launching Chrome because common Linux hosts
block the unprivileged namespaces it needs; the page loads only the local
Mermaid bundle and font, and every network request is refused.
