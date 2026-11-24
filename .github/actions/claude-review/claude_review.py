"""Review a pull request with Claude Code and post the findings as comments.

action.yml runs one command for each step:

  check-size  Skip PRs over MAX_LINES, and comment once to say so.
  fetch       Save the PR details, its diff and the replies to earlier findings in
              .pr-review/ in the checkout, for Claude. Save all review threads in
              $RUNNER_TEMP/threads.json, outside the checkout, for post.
  review      Run Claude Code read-only on the checkout. Save its answer in
              $RUNNER_TEMP/review.json, for post.
  post        Deal with earlier findings, post the new findings as one review, and
              post a new summary comment.

The steps get their settings from environment variables, which action.yml sets:
GH_TOKEN, REPO (owner/name), PR_NUMBER, BASE_SHA, HEAD_SHA, ADDITIONS, DELETIONS,
MAX_LINES, ANTHROPIC_API_KEY, MODEL, MAX_TURNS and EFFORT. GitHub Actions sets
GITHUB_WORKSPACE (the checkout), RUNNER_TEMP, GITHUB_OUTPUT, GITHUB_API_URL and
GITHUB_GRAPHQL_URL. uv runs this script from the action's folder, not from the
checkout, so the checkout is GITHUB_WORKSPACE, not the current directory.

Claude reviews code that the PR can change, so the review command gives it no GitHub
token, and only Read, Grep and Glob in the checkout. See README.md, "Security".
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import httpx

ACTION_DIR = Path(__file__).parent

# Hidden HTML markers identify the comments of this action on later runs. GitHub does
# not show an HTML comment, but the API gives it in the comment text.
FINDING_MARKER = "<!-- claude-review-finding -->"
SUMMARY_MARKER = "<!-- claude-review-summary -->"
SUPERSEDED_MARKER = "<!-- claude-review-superseded -->"
TOO_LARGE_MARKER = "<!-- claude-review-too-large -->"

# Only replies from people with access to the repository go to Claude. Anyone can
# comment on a public PR, so other replies can contain injected instructions.
TRUSTED = ("OWNER", "MEMBER", "COLLABORATOR")

# The tools that Claude has, where it can use them, and where it never can. The
# denied locations are a second barrier: the allowed rule already limits the tools to
# the checkout. "//" is an absolute path and "~" is the home folder; both are for
# Claude Code. /proc/self/environ contains the API key. RUNNER_TEMP is added at run
# time: it is outside the checkout and holds this action's working files.
TOOLS = ("Read", "Grep", "Glob")
DENIED_PATHS = ("//proc/**", "//sys/**", "//etc/**", "//root/**", "//tmp/**", "//run/**",
                "//var/**", "~/.*/**")

# Tests replace this with httpx.MockTransport.
transport: httpx.BaseTransport | None = None


class Error(Exception):
    """An error with a message for the person who reads the log."""


def env(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise Error(f"{name} is not set")
    return value


def workspace() -> Path:
    return Path(env("GITHUB_WORKSPACE"))


def runner_temp() -> Path:
    return Path(env("RUNNER_TEMP"))


def pr_path() -> str:
    return f"/repos/{env('REPO')}/issues/{env('PR_NUMBER')}"


# --- GitHub API ------------------------------------------------------------------------

def github() -> httpx.Client:
    return httpx.Client(
        base_url=os.environ.get("GITHUB_API_URL") or "https://api.github.com",
        headers={
            "Authorization": f"Bearer {env('GH_TOKEN')}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        timeout=60,
        transport=transport,
    )


def call(gh: httpx.Client, method: str, path: str, **kwargs) -> httpx.Response:
    response = gh.request(method, path, **kwargs)
    response.raise_for_status()
    return response


def get_all(gh: httpx.Client, path: str) -> list:
    """GET every page of a REST list. GitHub gives the next page in the Link header."""
    items: list = []
    url: str | None = path
    params: dict | None = {"per_page": 100}
    while url:
        response = call(gh, "GET", url, params=params)
        items += response.json()
        url = response.links.get("next", {}).get("url")
        params = None  # The next URL has the parameters already.
    return items


def graphql(gh: httpx.Client, query: str, **variables) -> dict:
    """Review threads are in the GraphQL API only. It reports most errors with HTTP 200
    and an "errors" list, for example when the token can't resolve a thread."""
    url = os.environ.get("GITHUB_GRAPHQL_URL") or "https://api.github.com/graphql"
    body = call(gh, "POST", url, json={"query": query, "variables": variables}).json()
    if body.get("errors"):
        raise Error("; ".join(e.get("message", "unknown error") for e in body["errors"]))
    return body["data"]


