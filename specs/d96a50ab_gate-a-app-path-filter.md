# Fix gate A clean-tree assertion for non-default `app.path`

## Problem

Gate A in `just/sandbox/lifecycle/setup.just` asserts the factory clone's
working tree is clean via `git status --porcelain`. FILL clones the target app
into `~/app/<app.path>` — a directory *inside* the factory clone — so the
target clone shows up as an untracked entry (`?? <path>/`) in that porcelain
output. The default roster uses `path: target`, and the kernel `.gitignore`
happens to contain `/target/` (line 157), so the default is invisible to
porcelain. Any other path (e.g. `hello`) is reported as unexpected
working-tree changes and the mount fails at gate A:

```
unexpected working-tree changes in the factory clone (the tree must be clean):
     ?? hello/
```

The path is roster DATA, already parsed inside the gate's remote script. The
gate must treat the configured target path as expected untracked content, not
rely on a hand-maintained `.gitignore`.

## Root cause (verified by reading the code)

`just/sandbox/lifecycle/setup.just`, gate A remote script (`REMOTE_A`
heredoc, quoted — everything expands on the VM):

- It already parses `app_repo` and `app_path` out of `$cfg` with the same awk
  FILL uses, and defaults `app_path=target` when `app_repo` is set:
  ```bash
  [ -n "$app_repo" ] && [ -z "$app_path" ] && app_path=target
  ```
- It already uses `$app_path` for the target-clone SHA check
  (`tdir="$HOME/app/$app_path"`) — that part works for custom paths.
- The final cleanliness assertion is unconditional:
  ```bash
  porcelain="$(git status --porcelain)"
  if [ -n "$porcelain" ]; then
    echo "   unexpected working-tree changes in the factory clone (the tree must be clean):"
    printf '%s\n' "$porcelain" | sed 's/^/     /'
    exit 1
  fi
  ```
  It never filters out the expected `?? $app_path/` entry.

## Fix — one file: `just/sandbox/lifecycle/setup.just`

In gate A's `REMOTE_A` script, immediately before the cleanliness assertion,
filter the porcelain output to drop exactly the untracked-directory entry for
the configured target path. Only filter when `app_path` is non-empty (it is
empty in vendored mode, and an empty pattern must never hide real output):

```bash
porcelain="$(git status --porcelain)"
# The roster's app.path is DATA, not a .gitignore concern: FILL clones the
# target app to ~app/$app_path, so its untracked-directory entry is expected.
# Drop exactly that one line ('?? hello/'); every other line still fails.
if [ -n "$app_path" ]; then
  porcelain="$(printf '%s\n' "$porcelain" | grep -vxF "?? ${app_path}/" || true)"
fi
if [ -n "$porcelain" ]; then
  ... unchanged failure block ...
fi
```

Requirements for the edit:

- `grep -vxF` — whole-line, fixed-string match on exactly `?? <path>/`. Do
  NOT use a loose substring/prefix match: `?? hello-world/` or a modified
  file inside some other `hello*` path must still fail.
- `|| true` on the grep — REMOTE_A runs `set -uo pipefail` (no `-e`, so a
  grep exit 1 on "all lines filtered" would not abort, but keep the `|| true`
  for clarity and safety).
- Keep the failure message, the `sed 's/^/     /'` indent, and ALL of the
  mode/factory-sha/target-sha reporting lines byte-identical.
- Update the comment block above the cleanliness assertion (the one that ends
  "Only the FACTORY tree must be clean...") to mention the path filter.
- Do NOT touch the `.gitignore` `/target/` line — it stays as a harmless belt.

## Host-side preflight (mount.just) — verify, no change expected

`just/sandbox/mount.just` lines ~24–41: it parses `APP_PATH` from the roster
with the same awk and only *uses* it in vendored mode (`app.repo` empty), as a
local directory-existence check. In target mode (`app.repo` set) it performs
no path check at all — nothing there rejects or rewrites a custom path.
Confirm by reading those lines during implementation; expected outcome: no
edit. If you find any path assumption there, stop and report it instead of
editing.

## Verification — all for real, with gate output captured in the envelope

VMs cost money; sequence the work to use two VMs total.

Scratch roster (never committed, lives outside the repo):

```bash
sed 's|^  path: target|  path: hello|' \
  adws/adw_sssf_config/sssf.hello.config.yaml > /tmp/sssf.hello-path.config.yaml
grep -n 'path:' /tmp/sssf.hello-path.config.yaml   # must print 'path: hello'
```

### (a) Reproduce on CURRENT code (before the fix)

```bash
SSSF_CONFIG=/tmp/sssf.hello-path.config.yaml just sbx lifecycle mount repro-gatea
```

This must run create → fill → setup and FAIL at gate A with exactly:

```
[gate] A git integrity
   mode target
   ...
   unexpected working-tree changes in the factory clone (the tree must be clean):
     ?? hello/
```

Capture the output. Note the run id from the mount output (or
`sandbox_mount/host/run_record.py list`). Do NOT tear the VM down yet — it is
reused for (b) and (d).

### (b) After the fix: same scratch roster passes gate A, gates B–E green

Apply the setup.just edit, then re-run setup against the SAME run id from (a)
(the roster is already shipped on the VM; setup streams the HOST provisioner
and runs the host-side gate, so the fix takes effect without re-fill):

```bash
just sbx lifecycle setup <RUN_ID>
```

Must print `[gate] A PASS  git integrity (target payload)` (the `mode target`
and target-sha lines unchanged), confirm the target clone at `~/app/hello`
matches commit_sha, then `[gate] B PASS`, `C PASS`, `D PASS`, `E PASS`, and
`[setup] GATE PASSED`. Also spot-check on the VM:
`ssh <VM>.exe.xyz 'test -d ~/app/hello/.git && echo ok'`.

### (d) A genuinely unexpected change still fails (same VM, before teardown)

```bash
ssh <VM>.exe.xyz 'touch ~/app/NOT-EXPECTED.txt'
just sbx lifecycle setup <RUN_ID>
```

Gate A must FAIL and the porcelain listing must name `?? NOT-EXPECTED.txt`
(and must NOT list `?? hello/`). Capture the output. Then:

```bash
just sbx lifecycle teardown <RUN_ID>
```

### (c) Regression: default roster still green (fresh mount)

```bash
SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml just sbx lifecycle mount regress-gatea
```

Full mount must reach gates A–E green and the observe step. Note the run id,
then `just sbx lifecycle teardown <RUN_ID>`.

### Cleanup

- `rm /tmp/sssf.hello-path.config.yaml`
- `sandbox_mount/host/run_record.py list` — confirm no live VMs remain for
  these runs; teardown anything left.
- `git status --porcelain` — the only repo change is
  `just/sandbox/lifecycle/setup.just` (plus the spec file). The scratch roster
  never entered the repo.

## Compatibility

- Default `path: target`: unchanged — `.gitignore /target/` already hides it,
  and the filter would drop `?? target/` anyway. Belt and suspenders.
- Vendored mode (`app_repo` empty): `app_path` stays empty, no filter applied,
  behavior identical to today.
- Pre-existing run records (empty `factory_sha`): untouched by this change.

## Out of scope

README edits, `.gitignore` changes, mount.just changes (unless verification
uncovers a real bug — then report, don't fix silently), everything else.

## Done means

(a)–(d) demonstrated with gate output in the envelope, the fix landed in
`just/sandbox/lifecycle/setup.just` by this chain, scratch roster removed,
all test VMs torn down, tree otherwise clean.
