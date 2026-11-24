# Claude review action

A composite action that reviews a pull request with Claude Code and posts the findings as comments. This page is for people changing it. To use it, see [the workflow docs](../../../docs/workflows/claude-review.md), which has the [setup steps](../../../docs/workflows/claude-review.md#set-up-a-repository): most repositories should call the reusable workflow, not this action.

## How a review runs

The steps are in [`action.yml`](action.yml). The code is one script, [`claude_review.py`](claude_review.py), with one command for each step; its header lists the environment it uses. uv installs its dependencies from [`uv.lock`](uv.lock).

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
- **The PR can't change the setup:** uv reads its settings from this folder (`--project`), so a `uv.toml` or `.python-version` in the PR is ignored.

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

## What happens when…

Situations the action and the reusable workflow handle, and what you see. Most have a test in `test_claude_review.py`.

**When a review runs**

| Situation | What happens |
|---|---|
| Someone pushes while a review runs | The push starts a new run for the new commit, and the workflow cancels the old one (`concurrency`, `cancel-in-progress`). Until the cancel arrives, or if the action is used directly without that setting, the old run keeps to its own commit, so its comments still land on the right lines. |
| The PR is a draft | Skipped, unless someone adds the review label. |
| The review label is added | A review runs, also on a draft. The label is removed afterwards, also if the review failed, so it can be added again. A different label does nothing. |
| The label is added to a closed or merged PR | Nothing runs. |
| The PR is from a fork, or from Dependabot | Skipped: they get no secrets. |
| The PR is over `max-lines` | Skipped, with one comment saying so. Later pushes don't repeat it; a comment that only quotes the notice doesn't count. |

**Before Claude starts**

| Situation | What happens |
|---|---|
| `ANTHROPIC_API_KEY` is missing or empty | The step fails with a message saying to add the secret, without running Claude. (GitHub passes a missing secret as an empty string, and Claude Code would only say "Not logged in".) |
| The PR contains a `.pr-review` folder, file or symbolic link | It's removed and replaced; a symbolic link isn't followed. |
| The PR contains `CLAUDE.md`, `.claude/settings.json`, `.mcp.json`, `uv.toml` or `.python-version` | Claude Code and uv ignore them. Claude reads `CLAUDE.md` or `REVIEW.md` as review rules, through the Read tool. |
| A GitHub API call fails | The step fails with the method, path and HTTP status. |

**When Claude finishes**

| Situation | What happens |
|---|---|
| Claude reports an error, runs out of turns, or prints text instead of JSON (for example, no API credit) | The step fails with Claude's message, and nothing is posted. A failed review never looks like a review with no findings. |
| No findings | No review is posted; the summary says there were none. |

**When findings are posted**

| Situation | What happens |
|---|---|
| A finding is on a line that isn't in the diff, or in a deleted or unknown file | It goes in the summary, under "Findings that could not be attached to a diff line". |
| A finding covers lines in two different hunks, or its start is after its end | It's posted on its last line only. |
| GitHub rejects the review | Every finding goes in the summary, without the hidden marker, and the run gives a warning. |
| A file name has a space or unusual characters (`my notes.txt`, `café.py`) | Comments attach as normal: the name is decoded from the diff. |
| An earlier summary exists | The new summary is posted first, then old summaries from the same account are deleted. Other people's and other bots' comments, and quotes of a summary, are kept. If a delete fails, the run gives a warning. |

**Earlier findings**

| Situation | What happens |
|---|---|
| An earlier finding has no replies | It's resolved. The default token can't resolve threads, so instead it gets a **Superseded** note; people resolve it once checked. A finding already marked is left alone. |
| An earlier finding has replies | The thread is left open. Replies from owners, members and collaborators go to Claude, so it doesn't raise the finding again; other replies don't. |
| Someone replies to, or resolves, a thread during the review | The thread is checked again just before it's changed, and left alone. |
| That check fails | The thread is skipped with a warning; the new findings are still posted. |
| A thread was started by a person with a copied marker | It's ignored: only threads a bot started count. |
| The token is a personal access token | Summaries work, but earlier findings come from a person, so they aren't superseded or given to Claude. Use the default token or an app token. |
| The PR has more than 100 comments or review threads | Every page is read. |

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
