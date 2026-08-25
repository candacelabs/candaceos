# CandaceOS agent guide

CandaceOS turns one Linux box into a private agent-operated app lab. This
file is the operating manual for agents working on that system's own source,
in either of its two homes:

- the `candaceos/` folder of the private `candace-server` monorepo, which is
  canonical; and
- the generated public repository `candacelabs/candaceos`, a one-way snapshot
  of that folder.

CandaceOS is operated by exactly the kind of system reading this file. The
invariants below are not style preferences; they are the trust model that
makes it acceptable to point an agent at a real machine. Hold yourself to
them before asking the platform to.

Commands are written relative to this directory. From a monorepo checkout,
prefix them with `candaceos/` (for example `./candaceos/install.sh`).

## If this checkout is candacelabs/candaceos

This repository is generated. Every file is the tracked content of the
monorepo's `candaceos/` folder at one exact source revision, published as a
fresh snapshot with no monorepo history. The provenance marker
`.candace-export.json` records the source repository, source path, exact
source revision, selected-tree object ID, and destination. Each published
snapshot also carries an immutable `export-<sha12>` tag and a matching
GitHub Release on this repository. The snapshot is licensed under the
Apache-2.0 `LICENSE` at this root.

Consequences:

- No change lands here. There is no PR flow and no maintainer watching this
  repository for contributions. The exporter compares the destination
  byte-for-byte against the snapshot it last published and halts on any
  divergence, so a commit made here is not merely overwritten later; it
  wedges every future export until an operator investigates.
- A fix belongs in the monorepo. If you can reach the canonical repository,
  make the change under its `candaceos/` folder and let the next `main` push
  republish it. If you cannot reach it, say exactly that and stop. Never
  commit to this repository, never open a PR against it, and never fork and
  patch it as a substitute for the upstream change.
- Version identity is the export tag. When citing behavior, cite the
  `export-<sha12>` tag or the source revision in `.candace-export.json`, not
  a branch.

## Prime invariants

Each rule names its enforcement point. Violating any of these is never an
acceptable side effect of another task.

1. **The default install is harmless.** `./install.sh` with no flags runs the
   simulated demo harness and a dry-run node executor, and no service in the
   project mounts the Docker socket: in `compose.yaml`, only the
   `live`-profile `agent-live` service has `/var/run/docker.sock`. The
   dry-run executor performs Compose's read-only `config` preflight and
   returns the exact mutation plan without executing it.
2. **The live executor is the sole one-box socket holder, behind three
   explicit acts.** `--live-executor` requires an agent backend flag
   (`install.sh` rejects it without `--copilot` or `--opencode`), and the
   exact confirmation phrase `I_UNDERSTAND_DOCKER_SOCKET_IS_ROOT` must be
   typed interactively or supplied as `CANDACEOS_LIVE_CONFIRM` for
   non-interactive installs. The socket is host-root-equivalent; the
   installer says so before asking. Re-running the default installer demotes
   a previously live agent back to dry-run. The only other socket holders in
   this tree are the fleet's live worker agents (`fleet/worker.compose.yaml`)
   and the CD updater (`updater.compose.yaml`) — executors and the deployer,
   never a reasoning process.
3. **Core never receives the Docker socket**, in any Compose file in this
   tree. Core bridges the internal control network and the provider networks,
   mounts the app workspace read-only, and owns approvals, run fencing,
   receipts, placement, and the operator UI. The provider sidecars (Copilot
   CLI, OpenCode) get outbound network access and the writable workspace but
   no route to PostgreSQL, Warden, the executor, or the socket (`compose.yaml`
   networks; `fleet/control.compose.yaml`).
