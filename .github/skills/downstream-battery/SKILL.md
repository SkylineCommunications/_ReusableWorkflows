---
name: downstream-battery
description: 'Operate, extend, and debug the downstream integration-test battery for SkylineCommunications/_ReusableWorkflows. Use when running /test batteries, preparing cross-repository fixes with /prepare-downstream-fixes, adding downstream scenarios or repos, writing verify jobs, debugging BOOST-DailyRegression receiver runs, creating fixtures, or dispatching tests with correlation ids and tag SHAs.'
---

# Downstream battery operations

Operational knowledge for the `/test` integration-test battery that protects the reusable workflows. Architecture reference: [TESTING.md](../../../TESTING.md).

## When to Use This Skill

- Running or debugging a `/test` battery or a manual `repository_dispatch` test
- Preparing linked downstream issues and Copilot pull requests from a source PR
- Adding a scenario, verify job, or downstream repo
- Creating or mutating fixture solutions (NuGet, DataMiner package, connector)
- A downstream verify job fails and you need the diagnosis path

## Manual battery dispatch (without a PR)

```powershell
$tagSha = (git -C C:\GitHub\_ReusableWorkflows ls-remote origin refs/tags/test-downstream).Split("`t")[0]
gh api repos/SkylineCommunications/<repo>/dispatches `
  -f event_type='test-reusable-workflow' `
  -f "client_payload[pr_number]=0" `
  -f "client_payload[source_repo]=SkylineCommunications/_ReusableWorkflows" `
  -f "client_payload[head_sha]=<sha>" `
  -f "client_payload[tag_sha]=$tagSha" `
  -f "client_payload[correlation_id]=manual-<purpose>-<n>" --silent
