_CREDENTIAL_PAYLOAD_SHA256 = "8d4db03b8438ca74ea8aaf018cdb6494ed790b3fdd51f6796e76c30eec47ab87"

def _authenticated_download_repository(repository_ctx):
    repository_ctx.download(
        canonical_id = repository_ctx.name,
        output = "payload.txt",
        sha256 = _CREDENTIAL_PAYLOAD_SHA256,
        url = repository_ctx.attr.url,
    )
    repository_ctx.file(
        "BUILD.bazel",
        'exports_files(["payload.txt"])\n',
    )

authenticated_download_repository = repository_rule(
    implementation = _authenticated_download_repository,
    attrs = {
        "url": attr.string(mandatory = True),
    },
)
