# Claude review action

A composite action that reviews a pull request with Claude Code and posts the findings as comments. This page is for people changing the action. To use it in a repository, see [the workflow docs](../../../docs/workflows/claude-review.md); most repositories should call the reusable workflow, not this action directly.

## How a review runs

The steps are in [`action.yml`](action.yml). Each one runs a script from this folder:

| Step | Script | What it does |
|---|---|---|
| Check PR size | [`check-size.sh`](check-size.sh) | Skips pull requests over `max-lines` changed lines, and comments once to say so. |
| Fetch PR | inline, plus [`fetch-discussed.sh`](fetch-discussed.sh) | Saves the PR details, the diff, and earlier findings people have replied to, in `.pr-review/` in the checkout. |
| Install Claude Code | inline | `npm ci` installs the version pinned in [`package-lock.json`](package-lock.json), checking every package's checksum. |
| Run Claude review | [`review.sh`](review.sh) | Runs Claude Code read-only with [`prompt.md`](prompt.md) and [`standards.md`](standards.md), and saves its findings. |
| Post review comments | [`post.sh`](post.sh) | Resolves earlier findings nobody replied to, posts the new findings as one review, and updates the summary comment. |

The PR is fetched before Claude runs, so the Claude step needs no GitHub token. Claude gets the PR's title, description, files and diff, but not its comments: anyone can comment on a public PR, so comments could carry instructions meant to mislead the review. The one exception is replies to earlier findings from people with access to the repository (see [Disagreeing with a finding](#disagreeing-with-a-finding)).

Each script starts with a comment explaining what it does and which environment variables it uses.

## Files