# --- check-size --------------------------------------------------------------------------

def check_size() -> None:
    """Large PRs cost more to review and get worse reviews, so they are skipped. Sets the
    step output too-large; the other steps run only if it is "false"."""
    lines = int(env("ADDITIONS")) + int(env("DELETIONS"))
    limit = int(env("MAX_LINES"))
    with open(env("GITHUB_OUTPUT"), "a") as output:
        output.write(f"too-large={'true' if lines > limit else 'false'}\n")
    if lines <= limit:
        return
    with github() as gh:
        # The notice starts with the marker; a comment that quotes it does not. The
        # author isn't checked: nothing is posted yet, so the login isn't known. A wrong
        # match only stops the notice, and the PR is skipped anyway.
        comments = get_all(gh, f"{pr_path()}/comments")
        if any((c.get("body") or "").startswith(TOO_LARGE_MARKER) for c in comments):
            print("Too-large comment already posted; skipping review.")
            return
        call(gh, "POST", f"{pr_path()}/comments", json={"body": (
            f"{TOO_LARGE_MARKER}\nPR too large for automated review ({lines} lines "
            f"changed, limit {limit}). Consider splitting it up.")})


# --- fetch ---------------------------------------------------------------------------------

# post uses the thread id and isResolved to resolve or mark old findings, and the comment
# databaseId to edit them. "line" is null if the thread is outdated; then originalLine
# is the line of the first post. A thread gets at most 20 comments, but totalCount is
# always the full number, so the "no replies" check in post is always correct.
THREADS_QUERY = """
query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved path line originalLine
          comments(first: 20) {
            totalCount
            nodes { databaseId body authorAssociation author { __typename login } }
          }
        }
      }
    }
  }
}"""


def fetch() -> None:
    """Gets the PR before Claude starts, so the review step needs no GitHub token.

    The diff is for BASE_SHA...HEAD_SHA, the commits of the event that started this run.
    Usually they are also the PR's latest commits. If someone pushes after the run
    starts, the push starts a new run for the new commit, and the reusable workflow
    cancels this one (concurrency, cancel-in-progress). Until the cancel arrives, or if
    the action is used without that setting, this run keeps to the event's commits:
    the checkout and post also use HEAD_SHA, so the code that Claude reads, the diff
    that its line numbers refer to, and the commit that gets the comments are always
    the same.

    PR comments aren't fetched: anyone can post them. Only trusted replies to this
    action's findings go to Claude.
    """
    out = workspace() / ".pr-review"
    # Start empty: the PR can contain .pr-review, also as a symbolic link.
    if out.is_symlink() or out.is_file():
        out.unlink()
    elif out.exists():
        shutil.rmtree(out)
    out.mkdir()

    repo, number = env("REPO"), int(env("PR_NUMBER"))
    with github() as gh:
        # No list of changed files: GitHub gives it for the PR's latest commit, which can
        # be newer than HEAD_SHA after a push. The diff shows the files for HEAD_SHA.
        pr = call(gh, "GET", f"/repos/{repo}/pulls/{number}").json()
        details = {
            "title": pr["title"],
            "body": pr.get("body") or "",
            "author": {"login": (pr.get("user") or {}).get("login")},
            "baseRefName": pr["base"]["ref"],
            "headRefName": pr["head"]["ref"],
        }
        (out / "pr.json").write_text(json.dumps(details, indent=2) + "\n")

        # The diff has only the changes that the PR makes, as on its "Files changed" tab.
        # The PR branch starts from main at a commit (B, the merge base), and main can
        # move on after that:
        #
        #   main:  A --- B --- C --- D    <- BASE_SHA
        #                 \
        #   PR:            X --- Y        <- HEAD_SHA
        #
        # Two dots (D..Y) compare the two ends: X and Y, plus C and D in reverse, because
        # the PR branch doesn't have them. Claude would review code that the PR doesn't
        # touch. Three dots (D...Y) compare Y with B: only X and Y.
        #
        # BASE_SHA and HEAD_SHA are from the event, not looked up again here, so a push
        # after the run starts doesn't change the diff. The checkout and post use the same
        # HEAD_SHA, so Claude's line numbers match the lines that get the comments.
        diff = call(gh, "GET", f"/repos/{repo}/compare/{env('BASE_SHA')}...{env('HEAD_SHA')}",
                    headers={"Accept": "application/vnd.github.diff"})
        (out / "pr.diff").write_bytes(diff.content)

        threads: list = []
        cursor = None
        owner, name = repo.split("/", 1)
        while True:
            page = graphql(gh, THREADS_QUERY, owner=owner, name=name, number=number,
                           endCursor=cursor)["repository"]["pullRequest"]["reviewThreads"]
            threads += page["nodes"]
            if not page["pageInfo"]["hasNextPage"]:
                break
            cursor = page["pageInfo"]["endCursor"]

    # All threads, with comments from anyone: outside the checkout, so Claude can't read it.
    (runner_temp() / "threads.json").write_text(json.dumps(threads))
    (out / "discussed.json").write_text(json.dumps(discussed(threads), indent=2) + "\n")


