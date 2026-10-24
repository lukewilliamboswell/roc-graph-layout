# Performance harness

The harness builds one optimized native Roc executable against a minimally
vendored Zig platform. Explicit measurement markers exclude fixture creation
and reporting. Allocation fields count bytes requested through `roc_alloc`,
`roc_realloc`, and `roc_dealloc`; they are not operating-system RSS.

Run it through Blueprint, which supplies Zig and the script compiler, with the
latest Roc nightly as `roc` on `PATH`:

```sh
blueprint run bench -- smoke
blueprint run bench -- scale --output benchmarks/results/local
blueprint run bench -- compare baseline/samples.jsonl candidate/samples.jsonl
```

`smoke` and `scale` run the cases in `cases/<tier>.jsonl` and write
`samples.jsonl`, `summary.csv` and `summary.md` to `results/<tier>`, or to
the `--output` directory. `compare` also accepts two results directories.

Every sample runs in a fresh process. Generated fixtures provide scale ladders;
the `fixtures` package contains small graphs imported at compile time.
