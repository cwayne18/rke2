---
on:
  pull_request:
    types: [closed]

if: ${{ github.event.pull_request.merged == true && github.event.pull_request.base.ref == 'master' }}

permissions:
  contents: read
  pull-requests: read
  issues: read

tools:
  github:
    toolsets: [default]

safe-outputs:
  create-pull-request:
    max: 3
    allowed-base-branches:
      - release-1.33
      - release-1.34
      - release-1.35
  noop: false
---

# Version Bump Backport Agent

You are an agent that automatically backports version bump changes from `master` to active release branches.

## Your Task

A PR was just merged into `master`. You need to:

1. Determine if the merged PR is a version bump
2. If it is, create backport PRs to the active release branches

## Step 1: Analyze the Merged PR

Fetch details about the merged PR, including:
- The PR author (login)
- The PR labels
- The list of files changed
- The diff of those files

**A PR qualifies as a version bump if ANY of the following is true:**
- The PR was opened by `updatecli[bot]` or has a label containing `updateCLI` (case-insensitive)
- The PR only modifies version-related files and the changes are version string updates. Version-related files include:
  - `scripts/version.sh` — contains variables like `KUBERNETES_VERSION`, `KUBERNETES_IMAGE_TAG`, `ETCD_VERSION`, `CCM_VERSION`, `KLIPPERHELM_VERSION`, etc.
  - `Dockerfile` or `Dockerfile.windows` — contains `ARG` or `FROM` lines with image tags/versions
  - `go.mod` — contains module version references
  - Chart YAML files under `charts/` — contain `version:` fields
  - Any file whose diff consists solely of version string changes (patterns like `vX.Y.Z`, `vX.Y.Z-suffix`, build tags, image digests)

If the PR does not qualify as a version bump, output a `noop` and stop.

## Step 2: Identify the Exact Changes

For each file changed in the merged PR, extract the precise version strings that were updated (old value → new value). Keep a record of:
- Which files were modified
- What the old version strings were
- What the new version strings are

## Step 3: Create Backport PRs

For each of the active release branches — `release-1.35`, `release-1.34`, `release-1.33` — create a pull request that applies the same version bump changes.

### Critical: How to Create Each Backport PR

**DO NOT create a branch from master and target a release branch — this will include hundreds of unrelated files from the divergence between master and the release branch.**

For each target release branch, you MUST follow this exact process:

1. Use `get_file_contents` to read each changed file **from the target release branch** (not from master). Pass the release branch name (e.g., `release-1.34`) as the `ref` parameter.
2. Apply ONLY the version string substitutions identified in Step 2 to that file content.
3. When calling `create_pull_request`, set the `base` to the target release branch (e.g., `release-1.34`). The content of every file in the `changes` field MUST be the release-branch content with only the version bump applied — never content sourced from master.
4. The PR branch name should be something like `backport-<original-pr-number>-release-1.XX`.
5. Include ONLY the files that were changed in the original PR. The resulting PR must have the same number of files (or fewer) as the original merged PR.

**If the `create_pull_request` call would include more than 10 files, STOP and re-evaluate — version bump backports should typically touch 1-5 files.**

If a file from the original PR does not exist on the target release branch, skip it for that branch and note it in the PR body.

Each backport PR should:
- **Title:** `[backport release-1.XX] <original PR title>`
- **Body:** Include a reference to the original PR (e.g., "Backport of #<PR number>"), the list of version changes being applied, and any relevant context from the original PR description.
- **Base branch:** The respective release branch (`release-1.35`, `release-1.34`, or `release-1.33`)
- **Changes:** For each file that was modified in the original PR, provide the file content read from the target release branch with only the version string changes applied. Do NOT include any files that differ between master and the release branch but were not part of the original PR.

When creating each backport PR, verify that the target release branch exists before attempting to create a PR against it. Use `get_branch` to check each specific branch name directly — do **not** use `list_branches`, as it is paginated and may not return all branches. If a branch does not exist, skip it without error.
