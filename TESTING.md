# Downstream integration-test battery

How changes to the reusable workflows in this repository are integration-tested
against real consumer repositories before they reach the fleet.

## What a green battery means

> When the complete battery passes for a PR, existing consumers, supported
> inputs, the important execution contexts (branch, stable and prerelease
> tags, pull_request), failure behavior, and the critical side effects
> (packages, artifacts, catalog registrations) of the reusable workflows
> still work.

## Architecture

```mermaid
flowchart TD
    PR[PR in _ReusableWorkflows] -->|on: pull_request| Gate["Downstream Gate.yml<br/>posts commit status 'downstream-tests'<br/>pending (workflows/actions touched) or success (n/a)"]
    PR -->|maintainer comments /test| TD["Test Downstream.yml (runs from main)"]
      MAIN["manual workflow_dispatch on main"] -->|test-all, no source PR| TD
      PR -->|maintainer comments /prepare-test| MANUAL["Create/update per-PR tag<br/>test-pr-&lt;number&gt;<br/>with self-consistent action refs"]
    TD -->|1. map changed workflows AND composite actions| MAP[DOWNSTREAM_MAP]
      TD -->|2. force-push tag from PR head or main| TAG[(test-downstream tag)]
    TD -->|3. repository_dispatch<br/>pr_number, head_sha, tag_sha, correlation_id| RCV[pr-regression.yml receivers]
    RCV -->|verify-tag: ls-remote vs tag_sha| TAG
    RCV --> REG["BOOST-DailyRegression<br/>regression.yml (BRANCH + RELEASE)<br/>run-and-monitor.yml (single run)"]
    REG -->|gh workflow run -f correlation-id| CALLERS["scenario callers @test-downstream<br/>+ verify jobs"]
    TD -->|4. poll by correlation, ≤90 min| RCV
    TD -->|5. sticky PR comment + final commit status| PR
   TD -->|5. Actions summary for manual runs| SUMMARY[Actions run summary]
```

- **Gating**: `downstream-tests` is a commit status on the PR head SHA. Every
  push resets it (the gate re-runs), so a stale green can never carry over.
  Configured as a required check, a PR touching `.github/workflows/**` or
  `.github/actions/**` cannot merge without a passing `/test` battery.
- **Correlation**: the orchestrator's `correlation_id` flows into every
  dispatched run's `run-name`. Monitors locate runs by that id — never "the
  most recent run" — so concurrent activity cannot cross-attribute results.
- **Serialization**: `Test Downstream.yml` uses a queued concurrency group and
  holds it for the full battery, keeping the mutable `test-downstream` tag
  stable. Receivers additionally verify the tag SHA against the dispatch
  payload and fail closed if another battery overwrote it.
- **Fork PRs** remain blocked until a write-access maintainer reviews the exact
   head and comments `/test <40-character-head-sha>` or
   `/test-all <40-character-head-sha>`. The command fetches the server-side PR
   ref and fails unless the supplied, API, and fetched SHAs all match.

## Preparing a ref for manual testing

Comment `/prepare-test` on an internal PR to create or update a persistent
`test-pr-<number>` tag without starting the downstream battery. For a fork PR,
review the exact head and comment `/prepare-test <40-character-head-sha>`.
The command requires write access to the repository.

The tag points to a synthetic commit based on the current PR head. Every
cross-repository composite-action reference in the workflows and composite
actions is rewritten to the same `test-pr-<number>` tag, so manual tests use a
self-consistent version of the PR instead of loading actions from `main`.

Use the generated ref from a manual caller, for example:

```yaml
jobs:
   CI:
      uses: SkylineCommunications/_ReusableWorkflows/.github/workflows/Master Workflow.yml@test-pr-123
```

The workflow posts the exact ref and commit SHA on the PR. Run `/prepare-test`
again after an internal PR changes, or review the new fork head and run
`/prepare-test <new-head-sha>`; this force-updates that PR's tag. Each PR has
its own tag, so preparing a manual ref does not move or interfere with the
shared `test-downstream` tag used by the integration-test battery.