| File | Purpose |
|---|---|
| `action.yml` | The action: inputs and steps. |
| `check-size.sh`, `fetch-discussed.sh`, `review.sh`, `post.sh` | The logic, kept out of the YAML so it can be read, checked with ShellCheck and tested. |
| `prompt.md` | Instructions to Claude: where the PR is, what to return, how to write it. |
| `standards.md` | What counts as a problem. A repository's own `REVIEW.md` or `CLAUDE.md` takes precedence. |
| `schema.json` | The shape Claude's answer must have: findings (file, line, optional start line, comment) and a summary. |
| `package.json`, `package-lock.json` | Pin the Claude Code version. Dependabot proposes updates. |
| `tests/` | Unit tests for the scripts (see [Tests](#tests)). |

## Security

Claude reviews code that anyone with write access can change, so it's restricted. The restrictions are command-line flags in `review.sh`:

- **Only three tools:** `--tools "Read,Grep,Glob"`. There's no shell, no web access and no way to change files.
- **Only the checkout:** the tools are allowed only inside the checkout, and reading the places that hold secrets (`/proc`, `/etc`, `/tmp` and others) is denied as a backstop. The API key is in Claude Code's own environment, which is readable at `/proc/self/environ`.
- **Repository config is ignored:** `--setting-sources user` ignores the repository's `.claude/settings.json`, so a PR can't change Claude's tools or add hooks. `--strict-mcp-config` stops a `.mcp.json` in the repository starting MCP servers, which would run commands on the runner with the API key in their environment.
- **No GitHub token:** the checkout doesn't keep its token (`persist-credentials: false`), and the steps that use `gh` run before and after Claude, not during.
- **Claude's output is data, not code:** `post.sh` passes it to `gh` as fields or on stdin, never inside a shell command.

The tests in `tests/review.bats` fail if any of these flags is removed.

## Comments on the PR

- **Findings** are posted as one review per run, so there's one notification. Each finding is on a line, or a range of lines, in the diff. GitHub only accepts comments on lines that appear in the diff, so `post.sh` reads the diff first and moves any finding on another line into the summary.
- **The summary** is one comment, edited by each run rather than posted again.
- **Earlier findings** that nobody has replied to are resolved at the start of each run, so only the current findings are open. The base branch may require all threads to be resolved before merging.
- **Hidden markers** (HTML comments, which GitHub doesn't show) identify the action's own comments on later runs: `<!-- claude-review-finding -->`, `<!-- claude-review-summary -->` and `<!-- claude-review-too-large -->`.

## Disagreeing with a finding

When someone replies to a finding, the next run doesn't resolve that thread: it's now a conversation between people. `fetch-discussed.sh` collects the findings people have replied to, with their replies, into `.pr-review/discussed.json`, and `prompt.md` tells Claude not to raise them again unless the code has changed in a way the reply doesn't cover.

Only replies from owners, organisation members and collaborators are included, for the same reason comments aren't fetched.

## Tests

The scripts have unit tests, written with [bats](https://github.com/bats-core/bats-core) (Bash Automated Testing System). They run on every pull request that changes `.github/actions/`, in the [`action-tests.yml`](../../workflows/action-tests.yml) workflow. They need no API key, GitHub access or credits, and run in seconds.

To run them locally:

```bash
brew install bats-core          # or: sudo apt-get install bats
bats .github/actions/claude-review/tests
```

CI runs them on Ubuntu. macOS's own `awk` may behave slightly differently from Ubuntu's.

### What's in `tests/`

| File | Purpose |
|---|---|
| `check-size.bats` | Tests for `check-size.sh`: under, at and over the limit, and commenting only once. |
| `review.bats` | Tests for `review.sh`: the arguments passed to Claude, including every security flag, and each kind of failure. |
| `post.bats` | Tests for `post.sh`: which lines comments attach to, ranges, the summary, resolving earlier threads, and what happens when GitHub rejects a call. |
| `fetch-discussed.bats` | Tests for `fetch-discussed.sh`: which replies are passed to Claude and which are left out. |
| `defaults.bats` | Checks that the reusable workflow's input defaults match the action's, and that the limits are 2000 lines and 25 turns. |
| `test_helper.bash` | Shared setup, and helpers for checking what the fake `gh` was asked to do. |
| `bin/gh`, `bin/claude` | Fakes that stand in for the real programs (see below). |
| `fixtures/pr.diff` | A sample PR diff (see below). |

### The fakes in `tests/bin`

The tests run the real scripts, but with fake `gh` and `claude` programs, so nothing touches GitHub or the Claude API.

- **How they're used:** `test_helper.bash` puts `tests/bin` first in `PATH`, so when a script runs `gh`, the shell finds the fake first. `review.sh` runs Claude Code by its full path in the action folder, so `review.bats` links the fake `claude` into that path in a temporary folder.
- **Fake `gh`:**
  - records every call: its arguments in `NNN.args` and anything sent on stdin in `NNN.stdin`, so tests can check what would have been posted;
  - answers with sample GitHub responses that the test sets in environment variables (`GH_THREADS_JSON`, `GH_ISSUE_COMMENTS_JSON`, `GH_PR_JSON`);
  - applies the script's own `--jq` filter to that sample, as the real `gh` does, so the scripts' filters are tested too;
  - fails on request (`GH_FAIL_REVIEW`, `GH_FAIL_RESOLVE`), to test what happens when GitHub rejects a call.
- **Fake `claude`:** records its arguments and prints the output the test sets (`CLAUDE_OUTPUT`, `CLAUDE_EXIT`).

The fakes only behave as written, so they can't show how the real GitHub API behaves, such as whether the token is allowed to resolve threads. Real pull requests show that. This repository's own PRs run the review through `claude-review-caller.yml`.

### The sample diff in `tests/fixtures/pr.diff`

`post.bats` copies it to `.pr-review/pr.diff`, where the action saves a real PR's diff. It's small, but each part tests something:

| Part | New lines | Tests |
|---|---|---|
| `app.py`, first hunk | 1–4 | Added and context lines can both be commented on. Line 3 is a blank context line, which a diff stores as one space. |
| `app.py`, second hunk | 21–24 | A range across the two hunks (for example 3–22) is reduced to its last line. Line 10, between the hunks, isn't in the diff. |
| A removed line shown as `--- …` and an added line shown as `+++ …` | 23 is the added one | Lines that look like file headers are still counted as lines. |
| `old.txt`, deleted (`+++ /dev/null`) | none | A finding on a deleted file goes to the summary. |

## Changing the action

- **The prompt or standards:** there's no automated check of review quality. Try a change on a real pull request before merging it.
- **The scripts:** add or update a test in `tests/`, and run ShellCheck (CI runs it on the `.sh` files). Comments inside the `awk` and `jq` programs must not contain apostrophes: the programs are inside single quotes in the shell, so a `'` ends them early.
- **The Claude Code version:** Dependabot proposes updates to `package-lock.json`. Its install script, which puts the binary for the runner's platform in place, is approved by name in `allowScripts` in `package.json`.
- **The workflow and the action together:** the reusable workflow calls this action with `$/`, so both always come from the same commit.
