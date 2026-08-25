# CandaceOS SDK source distribution

This archive is a generated source projection of one exact upstream CandaceOS
commit. It is intended to be consumed as a pinned Bazel repository and is not
an independently maintained source tree.

This SDK is deliberately scoped to compile-time agent-harness extensibility.
It does not define dynamically loaded plugins or replace Core's application,
storage, fleet, reconciliation, HTTP, or Web UI ownership. Compose an
executable against the supplied defaults and replace only the harness you own:

```starlark
go_binary(
    name = "candaceos",
    srcs = ["main.go"],
    deps = [
        "@candaceos//pkg/candaceos/harness",
        "@candaceos//services/candaceos-core/bootstrap",
    ],
)
```

`MODULE.bazel`, the generated `BUILD.bazel` files, the Go toolchain declaration,
and the source module versions are part of the archive. The companion SHA-256
file authenticates the complete compressed artifact. The consuming root module
still owns final Bzlmod resolution and must commit its own `MODULE.bazel.lock`.

Use `archive_override` for a filename-bearing archive URL. It honors this
repository's transitive Bzlmod metadata. GitHub's authenticated release-asset
API uses an extensionless URL, so private consumers use a literal
`http_archive` with `type = "tar.gz"`; their root module must also provide
`rules_go`, the Go SDK, and the Go repositories referenced by the exported
`go.mod`.

The compiled Core still requires its normal PostgreSQL database. Warden and
node-agent endpoints retain their normal defaults and are required for fleet
observation and reconciliation. Custom provider configuration belongs to the
embedding binary; Core does not interpret provider-specific environment.

See `candaceos-sdk-manifest.json` for the source revision and selected-tree
digest from which this archive was generated.
