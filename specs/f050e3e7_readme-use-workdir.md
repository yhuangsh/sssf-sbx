# Plan: State the working directory prominently in README's `## Use`

## Goal

README.md's `## Use` section (line 133 onward) lists commands but never says
where they run. In toolbelt mode the sssf-sbx clone and the app repo are two
different repos, so this ambiguity is a real trap. Add one prominent statement
at the top of `## Use`, then audit the rest of the README for any line that
implies commands run from the app repo and fix it. No new sections; keep it
tight.

## File to touch

- `README.md` — the only file.

## Change 1 — working-directory statement at top of `## Use`

Insert immediately after the `## Use` heading (currently line 133), before
the existing line "The loop — mount, execute, watch, harvest, tear down:".
Format: a bold lead sentence followed by a short paragraph (2–4 sentences
total). Content requirements (from the request):

1. **Every command in this section runs from the sssf-sbx clone root** — the
   directory containing this README and the `justfile`. Give the three reasons
   it matters: that is where `dotenv-load` finds `.env`, where `SSSF_CONFIG`
   roster paths resolve, and what "repo root" means in every phase.
2. **Toolbelt mode:** that root is the reader's sssf-sbx checkout; their app
   repo is a DIFFERENT repo — nothing in this section runs from it. Note that
   `mount` clones the app from GitHub into the VM at `~/app/target` (i.e.
   `~/app/<path>` per the roster's `app.path`), and that a local clone of the
   app is optional and only for host-side work.
3. **Vendored mode:** the kernel directories live inside the app repo, so the
   sssf-sbx root and the app repo root are the SAME directory.

Suggested shape (builder may adjust wording, not substance):

```markdown
**Run everything below from the sssf-sbx clone root** — the directory
containing this README and the `justfile`. That is where `dotenv-load` finds
`.env`, where `SSSF_CONFIG` roster paths resolve, and what "repo root" means
in every phase. In **toolbelt** mode that root is your sssf-sbx checkout;
your app repo is a different repo and nothing here runs from it — `mount`
clones your app from GitHub into the VM at `~/app/target`, and a local clone
of your app is optional, only for host-side work. In **vendored** mode the
kernel directories live inside your app repo, so the two roots are the same
directory.
```

## Change 2 — consistency audit of the rest of the README

Read the whole README (it is ~165 lines) and fix any line that implies
commands run from the app repo. Keep each fix minimal — a clause or a few
words, no restructuring. Known spots to check:

- **Integration (a) Toolbelt** (lines 42–63): already says the app is an
  external repo and `fill` clones it into `~/app/<path>` on the VM — likely
  consistent; verify the "Copy that roster, edit the `app:` block, and run
  with `SSSF_CONFIG=<your roster>`" line does not imply running from anywhere
  but the sssf-sbx root (it should be fine, since that root is now stated in
  `## Use`; only adjust if it actively misleads).
- **Integration (b) Vendored** (lines 65–78): says "Copy `adws/`, … into your
  own repo" — consistent with the new statement; verify.
- **Prerequisites + arming checklist** (lines 119–131): `cp .env.sample .env`
  and `just sbx manage doctor` run from the sssf-sbx root — consistent in
  vendored mode and toolbelt mode alike; only touch if a line implies
  otherwise.
- **`## Use` body** (lines 135–165): commands and the trailing paragraph
  (`mount`/`harvest`/`teardown` notes, `just sbx run agent`, `just obs
  rosters`) — confirm none reference the app repo as cwd. The mention of
  `~/app/target` belongs to the VM, not the host — if any phrasing could be
  read as a host path, clarify it.

If the audit finds nothing to fix, that is an acceptable outcome — say so in
the builder report rather than inventing edits.

## Explicitly out of scope

- Any other README content, any other file, any code.

## Git discipline (standing rule)

- Do NOT run `git commit`, `git push`, `git checkout`, `git branch`,
  `git reset`, or any ref mutation. `git add` is allowed. Leave the tree
  dirty; the chain's commit phase owns the commit.
- `changed_files` in the report lists only files that exist afterwards
  (here: `README.md`).

## Verification

1. `grep -n 'clone root' README.md` — the new statement is present at the top
   of `## Use`.
2. Re-read `## Use` top to bottom: the statement precedes the command block
   and covers toolbelt + vendored modes.
3. Re-read the Integration and Prerequisites sections: no line implies a
   working directory other than the sssf-sbx clone root.
4. `git status --short` — only `README.md` modified (plus pre-existing
   untracked plan/spec artifacts); no ref mutations performed.