4. **The executor's mutation surface is two commands.** A live assignment
   runs only `docker compose ... config --quiet` and then
   `docker compose ... up -d --remove-orphans <service>`, invoked without a
   shell. The agent never runs `down`, never deletes volumes, and never
   touches host firewall rules, Tailscale ACLs, systemd units, or Docker
   daemon settings. Operator scripts that do run `down` (`uninstall.sh`,
   `fleet/node.sh rollback`) are operator-invoked commands, not agent
   capabilities, and even they never pass `--volumes` against durable state.
5. **Approval and fencing live in Core.** A harness proposes; Core approves,
   dispatches the typed reconcile, and records the receipt. Every mutation
   carries the Warden leader ID and term; the agent persists a higher fence
   before execution and rejects stale leaders and duplicate-term claimants.
   Losing quorum or an authoritative alive leader blocks reconcile approval
   and dispatch; it never fails open.
6. **One bounded writable workspace.** Apps are ordinary Compose directories
   below the workspace (`apps/`; the checked-in `hello` app is the template,
   reachable only on `127.0.0.1:18080` after an explicitly approved live
   assignment). The installer initializes the workspace as a local `main`
   Git repository and commits the hello app only when no `HEAD` exists; it
   never replaces existing history. The agent materializes approved
   revisions as sealed read-only snapshots in a bounded cache: 128 entries
   and 4 GiB by default, overridable via
   `CANDACEOS_AGENT_REVISION_MAX_ENTRIES` / `..._MAX_BYTES`, which
   `install.sh` validates as positive int64 before touching anything. A full
   cache keeps existing snapshots usable but rejects new revisions. Cleanup
   is deliberately manual because a live app may bind-mount a snapshot: stop
   reconciliation and the agent, remove only unused directories below the
   revision root, then restart.
7. **Secrets are generated, mode-600, and never widened.** The installer
   generates `random_hex_32` values with OpenSSL for the PostgreSQL password,
   agent token, Copilot connection token, and OpenCode password, and rewrites
   the runtime `.env` atomically with mode 600. It refuses a symlinked or
   wider-permission `.env`, duplicate or malformed names, placeholder or
   malformed secrets, and values containing whitespace, `#`, `$`, quotes, or
   backslashes (`environment.generated.sh`,
   `candaceos_environment_reconcile`). Provider API keys for OpenCode pass
   through the invoking environment only and are never persisted.
8. **Nothing here changes the host.** No script in this tree edits firewall
   rules, Tailscale ACLs, systemd units, Docker daemon settings, host DNS,
   or unrelated Compose projects. Fleet state must resolve below the
   invoking user's home directory (`fleet/node.sh`, `resolve_root`), and the
   updater deploy root defaults there. Keep it that way: if a task appears
   to require a host change, stop and surface the trust-model question
   instead of writing it.

## Entry points

### One-box install, status, uninstall

| Invocation | Agent harness | Executor | Host Docker socket |
|---|---|---|---|
| `./install.sh` | simulated demo | dry run | absent |
| `./install.sh --copilot` | official Copilot CLI 1.0.80 | dry run | absent |
| `./install.sh --copilot --live-executor` | official CLI 1.0.80 | live | agent only |
| `./install.sh --opencode` | pinned OpenCode 1.18.21 sidecar | dry run | absent |
| `./install.sh --opencode --live-executor` | pinned OpenCode sidecar | live | agent only |

`install.sh` is idempotent: it preserves materialized `.env` values, stops a
deselected provider sidecar, demotes or promotes the executor to match the
flags, and reports success only after Compose's bounded health wait
(`--wait --wait-timeout 120`) passes. `CANDACEOS_STATE_ROOT` selects an
external state root (used by the managed CD deployment); it defaults to this
directory. Core publishes `0.0.0.0:7780` with no built-in login; any client
that can reach the listener can operate it, and only browser mutations are
cross-origin-checked. Do not treat the one-box listener as authenticated.

`./status.sh` runs `docker compose ps` across every profile and fails if
CandaceOS is not installed. `./uninstall.sh` runs `down --remove-orphans`
across every profile and deliberately preserves the PostgreSQL volume,
receipts, app files, runtime state, and `.env`; removing those is a separate,
intentional operator act.

