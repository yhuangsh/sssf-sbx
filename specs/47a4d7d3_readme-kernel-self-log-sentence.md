# Plan: Append one sentence to README's "Developing sssf-sbx itself" section

## Request

In `README.md`'s `## Developing sssf-sbx itself` section, append exactly one sentence at the end:

> Kernel-self run issues are public by design — they are this project's development log.

## Current state

- `README.md` (596 lines). The section `## Developing sssf-sbx itself` starts at line 546 and **runs to end of file** — it is the last section; nothing follows it.
- The section's final paragraph is the **Issue tracking** paragraph, ending at line 596 with:

  ```
  `SSSF_ISSUES=0` still
  disables it, and a non-github.com origin or missing `gh` auth is a named skip.
  ```

  The file ends with a trailing newline after that line.

## Change

**File:** `README.md` — only file touched.

Append the sentence to the end of the **Issue tracking** paragraph (the last paragraph of the section and of the file), keeping it in the same paragraph — it is a direct continuation of the issue-tracking topic. Resulting end of file:

```
**Issue tracking.** Kernel-self runs open and close issues in this repo's own
GitHub origin (`yhuangsh/sssf-sbx`), labeled **`sssf:kernel`** — the project's
public development log. Same open → milestone → close lifecycle as any run; see
[Session tracking](#session-tracking-github-issues) above. `SSSF_ISSUES=0` still
disables it, and a non-github.com origin or missing `gh` auth is a named skip.
Kernel-self run issues are public by design — they are this project's
development log.
```

Exact sentence text (verbatim, including the em dash):

```
Kernel-self run issues are public by design — they are this project's development log.
```

Constraints:
- Exactly one sentence added; no other edits to the README or any other file.
- No new paragraph, no heading change — a space-separated append to the existing final paragraph (wrap the line naturally to match the surrounding ~79-column style).
- File must still end with a single trailing newline.

## Verify

1. `tail -5 README.md` shows the sentence as the last content.
2. `grep -c "Kernel-self run issues are public by design" README.md` prints `1`.
3. `grep -n '^## ' README.md` confirms no new heading was introduced and `## Developing sssf-sbx itself` is still the last section.
4. `git diff --stat` shows exactly one file changed, `README.md`, with +2/-1 lines (one wrapped paragraph line becomes two — or +1/-1 if reflow fits; the point is only README.md changed and the diff contains only this append).
