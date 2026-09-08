# Development deployment safety

The development workflow implements a generic transaction around a Compose
service. Repository-specific commands, endpoints, paths, and credentials are
provided only through encrypted workflow secrets and variables.

## Deployment transaction

The target keeps transaction state in a private directory under the deployment
user's home. Before any live deployment mutation, the controller snapshots:

- the existing environment and configured deployment files;
- images resolved by the previous Compose configuration;
- the running service image reference and immutable image ID;
- whether the deployment directory and service existed;
- deployment directory, Compose project/file, service, and network metadata;
- data directories that would be created by the attempted deployment.

After the snapshot is complete, the controller marks it `ready` and atomically
creates a stable `active` pointer with a hard link. Pointer creation fails when
another transaction is active. Only then may the controller mark
`deployment-started` and create directories, replace files, or change the
Compose runtime. Rollback reads its configuration from the persisted snapshot,
not from workflow secrets that may have changed since the transaction began.

Before each deployment, `recover-development.sh` checks the active pointer and
rolls back an interrupted prior transaction. A pointer to a snapshot that was
never marked ready is cleared without touching the deployment. A ready snapshot
without `deployment-started` is also discarded without runtime changes.

The transaction remains open while service health, network health, the
source-defined deployment check, artifact build, browser E2E, publication, and
download checksum verification run. Finalization verifies that the active
pointer still names the same transaction, removes the pointer, and then removes
the snapshot.

On failure or cancellation before finalization, rollback removes containers for
the snapshotted Compose project, restores files and environment, removes data
directories created by the attempt, retags the saved immutable image when
needed, and starts the previous state with `--pull never`. It verifies the exact
service image ID, network online state, and service health. If no service existed,
it verifies that no attempted project container remains. State and the active
pointer are retained when restoration or health verification fails.

Rollback does not require the attempted Compose file to be valid. It performs a
normal Compose shutdown only when that file parses and otherwise uses Compose
project labels as the cleanup boundary. Diagnostics are emitted only for
services carrying the explicit diagnostics label.

Workflow rollback steps use `always()` and finalization outcome checks so normal
failure and cancellation both attempt cleanup. A hard runner or target shutdown
can prevent same-job cleanup; the stable pointer and next-run recovery handle
that case.

## Immutable artifact publication

Artifact names include the exact 40-character source SHA. An existing exact-name
asset is downloaded and reused only when its SHA-256 matches the new build. A
mismatch fails without deleting or replacing the existing asset.

Before release creation, the controller persists a random transaction marker,
the expected SHA, and whether the tag already exists. The marker is embedded in
the release body. If the create response is lost, rollback discovers and deletes
a release only when its target SHA and marker both match. A pre-existing tag is
never deleted. A tag created by the transaction is deleted through Gitea's
repository tag endpoint only after release ownership is proven.

A newly uploaded asset is recorded by the exact asset ID returned by Gitea and
may be deleted only by that ID. If an upload response is lost, ownership is
unknown: rollback retains the asset, release, and tag. A later run may reuse that
asset only after checksum verification.

## Source-defined acceptance

The public controller decodes encrypted build and E2E command values. Both run
from the prepared exact source revision with strict Bash error handling. They can
read these generic runtime values:

- `DEVELOPMENT_BUILD_ID`
- `DEVELOPMENT_ARTIFACT_PATH`
- `DEVELOPMENT_ENDPOINTS`
- `DEVELOPMENT_API_TOKEN`
- `DEVELOPMENT_ADMIN_TOKEN`

Build and E2E output remains in ephemeral runner logs. E2E must pass before any
release mutation. The uploaded artifact is downloaded and verified before the
deployment can be finalized.

## Relay lifecycle

`prepare-relay.sh` reserves the object key before image build or upload and
stores it in the step output and runner temporary directory. `build-image.sh`
persists the same handle again before upload. Cleanup can therefore address a
completed object or an incomplete multipart upload after any later failure.

Both the build failure path and the final `always()` cleanup job call
`cleanup-relay.sh`. Cleanup aborts every multipart upload for the exact key,
removes the completed object, and verifies both are absent. Its summary contains
only a truncated evidence hash, not the endpoint, bucket, key, credentials,
source location, or target. The scheduled sweeper remains defense in depth for a
hard workflow interruption.

## Runtime portability

Controller and test scripts require Bash. Development targets and hosted runners
are Linux environments and must provide GNU `base64`, `sed`, `sha256sum`, and
`timeout`, plus Docker Compose, AWS CLI, `curl`, `jq`, OpenSSL, and Zstandard
where referenced. Scripts check required commands before mutation. They are not
intended for POSIX `sh` or default macOS userland without compatible GNU tools.

## Privacy boundary

Public workflows, scripts, and documentation must not contain private project
names, host labels, private domains, IP addresses, account identifiers, or
credentials. SSH configuration uses generic `TARGET_SSH_*` inputs. Concrete
values remain encrypted secrets or variables. Existing secret configuration
must be migrated to those generic names before the production workflow is next
dispatched.

Repository-specific marker checks are supplied to the safety suite through the
base64-encoded `PRIVATE_MARKERS_B64` secret. The marker values therefore never
need to appear in this public repository.

Runner cleanup removes prepared source, image archives, credentials, acceptance
logs, release responses, downloaded artifacts, and relay handles on every
workflow result. Remote staging and payload files are also removed on success or
failure.

## Targeted validation

The local safety suite is intentionally isolated from external services:

```bash
bash tests/development-safety.test.sh
```

It covers shell/workflow syntax, relay persistence and multipart cleanup,
active-pointer ordering and recovery, rollback restoration and health checks,
finalization ownership, E2E gating, immutable artifacts, release/tag/asset
ownership, the Gitea tag deletion endpoint, and private-marker scanning.