def first_comment(thread: dict) -> dict:
    nodes = thread["comments"]["nodes"]
    return nodes[0] if nodes else {}


def is_bot_finding(comment: dict) -> bool:
    """A thread is an earlier finding only if a bot started it with the marker. Anyone
    can copy the marker. See README.md for personal access tokens."""
    return (FINDING_MARKER in (comment.get("body") or "")
            and (comment.get("author") or {}).get("__typename") == "Bot")


def finding_text(body: str) -> str:
    """The finding as Claude wrote it: without a superseded note and without the marker."""
    return body.split(SUPERSEDED_MARKER + "\n\n")[-1].split("\n\n" + FINDING_MARKER)[0]


def discussed(threads: list) -> list:
    """Earlier findings that trusted people replied to, with those replies. Claude then
    doesn't raise a finding again after someone has disagreed with it."""
    result = []
    for thread in threads:
        first = first_comment(thread)
        if not is_bot_finding(first):
            continue
        replies = [{"author": (c.get("author") or {}).get("login"), "body": c.get("body")}
                   for c in thread["comments"]["nodes"][1:]
                   if c.get("authorAssociation") in TRUSTED]
        if replies:
            result.append({
                "path": thread["path"],
                # If the thread is outdated, use the original line.
                "line": thread["line"] if thread.get("line") is not None else thread.get("originalLine"),
                "resolved": thread["isResolved"],
                "finding": finding_text(first["body"]),
                "replies": replies,
            })
    return result


# --- review --------------------------------------------------------------------------------

def claude_args(prompt: str, schema: str) -> list[str]:
    """The Claude Code command. Each restriction is a flag; the tests fail if one goes.

    --bare: no CLAUDE.md files, hooks, plugins or auto memory, and no keychain. A
      CLAUDE.md in the PR could import files with "@path", which Claude Code reads
      itself, possibly outside the rules below. Claude still applies the repository's
      CLAUDE.md or REVIEW.md: the prompt tells it to read them with the Read tool.
    --setting-sources user: ignore .claude/settings.json in the repo, so it can't change
      the tools or add hooks. This also stops the project CLAUDE.md.
    --strict-mcp-config, without --mcp-config: start no MCP servers, so a .mcp.json in
      the repo can't run a command on the runner, where the API key is.
    --tools: only Read, Grep and Glob exist. Other tools (Bash, WebFetch) are removed,
      not only refused.
    --allowedTools: those tools only in the checkout ("./**"). In print mode (-p), Claude
      Code refuses everything else, also symbolic links out of the checkout.
    --disallowedTools: a second barrier, for locations with secrets and RUNNER_TEMP.
    --json-schema: Claude Code returns the answer as structured_output.
    """
    denied = (*DENIED_PATHS, f"/{env('RUNNER_TEMP')}/**")  # RUNNER_TEMP starts with /.
    return [
        str(ACTION_DIR / "node_modules" / ".bin" / "claude"), "-p", prompt,
        "--bare",
        "--model", env("MODEL"),
        "--max-turns", env("MAX_TURNS"),
        "--effort", env("EFFORT"),
        "--setting-sources", "user",
        "--strict-mcp-config",
        "--tools", ",".join(TOOLS),
        "--output-format", "json",
        "--json-schema", schema,
        "--allowedTools", ",".join(f"{tool}(./**)" for tool in TOOLS),
        "--disallowedTools", ",".join(f"{tool}({path})" for tool in TOOLS for path in denied),
    ]


