# Plan: `just sbx scaffold` writes the roster to the repo root, untracked

## Goal

Change two behaviors of the scaffolder (`sandbox_mount/host/scaffold.py`, driven by
`just/sandbox/scaffold.just`):

1. **Roster destination** — write the generated roster to the **current directory**
   (the kernel clone root, where `.env` and the justfile live) as
   `sssf.<name>.config.yaml` — NOT into `adws/adw_sssf_config/`. If that file
   already exists, **ask**: overwrite / pick another name / abort. Never clobber
   silently.
2. **No git commit** — the scaffolder must NOT `git add`/`git commit` anything to
   the sssf-sbx repo. The roster is left **untracked**; the finish banner and next
   steps say so, point `SSSF_CONFIG` at it, and note that committing the roster
   into the kernel repo (for team sharing) is the user's choice, not automatic.

Also update the README scaffold section, which currently documents the old
write-into-`adws/adw_sssf_config/` + commit behavior.

## Files to touch

- `sandbox_mount/host/scaffold.py` — the only code change.
- `README.md` — the "Scaffolding a new app: `just sbx scaffold`" section
  (~lines 82–125).
- `just/sandbox/scaffold.just` — read it; its comments/recipe do not reference the
  roster destination or committing, so **no change is expected**. If any comment
  does mention it, fix the wording. The recipe already execs from the repo root
  (it inherits the module working directory), which is exactly the "current
  directory" the roster must land in.

## Changes in `sandbox_mount/host/scaffold.py`

### 1. `write_roster()` — new destination, collision prompt, no commit

Current signature: `write_roster(owner, name, ref, visibility) -> Path`, and it
hard-fails when the roster exists. Rework it:

- **Destination**: `roster = REPO_ROOT / f"sssf.{name}.config.yaml"`.
  (`REPO_ROOT` is the current directory when invoked via `just sbx scaffold`;
  keep deriving from `__file__` so a bare `uv run sandbox_mount/host/scaffold.py`
  from anywhere still lands in the kernel root.) Keep reading the TEMPLATE from
  `ROSTERS_DIR` — only the *output* moves.
- **Collision handling**: if `roster.exists()`, prompt instead of raising:

  ```python
  while roster.exists():
      choice = ask_choice(
          f"roster {roster.name} already exists — overwrite / pick another name / abort",
          ("overwrite", "rename", "abort"), "abort",
          aliases={"o": "overwrite", "r": "rename", "a": "abort"})
      if choice == "overwrite":
          break
      if choice == "abort":
          raise ScaffoldError(f"roster {roster.name} exists — aborted at user request (no roster written)")
      new = ask("new roster name (the <name> in sssf.<name>.config.yaml)", "")
      if not NAME_RE.match(new):
          print("  invalid name — use [A-Za-z0-9_.-]+")
          continue
      roster = REPO_ROOT / f"sssf.{new}.config.yaml"
  ```

  ("abort" raises *after* the app repo was already created/pushed — that is
  acceptable and matches how the private-token step can already fail late; the
  error message must make clear the roster was not written.)
- **Remove the git commit**: delete these three lines and the `sha` print:

  ```python
  run(["git", "add", "--", rel], cwd=REPO_ROOT)
  run(["git", "commit", "-m", f"Add scaffolded roster for {owner}/{name}", "--", rel], cwd=REPO_ROOT)
  sha = run(["git", "rev-parse", "--short", "HEAD"], cwd=REPO_ROOT).stdout.strip()
  print(f"[scaffold] committed roster: {rel} ({sha})")
  ```

  Replace with a plain write report, e.g.:

  ```python
  roster.write_text(text)
  print(f"[scaffold] wrote roster: {roster.name} (in the current directory, left untracked — NOT committed)")
  ```

  Keep the existing YAML round-trip validation of the `app:` block.
- Return the final `roster` path (the caller needs the possibly-renamed name for
  the banner).

### 2. Summary block (step 6 in `main()`)

- Change `roster_rel = f"adws/adw_sssf_config/sssf.{name}.config.yaml"` to
  `roster_rel = f"sssf.{name}.config.yaml"`.
- Change the printed line from
  `roster:      {roster_rel} (written + committed to this repo)` to
  `roster:      {roster_rel} (written to the current directory, untracked — NOT committed)`.

### 3. Finish banner + next steps (step 5' in `main()`)

- Capture the returned path: `roster_path = write_roster(...)` and use
  `roster_path.name` in the banner (covers the renamed case):

  ```
  [scaffold] done — <owner>/<name> (<visibility>) + roster sssf.<name>.config.yaml (untracked — your file, not committed)
  next steps:
    1. add to .env:   SSSF_CONFIG=sssf.<name>.config.yaml    # or pass it inline; relative roster paths resolve from this repo root
    2. preflight:     just sbx manage doctor
    3. mount:         just sbx mount <run-id>
  note: the roster is untracked. Committing it into this repo (e.g. to share with
  your team) is your choice — scaffold never touches the kernel's git history.
  lanes: 'just sbx run agent' steers; 'just sbx lifecycle execute' is the factory.
  ```

