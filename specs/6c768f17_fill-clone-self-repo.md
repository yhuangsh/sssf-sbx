# Plan — Kernel fill clones the wrong repo (self-reference fix)

## Bug

`just/sandbox/lifecycle/fill.just` line 30:

```
REPO="https://github.com/yhuangsh/inkwell-agent-sandboxes-and-software-factory.git"
```

This is a leftover from importing the kernel from the ancestor factory repo. This
kernel's fill must clone THIS KERNEL — self-referential, exactly like the factory
repo's fill points at its own fork. Evidence already gathered (not to be re-derived):

- A hello-roster mount produced a VM whose `~/app` origin is the factory URL at
  factory HEAD `b6e890a`.
- setup printed the provisioner-skew warning (host `cbba7cb1` vs clone `c754d15f`).
  The clone is a different project whose `provision.sh` differs from this kernel's
  by exactly 5 comment lines (the defensive-backstop note), so the informational
  skew warning fired over what was really a wrong-repo clone.

## Recon already done (do not repeat)

`git grep -n "inkwell-agent-sandboxes-and-software-factory"` across all tracked
files returns exactly ONE hit: `just/sandbox/lifecycle/fill.just:30`. (The only
other matches in the working tree are gitignored ADW session logs under
`adws/adw_data/` — runtime data, not source.) No README/docs prose mentions the
ancestor URL in tracked files. So the URL fix is a one-line change; there is
nothing else to fix.

The surrounding comments in `fill.just` ("FACTORY repo: stays PUBLIC and
credential-free…", "factory clone") are the kernel's own terminology for the
toolbelt clone and stay true after the fix — **leave them alone**. Do not reword
comments; the change is the REPO value only.

## Change

File: `just/sandbox/lifecycle/fill.just` (line 30)

```diff
-    REPO="https://github.com/yhuangsh/inkwell-agent-sandboxes-and-software-factory.git"
+    REPO="https://github.com/yhuangsh/sssf-sbx.git"
```

That is the entire code change. One line.

## Preflight (before mounting)

The skew check in `just/sandbox/lifecycle/setup.just` compares the HOST working
tree's `sandbox_mount/guest/provision.sh` sha256 against the VM clone's copy.
The clone comes from `origin/main` of `yhuangsh/sssf-sbx`, so the warning only
stays silent if the host tree's provision.sh matches origin's. Verify before
mounting:

```bash
git fetch origin
git status --short sandbox_mount/guest/provision.sh     # must be clean
git diff origin/main HEAD -- sandbox_mount/guest/provision.sh   # must be empty
```

If either shows a delta, STOP and report — the verification in (b) would fail for
a reason unrelated to this fix. (The fill.just fix itself is host-side code; it
does NOT need to be pushed for verification to be valid.)

## Verification (all four required, real runs — no dry runs)

Use the hello roster for everything: `export SSSF_CONFIG=sssf.hello.config.yaml`
(note: the mount preflight reads `SSSF_CONFIG` and the actual default fallback path
is `adws/adw_sssf_config/sssf.config.yaml`; the hello roster file lives at
`adws/adw_sssf_config/sssf.hello.config.yaml` — set the env var to that path if a
bare `sssf.hello.config.yaml` does not resolve. Confirm resolution by checking
fill's echo names the hello-server target repo.)

**(a) Fresh armed mount, gates A–E green:**

```bash
export SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml
just sbx mount hello-fix
```

Capture the full output. The mount chain is preflight → create → fill → setup →
observe and stops at observe. Gate assertions A–E in the setup phase must all
pass. Extract the RUN_ID from the final `mounted: <id>` line.

**(b) Right repo, no skew:**

- In the setup output captured in (a): the string `WARN: host provisioner` must
  NOT appear. (This is the skew warning at `setup.just` ~line 108.)
- On the VM (vm_name from `sandbox_mount/host/run_record.py get <RUN_ID> vm_name`):
  ```bash
  ssh <vm>.exe.xyz 'git -C ~/app remote get-url origin'
  ```
  must print exactly `https://github.com/yhuangsh/sssf-sbx.git`.
- Provisioner sha match:
  ```bash
  sha256sum sandbox_mount/guest/provision.sh | awk '{print $1}'
  ssh <vm>.exe.xyz 'sha256sum app/sandbox_mount/guest/provision.sh' | awk '{print $1}'
  ```
  must be identical.

**(c) One small in-sandbox SDLC via the execute lane:**

```bash
just sbx lifecycle execute <RUN_ID> "Add a GET /version endpoint to the server that returns {\"version\":\"1.0.0\"}, with a test"
```

This is detached and returns a PID. Poll until the run finishes (observe lane /
run record / trace db per repo convention), and confirm the SDLC completed its
phases successfully. This proves the in-VM adw layer cloned from the CORRECT repo
is complete for real work. Note the hello roster's known caveat (documented in
the roster's `app:` comments): the toy app's `checks:` map form can abort the
test phase — if that specific known issue bites, it is NOT a regression from this
fix; report it as such, but the plan-build legs must still have run for real.

**(d) Teardown clean:**

```bash
just sbx lifecycle teardown <RUN_ID>
```

Must exit 0, harvest, destroy the VM, and close the record.

## Done means

(a)–(d) demonstrated with captured output, the one-line fix landed in the working
tree, tree otherwise clean (the chain's commit phase owns the commit — leave the
fix dirty for it). changed_files: `just/sandbox/lifecycle/fill.just`.

## Out of scope

Everything else: no comment rewording, no doc updates, no changes to the
`factory` terminology in fill.just's prose, no work on the hello roster's known
`checks:` caveat beyond reporting it if it fires.
