# Performance harness

The harness builds one optimized native Roc executable against a minimally
vendored Zig platform. Explicit measurement markers exclude fixture creation
and reporting. Allocation fields count bytes requested through `roc_alloc`,
`roc_realloc`, and `roc_dealloc`; they are not operating-system RSS.

Use the compiler pinned in `.roc-version`:

```sh
ROC=/path/to/pinned/roc python3 benchmarks/run.py smoke
ROC=/path/to/pinned/roc python3 benchmarks/run.py scale --output benchmarks/results/local
python3 benchmarks/run.py compare baseline/samples.jsonl candidate/samples.jsonl
```

Every sample runs in a fresh process. Generated fixtures provide scale ladders;
the `fixtures` package contains small graphs imported at compile time.
