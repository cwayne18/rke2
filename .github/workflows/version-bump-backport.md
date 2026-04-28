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

> **CRITICAL — avoid large diffs:**
> The release branches may have diverged significantly from `master`. You **MUST NOT** create a branch from `master` and target the release branch, as this will produce a PR containing hundreds of unrelated files and will be rejected with an error (`E003: Cannot create pull request with more than 100 files`).
> Instead, follow the steps below precisely.

For each release branch, follow this exact procedure:

1. **Verify the branch exists.** Use `get_branch` to check each specific branch name directly — do **not** use `list_branches`, as it is paginated and may not return all branches. If a branch does not exist, skip it without error.

2. **Create a new working branch FROM the release branch.** The new branch must be based on the tip of the release branch (e.g., `backport/release-1.35/<original-pr-number>`), **not** on `master` or any other branch.

3. **Read the current content of only the files that were changed in the original PR** from the release branch (not from master). For each such file, apply only the specific version string changes identified in Step 2 (old value → new value). Do **not** modify any other files.

4. **Commit only those changed files** to the working branch. The commit should contain the same number of files as the original PR — typically just a handful. If a version string from the original PR does not appear in a file on the release branch, skip that substitution for that file (the version may already differ on that branch).

5. **Open a PR** from the working branch into the release branch (not into `master`).

Each backport PR should:
- **Title:** `[backport release-1.XX] <original PR title>`
- **Body:** Include a reference to the original PR (e.g., "Backport of #<PR number>"), the list of version changes being applied, and any relevant context from the original PR description.
- **Base branch:** The respective release branch (`release-1.35`, `release-1.34`, or `release-1.33`)
- **Changed files:** Only the files that were modified in the original version bump PR — **never** a full branch diff. The backport PR must not contain more files than the original PR.
