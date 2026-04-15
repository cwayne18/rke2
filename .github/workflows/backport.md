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
  add-comment:
    max: 1
    hide-older-comments: true
---

# Backport PR Creator

A user has triggered the `/backport` slash command on pull request #${{ github.event.issue.number || github.event.pull_request.number }}${{ github.event.pull_request.number }} in the repository `${{ github.repository }}`.

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
   b. Create a new branch from the target branch: `git checkout -b backport/<pr-number>-to-<target-branch> origin/<target-branch>`
   c. Cherry-pick the relevant commit(s) onto the new branch. If there are conflicts, abort the cherry-pick (`git cherry-pick --abort`), note the conflict in the summary, and move on to the next branch.
   d. If the cherry-pick succeeds (no conflicts), push the branch to the remote using safe-outputs `create-pull-request` with:
      - `branch`: `backport/<pr-number>-to-<target-branch>`
      - `base`: `<target-branch>`
      - `title`: `[backport] <original PR title> to <target-branch>`
      - `body`: A description referencing the original PR, including "Backport of #<pr-number> to `<target-branch>`."

4. **Post a summary comment** on the original PR using `add-comment` listing:
   - Which branches received a backport PR (with PR links if available)
   - Which branches were skipped because they don't exist
   - Which branches had cherry-pick conflicts (with advice to resolve manually)

### Important Notes

- Configure your git identity before committing: `git config user.email "github-actions[bot]@users.noreply.github.com"` and `git config user.name "github-actions[bot]"`
- Use `git fetch origin` before starting to ensure all remote branches are up to date
- Only create PRs for branches where the cherry-pick succeeded without conflicts
- If the PR has not been merged, inform the user via comment that backports are best done after merging, but proceed anyway using the individual commit SHAs from the PR