### Harness backend selector

`CANDACEOS_HARNESS_BACKEND=demo|copilot-cli|ollama|opencode` is the canonical
Core selector. A bare Core process defaults to `copilot-cli`. The installer
pins the selector through generated environment profiles: no flags selects
`demo`, `--copilot` selects `copilot-cli`, `--opencode` selects `opencode`
(`environment.generated.sh`, `candaceos_environment_apply_profile`). Fleet
deployment defaults to `copilot-cli` and additionally accepts `--harness
ollama` and the fleet-only `--harness custom`. Legacy `CANDACEOS_MODE` is
normalized only while loading configuration and rejected when it conflicts
with the canonical selector.

Backend facts an agent must not misstate:

- **Copilot.** Both installers reuse an exact compatible host binary or
  checksum-install pinned CLI 1.0.80 (archive and binary SHA-256 verified,
  `install-copilot.sh`) into digest-addressed user-owned state, then
  bind-mount it read-only into an isolated sidecar that reuses the Core
  image. CandaceOS never builds, transmits, or retains a Copilot image. The
  GitHub token is inherited in order from `COPILOT_GITHUB_TOKEN` (including
  a value persisted as operator state in the mode-600 `.env`), `GH_TOKEN`,
  `GITHUB_TOKEN`, then an authenticated host `gh`, then a hidden interactive
  prompt. Only a value supplied as `COPILOT_GITHUB_TOKEN` (or already in
  `.env`) is persisted; a token first discovered from the fallback sources
  is exported for that Compose run only, because the environment reconcile
  runs before token resolution. Copilot steering is native: `Steer now` interjects into the active
  turn.
- **OpenCode.** The reviewed v1.18.21 Linux x64 release is built into a
  private container from its upstream archive and published SHA-256
  (`Dockerfile.opencode`). Its port and generated Basic-auth credential are
  never published to the host. The root-owned managed policy
  (`opencode-managed.json`, pinned via `OPENCODE_CONFIG`) permits workspace
  reads/edits and ordinary build/test/status commands and denies
  external-directory access and other shell commands; a project-local config
  cannot override it. That policy is defense in depth, not the sandbox — the
  container and its mounts are the hard boundary, and a credential visible to
  the OpenCode process is not isolated from code it runs. Select an explicit
  `provider/model` (`CANDACEOS_OPENCODE_MODEL`, persisted operator state);
  Core does not guess one. OpenCode has no supported soft mid-turn
  injection, so `Steer now` aborts the active turn and resubmits; `Send
  after current` is an ordered follow-up. Steering queues and run mappings
  are in memory; a Core restart does not yet replay them.
- **Ollama** (fleet only). The manifest-pinned official 0.20.4 image is
  pulled only on the GPU worker; models persist below the fleet state root.
  Before Core activates, a bounded warm-up must prove the model is
  tool-capable, loaded at the configured context, and fully GPU-resident
  (`fleet/node.sh`, `verify_ollama_model`). The observed model digest, image
  digest, and policy are recorded in the release evidence and receipt, and a
  post-deploy acceptance run must complete the `candace_fleet_status` tool
  and return assistant text. This backend never reads GitHub or Copilot
  credentials.
- **Custom** (fleet only). An externally compiled Core binary, built from
  the SDK archive, is layered over the standard Core runtime image. The
  deployer records its SHA-256 and SDK revision in the receipt and refuses a
  binary whose SDK revision differs from the exact deployed source revision.

### Three-node fleet (`fleet.sh`)

