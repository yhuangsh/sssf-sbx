# Plan: delta-tar the teardown artifacts step

## Problem

`just sbx lifecycle teardown`'s artifacts step (`just/sandbox/lifecycle/teardown.just`,
step "── 1. artifacts ──", currently the `ssh ... "cd app ...; tar cf - \$P"` block)
tars the WHOLE `specs/`, `app_docs/`, sssf.db, run.log trees **uncompressed**.
Measured on a real box: 9.95MB transferred at ~16KB/s over the dal-region link ≈
**10 minutes**, even when the run changed NOTHING in the factory tree. The host
already owns every tracked-and-unmodified byte — it cloned the same sha, and mount
gate A asserts the tree clean. Measured run-delta (untracked non-ignored +
HEAD-modified files under specs/ and app_docs/) on that box: **ZERO files**. The
only unique data is the gitignored trace db (56KB) and run.log.

## Scope

One file: `just/sandbox/lifecycle/teardown.just`. Nothing else. Out of scope:
harvest bundle mechanics, provisioner, everything else.

## Change

Replace the artifacts step (the `if [ "$VM_ALIVE" = 1 ]; then ... fi` block under
`# ── 1. artifacts ──`) with a **delta tar**:

### 1. VM-side: build a delta file list instead of tarring whole trees

One ssh round trip. Run a remote `bash -s` (heredoc or a single quoted command —
builder's choice, but mind quoting: `$TAR_PATHS` must expand on the HOST and be
passed in, everything else stays literal on the VM). Remote logic:

- `cd app 2>/dev/null || exit 0` — preserve the existing no-git-repo semantics
  exactly (run died before the clone → silent success, empty stream).
- Build the list restricted to the existing `$TAR_PATHS` set (`specs app_docs`,
  computed above the block — that variable and the target-mode
  `$APP_PATH/$APP_MANIFEST` extension stay as-is):
  - `git ls-files --others --exclude-standard -- $TAR_PATHS` — new/untracked,
    non-ignored files.
  - `git diff --name-only --diff-filter=d HEAD -- $TAR_PATHS` — HEAD-modified
    tracked files. `--diff-filter=d` (lowercase) EXCLUDES deleted files, which
    would otherwise appear in the list and make `tar -T` fail on a missing name.
  - PLUS the always-files that are gitignored (git never reports them), each
    included only if present (`[ -f "$f" ]`): `adws/adw_data/sssf.db`, `run.log`,
    and in target mode `$APP_PATH/$APP_MANIFEST`.
  - `sort -u` the union into a temp listfile on the VM (`mktemp`, `rm -f` it in
    both branches).
- Guard git invocations so a weird repo state (e.g. no HEAD) degrades to
  whatever the always-files give, not a hard remote failure.

### 2. Empty vs non-empty list

- **Empty list** → the VM prints `no run artifacts to pull — factory tree
  unchanged` to **stderr** (stdout is the tar stream; ssh forwards stderr to the
  host terminal) and exits 0 with an empty stdout. Host side: still `mkdir -p
  "$ART"` (the artifacts dir IS created — this supersedes the current
  `rmdir "$ART"` empty-dir cleanup, which must be removed), no transfer attempted.
  Replace the old `echo "   artifacts: none found on the vm"` else-branch with
  this behavior; if the builder prefers the message host-side, the empty-tar
  branch prints exactly `no run artifacts to pull — factory tree unchanged`
  instead. Either way that exact string appears, and the old message goes away.
- **Non-empty** → VM runs `tar czf - -T <listfile>` (gzip — the payload is tiny
  so CPU is free, and the link is the bottleneck), host extracts with
  `tar xzf "$TAR_TMP" -C "$ART"` and prints the existing
  `   artifacts -> $ART` line unchanged.

### 3. Keep these semantics untouched

- The sentinel: `> "$TAR_TMP" || true` — a failed artifact pull must NOT abort
  the teardown (only a failed harvest does).
- Order: artifacts → harvest → destroy → close. Harvest failure still aborts
  before destroy with the existing `!!` messages (that block is not touched).
- Every other message shape (`── teardown`, `vm: ...`, `harvest: ...`, etc.).
- `mktemp`/`rm -f "$TAR_TMP"` host-side handling.
- `VM_ALIVE = 0` branch: `   artifacts: skipped (no vm)` unchanged.

### 4. Comment the WHY (required)

Above the new remote command, a comment block with the measured numbers:

- whole-tree uncompressed tar: 9.95MB on a real box whose run changed nothing;
- dal-region link ~16KB/s → ≈10 minutes of teardown spent transferring bytes the
  host already has;
- the host owns every tracked-unchanged byte by construction (it cloned the same
  sha; mount gate A asserts the tree clean), so only the run-delta (untracked +
  HEAD-modified under the tar paths) plus the gitignored always-files
  (sssf.db 56KB, run.log, target manifest) can be unique.

## Verify (for real, with timings in the envelope)

Current `.sandbox/runs/` holds only `preflight-armed-check-20261005-ffad0a`,
already closed — there is NO live hello-* VM, so (a) falls through to a fresh VM
per the prompt.

- **(b) full cycle, fresh armed mount:**
  1. `SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml just sbx mount hello-<suffix>`
     — gates A–E must be green.
  2. Drive a small execute that writes at least one new file under BOTH `specs/`
     and `app_docs/`, e.g.
     `just sbx lifecycle execute hello-<suffix> "create a one-line spec note file"`
     (detached; wait for completion via the returned PID / `just sbx lifecycle observe`).
  3. `time just sbx lifecycle teardown hello-<suffix>` — record wall time of the
     artifacts step (expect seconds, not minutes). Confirm:
     - the run's NEW spec/doc files ARE in `.sandbox/runs/hello-<suffix>-artifacts/`,
     - `sssf.db` present there,
     - harvest bundle verified (harvest output green before destroy),
     - teardown completes well under a minute for the artifacts step.
- **(a)** if a live hello-* VM exists at build time, also/instead re-run its
  teardown: completes well under a minute, trace db landed in the artifacts dir.
- **(c) harvest-failure abort:** a read-only check is acceptable — confirm the
  `just sbx manage harvest "$RUN_ID" || { ... exit 1; }` block is untouched and
  still ordered before the destroy step, so a failed harvest leaves the VM alive
  and aborts the teardown.
- Also sanity-check the empty-delta path if cheap (teardown of a run that wrote
  nothing): the `no run artifacts to pull — factory tree unchanged` message
  prints, the (empty) artifacts dir exists, teardown completes.

## Done means

(b) (and (a) if applicable) + (c) demonstrated with real timings in the
envelope; fix landed by this chain; `git status` clean of scratch. The chain's
commit phase owns the commit — leave the work dirty in the tree. changed_files
lists only files that exist afterwards (`just/sandbox/lifecycle/teardown.just`).