## Preparing downstream fix pull requests

When a reusable-workflow change requires edits to one or more battery repos,
a maintainer with write access can comment on the source PR:

```text
/prepare-downstream-fixes
- Consume the new workflow output from the caller job.
- Assert the expected names and URLs in the verify job.
- Cover both SDK multi-manifest and supported legacy behavior.
```

The first line must match exactly and the following acceptance criteria are
required. The command maps the PR's changed workflows and composite actions
through `DOWNSTREAM_MAP`, creates or reuses one linked `downstream-fix` issue
per affected repository, and assigns `copilot-swe-agent[bot]`. Each assignment
starts an independent Copilot session in that repository; the resulting pull
requests must be reviewed and merged separately.

The command is idempotent for a source PR. Re-running it reuses an existing
open task identified by its machine-readable source marker. It never reopens a
closed task, pushes to a downstream branch, merges a pull request, or executes
content from the source PR. The source PR title is not copied into Copilot's
task; only maintainer-authored acceptance criteria and allowlisted workflow
names are forwarded. Every run appends an audit summary to the source PR. A
partial failure leaves successfully created tasks intact and fails the run.

Configure `DOWNSTREAM_ISSUES_TOKEN` in `_ReusableWorkflows` before enabling the
command. Copilot issue assignment requires a user-to-server token. Use a
fine-grained user PAT scoped only to the repositories in `DOWNSTREAM_MAP`, with
metadata read and **Actions, Contents, Issues, and Pull requests: read and
write**. A GitHub App installation token is not supported for this operation.
Keep this credential separate from `DOWNSTREAM_PAT` and do not grant
administration access.

Copilot coding agent must be enabled and assignable in every target repository.
If assignment is unavailable, the downstream issue remains as an auditable
manual task and the orchestration run reports a failure. Because
`issue_comment` loads workflows from the default branch, this command becomes
available only after its orchestrator changes merge.

## Downstream repositories

| Repository | Exercises | Key assertions |
| --- | --- | --- |
| `BOOST-DailyRegression-Connector-SDK` | Connector Master (SDK route), BRANCH + RELEASE | `Connector Package` + `validatorResults` artifacts; on tags `SBOM` + catalog registration job |
| `BOOST-DailyRegression-Connector-Legacy` | Connector Master (Legacy route) — frozen (deprecating) | run conclusion only |
| `BOOST-DailyRegression-Automation-SDK` / `-Legacy` | Automation Master — frozen (deprecating) | run conclusion only |
| `BOOST-DailyRegression-InternalNuGet` | Internal NuGet wrapper → Master Workflow; Wrapper Migration (dry run) | `SignedNugetPackages` artifact; on tags `Push NuGet Packages` job; migration rewrite/idempotency matches repo state |
| `BOOST-DailyRegression-Skyline.DataMiner.Sdk` | App Packages wrapper → Master Workflow; Update Catalog Details | `SignedDataMinerPackages`; on tags `Upload to Catalog` job; `Catalog Details` artifact contains manifests |
| `BOOST-DailyRegression-SharedLibrary` | Master Workflow direct (modern inputs), ProjectReference build order, signing dedup | `SignedDataMinerPackages`; signing dedup summary present with duplicates > 0 (Azure 429 guard); on tags catalog upload |
| `BOOST-DailyRegression-MasterWorkflow` | Master Workflow feature matrix: NuGet path, multi-package + `override-catalog-identifiers`, `.slnf` filtering, `dxm-projects-ubuntu` (.deb), WiX branch and prerelease, mixed DataMiner/NuGet/WiX `.slnx`, recursive `global.json` SDK updates, `pull_request` event (synthetic PR), no-filter negative | deep assertions incl. nupkg names, manifest ids, `.deb`, mixed package artifacts, prerelease `dev`/`qa` publication with no `prod` or stable-only WiX SBOM steps, and zero/one/two `global.json` behavior |
| `BOOST-DailyRegression-NegativePaths` | Expected failures: broken build, invalid catalog mapping, validator criticals, missing validator results, `pull_request_target` rejection; plus the connector `solution-filter-name` positive control | run must fail **at the expected job** (`expected-failed-job` in run-and-monitor) |