The fleet uses the same Core, Warden, and node-agent primitives across one
control node and two workers (one labeled `gpu=true`). Node targets and
addresses are parameters, not facts baked into this tree: the tracked
defaults are neutral placeholders, and real operator topology is supplied by
an optional topology file outside the export root
(`server_admin_scripts/candaceos-fleet-topology.env` in the monorepo, or a
gitignored `fleet/topology.local.env` locally) or by the
`CANDACEOS_CONTROL_TARGET`/`..._IP`, `..._AI_...`, `..._PROD_...` overrides
and their command-line flags. Never hardcode a real IP, hostname, or
username into a tracked file; that is what the topology file is for.

- `./fleet.sh plan` is credential-free and performs no SSH, Docker,
  filesystem, or credential reads (`test-fleet.sh` enforces this with
  poisoned stub binaries).
- `./fleet.sh deploy` requires clean `go/` and `candaceos/` trees and a
  `HEAD` that is the exact pushed upstream revision, plus `flock` on the
  operator host and `rsync` on the invoking host and both remote hosts. It
  builds the four CandaceOS images once on the invoking host — never on the
  control node — plus a release-tagged pinned PostgreSQL, then rsyncs
  uncompressed image archives as resumable rolling deltas into a bounded
  per-role `image-cache/` on each node. A node verifies the complete
  archive SHA-256 before `docker load`, and the deployer checks
  every loaded image's canonical runtime fingerprint (platform, RootFS
  layers, normalized runtime Config — not Docker metadata) before any live
  writer stops. First cutover discovers the running legacy one-box stack,
  quiesces writers, snapshots Git and PostgreSQL consistently, and restores
  and fingerprint-verifies the database on the control node before Core
  starts; the old containers and state remain intact for rollback. Upgrades
  advance workers first and cut the singleton control stack over last.
  Success requires Core health, the exact Git source HEAD served read-only
  on port 9418, both authenticated live-agent identities, and three
  authoritative Warden views agreeing on one term, leader, voter/address
  set, and three alive peers. Fleet workers keep the compatibility
  workspace empty and read-only; their agents fetch approved commits from
  the control node's read-only Git service into agent-owned bare
  repositories instead of sharing a writable worktree.
- **Receipts, lock, journal.** Deploy and rollback serialize through a
  nonblocking flock on `receipt_root/operator.lock`
  (`CANDACEOS_FLEET_RECEIPT_ROOT`, default
  `~/.local/state/candaceos-fleet/receipts`). Before any service stops, the
  deployer fsyncs a mode-600 cutover journal; on failure the EXIT trap rolls
  the candidate back exactly once and writes a `failed` receipt. Rerunning
  deploy from the same operator account (or the same receipt root) first
  recovers the newest interrupted journal — only the newest journal is
  authoritative, so an older failed receipt can never roll back a newer
  deployed release — and marks it `recovered`. This is an operator-side
  serialization and recovery boundary, not a distributed lock.
- `./fleet.sh rollback [RECEIPT]` (default: the latest `deployed` receipt)
  restores the three recorded previous releases, preserving a
  forward-recovery database dump before restoring the per-release backup,
  and refuses to restart legacy services while a failed candidate may still
  own their ports. It is resumable per node. `./fleet.sh status` re-verifies
  Core, source HEAD, both agents, and quorum.
- `fleet/node.sh` is the single-file remote helper, streamed over
  `ssh bash -s` with `%q`-quoted arguments. Releases are immutable
  directories under the per-user state root with a `current` symlink
  committed only after activation; the state root must resolve below the
  invoking user's home directory.

No host checkout, firewall, Tailscale ACL, systemd unit, Docker daemon
setting, public route, or unrelated Compose project is changed by any fleet
operation.

### Merge-to-deploy updater (`bootstrap-updater.sh`, `updater.sh`)

