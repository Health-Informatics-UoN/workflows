# Claude review action

A composite action that reviews a pull request with Claude Code and posts the findings as comments. This page is for people changing it. To use it, see [the workflow docs](../../../docs/workflows/claude-review.md): most repositories should call the reusable workflow, not this action.

## How a review runs

The steps are in [`action.yml`](action.yml). The code is one script, [`claude_review.py`](claude_review.py), with one command for each step; its header lists the environment it uses. uv installs its dependencies from [`uv.lock`](uv.lock), and runs it from this folder, not from the checkout.

| Step | Command | What it does |
|---|---|---|
| Set up uv | `astral-sh/setup-uv` | Installs uv. |
| Check PR size | `check-size` | Skips PRs over `max-lines`, and comments once to say so. |
| Fetch PR | `fetch` | Saves the PR details, the diff for the reviewed commits, and replies to earlier findings in `.pr-review/`. Saves all review threads to `$RUNNER_TEMP/threads.json`, outside the checkout, for `post`. |
| Set up Node.js | `actions/setup-node` | Node 24. Claude Code needs 22 or later; the runner default changes over time. |
| Install Claude Code | inline | `npm ci` installs the version in `package-lock.json`, checking each checksum. Dependabot proposes updates. |
| Run Claude review | `review` | Runs Claude Code read-only with the files in [`prompt/`](prompt/). |
| Post review comments | `post` | Deals with earlier findings, posts the new findings as one review, and posts a new summary. |

[`prompt/`](prompt/) holds what Claude is told: `prompt.md` (instructions), `standards.md` (what counts as a problem) and `schema.json` (the shape of the answer). Changes there change the review, not the code.

## Security

Claude reviews code that anyone with write access can change, so it's restricted. Most restrictions are flags in `claude_args` in `claude_review.py`, and the tests fail if one is removed:

- **Only Read, Grep and Glob** (`--tools`): no shell, no web access, no edits.
- **Only the checkout:** the tools are allowed only there. Secret locations (`/proc`, `/etc`, `/tmp`, `$RUNNER_TEMP` and others) are also denied, as a backstop: the API key is readable at `/proc/self/environ`.
- **Repository config ignored:** `--setting-sources user` ignores `.claude/settings.json`, and `--strict-mcp-config` stops a `.mcp.json` starting MCP servers, which would run with the API key.
- **No auto-loaded `CLAUDE.md`** (`--bare`): Claude Code doesn't load `CLAUDE.md` files, hooks, plugins or auto memory itself. A `CLAUDE.md` can import files with `@path`, and Claude Code reads those outside the tool rules above. Claude still applies the repository's `CLAUDE.md` or `REVIEW.md` by reading them with the Read tool, as the prompt tells it to.
- **No GitHub token:** the workflow's checkout doesn't keep it (`persist-credentials: false`, not tested), and the GitHub token is only in the steps before and after Claude.
- **No comments, with one exception:** anyone can comment on a public PR, so Claude gets only replies to the action's own findings (threads a bot started) from owners, members and collaborators.
- **Output is data:** `post` sends Claude's output to the GitHub API as JSON, never in a shell command.
- **The PR can't change the setup:** uv runs from this folder, so a `uv.toml` or `.python-version` in the PR is ignored.

One known gap: Claude applies `REVIEW.md` or `CLAUDE.md` from the PR's commit, and they win over the standards, so a PR can weaken its own review.

## Comments on the PR

What users see is in [the workflow docs](../../../docs/workflows/claude-review.md). How `post` does it:

- GitHub only accepts comments on diff lines, so findings on other lines go into the summary.
- The workflow token can't resolve threads, and the action doesn't ask for more permission, so earlier findings are marked superseded instead.
- Hidden markers (HTML comments) identify the action's comments on later runs. Anyone can copy a marker, so:
  - an old summary is deleted only if it comes from the account that posted the new one and starts with the marker;
  - the too-large notice counts only if a comment starts with the marker;
  - an earlier finding counts only if a bot started its thread. With a personal access token, earlier findings come from a person, so they aren't superseded or given to Claude; use the default token or an app token.
- The checkout, diff and comments all use the event's commit, so a push during a review can't shift line numbers.

## Tests

[`test_claude_review.py`](test_claude_review.py) has pytest tests, run by [`action-tests.yml`](../../workflows/action-tests.yml) on PRs that change `.github/actions/`. GitHub is a fake (`httpx.MockTransport`) and so is Claude Code, so they need no API key or GitHub access. To run them locally:

```bash
cd .github/actions/claude-review
uv run --frozen pytest
```

The tests are grouped by command, plus a check that the workflow and action defaults match. The top of the file describes the sample diff. The fakes can't show how the real API behaves: real runs on this repository's own PRs do.

## Changing the action

- **`prompt/`:** nothing checks review quality automatically. Try changes on a real PR first.
- **`claude_review.py`:** update the tests. Dependabot updates `uv.lock` monthly; after changing `pyproject.toml`, run `uv lock`.
- **Claude Code's install script** puts the binary for the runner's platform in place. It's approved by name in `allowScripts` in `package.json`.
- **The workflow** calls this action with `$/`, so both come from the same commit.