Scenario callers in the two purpose-built repos are `workflow_dispatch`-only:
release flows dispatch *at* tag refs instead of using tag-push triggers, so tag
pushes fan out zero redundant runs.

`BOOST-DailyRegression-ExternalDependencies` is a separate daily/manual smoke
repository, not a mapped battery consumer. Its own `external-services.yml`
builds a small protocol, performs a volatile Catalog upload, and independently
deploys an already-published test item to a sandbox agent without running the
entire Master/Connector/Automation pipeline. See its README for the isolated
`external-smoke` environment, keys, variables, and activation steps. The
disabled Connector SDK schedule stays disabled; deprecated pipelines are not
new daily hosts.

## Running and interpreting the battery

1. Open a PR. The gate sets `downstream-tests` to *pending* if reusable
   workflows or composite actions are touched (composite-action-only changes
   are mapped to their consuming workflows automatically).
2. A user with write access comments `/test` (affected repos only) or
   `/test-all` (every mapped repo). For a fork, the maintainer must first review
   the exact head and append its full SHA to the command. This is privileged
   approval: the promoted workflow code runs in trusted battery repositories
   with their configured OIDC, signing, Catalog, package, and test credentials.
3. The orchestrator posts progress to a sticky PR comment (always reposted as
   the newest comment; processed command comments are collapsed as resolved)
   and finishes by setting the commit status. ❌ any receiver failed / no run
   found / timeout; ✅ all receivers green.
4. On transient failures (e.g. an Azure hiccup in one repo), comment `/retest`:
   only the repos that failed in the previous battery are re-dispatched, and
   the earlier successes carry over into the final result. `/retest` refuses to
   run when the PR head moved since the previous battery (results would no
   longer apply) or when no previous battery result exists on the PR.
5. Merging is possible only with the status green (when configured as a
   required check).

## Manual test-all on main (no PR)

In this repository, open **Actions → Test Downstream → Run workflow** and
select `main`. No inputs or PR are required. The workflow rejects other refs
and checks that the checkout still matches the current `main` head. It then
uses the same serialized `test-downstream` tag, all repos in `DOWNSTREAM_MAP`,
SHA-verified receivers, and exact correlation-based polling as `/test-all`.
The Actions run summary contains links and conclusions; no PR comment or
`downstream-tests` commit status is posted. A failed/no-run/timeout receiver
fails the manual run. Re-run manually after an infrastructure failure instead
of using `/retest`. This uses `DOWNSTREAM_PAT` and trusted downstream
credentials, and the mapped receiver still tests its *downstream* synthetic
pull-request case. It does not substitute for the required check on a source
PR. Do not start it while another battery is preparing or using the shared tag.

For a targeted runner check, open **Actions → Master Workflow Runner Trial**
in `BOOST-DailyRegression-MasterWorkflow` and run it from `main` with an
`ubuntu-latest` or `ubuntu-YY.MM` hosted label. It calls Master Workflow
`@main` against the mixed solution and asserts the three artifact families.
Only the reusable workflow's CI job accepts the requested `runs-on` value;
Windows packaging and other support jobs use their normal runners. This
trial is manual-only and does not run as part of `/test` or the daily smoke.

## Diagnosing a failure

1. Open the sticky comment → follow the failing repository's run link.
2. In the receiver run, the failing job names the scenario (e.g.
   `c1-validator-critical / run-workflow`).