def run_claude(args: list[str], cwd: Path) -> str:
    """Runs Claude Code and returns what it prints. A failed run also prints JSON with
    the error, so the exit status isn't checked here; review checks the output."""
    try:
        return subprocess.run(args, cwd=cwd, stdout=subprocess.PIPE, text=True, check=False).stdout
    except OSError as e:
        raise Error(f"Could not run Claude Code: {e}") from None


def review() -> None:
    # A caller's secret that doesn't exist reaches the action as an empty string, also if
    # the workflow marks it as required. Claude Code then says only "Not logged in".
    if not os.environ.get("ANTHROPIC_API_KEY"):
        raise Error("ANTHROPIC_API_KEY is empty. Add it as an Actions secret (Settings > "
                    "Secrets and variables > Actions) and pass it to the workflow under secrets:.")

    prompt_dir = ACTION_DIR / "prompt"
    # Compact, and a check that schema.json is valid JSON.
    schema = json.dumps(json.loads((prompt_dir / "schema.json").read_text()),
                        separators=(",", ":"), ensure_ascii=False)
    prompt = ((prompt_dir / "prompt.md").read_text().rstrip("\n") + "\n\n"
              + (prompt_dir / "standards.md").read_text().rstrip("\n"))

    output = run_claude(claude_args(prompt, schema), cwd=workspace())
    (runner_temp() / "review.json").write_text(output)

    # For some failures (for example, no credit), Claude Code prints text, not JSON.
    try:
        result = json.loads(output)
    except ValueError:
        result = None
    if not isinstance(result, dict):
        print("::error::Claude review did not complete")
        print(output)
        raise SystemExit(1)

    print(json.dumps({key: result.get(key) for key in
                      ("is_error", "num_turns", "total_cost_usd", "permission_denials")}, indent=2))

    # Complete only with no error and findings in the shape of the schema. If Claude
    # uses all its turns, there is no structured_output. Thus, a failed review doesn't
    # look like a review with no findings.
    if result.get("is_error") is not False or not isinstance(result.get("structured_output"), dict):
        print("::error::Claude review did not complete")
        print(result.get("result") or "")
        raise SystemExit(1)


# --- post ----------------------------------------------------------------------------------

def unquote(name: str) -> str:
    """Git quotes a file name with unusual characters and writes them as backslash codes,
    for example "b/caf\\303\\251.py" for café.py. Change it back: \\NNN is one byte in
    octal, \\t and \\n are a TAB and a new line, and a backslash before another character
    is that character."""
    if not (len(name) >= 2 and name.startswith('"') and name.endswith('"')):
        return name
    quoted, out, i = name[1:-1], bytearray(), 0
    while i < len(quoted):
        char = quoted[i]
        if char != "\\":
            out += char.encode()
            i += 1
        elif quoted[i + 1:i + 2] and quoted[i + 1] in "01234567":
            out.append(int(quoted[i + 1:i + 4], 8))
            i += 4
        else:
            following = quoted[i + 1:i + 2]
            out += {"t": "\t", "n": "\n"}.get(following, following).encode()
            i += 2
    return out.decode("utf-8", errors="replace")


