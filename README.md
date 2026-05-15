# \_ReusableWorkflows

Centralized GitHub Actions **reusable workflows** used by 2000+ Skyline
repositories. Caller repos reference one of the *master* workflows here so
that build, validation, packaging and publishing logic stays consistent
across the fleet and can be evolved in a single place.

## Master workflows

| Workflow                                                  | Purpose                                                        |
| --------------------------------------------------------- | -------------------------------------------------------------- |
| `Connector Master Workflow.yml`                           | CI/CD for DataMiner connector solutions (SDK and Legacy).      |
| `Connector Master SDK Workflow.yml`                       | SDK-style connector pipeline (validator, Sonar, packaging).    |
| `Connector Master Legacy Workflow.yml`                    | Legacy connector pipeline.                                     |
| `Automation Master Workflow.yml`                          | CI/CD for Automation scripts (SDK and Legacy).                 |
| `Automation Master SDK Workflow.yml` / `Legacy`           | SDK / Legacy automation pipelines.                             |
| `NuGet Solution Master Workflow.yml`                      | Build & publish public NuGet packages.                         |
| `Internal NuGet Solution Master Workflow.yml`             | Build & publish internal NuGet packages.                       |
| `SRM Function Master Workflow.yml`                        | CI/CD for SRM functions.                                       |
| `DataMiner App Packages Master Workflow.yml`              | Build & publish DataMiner application packages.                |
| `Update Catalog Details Workflow.yml`                     | Update Catalog metadata on release.                            |
| `Test Downstream.yml`                                     | Verifies downstream repos still build against changes here.    |
| `SDK Migration Workflow.yml`                              | Detects legacy csproj and asks Copilot to open a migration PR. |
| `Master Workflow.yml`                                     | Top-level dispatcher.                                          |

---

## AI Review (advisory) — opt-in

The `Connector Master Workflow.yml` can post an **AI-generated, advisory
summary** of the DataMiner connector validator output as a comment on the
pull request. It is implemented as a separate reusable workflow
(`AI Review Workflow.yml`) and uses [GitHub Models] via
`actions/ai-inference@v2`, so no extra API key is required.

[GitHub Models]: https://docs.github.com/en/github-models

### What it does

1. Downloads the `validatorResults` artifact produced by the connector
   pipeline (`validateResults.json` + `compareResults.json`).
2. Compresses the JSON (top issues only, useful fields only) into a prompt.
3. Asks a model to produce a short Markdown review grouped by severity,
   with file:line and concrete fixes, and a dedicated **Breaking changes**
   section for compare-validator findings.
4. Posts the review as a PR comment and writes it to the job step summary.

### Guarantees

- **Advisory only.** The job has `continue-on-error: true` and runs *after*
  the existing quality gate. It can never block a merge.
- **Opt-in per repo.** Disabled by default; nothing changes for existing
  callers.
- **Least privilege.** The AI job declares its own minimal `permissions:`
  (`contents: read`, `pull-requests: write`, `models: read`,
  `actions: read`) instead of inheriting the workflow-level `write-all`.
- **PR-scoped.** Only runs on `pull_request` events.

### How to opt in

In your repo's wrapper workflow, set `enable_ai_review: true` when calling
the connector master workflow:

```yaml
jobs:
  CI:
    uses: SkylineCommunications/_ReusableWorkflows/.github/workflows/Connector Master Workflow.yml@main
    with:
      sonarCloudProjectName: my-sonar-project
      enable_ai_review: true            # turn on the AI review
      # ai_review_model: openai/gpt-4o-mini   # optional override
    secrets: inherit
```

### Inputs

| Input              | Type    | Default               | Description                                  |
| ------------------ | ------- | --------------------- | -------------------------------------------- |
| `enable_ai_review` | boolean | `false`               | Enable the advisory AI review job.           |
| `ai_review_model`  | string  | `openai/gpt-4o-mini`  | GitHub Models model id used for the review.  |

### Scope

The AI Review is currently only wired into the **Connector** master
workflow, because the connector pipeline is the only one that produces
validator output. Other masters (Automation, NuGet, SRM Function, App
Packages) do not have an equivalent validator, so the AI review is not
applicable there. Future AI-assisted workflows for those pipelines (e.g.
test-failure triage, release-notes generation) will be added as separate
reusable workflows when needed.

---

## SDK Migration (agentic) — automatic on legacy repos

`SDK Migration Workflow.yml` is an **agentic** reusable workflow that
helps move older connector repos off the legacy csproj format and onto
the SDK-style csproj that the modern `Connector Master SDK Workflow.yml`
pipeline expects.

