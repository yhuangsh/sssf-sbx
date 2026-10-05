# Plan: derive the VM tag from the mounted app (kill the hard-coded `inkwell` tag)

Session: `73a0a4fd` · scope: 3 tracked files + this spec · no README, no roster-schema, no factory-repo changes.

## The defect

`just/sandbox/lifecycle/create.just:56-59` tags every VM `--tag inkwell`:

```bash
echo "vm:      creating $RUN_ID (ssh exe.dev new --tag inkwell) ..."
VM_JSON="$(ssh exe.dev new --name "$RUN_ID" --tag inkwell --json)"
```

`inkwell` is this kernel's monolithic ancestor. The kernel is now generalized — it mounts
any app named by the active roster's `app.repo` — so the tag must name the APP, not the
ancestor. The tag exists so a project's VMs can be found and bulk-cleaned as a group (the
control plane exposes it as `tags:` in `ssh exe.dev ls --json`, confirmed live:
`{"vm_name":"...","tags":["inkwell"],...}`). Wrong tag = a cleanup pass either misses the
app's VMs or sweeps another project's.

## Design — resolution order (explicit > derived > fallback)

1. **EXPLICIT** — `just sbx mount <run-id> [tag]` and
   `just sbx lifecycle create <run-id> [tag]` each gain an optional second positional.
   Non-empty value is used verbatim. Empty = unresolved.
2. **DERIVED** — when unresolved, derive from the ACTIVE roster's `app.repo` basename:
   `https://github.com/yhuangsh/hello-server.git` → `hello-server`, sanitized to a
   lowercase `[a-z0-9-]` label, truncated to 32 chars.
3. **FALLBACK** — no `app.repo` (vendored mode) → `sssf`.

Derivation lives **only in `create.just`**. `mount` just forwards its optional tag to
create; create derives when what it receives is empty. That keeps the roster parse in one
place instead of two, and it is exactly the "empty = unresolved" contract the task asks for.
`mount`'s arming preflight stays first and untouched (still before create).

## Files (exactly these three)

| File | Change |
|---|---|
| `just/sandbox/lifecycle/create.just` | optional `TAG` arg; resolve; `--tag "$TAG"`; surface + assert; record it |
| `just/sandbox/mount.just` | optional `TAG` arg; forward to create |
| `sandbox_mount/host/run_record.py` | add `"tag"` to `FIELDS` so `set tag=...` is accepted |

Do not touch: README, rosters, the factory repo, `fill/setup/observe/teardown`, `runs_table.py`.

---

## Edit 1 — `just/sandbox/lifecycle/create.just`

### 1a. Signature (line 13)

```just
# boot a VM for one run: just sbx lifecycle create <task-or-run-id> [tag]
create RUN_ID TAG='':
```

`just` accepts a defaulted positional after a required one, and `{{TAG}}` interpolates to
the empty string when it is omitted — verified with a scratch justfile:

```
$ just -f j.just foo x          → A=[x] B=[]
$ just -f j.just foo x mytag    → A=[x] B=[mytag]
$ just -f j.just foo x ""       → A=[x] B=[]
```

The file is `import`ed into the `sbx::lifecycle` module, which already sets
`positional-arguments`, `dotenv-load` and `working-directory := '../../..'` (repo root), so
no `set` lines and no new imports. `SSSF_CONFIG` is visible exactly as it is in `mount`/`fill`.

### 1b. Resolve the tag — new step between the record and the VM

Insert after the `trap _on_exit EXIT` block (line 55) and before the `── 3. the VM ──`
comment. This is before the VM exists, so the record always carries the tag even if create
later fails — the same "record first" discipline the phase already uses.

