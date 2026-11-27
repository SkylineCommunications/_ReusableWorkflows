const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "../../..");
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

function scriptFrom(file, marker) {
  const text = fs.readFileSync(path.join(root, file), "utf8").replace(/\r\n/g, "\n");
  const start = text.indexOf(marker);
  assert.notEqual(start, -1);
  const lines = text.slice(start + marker.length).split(/\r?\n/);
  const result = [];
  for (const line of lines) {
    if (line && !line.startsWith("            ")) break;
    result.push(line.slice(12));
  }
  return result.join("\n");
}

const selectScript = scriptFrom(
  ".github/workflows/okf-source-sync.md",
  "          script: |\n",
);
const reviewScript = scriptFrom(
  ".github/workflows/OKF Source Sync Review Workflow.yml",
  "          script: |\n",
);
const owner = "example";
const repo = "docs";
const sha = "a".repeat(40);

function sourcePr(overrides = {}) {
  return {
    number: 10,
    merged_at: "2026-01-01",
    merge_commit_sha: sha,
    changed_files: 1,
    base: { ref: "main", repo: { full_name: `${owner}/${repo}` } },
    head: { ref: "source" },
    user: { login: "author" },
    ...overrides,
  };
}

function syncPr(number, source = 10, overrides = {}) {
  return {
    number,
    state: "open",
    base: { ref: "main" },
    head: { ref: `automation/okf-source-sync-pr-${source}`, repo: { full_name: `${owner}/${repo}` } },
    body: `Source-sync for merged PR #${source}\n<!-- gh-aw-workflow-id: okf-source-sync -->`,
    user: { login: "github-actions[bot]" },
    ...overrides,
  };
}

async function select({ mode = "per-pr", source = sourcePr(), prs = [], files } = {}) {
  const outputs = {};
  const fileList = files ?? [{ filename: "docs/source.md", status: "modified" }];
  const github = {
    rest: { pulls: { get: async () => ({ data: source }), listFiles: {}, list: {} } },
    paginate: async method => method === github.rest.pulls.listFiles ? fileList : prs,
  };
  await new AsyncFunction("github", "context", "core", "process", selectScript)(
    github,
    { repo: { owner, repo } },
    { setOutput: (key, value) => { outputs[key] = value; } },
    { env: { SOURCE_PR: "10", PR_MODE: mode } },
  );
  return outputs;
}

test("per-pr mode selects only the matching source PR and preserves rename paths", async () => {
  const outputs = await select({
    prs: [syncPr(20, 11), syncPr(21, 10)],
    files: [{ filename: "docs/new.md", previous_filename: "docs/old.md", status: "renamed" }],
  });
  assert.equal(outputs.target, 21);
  assert.equal(outputs["target-ref"], "automation/okf-source-sync-pr-10");
  assert.equal(outputs["changed-files"], "docs/new.md\ndocs/old.md");
  assert.equal(outputs["merge-sha"], sha);
});

test("single mode reuses an existing managed PR; no match creates a new one", async () => {
  assert.equal((await select({ mode: "single", prs: [syncPr(20, 11)] })).target, 20);
  const generated = syncPr(22, 11, {
    head: { ref: "automation/okf-source-sync-pr/generated", repo: { full_name: `${owner}/${repo}` } },
  });
  assert.equal((await select({ mode: "single", prs: [generated] })).target, 22);
  assert.equal((await select({ mode: "per-pr", prs: [syncPr(20, 11)] })).target, "");
});

test("selection fails closed on ambiguous or unmarked managed PRs", async () => {
  await assert.rejects(select({ mode: "single", prs: [syncPr(20), syncPr(21)] }), /Multiple matching/);
  await assert.rejects(select({ mode: "single", prs: [syncPr(20, 10, { body: "edited" })] }), /missing workflow marker/);
  await assert.rejects(select({ mode: "single", prs: [syncPr(20, 10, { user: { login: "someone" } })] }), /unexpected author/);
});

test("selection ignores fork PRs and rejects incomplete or malformed source evidence", async () => {
  const fork = syncPr(20, 10, {
    head: { ref: "automation/okf-source-sync-pr-10", repo: { full_name: "fork/docs" } },
  });
  assert.equal((await select({ mode: "single", prs: [fork] })).target, "");
  await assert.rejects(select({ source: sourcePr({ changed_files: 2 }) }), /complete source PR file list/);
  await assert.rejects(select({ files: [{ filename: "bad\npath", status: "modified" }] }), /represented safely/);
  await assert.rejects(select({ source: sourcePr({ merged_at: null }) }), /must be merged/);
});

test("merges of generated PRs are skipped", async () => {
  const source = sourcePr({
    user: { login: "github-actions[bot]" },
    head: { ref: "automation/okf-source-sync-pr-10" },
  });
  assert.equal((await select({ source })).skip, "true");
});

async function review({ generated = syncPr(20), source = sourcePr(), requested = [], direct = true, prefix = "automation/okf-source-sync-pr-" } = {}) {
  const calls = [];
  const github = {
    rest: {
      pulls: {
        get: async ({ pull_number }) => ({ data: pull_number === 20 ? generated : source }),
        list: {},
        listRequestedReviewers: async () => ({ data: { users: requested } }),
        requestReviewers: async request => { calls.push(request); },
      },
      repos: { getCollaboratorPermissionLevel: async () => ({ data: { permission: "write" } }) },
    },
    paginate: async () => [generated],
  };
  const replacements = {
    "${{ toJSON(inputs.workflow-id) }}": JSON.stringify("okf-source-sync"),
    "${{ toJSON(inputs.generated-branch-prefix) }}": JSON.stringify(prefix),
    "${{ toJSON(inputs.base-branch) }}": JSON.stringify("main"),
    "${{ toJSON(inputs.source-pr-pattern) }}": JSON.stringify("Source-sync for merged PR #(\\d+)"),
    "${{ inputs.generated-pr-number }}": direct ? "20" : "0",
    "${{ inputs.source-pr-number }}": direct ? "10" : "0",
  };
  let script = reviewScript;
  for (const [expression, value] of Object.entries(replacements)) script = script.replace(expression, value);
  await new AsyncFunction("github", "context", "core", script)(
    github,
    { repo: { owner, repo }, payload: { workflow_run: { id: 42, conclusion: "success" } } },
    { info() {}, warning() {} },
  );
  return calls;
}

test("direct review targets the current source author and is idempotent", async () => {
  const calls = await review();
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].reviewers, ["author"]);
  assert.equal((await review({ requested: [{ login: "author" }] })).length, 0);
  const generated = syncPr(20, 10, {
    head: { ref: "automation/okf-source-sync-pr/generated", repo: { full_name: `${owner}/${repo}` } },
  });
  assert.equal((await review({ generated, prefix: "automation/okf-source-sync-pr" })).length, 1);
});

test("direct review rejects untrusted PRs; workflow-run matching remains supported", async () => {
  await assert.rejects(review({ generated: syncPr(20, 10, { user: { login: "someone" } }) }), /not a trusted/);
  const legacy = syncPr(20, 10, { body: "Source-sync for merged PR #10\nid: 42, workflow_id: okf-source-sync" });
  assert.equal((await review({ generated: legacy, direct: false })).length, 1);
});