3. run-and-monitor's log links the dispatched scenario run (`run_url`) and
   lists its failed jobs/steps. Expected-failure scenarios distinguish "did not
   fail" from "failed at the wrong job" in the error message.
4. Scenario run names embed the correlation id
   (`… [<orchestrator-run>-<attempt>-BRANCH]`), so runs belonging to one
   battery are greppable across repos.

## Adding coverage

**New scenario in an existing repo**
1. Add a `workflow_dispatch` caller pinned `@test-downstream` with the
   `correlation-id` input + `run-name` pattern (copy an existing one).
2. Assert side effects in a `verify` job (`needs: CI`, `if: always()`, treat
   skip/cancel as failure). For expected failures, no verify job — set
   `expected-conclusion: failure` and `expected-failed-job` in the receiver.
3. Wire it into `pr-regression.yml` (parallel, or chained if it mutates shared
   state such as the auto-committed catalog YAML or the same catalog item).

**New downstream repository** — justified only for a new *pipeline shape* that
existing repos cannot host (auto-detection conflicts, incompatible repo-level
conventions). Checklist:
1. Fixtures + receiver + callers (copy the structure of
   `BOOST-DailyRegression-MasterWorkflow`).
2. Secrets: `TEAMS_WEBHOOK`; `SYNTHETIC_PR_PAT` only if synthetic PRs are
   needed (fine-grained, that repo only, contents + pull-requests write —
   `GITHUB_TOKEN`-created PRs do not trigger `pull_request` workflows).
3. Repo topic (e.g. `connector`) when the pipeline runs
   `github-to-catalog-yaml`, which infers the artifact type from topics.
4. Add the repo to `DOWNSTREAM_MAP` in `Test Downstream.yml`, listing every
   workflow file (including transitive sub-pipelines) whose change should
   dispatch it.
5. Validate fixtures locally first (build; for connectors run
   `dataminer-validator validate protocol-solution` — the initial-version gate
   requires 0 critical/major/minor).

## Composite actions

`Test composite actions.yml` (in-repo, on push/PR touching
`.github/actions/**`) remains the first line of defense with per-action smoke
tests and idempotency assertions. The battery complements it: `/test` maps
changed actions to the workflows that consume them and dispatches those repos.

## Known limitations

- **Fork status initialization**: the `pull_request` token cannot post a commit
   status on a fork head. The required check remains expected until the trusted
   `/test <head-sha>` or `/test-all <head-sha>` run posts its pending status.
- **`/test` runs `main`'s orchestrator** (`issue_comment` semantics): fixes to
  `Test Downstream.yml` itself only take effect after merge.
- **WiX stable release and debian release flows**: not in the battery.
   Date-based release tags exceed MSI's ProductVersion major limit; a separate
   SemVer prerelease exercises WiX MSI publishing only to `dev` and `qa`.
   The `.deb` release path still publishes to shared infrastructure.
- **Missing-compare-results gate path (N8)**: no deterministic way to force it;
  uncovered.
- **Missing-secret behavior**: not testable in Skyline-managed repos — OIDC/Key
  Vault always supplies secrets.
- **Automation and Connector-Legacy pipelines**: frozen at run-conclusion
  coverage (both deprecating).
- **SonarCloud paths**: excluded (org is moving away from SonarCloud).
- **Playwright Docker ACR Workflow** and the public **NuGet Solution wrapper**:
  out of scope.

## Deployment-order constraint

When changing the dispatch inputs between `run-and-monitor.yml` and the
scenario callers: merge the callers (new optional inputs) **before**
`BOOST-DailyRegression` starts passing them, or `gh workflow run` fails on
unexpected inputs. Orchestrator changes here are safe in any order — receivers
tolerate missing payload fields (legacy dispatch path).
Publish the MasterWorkflow fixture callers and receiver before using a manual
`main` battery to claim prerelease/mixed coverage. The new daily repository
requires sandbox credentials, an existing test Catalog item, and a first
manual smoke run before its schedule can be treated as operational.
