# Review standards

## Flag
- Logic bugs: wrong results, off-by-one errors, unhandled edge cases (empty input, `None`, missing files).
- Security issues: secrets in code, unsafe use of user input (shell, SQL, file paths), insecure defaults.
- Missing or swallowed error handling (bare `except:`, errors silently ignored).
- Race conditions: shared state or files touched concurrently without locking, check-then-act bugs.
- GitHub Actions: secrets or `${{ }}` untrusted input interpolated directly into `run:` scripts,
  overly broad `permissions`, third-party actions not pinned to a commit SHA.

## Don't flag
- Formatting or naming preferences.
- Missing comments or docstrings.
- Suggestions to refactor working code without a concrete defect.

## Confidence
- Only report a finding when you can point to the exact line in the diff that causes it.
- If you couldn't verify something (for example, it depends on a file or workflow you can't see),
  don't report it as a finding. Mention it in the summary as a question instead.
