# `just sbx scaffold` — interactive GitHub-app scaffolder for the kernel

## Goal

A new host-side command `just sbx scaffold [repo]` that interactively produces a
GitHub app repo sssf-sbx can drive **out of the box** (toolbelt/target mode) plus
the matching roster committed to this repo, so the user's next command is a plain
`just sbx mount <run-id>`.

Everything is manifest/roster **data**, no factory-code edits per app. The
generated artifacts must line up with what the existing machinery already
consumes:

- **Manifest** (`sssf.app.yaml` in the app repo): `runtime:` bun|node|uv|none,
  `install:`/`build:` shell lists, optional `serve:` {command, port,
  health_path}, `checks:` map of `name: [argv...]` — parsed by
  `sandbox_mount/guest/provision.sh` step 5, `just/sandbox/lifecycle/observe.just`
  (serve block), and `adws/adw_modules/quality.py::_load_checks` (checks map and
  list forms both supported).
- **Roster** (`adws/adw_sssf_config/sssf.<name>.config.yaml`): a copy of the
  shipped `sssf.hello.config.yaml` template with only the `app:` block replaced
  (`repo`/`ref: main`/`path: target`/`manifest: sssf.app.yaml`) and a header
  comment naming it scaffolded. The awk line-parsers in `just/sandbox/mount.just`
  and `just/sandbox/manage/mod.just` (doctor) require the flat `app:` block with
  two-space-indented keys — keep that exact shape.
- **Private repos** ride `APP_REPO_GIT_TOKEN` in the host `.env` (see fill.just
  `APP_REPO_PRIVATE_NO_TOKEN` / `APP_REPO_CLONE_FAILED`); public repos clone
  unauthenticated.

## Files to touch

| file | change |
| --- | --- |
| `sandbox_mount/host/scaffold.py` | NEW — the whole interactive scaffolder. uv-run PEP-723 script (`# /// script` header, `dependencies = ["pyyaml"]`), executable bit set, same house style as `run_record.py` (stdlib + pyyaml only, docstring header explaining purpose and usage, named errors on stderr, non-zero exit on failure). |
| `just/sandbox/scaffold.just` | NEW — thin recipe, same pattern as `mount.just` (imported, no `set` lines). |
| `just/sandbox/mod.just` | EDIT — add `import 'scaffold.just'` next to `import 'mount.just'`; mention `scaffold` in the header's THE SHAPE comment. |
| `README.md` | EDIT — new section documenting the scaffolder (placement and content below). |

Runtime artifacts the feature itself writes when run (not authored by hand):
the app repo on GitHub, and `adws/adw_sssf_config/sssf.<name>.config.yaml`
(scaffold commits it itself — requirement 5).

## `sandbox_mount/host/scaffold.py`

Single file, PEP-723 header so `uv run sandbox_mount/host/scaffold.py` resolves
pyyaml. All interaction via `input()` with sane defaults (bare Enter accepts the
default, shown in `[brackets]`). Every prompt reads exactly ONE line so the flow
is drivable by a piped here-doc; `EOFError` mid-flow = clean
`[scaffold] input closed (EOF) — aborting, nothing done yet` on stderr, exit 1
(before any destructive step the summary gate below also guards this).

### Step 0 — preflight (before any prompt)

1. `shutil.which("gh")` — missing → stderr:
   `[scaffold] gh CLI not found — install it from https://cli.github.com and run 'gh auth login' first`, exit 1.
2. `gh auth status` (subprocess, capture) — non-zero →
   `[scaffold] gh is not authenticated — run 'gh auth login' first`, exit 1.
3. Resolve the default owner once: `gh api user --jq .login` → `GH_USER`.
4. Resolve repo root from `Path(__file__).resolve().parents[2]` and assert
   `adws/adw_sssf_config/sssf.hello.config.yaml` and `just/sandbox/mod.just`
   exist there (i.e. we are inside an sssf-sbx checkout) — else named error.
