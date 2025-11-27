# Branch Governance Policy

_Last updated: 2025-11-27_

The following rules keep `main` stable, provide dedicated staging areas, and separate contributions by trust level. All contributors **must** target the appropriate branch family and follow the associated workflow.

## Branch Families

| Branch Pattern | Purpose | Who Can Push | Notes |
|----------------|---------|--------------|-------|
| `main` | Production-ready code. | Nobody directly (PRs only). | Protected: requires PR + passing CI; no direct pushes or merges. |
| `features/new/*` | Net-new feature work. | Verified contributors + maintainers. | Used for greenfield features prior to review. |
| `features/existing/*` | Enhancements to existing features. | Verified contributors + maintainers. | Keep changes scoped to one area for review clarity. |
| `issues/bugfixes/*` | Bug fixes tracked via GitHub issues. | Verified contributors + maintainers. | Include issue ID in branch name where possible. |
| `contributors/verified/*` | Collaboration space for colleagues with `@intecbusiness.co.uk` emails. | Only members of the `intec-collaborators` team (see setup below). | Use when multiple verified contributors co-develop a feature. |
| `contributors/public/*` | Default target for community PRs (forks). | Maintainers only (public contributors create PRs against this branch). | Provides isolation until code is reviewed and promoted. |

## Contribution Flow

1. **Public (unverified) contributors**
   - Fork the repo.
   - Create topic branch in fork (any name) and open a PR targeting `contributors/public/<topic>`.
   - Maintainers triage, merge into public branch, then cherry-pick or PR into a feature/bugfix branch.

2. **Verified contributors (intec colleagues)**
   - Clone repo directly (no fork needed).
   - Create branches under `features/new`, `features/existing`, `issues/bugfixes`, or `contributors/verified` depending on scope.
   - Open PRs into `main` (or the relevant staging branch) once CI passes.

3. **Maintainers**
   - Guard `main` and `contributors/public` from direct pushes.
   - Enforce CI + review before merging.
   - Promote code from staging branches into `main` via PR.

## Pull Request Expectations

- All merges into `main` must:
  - be initiated from a PR,
  - pass required status checks (PowerShell CI),
  - receive at least one code review approval,
  - be performed by a maintainer.
- Squash merges are recommended to keep history clean.

## Teams & Permissions

Create a GitHub team (e.g., `intec-collaborators`) and add colleagues with `@intecbusiness.co.uk` emails. Grant that team push access to all branch families **except** `main` and `contributors/public`.

Public contributors remain outside the org and interact solely via PR targeting `contributors/public/*`.

---

# GitHub CLI Reference

Use the [GitHub CLI](https://cli.github.com/) (`gh`) to enforce branch rules. Replace `OWNER` and `REPO` with your organization/repository names.

## Protect `main`

```powershell
# Require PRs, status checks, and block direct pushes
$repo = "OWNER/REPO"
gh api \ 
  --method PUT \ 
  -H "Accept: application/vnd.github+json" \ 
  /repos/$repo/branches/main/protection \ 
  -f required_status_checks='{"strict":true,"contexts":["PowerShell CI"]}' \ 
  -f enforce_admins=true \ 
  -f required_pull_request_reviews='{"required_approving_review_count":1,"dismiss_stale_reviews":true}' \ 
  -f restrictions='null' \ 
  -f allow_force_pushes=false \ 
  -f allow_deletions=false
```

> Setting `enforce_admins=true` ensures even maintainers get a warning if they try to push directly to `main`.

## Add Pattern Rules

GitHub branch protection does not natively support wildcards via the API, but you can create rules using the ["create branch protection rule" mutation](https://docs.github.com/en/graphql/reference/mutations).

Example using GraphQL to restrict pushes to `contributors/public/*` (only maintainers can push):

```powershell
$repoId = gh api graphql -f query='query($owner:String!, $name:String!){repository(owner:$owner, name:$name){id}}' -f owner='OWNER' -f name='REPO' --jq '.data.repository.id'

gh api graphql \ 
  -f query='mutation($repositoryId:ID!, $pattern:String!){
    createBranchProtectionRule(input:{
      repositoryId:$repositoryId,
      pattern:$pattern,
      requiresApprovingReviews:false,
      isAdminEnforced:true,
      restrictsPushes:true,
      pushAllowances:[]
    }) { branchProtectionRule { id pattern } }
  }' \ 
  -f repositoryId=$repoId \ 
  -f pattern='contributors/public/*'
```

> With `pushAllowances` empty, nobody can push directly; all contributions must come via PRs. Maintainers can still merge PRs.

Repeat the mutation with different `pattern` values and `pushAllowances` as needed. To allow the `intec-collaborators` team to push to `features/new/*`, include their team ID:

```powershell
$teamId = gh api graphql -f query='query($org:String!, $slug:String!){organization(login:$org){team(slug:$slug){id}}}' -f org='OWNER' -f slug='intec-collaborators' --jq '.data.organization.team.id'

gh api graphql \ 
  -f query='mutation($repositoryId:ID!, $pattern:String!, $teamId:ID!){
    createBranchProtectionRule(input:{
      repositoryId:$repositoryId,
      pattern:$pattern,
      requiresApprovingReviews:false,
      isAdminEnforced:false,
      restrictsPushes:true,
      pushAllowances:[{teamId:$teamId}]
    }) { branchProtectionRule { id pattern } }
  }' \ 
  -f repositoryId=$repoId \ 
  -f pattern='features/new/*' \ 
  -f teamId=$teamId
```

Apply similar rules for:
- `features/existing/*`
- `issues/bugfixes/*`
- `contributors/verified/*`

Ensure `restrictsPushes` is `false` for branches where the wider contributor set should push, or provide the appropriate team/user IDs in `pushAllowances`.

### List Existing Rules

```powershell
gh api graphql -f query='query($owner:String!, $name:String!){repository(owner:$owner, name:$name){branchProtectionRules(first:50){nodes{pattern isAdminEnforced restrictsPushes matchingRefs(first:5){nodes{name}}}}}}' -f owner='OWNER' -f name='REPO'
```

### Delete a Rule

```powershell
gh api graphql \ 
  -f query='mutation($ruleId:ID!){deleteBranchProtectionRule(input:{branchProtectionRuleId:$ruleId}){clientMutationId}}' \ 
  -f ruleId='<RULE_ID_FROM_LIST_COMMAND>'
```

---

## Maintenance Tips

- Review branch rules quarterly to ensure they still align with team structure.
- Keep `PowerShell CI` (or additional workflows) listed under required status checks so merges cannot bypass quality gates.
- Update this policy document if branch families or team names change.
