# Vendored platform provenance

The benchmark platform is a purpose-built derivative of
`roc-platform-template-zig` release 1.1.0, commit `7aee8ac`.

Only the platform sources, generated Roc ABI, Zig build support, license, and
prebuilt target inputs needed by Roc are retained in this flattened directory.
Local changes add monotonic timing and allocation telemetry around explicit
measurement markers.