def commentable_lines(diff: str) -> dict[str, dict[int, int]]:
    """{path: {new line: hunk number}} for each line that can have a review comment.

    GitHub accepts a comment only on a line in the diff (an added line or a context line
    near it), and one bad comment makes it reject the whole review. A comment on a range
    of lines must start and end in the same hunk. An example diff:

      +++ b/app.py      <- the file name, after "+++ b/"
      @@ -1,3 +1,4 @@   <- a hunk: +1 means it starts at new line 1
       import os        <- a context line: new line 1
      +import sys       <- an added line: new line 2
      -import re        <- a removed line: not in the new file

    In a hunk, a removed line "-- x" shows as "--- x" and an added line "++ x" as
    "+++ x", so "+++" is a file name only before the first hunk of a file. If a name has
    a space, Git adds a TAB after it on the "+++" line.
    """
    lines: dict[str, dict[int, int]] = {}
    path: str | None = None
    in_hunk, hunk, line = False, 0, 0
    for text in diff.split("\n"):
        if text.startswith("diff --git "):
            path, in_hunk = None, False
        elif not in_hunk and text.startswith("+++ "):
            name = text[4:]
            # "+++ /dev/null" is a deleted file: it has no lines for comments.
            path = None if name == "/dev/null" else unquote(name.removesuffix("\t"))[2:]
        elif text.startswith("@@ "):
            in_hunk, hunk = True, hunk + 1
            match = re.search(r"\+(\d+)", text)
            line = int(match.group(1)) if match else 0
        elif in_hunk and path is not None and text[:1] in (" ", "+"):
            lines.setdefault(path, {})[line] = hunk
            line += 1
    return lines


def split_findings(findings: list, commentable: dict[str, dict[int, int]]) -> tuple[list, list]:
    """(review comments, findings for the summary). A comment is on the new side of the
    file. A start_line makes a range only if it comes before line and is in the same
    hunk; if not, the comment is on the last line only."""
    def hunk_of(path, line):
        return commentable.get(path, {}).get(line)

    comments, unanchored = [], []
    for finding in findings:
        hunk = hunk_of(finding["path"], finding["line"])
        if hunk is None:
            unanchored.append(finding)
            continue
        comment = {"path": finding["path"], "line": finding["line"], "side": "RIGHT",
                   "body": finding["body"] + "\n\n" + FINDING_MARKER}
        start = finding.get("start_line")
        if start is not None and start < finding["line"] and hunk_of(finding["path"], start) == hunk:
            comment |= {"start_line": start, "start_side": "RIGHT"}
        comments.append(comment)
    return comments, unanchored


THREAD_NOW_QUERY = """
query($id: ID!) { node(id: $id) { ... on PullRequestReviewThread {
  isResolved comments(first: 1) { totalCount } } } }"""

RESOLVE_MUTATION = """
mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { id } } }"""


def supersede_earlier(gh: httpx.Client, threads: list, head_sha: str) -> None:
    """Each run reviews the whole PR again, so its findings replace the earlier ones.

    Earlier findings without replies are resolved. The default token can't resolve threads
    ("Resource not accessible by integration"), and this action doesn't ask for more
    permission; then a superseded note goes at the top of the comment, and people
    resolve the thread. A thread with a reply is a conversation between people, so it
    isn't changed. threads.json is from before the review, so each thread is checked again
    just before it is changed.
    """
    superseded = 0
    for thread in threads:
        first = first_comment(thread)
        if (thread["isResolved"] or thread["comments"]["totalCount"] != 1
                or not is_bot_finding(first) or SUPERSEDED_MARKER in first["body"]):
            continue
        try:
            now = graphql(gh, THREAD_NOW_QUERY, id=thread["id"])["node"]
        except (Error, httpx.HTTPError):
            # The new findings are more important; skip this thread.
            print(f"::warning::Could not check review thread {thread['id']}")
            continue
        if now["isResolved"] or now["comments"]["totalCount"] != 1:
            continue
        try:
            graphql(gh, RESOLVE_MUTATION, id=thread["id"])
            continue
        except (Error, httpx.HTTPError):
            pass
        note = (f"**Superseded** by the review of `{head_sha[:7]}`. This finding is from an "
                "earlier review and may no longer apply. Resolve this thread when you have "
                f"checked it.\n{SUPERSEDED_MARKER}\n\n")
        try:
            call(gh, "PATCH", f"/repos/{env('REPO')}/pulls/comments/{first['databaseId']}",
                 json={"body": note + first["body"]})
            superseded += 1
        except httpx.HTTPError:
            print(f"::warning::Could not resolve or mark review thread {thread['id']}")
    if superseded:
        print(f"::notice::Marked {superseded} earlier finding(s) as superseded; "
              "the token can't resolve review threads.")