It is **wired into `Connector Master Workflow.yml`** and triggers
automatically when the legacy path is taken — no per-repo opt-in needed.
This way, developers working on an old repo organically discover a
migration PR the next time CI runs on the default branch.

### What it does

1. The connector master workflow's `check_solution_type` job runs
   `SDKChecker`. If `isSdk=false`, the `CI_Legacy` job runs as before.
2. In parallel, `Request_SDK_Migration` calls this workflow with
   `assume_legacy: true`.
3. The workflow checks for an existing open issue/PR with the
   `sdk-migration` label, or an open PR from `chore/sdk-migration`. If
   one exists, it skips.
4. Otherwise it opens a GitHub Issue with a detailed migration brief and
   **assigns it to the GitHub Copilot coding agent**.
5. Copilot iterates on the conversion, runs `dotnet build` and
   `dataminer-validator` in its own sandbox, and opens a PR titled
   `chore: migrate to SDK-style csproj`.
6. That PR runs through the normal `Connector Master Workflow.yml` —
   which now takes the **SDK** path — so the same quality gate that
   protects human PRs also protects this agent-generated PR.

### Trigger gating

The migration request only fires when **all** of the following are true:

- The solution is legacy-style (`isSdk == 'false'`).
- The event is a `push` (not a `pull_request` or tag).
- The push is to the **default branch** of the repo.

This avoids creating duplicate issues from PR runs or feature-branch
pushes. The reusable workflow is also idempotent as a second line of
defense.

### Guarantees

- **No direct writes to `main`.** The agent always opens a PR.
- **Idempotent.** Skips if an open issue or PR with the `sdk-migration`
  label, or a PR from `chore/sdk-migration`, already exists.
- **Quality-gated.** The agent's PR goes through the same SDK pipeline
  that protects human PRs.
- **Least privilege.** Job-scoped `permissions:` (`contents: read`,
  `issues: write`, `pull-requests: read`).
- **Falls back gracefully.** If the Copilot coding agent assignment
  fails (e.g. no user token, agent not enabled on the repo), the issue
  is still created (unassigned) so the work is tracked.

### Required setup — Copilot assignment token

GitHub does **not** allow assigning the Copilot coding agent with the
default `GITHUB_TOKEN`, because it is a GitHub App installation token
and the `replaceActorsForAssignable` mutation is restricted to
user-owned tokens. Without a user token, the issue is still created but
remains unassigned (you'll see a warning in the workflow log).

To make assignment work fleet-wide, create one **organization-level
secret** that the reusable workflow can read via `secrets: inherit`:

| Secret name              | Type                                                                              |
| ------------------------ | --------------------------------------------------------------------------------- |
| `COPILOT_ASSIGN_TOKEN`   | Fine-grained PAT (or OAuth token) with **Issues: Read and write** on target repos |

Steps:

1. Create a fine-grained PAT owned by a service user (not a personal
   account) with **Issues: Read and write** for the connector repos.
2. Add it as an organization secret named `COPILOT_ASSIGN_TOKEN` and
   make it available to the connector repositories.
3. Ensure the leaf wrapper workflow in each connector repo uses
   `secrets: inherit` when calling `Connector Master Workflow.yml`
   (this is already the standard pattern).

If the secret is missing, the workflow degrades gracefully — issues are
still opened and labeled, just without the Copilot assignee.

### Standalone use (optional)

The workflow can also be called directly (e.g. on a schedule across the
fleet) if you want a one-shot sweep instead of waiting for each repo's
next push to its default branch:

```yaml
jobs:
  Migration:
    uses: SkylineCommunications/_ReusableWorkflows/.github/workflows/SDK Migration Workflow.yml@main
    with:
      dry_run: true   # recommended for the initial pilot
```

When called standalone, omit `assume_legacy` and the workflow will run
`SDKChecker` itself.

### Inputs

| Input           | Type    | Default              | Description                                                                |
| --------------- | ------- | -------------------- | -------------------------------------------------------------------------- |
| `assume_legacy` | boolean | `false`              | Caller asserts the solution is legacy-style; skips the SDKChecker run.     |
| `assignee`      | string  | `copilot-swe-agent`  | Login of the Copilot coding agent (override only if needed).               |
| `dry_run`       | boolean | `false`              | Log the planned issue without creating it.                                 |
| `debug`         | boolean | `false`              | Verbose logging.                                                           |

---

## Cost & rate limits

The SDK Migration workflow consumes Copilot coding agent capacity. At
2000+ repos:

- Trigger gating (push to default branch only, idempotency check) keeps
  volume bounded.
- Review Copilot agent throughput before assuming fleet-wide rollout is
  smooth.