```

To test unmerged workflow code first: commit on a branch, then `git tag -f test-downstream && git push -f origin test-downstream` (skip the composite-ref rewrite only when no composite actions changed). Verify no battery is in flight before moving the tag.

Single scenario: `gh workflow run <caller>.yml --repo <repo> --ref main -f correlation-id=manual-<purpose>`.

## Per-PR ref for manual testing

Comment `/prepare-test` on an internal `_ReusableWorkflows` PR to create or
update `test-pr-<number>`. For a fork PR, a write-access maintainer must review
the exact head and comment `/prepare-test <40-character-head-sha>`. The command
fails unless the supplied, API, and fetched PR-ref SHAs match. The generated
tag rewrites all cross-repository composite-action references to that same tag.
It does not dispatch the battery or interfere with `test-downstream`.

## Cross-repository fix preparation

Copilot code-review autofix and each coding-agent session can modify only one
repository. When a source PR requires battery-repository edits, produce an
exact maintainer command instead of implying that the source autofix can make
those edits:

```text
/prepare-downstream-fixes
- <observable downstream behavior to add or change>
- <specific caller output, artifact, job, or URL to assert>
- <required SDK, legacy, branch, or release scenarios>
```

The maintainer posts this on an `_ReusableWorkflows` PR. The default-branch
`Test Downstream.yml` maps changed workflows and actions through its hard
allowlist, creates or reuses a linked issue in every affected repository, and
assigns `copilot-swe-agent[bot]`. Fork-controlled PR titles are not forwarded
to Copilot. Each issue must instruct Copilot to open a PR, avoid direct default-
branch pushes and automatic merges, retain normal production refs, validate
the receiver scenario, and link the source PR.

Treat the command comment as human approval for task creation and Copilot
assignment. Never infer acceptance criteria silently, accept repository names
from comment input, execute PR content, or broaden the map. The dedicated
`DOWNSTREAM_ISSUES_TOKEN` must be a user-to-server token scoped only to mapped
repositories. Copilot assignment requires metadata read plus Actions, Contents,
Issues, and Pull requests read/write; GitHub App installation tokens are not
supported. Repeated commands reuse the source marker; closed tasks require
manual review rather than reopening.

## Diagnosis path for a red battery

1. Receiver run → failing job names the scenario (`c1-validator-critical / run-workflow`).
2. run-and-monitor log has the dispatched run's `run_url` and failed jobs/steps.
3. Runs of one battery share the correlation id in their `run-name`: `[<id>-BRANCH]` / `[<id>-RELEASE]`.
4. Extract failure summaries: `gh run view <id> --repo <repo> --log 2>&1 | Select-String -Pattern 'Validator Quality Gate failed:' -Context 0,6`.
5. Transient infra failure (Azure, runner)? Comment `/retest` on the PR: only the failed repos re-dispatch; previous successes carry over (state lives in a `<!-- state:test-downstream ... -->` line inside the sticky comment and is invalidated when the head SHA moves).

For fork PRs, `/test` and `/test-all` require the full reviewed head SHA. Treat
the command as approval to execute that exact workflow code in trusted battery
repositories with their configured OIDC, signing, Catalog, package, and test
credentials. `/retest` accepts no SHA and only reuses state for an unchanged,
previously approved head.

## Verify-job pattern (side-effect assertions)

- `needs: CI`, `if: always()`, first assert `needs.CI.result == 'success'` (skip/cancel = fail).
- Artifacts: `gh api --paginate "repos/$REPO/actions/runs/$RUN_ID/artifacts" --jq '.artifacts[].name'` + `grep -Fxq`; deep-inspect via `gh run download $RUN_ID -n <artifact>`.
- Job/step conclusions: `gh api .../runs/$RUN_ID/jobs`; nested reusable jobs are named `<caller job> / <nested job>` (e.g. `CI / CI`, `CI / CI_SDK / SDK Skyline Quality Gate`).
- Expected failures: no verify job — use run-and-monitor's `expected-conclusion: failure` + `expected-failed-job: <job-name substring>`.

## Gotchas (all hit in practice)

- **jq `contains()` is case-sensitive** — match job names with exact casing (`Migrate wrapper`, not `migrate`).
- **`issue_comment` workflows run `main`'s version** — orchestrator changes only take effect after merge; test them pre-merge via manual dispatch instead.
- **Copilot sessions are repository-scoped** — `/prepare-downstream-fixes` coordinates separate downstream issues and sessions; it cannot create one atomic multi-repo PR.
- **PRs created with `GITHUB_TOKEN` do not trigger `pull_request`/`pull_request_target` workflows** — synthetic-PR scenarios need a fine-grained PAT (`SYNTHETIC_PR_PAT`).
- **`github-to-catalog-yaml` infers the artifact type from repo topics** — connector-pipeline sandbox repos need e.g. the `connector` topic or the auto-catalog job fails.
- **Connector fixtures must be initial versions (`<Version>x.y.z.1</Version>`, e.g. `1.0.0.1`)** — any later version makes the validator's compare fetch the previous version from the Catalog, which crashes without catalog identity, and the gate fails on missing compare results.
- **Validate fixtures locally before pushing**: `dotnet build`; connectors additionally `dataminer-validator validate protocol-solution --solution-path <sln>` — the initial-version gate demands 0 critical/major/minor (a "good" fixture with 3 minors fails).
- **The connector pipeline auto-commits `.githubtocatalog/auto-generated-catalog.yml` to main** — chain connector scenarios in receivers (never parallel) and expect to `git pull --rebase` over `auto-generated` commits.
- **`dxm-projects-ubuntu` paths are repo-root-relative** and each project needs `packaging/Debian/content/DEBIAN/control` + `lib/systemd/system/<unit>.service` (copy the skeleton from the `package-debian` job in `Test composite actions.yml`).
- **Date-based release tags exceed MSI's ProductVersion major limit (255)** — WiX scenarios are BRANCH-only by design.
- **Two `DataMinerType=Package` projects in one solution**: each `PackageContent/ProjectReferences.xml` must `Exclude` the sibling or the SDK fails with "package project inside another package project".
- **Deployment order for dispatch-input changes**: downstream callers must merge new optional inputs before `BOOST-DailyRegression`'s run-and-monitor starts passing them (`gh workflow run` rejects unknown inputs).
- **In PowerShell, `python - @'...'@` does not pipe to stdin** — python opens a REPL; write a temp `.py` file instead.

## References

- [TESTING.md](../../../TESTING.md) — architecture, coverage table, adding-coverage checklists
- [reusable-workflows.instructions.md](../../instructions/reusable-workflows.instructions.md) — "Downstream battery coupling" lists every asserted artifact/job name
