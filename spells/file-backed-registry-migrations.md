# File-backed registry migrations

Role: Software Developer

Category: File-backed registry migration

## Requirement

When a JSON registry points to companion files, schema changes must keep the index, sidecar files, install/update/delete flows, and remote publish payloads synchronized.

## Trigger

Use this review lens for local-first registries, markdown-backed records, manifest-plus-file layouts, import/install flows, or migrations from embedded content to sidecar files.

## Safe path

Define the canonical index fields and relative file constraints, write sidecar files atomically with registry updates, sanitize generated paths, migrate old embedded records into companion files, and verify fresh plus already-deployed storage migrations.