`./bootstrap-updater.sh` arms continuous deployment on a bootstrap node. It
inherits the host's authenticated `gh` credential (or a token from the
environment) into a mode-600 file under the deploy root, clones the local
checkout to pin the currently running revision as the first rollback source,
adopts the running stack's `.env`, app workspace, and file-backed runtime
into the external deploy root (`CANDACEOS_DEPLOY_ROOT`, default
`~/.local/share/candaceos-deployer`) while briefly quiescing it, restores the
original state root if adoption fails, verifies the adopted stack's health
endpoint, records the bootstrap revision exactly once (a later bootstrap
never overwrites a revision advanced by a verified deployment,
`record-bootstrap-revision.sh`), and starts the separate `candaceos-cd`
Compose project. Re-run it to rotate the credential or rebuild the updater
image; `--force-recreate` is what makes rotation replace the bind-mounted
token inode.

The updater container runs read-only with the operator's UID/GID plus only
the Docker socket's supplementary group. It polls the configured
`CANDACEOS_REPOSITORY` — a required parameter with no default — for exact
`main` commit IDs every `CANDACEOS_POLL_INTERVAL` seconds (default 30,
minimum 5). Its container healthcheck tolerates a 30-minute heartbeat gap
so a legitimate source build plus Compose's bounded readiness wait is not
restarted mid-transaction. A revision without the deployment contract
(`candaceos/install.sh`, `compose.yaml`, and both generated environment
files present at that commit) leaves the updater armed and the current stack
alone; a revision that does not touch CandaceOS or its Go inputs is skipped
with a receipt. A relevant revision is checked out exactly (detached, forced,
`clean -ffdx`), deployed with `install.sh --copilot` — real Copilot, always
the dry-run executor — and verified against the loopback health endpoint and
all five required services before the revision receipt advances. A failed
candidate is marked on GitHub (commit status `candaceos/bootstrap-deploy`),
rolled back to the exact previously recorded revision, reverified, and
retried from durable per-revision state after 60 seconds with exponential
backoff capped at one hour, until it succeeds or a newer `main` revision
supersedes it. GitHub status publication failures land in a durable outbox
and are retried without redeploying.

The updater never pushes, never merges, never changes network policy, and
never enables the live executor. `./updater-status.sh` prints the active
revision, receipts (`control/deployments.jsonl`), and container state.

### SDK packaging and publishing (`sdk/`)

The SDK is a deterministic source projection for compile-time harness and
component extensibility — not a plugin system. `sdk/dist/allowlist.txt` is
the exact exported set. `sdk/dist/package.sh` extracts those paths from Git
objects at one exact revision and proves the extraction matches the tracked
tree, strips the monorepo-local candacelib override from `go.mod`, installs
the pinned Bazel/rules_go/Gazelle/Go toolchain templates, writes
`candaceos-sdk-manifest.json` with the selected-tree digest, runs Gazelle
and `bazel mod tidy` twice in the pinned Bazel container and fails unless
the generated metadata is byte-identical, then creates the normalized
archive twice and fails unless the bytes are identical. Determinism is the
contract: the same commit must always produce the same archive.

`sdk/publish.sh [SOURCE_REF]` packages that archive and publishes it as the
prerelease `candaceos-sdk-<full-sha>` on the configured
`CANDACEOS_SDK_REPOSITORY` — a required parameter with no default — with the
archive and its `.sha256` as assets. It never clobbers: an existing asset is
accepted only when GitHub's recorded digest matches the newly reproduced
bytes, and a conflicting asset or tag fails the publish. Its `KEY=value`
output is the consumer's lock material (SHA-256, SRI integrity,
`strip_prefix`, and the asset API URLs). `sdk/github-credential-helper.sh` is
the Bazel credential helper for private consumption: it answers only for
`https://api.github.com`, refuses to run when a direct token environment
variable is set, and requires a mode-600 token file
(`CANDACEOS_SDK_GITHUB_TOKEN_FILE`) or an authenticated `gh` fallback,
emitting headers with no logging.

### Test suites

- `./test-install-validation.sh` — quota validation, placeholder-secret
  rejection, and fail-before-mutation ordering. Needs bash only; Docker is
  stubbed.
