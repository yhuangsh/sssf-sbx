# README: lane mental-model callout + hot-reload serve example

Two surgical documentation edits to `README.md` — **no other file is touched**.

## Verified ground truth (planner already checked; do not re-litigate)

- `just/sandbox/run/mod.just`: `run cmd` is a synchronous generic escape hatch
  ("Your inspection tool"); `run agent` is a single `pi -p --session-id <sid>
  <prompt>` invocation over ssh — ONE pi turn per call, resumable session, no
  chain, no gates, no commit machinery anywhere in `run/` ("these two write
  nothing and are not phases"). Edits an agent makes here stay uncommitted
  working-tree changes.
- `just/sandbox/lifecycle/execute.just`: `execute` is the detached full SDLC
  (default chain `sdlc`), the "default for real work" — gates, reviews, and
  ADW commits land on the target clone's run branch `sbx/<run-id>`.
- `just/sandbox/manage/harvest.just`: harvest pulls the run's commits home as
  a git bundle into `refs/sandbox/<run-id>`.
- Nothing but `mount` (create→fill→setup→observe) creates a sandbox and
  nothing but `teardown` destroys one; teardown harvests first and a failed
  harvest aborts the destroy.
- `just/sandbox/lifecycle/observe.just`: the app process is started once
  (`nohup $SERVE_COMMAND`), idempotently ("already listening — leaving it
  alone"). There is no reload machinery; the only way to get live reload is
  for the app's own manifest `serve.command` to be a hot-reloading command.
- Shipped hello roster `adws/adw_sssf_config/sssf.hello.config.yaml`: the
  hello-server manifest serves `bun run server.ts` on 4501. The README's
  Arming example mirrors that command today.

## Edit 1 — LANE MENTAL MODEL callout in `## Use`

Location: in the `## Use` section (starts at README line 133). Insert a new
short block **immediately before** the line `The loop — mount, execute, watch,
harvest, tear down:` (i.e. after the long intro paragraph that ends "...the
two roots are the same directory."). Prominent placement: the reader meets the
lanes before the command list.

Content to add (match the file's tone — bold lead-ins, terse bullets, `—`
dashes; adjust wording lightly only to keep it consistent):

```md
**Lane mental model** — users conflate steering with the factory; keep them
separate:

- **`just sbx run agent` / `just sbx run cmd`** — steering and inspection.
  `run agent` is ONE pi turn inside the box: no chains, no gates, no commits —
  its edits stay uncommitted working-tree changes.
- **`just sbx lifecycle execute`** — the factory: the full SDLC with gates,
  reviews, and commits to the target's run branch.
- **`just sbx manage harvest`** — bringing the run's commits home.
- **`just sbx mount` / `just sbx lifecycle teardown`** — the only times a
  sandbox is created or destroyed. A fresh mount is for a clean box, never
  needed just to test a change.

The app process starts once at `observe` and does not hot-reload unless the
app's own manifest opts in (see the serve example below).
```

Notes for the builder:
- The final sentence is required — one sentence only, and it must point at
  the serve example below (the Bun manifest in `## Arming for any language`).
- Do not alter the surrounding paragraphs or the sh code block.

## Edit 2 — hot-reload serve command in the Arming example

Location: `## Arming for any language`, the "Bun app:" fenced yaml block
(currently around line 100). Change exactly one line and add a brief inline
comment:

From:
```yaml
serve:
  command: bun run server.ts
```

To:
```yaml
serve:
  command: bun --hot server.ts  # live reload during development: Bun re-imports the module graph without restarting the server
```

Keep `port: 4501` and `health_path: /` unchanged. Keep the comment brief; if
the line feels too long it may be shortened to e.g. `# --hot: live reload —
Bun re-imports the module graph without restarting the server`. Do not change
the Python/uv example or the field table.

## Verify

1. `git diff --stat` shows **README.md only**.
2. `grep -n "LANE MENTAL MODEL\|Lane mental model\|bun --hot" README.md`
  shows both edits present.
3. Re-read both edited regions and confirm the claims still match
  `just/sandbox/run/mod.just`, `just/sandbox/lifecycle/observe.just`, and the
  hello roster (they do — see ground truth above; only tone/wording should
  have been in play).
4. Confirm the callout sits inside `## Use` before the `The loop —` line, and
  the yaml example is inside `## Arming for any language`.
5. The chain's commit phase owns the commit — leave the tree with the README
  edit dirty, do not commit.

## Out of scope

Every file other than `README.md`.
