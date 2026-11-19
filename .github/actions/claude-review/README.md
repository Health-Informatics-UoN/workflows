# Claude review action

A composite action that reviews a pull request with Claude Code and posts the findings as comments. This page is for people changing the action. To use it in a repository, see [the workflow docs](../../../docs/workflows/claude-review.md); most repositories should call the reusable workflow, not this action directly.

## How a review runs

The steps are in [`action.yml`](action.yml). Each one runs a script from this folder:

| Step | Script | What it does |
|---|---|---|
| Check PR size | [`check-size.sh`](scripts/check-size.sh) | Skips pull requests over `max-lines` changed lines, and comments once to say so. |
| Fetch PR | [`fetch-pr.sh`](scripts/fetch-pr.sh), then [`fetch-discussed.sh`](scripts/fetch-discussed.sh) | Saves the PR details, the diff for the exact commits being reviewed, and earlier findings people have replied to, in `.pr-review/` in the checkout. Also saves the PR's review threads to `$RUNNER_TEMP/threads.json`, outside the checkout, for `post.sh`: they're fetched once per run, and Claude can't read them. |
| Set up Node.js | `actions/setup-node` | Installs Node 24. Claude Code needs Node 22 or later, and the runner image's default changes over time. |
| Install Claude Code | inline | `npm ci` installs the version pinned in [`package-lock.json`](package-lock.json), checking every package's checksum. |
| Run Claude review | [`review.sh`](scripts/review.sh) | Runs Claude Code read-only with [`prompt/prompt.md`](prompt/prompt.md) and [`prompt/standards.md`](prompt/standards.md), and saves its findings. |
| Post review comments | [`post.sh`](scripts/post.sh) | Marks earlier findings nobody replied to as superseded, posts the new findings as one review, and posts a new summary at the bottom of the PR. |

The PR is fetched before Claude runs, so the Claude step needs no GitHub token. Claude gets the PR's title, description, files and diff, but not its comments: anyone can comment on a public PR, so comments could carry instructions meant to mislead the review. The one exception is replies to earlier findings from people with access to the repository (see [Disagreeing with a finding](#disagreeing-with-a-finding)).

Each script starts with a comment explaining what it does and which environment variables it uses.

## Files

| File | Purpose |
|---|---|
| `action.yml` | The action: inputs and steps. |
| `scripts/` | The logic, kept out of the YAML so it can be read, checked with ShellCheck and tested: `check-size.sh`, `fetch-pr.sh`, `fetch-discussed.sh`, `review.sh` and `post.sh`. |
| `prompt/` | What Claude is told. Changes here change the review, not the code. |
| `prompt/prompt.md` | Instructions to Claude: where the PR is, what to return, how to write it. |
| `prompt/standards.md` | What counts as a problem. A repository's own `REVIEW.md` or `CLAUDE.md` takes precedence. |
| `prompt/schema.json` | The shape Claude's answer must have: findings (file, line, optional start line, comment) and a summary. |
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
- **The summary** is one comment. Each run posts a new one, so it appears at the bottom of the conversation and notifies people, then deletes the previous one. (Editing it in place left the latest review far up the PR, where nobody saw it.)
- **Earlier findings** that nobody has replied to are dealt with at the start of each run. `post.sh` tries to resolve them, but the default workflow token isn't allowed to ("Resource not accessible by integration"), and the action deliberately doesn't ask for more permission. So instead it adds a **Superseded** note to the top of each one, naming the review that replaced it, and people resolve them. The base branch may require all threads to be resolved before merging. If a caller passes a token that is allowed to resolve threads, as `github-token`, they're resolved instead.
- **Hidden markers** (HTML comments, which GitHub doesn't show) identify the action's own comments on later runs: `<!-- claude-review-finding -->`, `<!-- claude-review-summary -->` and `<!-- claude-review-too-large -->`. Anyone can copy a marker into a comment of their own, so a comment only counts as the action's if it also comes from a bot account.
- **One commit throughout:** the checkout, the diff and the comments all use the commit from the event that started the run, so a push during a review can't make the line numbers point at different code.

## Disagreeing with a finding

Replies to a finding are passed to Claude on the next run, so it does not raise the finding again. See [the workflow docs](../../../docs/workflows/claude-review.md#disagreeing-with-a-finding) for how this works and which replies count. `scripts/fetch-discussed.sh` collects them.

## Tests

The scripts have unit tests, written with [bats](https://github.com/bats-core/bats-core) (Bash Automated Testing System). They run on every pull request that changes `.github/actions/`, in the [`action-tests.yml`](../../workflows/action-tests.yml) workflow. They need no API key, GitHub access or credits, and run in seconds.

To run them locally:

```bash
brew install bats-core          # or: sudo apt-get install bats
bats .github/actions/claude-review/tests
```

CI runs them on Ubuntu. macOS's own `awk` may behave slightly differently from Ubuntu's.

There is one test file for each script, and `defaults.bats` checks that the workflow and action defaults match. `test_helper.bash` holds the shared setup and helpers. The tests use fake `gh` and `claude` programs in `tests/bin`, so nothing touches GitHub or the Claude API; the header of each fake explains how it works. `tests/post.bats` describes what each part of the sample diff, `tests/fixtures/pr.diff`, tests.

The fakes only behave as written. Real runs show how the GitHub API behaves: for example, they showed that the workflow token cannot resolve review threads. This repository's own PRs run the review through `claude-review-caller.yml`.

## Changing the action

- **The prompt or standards** (in `prompt/`): there's no automated check of review quality. Try a change on a real pull request before merging it.
- **The scripts:** add or update a test in `tests/`, and run ShellCheck (CI runs it on the `.sh` files). Comments inside the `awk` and `jq` programs must not contain apostrophes: the programs are inside single quotes in the shell, so a `'` ends them early.
- **The Claude Code version:** Dependabot proposes updates to `package-lock.json`. Its install script, which puts the binary for the runner's platform in place, is approved by name in `allowScripts` in `package.json`.
- **The workflow and the action together:** the reusable workflow calls this action with `$/`, so both always come from the same commit.
