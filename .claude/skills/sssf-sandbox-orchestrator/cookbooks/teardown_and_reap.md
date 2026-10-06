# Teardown and clean up

`just sbx lifecycle teardown <run-id>` is the only thing in this repo that destroys a VM. It is **always
an explicit human decision** — never chained, never automatic, never suggested casually. The only flag
is `--no-harvest`.

## Why it is never chained

`just sbx mount` stops at `observe`. Every failure path in create / fill / setup / execute / observe
prints the teardown command and **leaves the box alive** — that is an offer, not a recommendation. The
reasons compound:

- **The VM is the evidence.** A gate that auto-destroys throws away the only copy of what went wrong.
- **`ssh exe.dev rm` has no confirmation and no undo.** It deletes the persistent disk.
- **A VM sitting for an hour is cheap. A run destroyed early is gone.** The asymmetry is not close.

So: propose it, wait for a yes, then run it. Never fold it into a script that also did something else.

## The order, and why each step is where it is

```
1. artifacts (gzipped delta-tar)   2. harvest the commits   3. destroy the VM   4. close the record
```

Everything that READS the box runs before the one thing that destroys it.

**1 — artifacts before destroy.** The artifacts are a **gzipped delta-tar** of only the run's own
changes under `specs`, `app_docs`, `adws/adw_data/sssf.db` and `run.log` (plus the target's manifest —
`<app.path>/<manifest>` — in target mode). The delta is untracked-non-ignored files plus HEAD-modified
files, and the always-files (`sssf.db`, `run.log`) that git cannot report; gitignored files in the tar
paths come along. Those are the only unique bytes: the host owns the rest of the tree by construction
(it cloned the same sha and gate A proved the tree clean), so the old whole-tree `tar` of a box whose run
changed nothing shipped ~9.95MB of bytes the host already had. An empty delta **skips the transfer**
entirely. The tar extracts to `.sandbox/runs/<run-id>-artifacts/`.

**2 — harvest the commits, and a failure ABORTS the destroy.** File copies LOSE history, and SSSF
commits plan, code and docs as **separate commits** — the shape of the run is in the commit graph, not
the files. Teardown delegates to `just sbx manage harvest <run-id>`, so it is the same recipe you can run
any time on its own. If harvest fails, teardown **stops before destroying** and tells you to diagnose
and re-run, or to pass `--no-harvest` to skip it deliberately. Destroying a VM whose commits were never
pulled is the one irreversible mistake this file can make, so that is where the asymmetry is enforced.
`--no-harvest` is for when you already harvested.

**3 — destroy the VM.** Only if the control plane says it is actually alive
(`ssh exe.dev ls --json`), then `ssh exe.dev rm <vm>`.

**4 — close the record.** `close` stamps `closed_at` and is idempotent (first close wins). The `.env`
and the run branch live on the VM, so they go with it; there is no key to shred and no spend to capture
here.

## It is idempotent, and partial states are normal

A run can die anywhere: VM but no record, record but no VM, one whose VM is already gone. Every step is
individually guarded, so re-running teardown is the normal recovery path, not a risk.

The one hard prerequisite is **the run record** — it is the only handle on the VM. No record, no
teardown.

Two places it stops on purpose:

| Condition | Behavior | Why |
|---|---|---|
| no run record for the id | reports and exits 1 | the record is the only handle on the VM; there is nothing to close |
| harvest failed | reports and exits 1, **VM left alone** | destroying a box whose commits were never pulled loses the run's work irreversibly |

Everything else (a VM that is already gone, a manifest that never landed, an empty artifact delta) is
the normal path, not an error.

## The harvest-before-destroy asymmetry

A crash between harvest and destroy leaves the commits safe on the host and the VM alive: visible and
cheap. The reverse — destroy first — leaves a run's commits only in a VM that no longer exists: gone.
Order the failure modes, not the happy path.

The same reasoning is why harvest is its own recipe. Teardown is the human's call, so a harvest that only
ran inside teardown would leave commits hostage to a decision nobody has made yet. Standalone and
idempotent, the exposure window is seconds instead of days. Harvest writes nothing to the run record —
the bundle's existence at `.sandbox/runs/<run-id>.bundle` **is** the record.

## Inspecting what came home

```bash
just sbx manage harvest <run-id>
git log --oneline --graph <commit_sha>..refs/sandbox/<run-id>
git diff <commit_sha>..refs/sandbox/<run-id>
```

Harvest bundles the range `<commit_sha>..refs/heads/sbx/<run-id>` (small, and it refuses to import
history that does not descend from the pin), verifies it, then fetches into `refs/sandbox/<run-id>`.
In target mode it fetches into a bare cache of the app repo (`.sandbox/repos/<app-repo>.git`) instead,
so the app's commits never touch the factory repo. If a run's commits are missing, check the ADW
committed at all (`NOCOMMITS` means the branch tip still equals `commit_sha`) before suspecting the
bundle.

## Fleet hygiene (there is no `reap`)

There is **no reap recipe** in this kernel — no key minting exists, so there is nothing to revoke.
What you have instead:

- `just sbx manage list` shows every run's record state (`open`/`closed`) and whether its VM is still
  alive (`ssh exe.dev ls --json`, one call for the whole table).
- `ssh exe.dev ls` is the control-plane truth — the list of VMs that actually exist.
- **The VM tag is what bulk identification filters on.** `create` derives it from the roster's
  `app.repo` basename (or takes an explicit mount arg) and records it; it names the app, not the kernel.
- A VM whose **run record is gone** is removed by hand: `ssh exe.dev rm <vm>`.

So the backstop for a teardown that never ran is `just sbx manage list` → filter by tag on
`ssh exe.dev ls` → `ssh exe.dev rm` the orphan. Nothing expires and nothing auto-destroys; a forgotten
VM bills until someone does this.
