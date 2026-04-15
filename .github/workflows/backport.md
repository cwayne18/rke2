---
on:
  slash_command:
    name: backport
    events: [pull_request, pull_request_review_comment, issue_comment]
permissions:
  contents: read
  pull-requests: read
  issues: read
checkout:
  fetch-depth: 0
tools:
  github:
    toolsets: [default]
  bash: true
safe-outputs:
  create-pull-request:
    title-prefix: "[backport] "
    labels: [backport]
    draft: false
    max: 4
    preserve-branch-name: true
  create-issue:
    title-prefix: "[backport] "
    labels: [backport]
    max: 4
  add-comment:
    max: 1
    hide-older-comments: true
---

# Backport PR Creator

A user has triggered the `/backport` slash command on pull request #${{ github.event.issue.number || github.event.pull_request.number }} in the repository `${{ github.repository }}`.

The full comment/text that triggered this workflow is:
"${{ steps.sanitized.outputs.text }}"

## Your Task

Create backport pull requests for the following target branches, in this order:
1. `release-1.35`
2. `release-1.34`
3. `release-1.33`
4. `release-1.32`

### Steps

1. **Identify the PR being backported**: The triggering PR is #${{ github.event.issue.number || github.event.pull_request.number }}. Use GitHub tools to get the PR details — specifically:
   - The merge commit SHA (or the list of commits if the PR has not been merged yet)
   - The PR title and description
   - Whether the PR is already merged

2. **Get the commits to cherry-pick**:
   - If the PR is **merged**, use the merge commit SHA. Run `git log --merges --oneline | head -5` to confirm. For a merge commit, use `git cherry-pick -m 1 <merge-sha>` so only the changes from the feature branch are applied.
   - If the PR is **not merged yet**, warn the user and create backport branches using the individual commit SHAs from the PR's commits. For each commit in the PR, cherry-pick it to the target branch.

3. **For each target branch** (`release-1.35`, `release-1.34`, `release-1.33`, `release-1.32`):
   a. Check if the target branch exists: `git ls-remote --heads origin <branch>`. If the branch does not exist, skip it and note it in the final comment.
   b. Record the current HEAD SHA of the target branch **before** creating the backport branch: `BASE_COMMIT=$(git rev-parse origin/<target-branch>)`. This will be used both as `base_commit` in the `create-pull-request` call and as the base for generating the minimal patch.
   c. Create a new git worktree for the target branch (do **not** `git checkout` in the main workspace, as that would make the patch contain all branch divergence):
      ```
      WORKTREE=/tmp/backport-<pr-number>-to-<target-branch>
      git worktree add "$WORKTREE" -b backport/<pr-number>-to-<target-branch> origin/<target-branch>
      ```
   d. Cherry-pick the relevant commit(s) inside the worktree. If the cherry-pick exits with a non-zero status (conflicts detected):
      - Run `scripts/resolve-backport-conflicts` from the **main workspace**, pointing it at the worktree:
        `$GITHUB_WORKSPACE/scripts/resolve-backport-conflicts <commit-sha> "$WORKTREE"`
      - If the script succeeds, stage the resolved file and continue the cherry-pick:
        `(cd "$WORKTREE" && git add scripts/build-images && git cherry-pick --continue --no-edit)`
      - If the script fails (conflicts in other files or auto-resolution failed), abort:
        `(cd "$WORKTREE" && git cherry-pick --abort)`; note the conflict in the summary and move on to the next branch.
   e. If the cherry-pick succeeded, generate a **minimal** patch containing only the cherry-picked changes:
      ```
      (cd "$WORKTREE" && git diff "$BASE_COMMIT" HEAD) > /tmp/gh-aw/aw-backport-<pr-number>-to-<target-branch>.patch
      ```
      Then clean up the worktree: `git worktree remove "$WORKTREE" --force`
      
      Use safe-outputs `create-pull-request` with:
      - `branch`: `backport/<pr-number>-to-<target-branch>`
      - `base`: `<target-branch>`
      - `base_commit`: the SHA captured in step 3b (`$BASE_COMMIT`) — **this is required** to limit the patch to only the cherry-picked changes
      - `title`: `[backport] <original PR title> to <target-branch>`
      - `body`: A description referencing the original PR, including "Backport of #<pr-number> to `<target-branch>`."
   f. After creating the PR, also open a tracking GitHub issue using safe-outputs `create-issue` with:
      - `title`: `[backport] <original PR title> to <target-branch>`
      - `body`: A description noting that a backport PR was opened, referencing the original PR number and the backport PR (if available). Include "Backport of #<pr-number> targeting `<target-branch>`."

4. **Post a summary comment** on the original PR using `add-comment` listing:
   - Which branches received a backport PR and tracking issue (with links if available)
   - Which branches were skipped because they don't exist
   - Which branches had cherry-pick conflicts (with advice to resolve manually)

### Important Notes

- Configure your git identity before committing: `git config user.email "github-actions[bot]@users.noreply.github.com"` and `git config user.name "github-actions[bot]"`
- Use `git fetch origin` before starting to ensure all remote branches are up to date
- Only create PRs for branches where the cherry-pick succeeded without conflicts
- If the PR has not been merged, inform the user via comment that backports are best done after merging, but proceed anyway using the individual commit SHAs from the PR