- `./test-fleet.sh` — the hermetic fleet suite: the plan command's read-only
  contract (enforced with poisoned transport stubs), SSH argument quoting,
  receipt/journal crash recovery, rollback gating, the image
  fingerprint/save/rsync/load pipeline, the fleet Compose models, and the
  static regression guards. Needs bash, git, python3, flock, the Docker CLI
  with the Compose plugin (for `config`), and an existing
  `/var/run/docker.sock` to stat. It mutates no daemon state and contacts
  no network or remote host.
- `./sdk/test-publish.sh` — publish idempotence, the non-clobber refusal,
  and the credential helper's host pinning and mode checks. Hermetic: fake
  `gh`, fake packager, no network.
- `./test-updater.sh` — runs the install-validation suite first, then the
  bootstrap marker semantics and the retry/finalization/rollback state
  machines by sourcing `updater.sh` with mocked `docker` and `curl`, and
  finally builds `Dockerfile.updater` and exercises the container health
  and askpass paths. Mostly hermetic; that final phase needs a Docker
  daemon.
- `./test-claw-chat.sh` — the disposable demo-backed stack with the real
  pinned OpenCode sidecar: dashboard-to-chat link, SSE transcript,
  reconnect snapshot, exact-run abort, stale-run fence, Core's
  container-network listener, the sidecar's absent published port, then the
  pinned OpenCode SDK contract Go tests inside the built Core image. Needs
  a Docker daemon, network, and the monorepo `go/` tree; no provider
  credential is used or accepted.
- `./test-opencode-sdk-contract.sh` — the single live OpenCode SDK contract
  spec against the pinned server. Docker daemon, network, and the monorepo
  `go/` tree.
- `./sdk/test-external-consumer.sh` — archive determinism plus real Bazel
  consumers (`http_archive`, `archive_override`, and the credential-cache
  behavior). Docker daemon, network, monorepo `go/` history; the heaviest
  suite.

CI runs `test-claw-chat.sh` on a self-hosted Docker runner for every pull
request that touches CandaceOS or its Go inputs
(`.github/workflows/candaceos-acceptance.yml` in the monorepo).

## Configuration doctrine

**Generated projections are read-only.** `.env.example`,
`environment.generated.sh`, and `compose.environment.generated.yaml` are
projections of the monorepo-root `Candacefile`, the single authored owner of
names, defaults, lifecycles, profiles, and per-service environment. In the
monorepo, edit the `Candacefile` and run
`python3 tools/candace_environment.py write` (check mode fails CI on drift).
In the standalone repository the generator and `Candacefile` are absent:
never edit the generated files by hand anywhere — a hand edit diverges from
the owner and is erased by the next snapshot. `compose.yaml` owns container
structure only; every command that reconstructs the project layers the
generated environment overlay onto it.

**The runtime `.env` is data, not policy.** The installer never sources it.
It atomically rewrites exactly the secret, host, and explicit operator
values: generated `random_hex_32` secrets; host facts (state root, UID/GID,
workspace path); and operator state (`COPILOT_GITHUB_TOKEN`,
`CANDACEOS_OPENCODE_MODEL`, the revision-cache quotas). Policy defaults and
OpenCode provider pass-through credentials (`OPENAI_API_KEY`,
`ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`) are never persisted there.

**Never commit runtime or secret state.** `.gitignore` covers `.env` and the
runtime artifact directories (`runtime/`, `revisions/`). App workspace
contents, receipts, fleet caches, deploy roots, provider credentials, and
OpenCode OAuth state are all uncommittable operator state, wherever they
appear on disk.

**Topology is external.** Tracked fleet defaults are neutral placeholders;
real node targets and addresses come from the topology file described above
or explicit overrides. **Repository targets are required parameters.**
`CANDACEOS_REPOSITORY` (updater) and `CANDACEOS_SDK_REPOSITORY` (SDK
publish) have no default; scripts fail closed when they are unset rather
than guessing a repository.

## Working on this code (monorepo)

