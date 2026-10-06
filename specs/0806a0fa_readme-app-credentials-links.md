# Plan: README linkage to the APP_* credential channel

## Goal

Two small linkage fixes in `README.md` so readers scanning the manifest table
or the arming checklist discover the `APP_*` credential channel. The detail
section `### App credentials: the \`APP_*\` namespace` (currently at
README.md:121) already exists and stays as-is. Everything else in README.md
stays byte-identical. **Only `README.md` is edited.**

## Edit 1 — `## Arming for any language` manifest table (around README.md:90–91)

Current rows:

```
| `install:` | List of shell commands, run from the app root at `setup`. |
| `build:` | Same, optional. |
```

Replace with:

```
| `install:` | List of shell commands, run from the app root at `setup` **with the app's environment**: the `APP_*` secrets and the shipped LLM keys from `app/.env` are already in the environment (see [App credentials](#app-credentials-the-app_-namespace)). |
| `build:` | Same, optional — also runs with the app's environment (`APP_*` secrets + `app/.env` LLM keys; see [App credentials](#app-credentials-the-app_-namespace)). |
```

(One clause appended per row, not a paragraph. The exact markdown link anchor
may be written as plain text "(see 'App credentials: the `APP_*` namespace' below)"
if the anchor form proves fiddly — either satisfies the linkage requirement.)

## Edit 2 — `## Prerequisites + arming checklist` step 3 (README.md:159–160)

Current:

```
3. Set `APP_REPO_GIT_TOKEN` **only if** the app repo is private (public repos
   clone unauthenticated).
```

Replace with:

```
3. Add `APP_REPO_GIT_TOKEN` **only if** the app repo is private (public repos
   clone unauthenticated), plus any other `APP_*` secrets your manifest's
   `install:`/`build:` commands need (e.g. `APP_TAILSCALE_AUTHKEY`) — see
   [App credentials](#app-credentials-the-app_-namespace) above.
```

(As with Edit 1, a plain-text "see 'App credentials: the `APP_*` namespace'"
reference is an acceptable alternative to the markdown link.)

## Constraints

- No other line of README.md changes; keep wording tight (one clause per edit).
- Do not touch the `### App credentials` section itself or anything else in the repo.
- Do not commit — the chain's commit phase owns the commit.

## Verification

1. `git diff --stat` shows only `README.md` modified.
2. `grep -n "App credentials" README.md` shows the existing section heading plus
   the two new references.
3. `grep -n "APP_TAILSCALE_AUTHKEY" README.md` shows the new checklist mention.
4. `git status --porcelain` shows only the intended changes (README.md plus the
   spec/plan files the chain tracks); tree otherwise clean.
