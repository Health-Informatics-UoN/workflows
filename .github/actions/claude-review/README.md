# Claude review action

A composite action that reviews a pull request with Claude Code and posts the findings as comments. This page is for people changing it. To use it, see [the workflow docs](../../../docs/workflows/claude-review.md): most repositories should call the reusable workflow, not this action.

## How a review runs

The steps are in [`action.yml`](action.yml). Each script's header explains what it does and the environment it uses.

| Step | Script | What it does |
|---|---|---|
| Check PR size | [`check-size.sh`](scripts/check-size.sh) | Skips PRs over `max-lines`, and comments once to say so. |
| Fetch PR | [`fetch-pr.sh`](scripts/fetch-pr.sh) | Saves the PR details and the diff for the reviewed commits in `.pr-review/`. |
| Set up Node.js | `actions/setup-node` | Node 24. Claude Code needs 22 or later; the runner default changes over time. |
| Install Claude Code | inline | `npm ci` installs the version in `package-lock.json`, checking each checksum. Dependabot proposes updates. |
| Run Claude review | [`review.sh`](scripts/review.sh) | Runs Claude Code read-only with the files in [`prompt/`](prompt/). |
| Post review comments | [`post.sh`](scripts/post.sh) | Deals with earlier findings, posts the new findings as one review, and posts a new summary. |

[`prompt/`](prompt/) holds what Claude is told: `prompt.md` (instructions), `standards.md` (what counts as a problem) and `schema.json` (the shape of the answer). Changes there change the review, not the code.

## Security

Claude reviews code that anyone with write access can change, so it's restricted. Most restrictions are flags in `review.sh`, and `tests/review.bats` fails if one is removed:

- **Only Read, Grep and Glob** (`--tools`): no shell, no web access, no edits.
- **Only the checkout:** the tools are allowed only there. Secret locations (`/proc`, `/etc`, `/tmp`, `$RUNNER_TEMP` and others) are also denied, as a backstop: the API key is readable at `/proc/self/environ`.
- **Repository config ignored:** `--setting-sources user` ignores `.claude/settings.json`, and `--strict-mcp-config` stops a `.mcp.json` starting MCP servers, which would run with the API key.
- **No auto-loaded `CLAUDE.md`** (`--bare`): Claude Code doesn't load `CLAUDE.md` files, hooks, plugins or auto memory itself. A `CLAUDE.md` can import files with `@path`, and Claude Code reads those outside the tool rules above. Claude still applies the repository's `CLAUDE.md` or `REVIEW.md` by reading them with the Read tool, as the prompt tells it to. A local check (Claude Code 2.1.330) found that `--setting-sources user` alone already stops the project `CLAUDE.md` and its imports, and that an import through a symlink out of the project, or an absolute import, isn't loaded even with default flags.
- **Key check on the output:** if Claude's output contains the API key as plain text, `review.sh` deletes it and fails, before anything is shown or posted. This doesn't depend on the other restrictions, but it doesn't find an encoded key.
- **No GitHub token:** the workflow's checkout doesn't keep it (`persist-credentials: false`, not tested), and `gh` runs only before and after Claude.
- **No comments:** anyone can comment on a public PR, so comments could carry instructions meant to mislead the review.
- **Output is data:** `post.sh` passes Claude's output to `gh` as fields or on stdin, never in a shell command.

One known gap: Claude applies `REVIEW.md` or `CLAUDE.md` from the PR's commit, and they win over the standards, so a PR can weaken its own review.

## Comments on the PR

What users see is in [the workflow docs](../../../docs/workflows/claude-review.md). How `post.sh` does it:

- GitHub only accepts comments on diff lines, so findings on other lines go into the summary.
- Hidden markers (HTML comments) identify the action's comments on later runs. Anyone can copy a marker, so a comment counts only if a bot posted it.
- The checkout, diff and comments all use the event's commit, so a push during a review can't shift line numbers.

## Tests

The scripts have [bats](https://github.com/bats-core/bats-core) unit tests, run by [`action-tests.yml`](../../workflows/action-tests.yml) on PRs that change `.github/actions/`. They use fake `gh` and `claude` programs (`tests/bin`, each explained in its header), so they need no API key or GitHub access. To run them locally:

```bash
brew install bats-core          # or: sudo apt-get install bats
bats .github/actions/claude-review/tests
```

There's one test file per script, plus `defaults.bats` (workflow and action defaults match). `tests/post.bats` describes the sample diff. CI runs on Ubuntu; macOS's `awk` can differ. The fakes can't show how the real API behaves: real runs on this repository's own PRs do.

## Changing the action

- **`prompt/`:** nothing checks review quality automatically. Try changes on a real PR first.
- **Scripts:** update the tests. Comments inside the `awk` and `jq` programs must not contain apostrophes: the programs are in single quotes, so a `'` ends them.
- **Claude Code's install script** puts the binary for the runner's platform in place. It's approved by name in `allowScripts` in `package.json`.
- **The workflow** calls this action with `$/`, so both come from the same commit.