5. Optional positional argv[1] pre-fills the repo name answer.

### Step 1 — questions (in this exact order)

1. **Repo name.** `owner/name` or a bare `name` (owner defaults to `GH_USER`).
   Validate: owner `^[A-Za-z0-9](-?[A-Za-z0-9])*$`, name
   `^[A-Za-z0-9_.-]+$` (GitHub's own rules). Bad input → explain and re-prompt.
2. **Exists or create-new.** Prompt `[exists/create]`, default `create`.
   Accept `e`/`exists`, `c`/`create` (case-insensitive); anything else re-prompts.
   - **exists**: `gh repo view <owner>/<name>` (capture, no prompt).
     Failure → `[scaffold] cannot reach <owner>/<name> — if it is private, gh needs access; if the mount will clone it from a sandbox, the host .env needs APP_REPO_GIT_TOKEN (a token with repo read on that repo)` and exit 1. Then `gh repo view --json isPrivate,defaultBranchRef` to learn visibility + default branch.
   - **create**: prompt visibility `[public/private]`, default `public`;
     only those two words accepted (re-prompt otherwise).
3. **Runtime.** `[bun/node/uv/none]`, default `bun`. Enum-validated, re-prompt.
4. **Serve.** Default: **on** for bun/node, **off** for none (library) and uv.
   Prompt `serve? [Y/n]` (or `[y/N]` when default off). When on:
   - `command`: default per runtime — bun: `bun --hot server.ts`;
     node: `node server.js`; uv: `uv run python app.py`.
   - `port`: default `4501`; must parse as int in 1–65535, else re-prompt.
   - `health_path`: default `/`; must start with `/`, else re-prompt.
5. **Checks.** Default: one test check matching the skeleton (below). Prompt
   `add the default test check? [Y/n]`; if `n`, the manifest omits `checks:`.
6. **Summary + confirm.** Print every resolved answer and the exact planned
   actions (create repo / clone+add files / files that WILL be created /
   visibility / token action / roster path + commit). Then
   `proceed? [y/N]` — anything but `y`/`yes` aborts with
   `[scaffold] aborted — nothing was created or pushed`. This is the only gate
   before anything destructive.

### Step 2 — build the payload (in a temp dir, always)

Work in `tempfile.mkdtemp(prefix="sssf-scaffold-")`, `shutil.rmtree` in a
`finally`. Two paths:

**CREATE-NEW**
1. Write the full skeleton for the chosen runtime (contents below), including
   `sssf.app.yaml` and `.gitignore`.
2. `git init -b main`, `git add -A`, commit
   `Initial commit: sssf-sbx scaffolded <runtime> app`. Commit identity: host
   `git config user.name`/`user.email` if set, else `-c user.name=<GH_USER>
   -c user.email=<GH_USER>@users.noreply.github.com` per command.
3. `gh repo create <owner>/<name> --<public|private> --source=. --push`
   (run from the temp dir; gh handles remote + push to `main`).

**EXISTING**
1. `gh repo clone <owner>/<name> <tmpdir>` (gh auth covers private).
2. **PRESERVE everything.** Only ADD what is missing:
   - `sssf.app.yaml` absent → write it. Present → **ask**
     `[scaffold] sssf.app.yaml already exists — overwrite? [y/N]`; default keep.
   - Repo is "empty-ish" (no tracked files other than README*/LICENSE*/.gitignore)
     → write the runtime skeleton files that do not already exist.
     Not empty-ish → write none of the skeleton, say so.
   - `.gitignore` absent → write a minimal one (below).
3. If nothing was added, say so and skip commit/push. Otherwise
   `git add -A`, commit
   `sssf-sbx scaffold: add manifest[ + skeleton] for <runtime> runtime`,
   `git push origin HEAD:<defaultBranch>`.

**Manifest validation (both paths, before any push):** after writing
`sssf.app.yaml`, parse it back with `yaml.safe_load` and assert: `runtime` ∈
{bun, node, uv, none}; if `serve` present, `port` int in 1–65535 and
`health_path` starts with `/`; if `checks` present it is a dict of name → list.
Failure = a scaffold bug: named error, exit 1, nothing pushed (create-new pushes
only after validation; existing pushes only after validation).

### Step 3 — private-repo token check (whenever the repo is private)

Private = chosen visibility `private`, or `isPrivate` from `gh repo view`.
Check the host `.env` FILE at repo root for a line starting
`APP_REPO_GIT_TOKEN=` with a non-empty value (the just recipe's dotenv-load puts
it in the environment too, but the file is what persists — check the file).
- Present → say so, move on.
- Missing → warn: a mount will fail FILL with `APP_REPO_PRIVATE_NO_TOKEN`
  without it, then offer:
  `add APP_REPO_GIT_TOKEN from 'gh auth token' to .env now? [y/N]`.
  - `y` → append `APP_REPO_GIT_TOKEN=<output of gh auth token>` to `.env`
    (create the file if absent; never print the token) and confirm by line
    number only.
  - anything else → print the exact line for the user to add:
    `APP_REPO_GIT_TOKEN=<a token with repo read — e.g. the output of: gh auth token>`.

### Step 4 — roster (always, both paths)

1. Read `adws/adw_sssf_config/sssf.hello.config.yaml`.
2. Prepend a header comment block:
   `# sssf.<name>.config.yaml — SCAFFOLDED by 'just sbx scaffold' on <UTC date>`
   `# app repo: https://github.com/<owner>/<name> (<public|private>) — everything below is the shipped hello template with the app: block filled in.`
3. Replace the template's `app:` block — from the line matching `^app:` to the
   line before `^agents:` — with exactly:

   ```yaml
   app:
     repo: https://github.com/<owner>/<name>.git   # scaffolded <public|private> repo
     ref: main
     path: target
     manifest: sssf.app.yaml
   ```

   (For existing repos whose default branch is not `main`, use that branch as
   `ref`.) Keep the surrounding blank-line structure so the awk parsers and
   humans see the same shape as the template.
4. Write to `adws/adw_sssf_config/sssf.<name>.config.yaml`; **refuse to
   overwrite** an existing file (name collision → tell the user to remove the
   old roster or pick another name, exit 1). Parse the result back with pyyaml
   and assert `app.repo/ref/path/manifest` are what was just written.
5. Commit ONLY that file to this repo:
   `git add adws/adw_sssf_config/sssf.<name>.config.yaml &&
    git commit -m "Add scaffolded roster for <owner>/<name>"`
   then print that it committed (this is requirement 5 — the roster is team
   config; scaffold itself owns this commit, distinct from the chain's).

### Step 5 — finish (print, then exit 0)

```
[scaffold] done — <owner>/<name> (<visibility>) + roster adws/adw_sssf_config/sssf.<name>.config.yaml (committed)

next steps:
  1. add to .env:   SSSF_CONFIG=adws/adw_sssf_config/sssf.<name>.config.yaml
  2. preflight:     just sbx manage doctor
  3. mount:         just sbx mount <run-id>
lanes: 'just sbx run agent' steers; 'just sbx lifecycle execute' is the factory.
```

## Skeletons (verbatim content the builder writes into scaffold.py as data)

One test check per skeleton; every server reads `PORT` from the environment
(observe starts the app with `PORT=<serve.port>` prefixed) and binds 0.0.0.0.

**bun** — `package.json` (`{"name": "<name>", "version": "0.1.0", "private": true, "scripts": {"start": "bun run server.ts"}}`),
`server.ts` (hello-server shape: exported `greet(name)`; `if (import.meta.main)` block `Bun.serve({port, fetch: () => new Response(greet("world") + "\n")})` with `const port = Number(process.env.PORT ?? 4501)`),
`server.test.ts` (`bun:test` describe/expect on `greet`).
Manifest:
```yaml
runtime: bun
install: [bun install]
build: []
serve:
  command: bun --hot server.ts
  port: 4501
  health_path: /
checks:
  test: [bun, test]
```
(If the user answered serve off, omit the `serve:` block; checks per their answer.)

**node** — zero-dependency. `package.json` (`{"name": ..., "private": true, "type": "module", "scripts": {"start": "node server.js", "test": "node --test"}}`),
`server.js` (`node:http` `createServer` answering `hello, world\n` on every path, `listen(Number(process.env.PORT ?? 4501))`),
`server.test.js` (`node:test` + `node:assert`, a pure exported `greet` tested, same shape as bun's).
Manifest: `runtime: node`, `install: []`, `serve: {command: node server.js, port: 4501, health_path: /}`, `checks: {test: [node, --test]}`.
(Node on the VM is provision.sh's standalone Node 22 — `node --test` is built in, no install needed.)

**uv** — `pyproject.toml` (PEP-621, name, version, `dependencies = []`,
`[dependency-groups] dev = ["pytest"]`), `app.py` (a `greet()` plus a tiny
`http.server`-based `main()` guarded by `if __name__ == "__main__":`, PORT from
env), `test_app.py` (pytest asserts on `greet`).
Manifest: `runtime: uv`, `install: [uv sync]`, `checks: {test: [uv, run, pytest]}`;
`serve:` only if the user turned it on — command `uv run python app.py`.

**none** — `README.md` only (`# <name>` + a line that it was scaffolded by
sssf-sbx as a library/no-runtime repo). Manifest: `runtime: none`, no `serve:`,
no `checks:` unless the user added one.

**`.gitignore`** (bun/node/uv skeletons): `node_modules/`, `dist/`, `.venv/`,
`__pycache__/`, `.env`.

## `just/sandbox/scaffold.just` + `mod.just`

New file, header comment in the mount.just style explaining it is imported by
the root justfile so no `set` lines, then:

```just
# interactively scaffold a GitHub app repo + roster this kernel can mount out of the box
scaffold REPO='':
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "{{REPO}}" ]; then
        exec uv run sandbox_mount/host/scaffold.py "{{REPO}}"
    else
        exec uv run sandbox_mount/host/scaffold.py
    fi
```

(`exec` so signals/stdin behave exactly like the bare script; interactivity is
unaffected by just.) In `just/sandbox/mod.just`: add `import 'scaffold.just'`
after `import 'mount.just'`, and a `just sbx scaffold` line in the header's
THE SHAPE comment.

## README.md

New subsection right after `### (b) Vendored` in "Integration — two ways to
attach an app": `### Scaffolding a new app: just sbx scaffold`. Content: what it
does (interactive; creates-or-adopts a GitHub repo, seeds a manifest + skeleton
for bun/node/uv/none, wires `APP_REPO_GIT_TOKEN` for private repos, writes AND
commits the roster), a short transcript sketch, the printed next steps, and the
note that `gh` (installed + `gh auth login`) is a hard dependency of this one
command. Also add `scaffold` to the `just/sandbox/` row of the directory map
table and `sandbox_mount/host/scaffold.py` to the `sandbox_mount/host/` row.

## Verification (real, all five required)

Prereqs: `gh auth status` ok (verified during planning: logged in as
`yhuangsh`, `repo` scope), `just sbx manage doctor` green against the hello
roster (provider keys present in `.env`). All throwaway repos named
`sssf-scaffold-test-*` under the `gh api user --jq .login` account; ALL of them
**and their /tmp clones** are deleted at the end (`gh repo delete <owner>/<repo> --yes`).

**(a) create-new public bun, piped answers.** Pipe a here-doc of answers (name
`sssf-scaffold-test-bun`, create, public, bun, serve defaults, checks yes,
confirm `y`) into `just sbx scaffold`. Assert: `gh repo view` shows the repo
public; `gh api repos/<owner>/sssf-scaffold-test-bun/contents` lists
`sssf.app.yaml`, `server.ts`, `server.test.ts`, `package.json`; roster
`adws/adw_sssf_config/sssf.sssf-scaffold-test-bun.config.yaml` exists in this
repo and `git log --oneline -1 -- <roster>` shows scaffold's commit;
`git ls-remote https://github.com/<owner>/sssf-scaffold-test-bun.git` works with
NO credentials (public clone proof).

**(b) create-new private node.** Same with `sssf-scaffold-test-node`, private,
node. Assert: repo is private (`gh repo view --json isPrivate`); the run
exercised the token path — if `APP_REPO_GIT_TOKEN` is absent from `.env` at
that moment, answer `y` to the offer and verify the line landed (never print
the token); if it is already present, verify scaffold says so. Then prove the
clone path: `git clone https://x-access-token:$(gh auth token)@github.com/<owner>/sssf-scaffold-test-node.git /tmp/...`
succeeds while an unauthenticated `git ls-remote https://github.com/...` fails.
(Keep `.env`'s final state as the operator had it — if the token line was added
for the test and was not there before, remove it after (d) and note it.)

**(c) existing-repo, additions only.** Pre-seed `sssf-scaffold-test-existing`
via `gh repo create --public` + a pushed `NOTES.txt` with known content and NO
manifest. Run scaffold in `exists` mode (uv runtime). Assert via
`gh api .../contents`: `NOTES.txt` still there with the original content,
`sssf.app.yaml` added, skeleton added (repo was empty-ish), commit message on
the default branch is the scaffold message.

**(d) OUT-OF-BOX PROOF.** With the roster from (a):
`SSSF_CONFIG=adws/adw_sssf_config/sssf.sssf-scaffold-test-bun.config.yaml just sbx mount scaffold-proof-<something>`
must run create → fill → setup (gates A–E green) → observe, ending with
`app  200 anonymous` for the scaffolded bun server. Then
`SSSF_CONFIG=<same> just sbx lifecycle teardown <run-id>`. If doctor complains
about provider keys for the hello-template providers, STOP and report — do not
edit the roster's model list to dodge a missing key.

**(e) invalid inputs rejected cleanly** (drive with piped answers, assert
non-zero exit or re-prompt, and NO repo created): port `70000` and `abc`
re-prompt; visibility `maybe` re-prompts; `exists` against
`<owner>/sssf-scaffold-test-does-not-exist` exits 1 naming
`APP_REPO_GIT_TOKEN` guidance. `gh repo list` before/after proves nothing was
created by the failing runs.

**Cleanup (mandatory):** `gh repo delete --yes` for every
`sssf-scaffold-test-*` repo; remove their /tmp clones; remove the
verification-created rosters `adws/adw_sssf_config/sssf.sssf-scaffold-test-*.config.yaml`
from the tree (scaffold committed them at runtime — that history noise is
accepted; the deletions ride the chain's commit). Also delete
`.sandbox/runs/scaffold-proof-*` records via teardown (d already does) and any
stray local run records.

## Guardrails / notes for the builder

- Never print tokens. The `gh auth token` output only ever goes into `.env` or
  a subprocess env, never stdout/stderr/log.
- scaffold.py never overwrites an existing roster file or an existing
  `sssf.app.yaml` without an explicit `y`.
- All git/gh subprocess calls: `subprocess.run([...], check=...)` with list
  argv (no shell), failures become named `[scaffold] ...` errors with the
  failing command's stderr tail.
- The roster's `app:` block MUST stay two-space indented flat keys — mount.just
  and doctor parse it with awk, not YAML.
- Do NOT modify `sssf.hello.config.yaml` itself; it is the template source.
- The chain's commit phase owns the feature commit; scaffold's own runtime
  roster commits (requirement 5) are separate and expected.
- Tree must be clean at the end except the feature files; throwaway repos and
  clones deleted.

## Out of scope

The factory repo, parked items, changes to the orchestrator skill/cookbooks,
and any changes to provision.sh/observe.just/quality.py (the scaffolded
manifests conform to what they already parse).
