---
name: OKF source sync
description: Update OKF content affected by a merged pull request.
on:
  workflow_call:
    inputs:
      source-pr:
        description: Number of the merged source pull request.
        required: true
        type: number
      pr-mode:
        description: Use per-pr for one update PR per source PR, or single to reuse one open update PR.
        required: false
        type: string
        default: per-pr
      preview:
        description: Preview changes without publishing them.
        required: false
        type: boolean
        default: true
permissions:
  contents: read
  pull-requests: read
  copilot-requests: write
concurrency:
  group: okf-source-sync-${{ github.repository }}
  queue: max
engine: copilot
inlined-imports: true
network: defaults
checkout:
  ref: main
  fetch-depth: 0
  fetch: ["*"]
tools:
  github:
    toolsets: [repos, pull_requests]
steps:
  - name: Verify source commit and report path
    shell: bash
    env:
      MERGE_SHA: ${{ needs.prepare.outputs.merge-sha }}
      REPORT_PATH: ${{ github.workspace }}/.okf-source-sync-report.json
    run: |
      test ! -e "$REPORT_PATH"
      git cat-file -e "$MERGE_SHA^{commit}"
      git merge-base --is-ancestor "$MERGE_SHA" HEAD
  - name: Detect OKF source drift
    uses: SkylineCommunications/_ReusableWorkflows/.github/actions/okf-source-sync@main
    with:
      changed-files: ${{ needs.prepare.outputs.changed-files }}
      report-path: ${{ github.workspace }}/.okf-source-sync-report.json
  - name: Verify source drift report
    shell: bash
    env:
      REPORT_PATH: ${{ github.workspace }}/.okf-source-sync-report.json
    run: |
      export EXPECTED_COMMIT="$(git rev-parse HEAD)"
      node <<'NODE'
      const fs = require("node:fs");
      const report = JSON.parse(fs.readFileSync(process.env.REPORT_PATH, "utf8").replace(/^\uFEFF/, ""));
      if (!report || typeof report !== "object" || Array.isArray(report) ||
          report.schema !== "skyline.okf-source-sync/0.1" ||
          !["no-change", "changes-detected"].includes(report.status) ||
          typeof report.dry_run !== "boolean" ||
          report.repository !== process.env.GITHUB_REPOSITORY ||
          typeof report.okf_root !== "string" || !report.okf_root ||
          report.candidate_commit !== process.env.EXPECTED_COMMIT ||
          report.scoped_detection !== true ||
          !Number.isSafeInteger(report.concepts_scanned) || report.concepts_scanned < 0 ||
          !Array.isArray(report.changed_paths) || report.changed_paths.length === 0 ||
          !report.changed_paths.every(path => typeof path === "string" && path.length > 0) ||
          !Array.isArray(report.declared_sources) ||
          !Array.isArray(report.affected_concepts) ||
          !Array.isArray(report.diagnostics) || report.diagnostics.length !== 0 ||
          !Array.isArray(report.limitations) ||
          !report.limitations.every(item => typeof item === "string")) {
        throw new Error("Source drift report is blocked or malformed.");
      }
      NODE