```bash
    # ── 2b. the tag ────────────────────────────────────────────────────────────
    # Bulk identification/cleanup filters on this, so it names the APP, not the
    # kernel's ancestor. Explicit arg wins; else derive from the ACTIVE roster's
    # app.repo basename; vendored (no repo:) -> "sssf". Same env var + fallback and
    # same app: block awk as mount/fill/teardown (a module hides the root `config`).
    ROSTER="${SSSF_CONFIG:-adws/adw_sssf_config/sssf.config.yaml}"
    TAG="{{TAG}}"
    if [ -z "$TAG" ] && [ -f "$ROSTER" ]; then
        APP_REPO=$(awk '
          /^app:[[:space:]]*$/      { a=1; next }
          /^[^[:space:]]/           { a=0 }
          a && /^[[:space:]]+repo:[[:space:]]/ { print $2; exit }
        ' "$ROSTER" 2>/dev/null || true)
        if [ -n "$APP_REPO" ]; then
            base="${APP_REPO##*/}"; base="${base%.git}"   # .../hello-server.git -> hello-server
            TAG="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' \
                   | sed -e 's/[^a-z0-9-]\+/-/g' -e 's/^-//' -e 's/-$//')"
            TAG="${TAG:0:32}"; TAG="${TAG%-}"             # cap, then re-trim a cut dash
        fi
    fi
    [ -n "$TAG" ] || TAG=sssf
    "$RR" set "$RUN_ID" tag="$TAG"
    echo "tag:     $TAG"
```

Notes the builder must keep:
- `[ -f "$ROSTER" ]` guard: today `create` works with no roster at all. The tag is cosmetic
  relative to the run, so a bogus/unset roster must not newly break create — it degrades to
  the `sssf` fallback. `mount`/`fill` still fail hard on a bad roster, which is where that
  belongs.
- Explicit tags are used verbatim (only omitting/empty routes to derivation). Do not
  sanitize the operator's explicit value.
- Trailing-slash repo URL → empty basename → empty derived tag → `sssf`. Acceptable; do not
  add URL parsing.

### 1c. Use the tag on the VM + update the echo (lines 56-59)

Replace the comment and the two lines with:

```bash
    # Control plane is plain ssh; --json makes it scriptable. --tag is what bulk
    # cleanup filters on — the APP this run mounts, resolved above.
    echo "vm:      creating $RUN_ID (tag $TAG) ..."
    VM_JSON="$(ssh exe.dev new --name "$RUN_ID" --tag "$TAG" --json)"
```

### 1d. Assert the tag actually landed

Insert immediately after `"$RR" set "$RUN_ID" vm_name="$VM_NAME" https_url="$HTTPS_URL"`
(around line 105), and fold the tag into the existing VM line right below it.

```bash
    # ── 3b. did the tag land? ──────────────────────────────────────────────────
    # `new --json`'s key names are UNVERIFIED; `ls --json` demonstrably carries
    # "tags". Trust the create payload when it names the tag, otherwise re-read the
    # one shape that is verified. A missing tag is FATAL: the tag's only job is bulk
    # cleanup, and a silent miss is a VM no cleanup pass will ever find.
    TAGS="$(printf '%s' "$VM_JSON" | python3 -c '
    import json, sys
    try:
        d = json.loads(sys.stdin.read())
    except ValueError:
        d = {}
    if isinstance(d, dict) and isinstance(d.get("vm"), dict):
        d = d["vm"]
    if isinstance(d, dict) and isinstance(d.get("vms"), list) and d["vms"]:
        d = d["vms"][0]
    if not isinstance(d, dict):
        d = {}
    print(" ".join(d.get("tags") or []))
    ')"
    if ! printf ' %s ' "$TAGS" | grep -qF " $TAG "; then
        TAGS="$(ssh exe.dev ls "$VM_NAME" --json | python3 -c '
    import json, sys
    want = sys.argv[1]
    vms = (json.load(sys.stdin) or {}).get("vms") or []
    hit = next((v for v in vms if v.get("vm_name") == want), {})
    print(" ".join(hit.get("tags") or []))
    ' "$VM_NAME")"
    fi
    case " $TAGS " in
        *" $TAG "*) echo "tag:     $TAG confirmed on $VM_NAME (tags: $TAGS)" ;;
        *) echo "create: tag '$TAG' did not land on $VM_NAME (reported: ${TAGS:-<none>})" >&2; exit 1 ;;
    esac

    echo "vm:      $VM_NAME  ->  $HTTPS_URL  (tag $TAG)"
```

