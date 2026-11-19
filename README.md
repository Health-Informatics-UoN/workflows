# Workflows

Reusable GitHub Actions workflows for common CI/CD tasks, designed to be easily integrated into your projects.

The intention here is to provide a consistent, secure, and maintanable set of workflows that enable us to release code quicker. Rather than every codebase having its own way of releasing code, publishing containers, that has to be learnt, and made secure individually. 

See the [docs](./docs/) for detailed documentation on each workflow, including parameters, usage instructions, and best practices.

See the [samples](./samples/) for example workflows demonstrating how to use these reusable workflows in real-world scenarios.

Some workflows use actions kept in this repository, under [`.github/actions/`](./.github/actions/). Each has a README for anyone changing it, covering how it works and how to run its tests: see the [Claude review action](./.github/actions/claude-review/README.md).

Note - this repository uses its own workflows to release, so you can check out the [release workflow](./.github/workflows/release.yml) for a real example of how to use these workflows together in a complete release pipeline.