def summary_body(head_sha: str, count: int, summary: str, unanchored: list) -> str:
    body = (f"{SUMMARY_MARKER}\n**Claude review** of {head_sha[:7]}: {count} inline "
            f"finding(s).\n\n{summary}\n")
    if unanchored:
        body += ("\n**Findings that could not be attached to a diff line:**\n"
                 + "\n".join(f"- `{f['path']}:{f['line']}`: {f['body']}" for f in unanchored))
    return body.rstrip("\n")


def post() -> None:
    temp = runner_temp()
    answer = json.loads((temp / "review.json").read_text())["structured_output"]
    threads = json.loads((temp / "threads.json").read_text())
    diff = (workspace() / ".pr-review" / "pr.diff").read_bytes().decode("utf-8", errors="replace")
    head_sha = env("HEAD_SHA")
    comments, unanchored = split_findings(answer["findings"], commentable_lines(diff))

    with github() as gh:
        # 1. Earlier findings.
        supersede_earlier(gh, threads, head_sha)

        # 2. The findings as one review, so all of them make one notification. COMMENT
        # doesn't approve or request changes. If GitHub rejects the review, the summary
        # gets every finding, without the marker, so no finding is lost.
        if comments:
            try:
                call(gh, "POST", f"/repos/{env('REPO')}/pulls/{env('PR_NUMBER')}/reviews", json={
                    "commit_id": head_sha, "event": "COMMENT",
                    "body": "Claude review findings. See the summary comment.",
                    "comments": comments})
            except httpx.HTTPError:
                print("::warning::GitHub rejected the review; listing all findings in the summary.")
                unanchored += [{"path": c["path"], "line": c["line"],
                                "body": c["body"].removesuffix("\n\n" + FINDING_MARKER)}
                               for c in comments]
                comments = []

        # 3. A new summary at the bottom tells people that the review ran; an edited one
        # stays far up, with no notification. Post the new summary first, so the PR always
        # has one if a step fails. The answer gives the login of the account that posted
        # it (github-actions[bot] for the default token); GET /user doesn't work with the
        # default token.
        posted = call(gh, "POST", f"{pr_path()}/comments", json={"body": summary_body(
            head_sha, len(comments), answer["summary"], unanchored)}).json()

        # Old summaries: from the same account and starting with the marker, except the
        # new one. Other bots, and a person who quotes a summary (with a personal token,
        # summaries come from that person), have comments that don't start with it.
        for comment in get_all(gh, f"{pr_path()}/comments"):
            if (comment["user"]["login"] == posted["user"]["login"] and comment["id"] != posted["id"]
                    and (comment.get("body") or "").startswith(SUMMARY_MARKER)):
                try:
                    call(gh, "DELETE", f"/repos/{env('REPO')}/issues/comments/{comment['id']}")
                except httpx.HTTPError:
                    print(f"::warning::Could not delete the previous summary comment {comment['id']}")


# --- main ----------------------------------------------------------------------------------

COMMANDS = {"check-size": check_size, "fetch": fetch, "review": review, "post": post}


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("command", choices=COMMANDS)
    args = parser.parse_args(argv)
    try:
        COMMANDS[args.command]()
    except Error as e:
        print(f"::error::{e}")
        raise SystemExit(1)
    except httpx.HTTPStatusError as e:
        print(f"::error::GitHub API: {e.request.method} {e.request.url.path} gave "
              f"HTTP {e.response.status_code}: {e.response.text[:300]}")
        raise SystemExit(1)
    except httpx.HTTPError as e:
        print(f"::error::GitHub API: {e}")
        raise SystemExit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