The fallback `ls` block for `VM_NAME` (lines ~76-84) and the name/url python (lines ~63-73)
stay exactly as they are — do not refactor the verified parsing.

### 1e. Record it (nice-to-have, and it is clean here)

Already done in 1b via `"$RR" set "$RUN_ID" tag="$TAG"` — but that only works after Edit 3
adds the field.

---

## Edit 2 — `just/sandbox/mount.just`

### 2a. Signature (line 14)

```just
mount RUN_ID TAG='':
```

### 2b. Forward it (line 43)

```just
    just sbx lifecycle create "{{RUN_ID}}" "{{TAG}}"
```

That is the only functional change. The arming preflight above it (lines ~20-40) stays
untouched and first; an empty `{{TAG}}` arrives at create as the empty unresolved value.

### 2c. Header comment

Extend the file's top comment (and/or the recipe's inline arming comment) with one line:
`# Optional second arg = the VM tag; empty derives the app name in create.`

---

## Edit 3 — `sandbox_mount/host/run_record.py`

`FIELDS` is a closed schema — an unknown key in `set` is a hard error, so the new field must
be declared. Add `"tag",` right after `"vm_name",` in the `FIELDS` tuple (line ~45):

```python
FIELDS = (
    "run_id",
    "vm_name",
    "tag",
    "https_url",
    ...
)
```

Nothing else. `create()` seeds it `None` for free (it iterates `FIELDS`), `get` returns
`None` for records that predate the field (they are read with `record.get`), and
`runs_table.py` only reads named keys, so the extra column is invisible there. No teardown
or list change is needed for correctness.

---

## Verification — for real, against the live control plane

`ssh exe.dev` is authenticated (verified: `ssh exe.dev ls --json` exits 0). Three throwaway
VMs. All IDs must match `^[a-z0-9-]+$`; pick fresh, unambiguous ones, e.g.
`tagcheck-a-20261005-c0ffee`. Capture every command to `/tmp`, never into the repo.

Before anything: confirm the tree still parses and nothing pre-existing is confused with your
work.

```bash
cd /home/huang/playground/sssf-sbx
just --list --list-submodules >/dev/null && echo "justfile parses"
just sbx lifecycle --list >/dev/null 2>&1 || true   # `just sbx` lists; use the root listing as the gate
git status --short   # NOTE: `adws/adw_sssf_config/sssf.meta6.config.yaml` is untracked and
                     # PRE-EXISTING (another session) — leave it alone, it is not yours.
```

### (a) armed mount, hello roster, NO explicit tag → tag `hello-server`

```bash
export SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml
timeout 900 just sbx mount tagcheck-a-20261005-c0ffee > /tmp/tag-a.log 2>&1; echo "mount exit=$?"
grep -nE "tag: +hello-server" /tmp/tag-a.log
ID_A=$(sandbox_mount/host/run_record.py list | jq -r '.[0].run_id')
sandbox_mount/host/run_record.py get "$ID_A" tag          # -> hello-server
ssh exe.dev ls "$ID_A" --json | jq -r '.vms[] | select(.vm_name=="'"$ID_A"'") | .tags'  # -> ["hello-server"]
```

Pass: the create output shows `tag: hello-server` / `hello-server confirmed`, the record's
`tag` is `hello-server`, and the live `ls --json` agrees.

**Known caveat, not a regression:** the hello roster's `sssf.app.yaml` declares `checks:` in
the compact map form and `quality._load_checks` wants a list (documented in
`sssf.hello.config.yaml` itself, session `83c5881a`). The chain can therefore exit non-zero
at `setup`. That is AFTER create and does not invalidate (a); record the exit code and note
it. If mount dies *before* the `tag:` line, that IS a failure.