### 4. Module docstring

The docstring's roster sentence ("a roster copied from the shipped
`sssf.hello.config.yaml` with only the `app:` block filled in …") stays accurate;
add one clause: the roster is written to the repo root **untracked** — scaffold
never commits to the kernel repo.

## Changes in `README.md`

In the "Scaffolding a new app: `just sbx scaffold`" section:

- **The "the roster" bullet** (currently: "writes
  `adws/adw_sssf_config/sssf.<name>.config.yaml` … **and commits it**, because the
  roster is team config") — rewrite to: writes `sssf.<name>.config.yaml` **in the
  current directory** (the kernel clone root, next to `.env` and the justfile)
  from the shipped hello template with only the `app:` block changed, and leaves
  it **untracked** — the roster is your file. If the file already exists the
  scaffolder asks (overwrite / pick another name / abort) rather than clobbering.
  Committing the roster into the kernel repo for team sharing is your choice;
  a useful side effect is that generated rosters no longer touch the kernel's
  git history.
- **The sample finish banner block** — update to the new output:

  ```sh
  # [scaffold] done — <owner>/<name> (public) + roster sssf.<name>.config.yaml (untracked — your file, not committed)
  #   1. add to .env:   SSSF_CONFIG=sssf.<name>.config.yaml
  #   2. preflight:     just sbx manage doctor
  #   3. mount:         just sbx mount <run-id>
  ```

  (Keep it faithful to whatever the code actually prints.)

## Verification (all real, all required)

Run everything from the repo root. Capture `git log -1 --format=%H` and
`git status --porcelain` **before** starting, for comparison.

### (a) create-new public bun flow, piped answers

```sh
NAME=sssf-scaffold-test-$(date +%s)
printf '%s\n' create public bun y '' '' '' y y | just sbx scaffold "$NAME"
```

(Answers in order: mode=create, visibility=public, runtime=bun, serve=y,
serve command/port/health path = defaults, default test check=y, proceed=y.
`just sbx scaffold "$NAME"` pre-fills the repo-name prompt. If a prompt is
missed the flow dies with `InputClosed` — adjust the answer list, do not fake
success.)

Assert afterwards:

- `test -f "sssf.${NAME}.config.yaml"` — roster is in the **current directory**.
- `git status --porcelain -- adws/adw_sssf_config/` is **empty** — the shipped
  config dir is untouched.
- `git log -1 --format=%H` equals the pre-run value — **no new commit**.
- `git status --porcelain` shows **only** `?? sssf.<NAME>.config.yaml` — nothing
  staged, nothing else.

### (b) existing-file collision

Do **not** delete the repo from (a) yet. Plant a sentinel and re-run in
`exists` mode against the same repo:

```sh
echo "# sentinel — do not clobber" > "sssf.${NAME}.config.yaml"
printf '%s\n' exists bun y '' '' '' y y | just sbx scaffold "$NAME"
# at the collision prompt the piped answers run out or answer 'abort' /
# 'rename' — drive at least:
#   - 'abort': exits non-zero, sentinel content intact (grep sentinel …)
#   - 'rename': answer a new name, confirm sssf.<new>.config.yaml is written
#     and the sentinel file is still intact
```

The scaffolder must **ask**; it must never silently overwrite. (Exact answer
stream depends on where the collision prompt lands; use `InputClosed` EOF as
the abort signal if simpler — the point is: no clobber, file intact.)

### (c) next steps + SSSF_CONFIG resolution

- The printed next steps from (a)/(b) must name
  `SSSF_CONFIG=sssf.<NAME>.config.yaml` (bare relative name, NOT the
  `adws/adw_sssf_config/…` path) and state the roster is untracked/not committed.
- Run `SSSF_CONFIG=sssf.<NAME>.config.yaml just sbx manage doctor` — the roster
  must **resolve** (no "roster not found" / roster-parse failure). Other doctor
  complaints (e.g. missing provider keys) are pre-existing environment facts,
  not failures of this change; judge only that the relative path from the repo
  root is found and parsed.

### Cleanup (mandatory)

```sh
gh repo delete "<owner>/${NAME}" --yes        # gh token has delete_repo scope
rm -f "sssf.${NAME}.config.yaml" "sssf.<new>.config.yaml"
git status --porcelain                        # only the intended source/README edits remain
```

## Done means

- (a), (b), (c) demonstrated with real command output.
- Only `sandbox_mount/host/scaffold.py` and `README.md` (and possibly a comment
  in `just/sandbox/scaffold.just`) are modified; tree otherwise clean; the
  throwaway GitHub repo and local test rosters are deleted.
- The chain's commit phase owns the commit — leave the work dirty.

## Out of scope

Everything else: no changes to mount/manage/lifecycle lanes, no `.gitignore`
entry for generated rosters, no changes to the template in
`adws/adw_sssf_config/`.