jobs:
  pre_activation:
    pre-steps:
      - name: Reject unsafe trigger
        uses: SkylineCommunications/_ReusableWorkflows/.github/actions/guard-trigger@main
  prepare:
    name: Validate source and select update PR
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read
    outputs:
      target: ${{ steps.select.outputs.target }}
      target-ref: ${{ steps.select.outputs.target-ref }}
      merge-sha: ${{ steps.select.outputs.merge-sha }}
      changed-files: ${{ steps.select.outputs.changed-files }}
      skip: ${{ steps.select.outputs.skip }}
    steps:
      - name: Reject unsafe trigger
        uses: SkylineCommunications/_ReusableWorkflows/.github/actions/guard-trigger@main
      - name: Select managed PR
        id: select
        uses: actions/github-script@v9.0.0
        env:
          SOURCE_PR: ${{ inputs.source-pr }}
          PR_MODE: ${{ inputs.pr-mode }}
        with:
          script: |
            const { owner, repo } = context.repo;
            const sourceNumber = Number(process.env.SOURCE_PR);
            const mode = process.env.PR_MODE;
            if (!Number.isSafeInteger(sourceNumber) || sourceNumber <= 0 ||
                !["per-pr", "single"].includes(mode)) {
              throw new Error("source-pr must be a positive integer and pr-mode must be per-pr or single.");
            }
            const source = (await github.rest.pulls.get({
              owner, repo, pull_number: sourceNumber,
            })).data;
            if (!source.merged_at || source.base.ref !== "main" ||
                source.base.repo?.full_name !== `${owner}/${repo}` ||
                !/^[0-9a-f]{40}$/i.test(source.merge_commit_sha || "")) {
              throw new Error("The source PR must be merged into main and have a verified merge commit.");
            }
            if (source.user?.login === "github-actions[bot]" &&
                source.head.ref.startsWith("automation/okf-source-sync-")) {
              core.setOutput("skip", "true");
              return;
            }
            const files = await github.paginate(github.rest.pulls.listFiles, {
              owner, repo, pull_number: sourceNumber, per_page: 100,
            });
            if (source.changed_files > 3000 || files.length !== source.changed_files) {
              throw new Error("The complete source PR file list could not be verified.");
            }
            const paths = new Set();
            for (const file of files) {
              if (!file.filename || /[\r\n]/.test(file.filename) ||
                  (file.status === "renamed" && (!file.previous_filename || /[\r\n]/.test(file.previous_filename)))) {
                throw new Error("A source PR file path is missing or cannot be represented safely.");
              }
              paths.add(file.filename);
              if (file.status === "renamed") paths.add(file.previous_filename);
            }
            if (paths.size === 0) {
              core.setOutput("skip", "true");
              return;
            }
            const prs = await github.paginate(github.rest.pulls.list, {
              owner, repo, state: "open", base: "main", per_page: 100,
            });
            const candidates = prs.filter(pr =>
              pr.head.repo?.full_name === `${owner}/${repo}` &&
              (pr.head.ref.startsWith("automation/okf-source-sync-pr-") ||
               pr.head.ref.startsWith("automation/okf-source-sync-pr/"))
            );
            if (candidates.some(pr => pr.user?.login !== "github-actions[bot]" ||
                !pr.body?.includes("<!-- gh-aw-workflow-id: okf-source-sync -->"))) {
              throw new Error("An OKF sync branch has an unexpected author or missing workflow marker; resolve it before continuing.");
            }
            const matches = mode === "single" ? candidates : candidates.filter(pr =>
              new RegExp(`Source-sync for merged PR #${sourceNumber}(?!\\d)`).test(pr.body)
            );
            if (matches.length > 1) {
              throw new Error("Multiple matching OKF sync PRs exist; resolve the ambiguity before continuing.");
            }
            core.setOutput("target", matches[0]?.number || "");
            core.setOutput("target-ref", matches[0]?.head.ref || "");
            core.setOutput("merge-sha", source.merge_commit_sha);
            core.setOutput("changed-files", [...paths].join("\n"));
            core.setOutput("skip", "false");
  agent:
    needs: [prepare]
    if: needs.prepare.outputs.skip != 'true'
  safe_outputs:
    needs: [prepare]
    if: needs.agent.result == 'success'
  request_review:
    needs: [prepare, safe_outputs]
    if: >-
      !inputs.preview &&
      (needs.safe_outputs.outputs.created_pr_number != '' || needs.safe_outputs.outputs.push_commit_sha != '')
    permissions:
      contents: read
      pull-requests: write
    uses: ./.github/workflows/OKF%20Source%20Sync%20Review%20Workflow.yml
    with:
      generated-pr-number: ${{ fromJSON(needs.safe_outputs.outputs.created_pr_number || needs.prepare.outputs.target || '0') }}
      source-pr-number: ${{ inputs.source-pr }}
      generated-branch-prefix: automation/okf-source-sync-pr
safe-outputs:
  staged: ${{ inputs.preview }}
  report-failure-as-issue: false
  report-missing-tool: false
  report-missing-data: false
  report-incomplete:
    create-issue: false
  create-pull-request:
    max: 1
    draft: true
    staged: ${{ inputs.preview || needs.prepare.outputs.target != '' }}
    base-branch: main
    branch-prefix: automation/okf-source-sync-pr/
    body-footer: "Source-sync for merged PR #${{ inputs.source-pr }}"
    allowed-files: [OKF/**]
    protected-files: blocked
    fallback-as-issue: false
    if-no-changes: ignore
  push-to-pull-request-branch:
    target: ${{ needs.prepare.outputs.target }}
    max: 1
    staged: ${{ inputs.preview || needs.prepare.outputs.target == '' }}
    allowed-files: [OKF/**]
    protected-files: blocked
    fallback-as-pull-request: false
    if-no-changes: ignore
---

# OKF source sync

Process merged PR #${{ inputs.source-pr }} in `${{ github.repository }}`. Its
verified merge commit is `${{ needs.prepare.outputs.merge-sha }}`. The
preparation job verified the complete changed-file list, including both names
of renamed files. Use those files as the only source scope. Record the
checked-out `main` commit before switching branches and use that revision for
source content and provenance, so an older queued run cannot undo newer source
changes.

The shared detection action has run before the agent. Treat its report at
`${{ github.workspace }}/.okf-source-sync-report.json` as scoping evidence, not
permission to invent changes or proof of semantic completeness. If the
report is blocked or cannot be read, use `report_incomplete` and do not publish.
Remove the report from the workspace before committing; never include it in
the update PR.

The selected existing update PR is `${{ needs.prepare.outputs.target }}` and
its branch is `${{ needs.prepare.outputs.target-ref }}`. When a branch is
selected, check it out in the agent workspace before assessing or editing the
bundle. Preserve its commits and human changes. Do not rebase or force-push.
If `main` has changed an affected OKF file since the update branch diverged,
use `report_incomplete` rather than overwriting or dropping those changes.
Inspect both existing and newly added or renamed sources. Do not repair
unrelated drift.

Edit only `OKF/**`, preserving identifiers, provenance, authority boundaries
and review status. Keep new or unreviewed content in draft. Update indexes
and logs only when the bundle conventions require it. If no source-backed
change remains, use `noop`. If coverage cannot be established, use
`report_incomplete` rather than publishing.

For meaningful changes, include `Source-sync for merged PR #${{ inputs.source-pr }}`
and the merge SHA, changed sources and affected concepts in the commit
message. If an existing PR was selected, commit on its branch and call
`push_to_pull_request_branch` once. Otherwise call `create_pull_request` once,
and include the same details in the PR body. Never use a different PR or
create a fallback PR.

When `${{ inputs.preview }}` is true, report the proposed files and use the
staged safe output for a preview. Local commits are allowed for that preview,
but do not publish a branch, PR, issue, comment, assignment or review request.
