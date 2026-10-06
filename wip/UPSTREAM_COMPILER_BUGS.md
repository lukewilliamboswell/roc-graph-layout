# Compiler limitations

## Default test backend crashes on Graph's import closure

Compiler: `nightly-2026-09-04-c125b82`, Linux x86_64.

From the repository root:

```sh
roc test package/Graph.roc
```

The compiler exits with SIGSEGV before reporting test results. The released
binary reports that stack tracing is disabled. The compiler defect has not yet
been reduced to a standalone reproducer or assigned an upstream issue.

Both alternative execution modes complete the same 162 tests successfully:

```sh
roc test package/Graph.roc --opt=interpreter
roc test package/Graph.roc --opt=size
```

This is a backend-specific test-runner limitation, not evidence that the tests
pass in the default backend. Keep both interpreted and built execution in the
verification workflow; do not remove assertions to accommodate the crash.