Changes are made in the monorepo's `candaceos/` folder only.

- **Every edit is a public release.** The folder is an active export: the
  moment a change reaches `main`, it is published to `candacelabs/candaceos`
  and tagged. Run `candace export validate` and `candace export preview`
  (or `python3 tools/component_export.py validate|preview`) before review.
  The exporter is not a secret scanner; review the actual diff as public
  content.
- **No operator identifiers.** Never introduce a real tailnet IP, hostname,
  machine name, username, or private repository slug into tracked files
  under `candaceos/`. The enforcement is a static grep gate — the same guard
  class `test-fleet.sh` already uses for its regression pins. When such a
  gate fires, fix the content; never widen or delete the pattern.
- **Bash style.** `set -Eeuo pipefail`; resolve the script directory with
  `CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P`; a
  component-prefixed `die()`; `printf` over `echo`; `%q` for anything that
  crosses SSH; atomic writes via mode-600 temporary file plus `mv`.
  Container-side helpers that run under BusyBox/Alpine (`fleet/source.sh`,
  `updater-git-askpass.sh`) stay POSIX `sh` with `set -eu`. Tests
  `bash -n` every script they cover; keep that true for new scripts.
- **Run the hermetic suites after changes**: `./candaceos/test-fleet.sh`,
  `./candaceos/sdk/test-publish.sh`, `./candaceos/test-install-validation.sh`,
  and `./candaceos/test-updater.sh` where a Docker daemon is available. Run
  the Docker-heavy acceptance gates when touching what they cover.
- **Build contexts reach `../go` by design.** `compose.yaml`,
  `Dockerfile.core`, and the fleet image builds compile Core, Warden, and
  the agent from the monorepo Go module. The canonical monorepo deploy —
  installer, fleet, updater, all building from the checkout — must keep
  working. Do not vendor `go/` into this folder or repoint contexts to make
  the standalone snapshot self-building; the snapshot is deliberately not a
  build root for Core.
- Read `go/services/candaceos-core/CLAUDE.md` before touching Core, harness
  adapters, or their contracts; `docs/candaceos_architecture.md` and
  `docs/candaceos_sdk.md` (monorepo-only paths) own the ownership, failure,
  and SDK-consumption semantics this file summarizes.

## What cannot be done from this repository alone

Stated plainly so no agent flails against it:

- **Building Core, Warden, or node-agent images.** Their build contexts are
  `../go`, which exists only in the monorepo. Only `Dockerfile.opencode`,
  `Dockerfile.updater`, and `Dockerfile.source` build from this tree alone.
  Consequently `./install.sh` and `./fleet.sh deploy` cannot complete here.
- **Packaging or publishing the SDK.** `sdk/dist/package.sh` reads
  `candaceos/sdk/dist/allowlist.txt` and the allowlisted `go/` paths out of
  monorepo Git history, which this snapshot does not carry;
  `sdk/publish.sh` additionally needs the configured
  `CANDACEOS_SDK_REPOSITORY` and an authenticated `gh` with Contents write.
- **Fleet deployment of a custom Core binary.** Even with an SDK-built
  binary in hand, `fleet.sh` requires a clean, pushed canonical monorepo
  checkout whose revision equals the binary's SDK revision.
- **The Docker-heavy tests that mount `go/`**: `test-claw-chat.sh`,
  `test-opencode-sdk-contract.sh`, and `sdk/test-external-consumer.sh`.
- **Any change.** Changes land upstream; see the top of this file.

What remains possible here: reading and auditing everything; running
`./test-install-validation.sh`, `./sdk/test-publish.sh`, and
`./test-updater.sh`; building the three self-contained images; and
consuming a published SDK archive from Bazel as an external repository.
`./test-fleet.sh` is hermetic but written for the monorepo layout: its
operator-side bundle check runs Git against the checkout's parent
directory, which is the monorepo root there and nothing in particular here.