### (b) explicit-tag mount → tag `mytag`

```bash
SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml \
  timeout 900 just sbx mount tagcheck-b-20261005-c0ff11 mytag > /tmp/tag-b.log 2>&1; echo "exit=$?"
grep -nE "tag: +mytag" /tmp/tag-b.log
ID_B=$(sandbox_mount/host/run_record.py list | jq -r '.[0].run_id')
sandbox_mount/host/run_record.py get "$ID_B" tag          # -> mytag
ssh exe.dev ls "$ID_B" --json | jq -r '.vms[].tags'       # -> ["mytag"]
```

The hello roster is required here only because the default roster fails `mount`'s preflight
(`apps/your-app` is absent) — the explicit tag itself is roster-independent and is used
verbatim.

### (c) direct vendored create with the default roster → fallback `sssf`

```bash
unset SSSF_CONFIG
just sbx lifecycle create tagcheck-c-20261005-c0ff22 > /tmp/tag-c.log 2>&1; echo "exit=$?"
grep -nE "tag: +sssf" /tmp/tag-c.log
ID_C=$(sandbox_mount/host/run_record.py list | jq -r '.[0].run_id')
sandbox_mount/host/run_record.py get "$ID_C" tag          # -> sssf
ssh exe.dev ls "$ID_C" --json | jq -r '.vms[].tags'       # -> ["sssf"]
```

`sssf.config.yaml` has an `app:` block with `path:`/`manifest:` and no `repo:` → vendored →
fallback. Create waits up to 60s for ssh; that is expected.

### Preflight still runs BEFORE create

Cheap and decisive — the default roster is guaranteed unarmed (`ls apps` → no such file):

```bash
unset SSSF_CONFIG
just sbx mount tagcheck-pre-20261005-c0ff33 > /tmp/tag-pre.log 2>&1; echo "exit=$?"
grep -n "\[mount\] app.path 'apps/your-app' does not exist" /tmp/tag-pre.log
sandbox_mount/host/run_record.py list | jq 'length'        # unchanged — no record created
ssh exe.dev ls tagcheck-pre-20261005-c0ff33 --json | jq '.vms | length'  # 0 — no VM created
```

Must fail in seconds on the host, with the named arming error, BEFORE any VM. This also
confirms Edit 2 did not reorder anything.

### Teardown every throwaway VM

```bash
for id in "$ID_A" "$ID_B" "$ID_C"; do just sbx lifecycle teardown "$id" --no-harvest; done
sandbox_mount/host/run_record.py list \
  | jq -r '.[] | select(.closed_at == null) | .run_id'      # none of A/B/C
ssh exe.dev ls --json | jq -r '.vms[].vm_name'              # none of A/B/C
```

`--no-harvest` is deliberate: these boxes ran no work, harvest would fail and its failure
aborts destroy. Teardown with no VM is a normal, guarded path, so it is safe even if a mount
died early.

**Do not touch** the pre-existing live VM `hello-20261005-2c1c21` (tag `inkwell`, no run
record — it belongs to an earlier session), nor `smw-*`, nor `inkwell-1-*`.

---

## Done means

- (a), (b), (c) each demonstrated with the create output line, the run record's `tag`, and the
  live `ls --json` agreeing; preflight ordering shown; all test VMs torn down.
- Fix landed **by this chain** — the commit phase owns the commit; leave the tree dirty.
- Working tree clean apart from the four files below plus the pre-existing untracked meta6
  roster. Test run records live under `.sandbox/runs/` and are gitignored.

## changed_files (expected)

- `just/sandbox/lifecycle/create.just`
- `just/sandbox/mount.just`
- `sandbox_mount/host/run_record.py`
- `specs/73a0a4fd_vm-tag-derivation.md` (this plan; written by the planner)

## Out of scope

README and any doc update; roster schema/values; the factory repo; `runs_table.py` display of
the new field; a `teardown`/cleanup-by-tag recipe; parked items.
