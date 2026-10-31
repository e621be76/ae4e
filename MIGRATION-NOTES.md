# Part 4 — GitLab CI → GitHub Actions

Legacy: `ci/legacy.gitlab-ci.yml`. New: `.github/workflows/ci.yml`.
I migrated the *intent* (test → scan → build → deploy), not the file.

## What changed and why

| Legacy | Now | Why |
|---|---|---|
| AWS access keys hardcoded in `variables:` | Removed. Nothing in the pipeline used them | Secrets in git are leaked secrets, even "example" ones. If AWS is needed later: GitHub OIDC → `aws-actions/configure-aws-credentials` assuming a role, no static keys |
| `sonar_check` with `allow_failure: true`, only on master, no gate wait | `sast` job: Semgrep with `--error`, every PR and push, required before the image job | A scan that can't fail is decoration. Semgrep needs no server or token for a public repo. It also scans the *rendered* Helm chart, because it can't parse raw templates |
| `npm test \|\| echo "tests flaky"` | `go vet` + `go test -race`, failure fails the job | Swallowed failures hide regressions. Flaky tests get fixed or quarantined explicitly, not ignored globally |
| `node:16`, `docker:20.10`, `sonar-scanner 4.6`, `bitnami/kubectl:1.24` | Current pinned versions; actions pinned to commit SHAs | EOL images get no security fixes. Mutable action tags are a supply-chain risk (the trivy-action tag hijack); Semgrep's `github-actions` ruleset enforces SHA pins and caught my own first draft |
| `npm install` | Go modules (no deps) | Reproducible builds (the npm equivalent would be `npm ci`) |
| `docker login -p $PASSWORD`, privileged docker-in-docker | `docker/login-action` with the job's `GITHUB_TOKEN`, BuildKit via `docker/build-push-action` | No password on the command line, no privileged service container, layer cache via `type=gha` |
| Push only `:latest` | `:sha-<short>` (immutable, deployed) + `:latest` (convenience) | `latest` can't be rolled back or audited |
| `deploy_prod`: manual `kubectl set image` with a long-lived kubeconfig secret | `bump-chart` job commits the new tag to `chart/values.yaml`; ArgoCD syncs it | CI never holds cluster credentials; git is the deploy log; rollback = `git revert` |
| `only: master` everywhere | `pull_request` runs test/scan/build (no push); `push` to `main` also publishes | Problems surface in review, not after merge. (`only:` is deprecated in GitLab too, in favor of `rules:`) |
| — | Trivy gate on fixable HIGH/CRITICAL in the image (bonus) | Catches vulnerable base images and Go stdlib versions before publishing. Runs the checksum-verified release binary, not the (once hijacked) action or the Alpine-based image |
| — | `terraform fmt/validate` + `helm lint` | Cheap checks for the other code in the repo |
| — | Explicit `permissions:` per job (default `contents: read`) | Least privilege for `GITHUB_TOKEN`; only the image job can write packages and only bump-chart can push |

Skipped: cosign signing (bonus). Keyless signing is a few lines, but nothing verifies signatures in this
cluster (no admission policy), so it would be decoration as well.

## Migrating GitLab CI variables/secrets in a real project

1. **Inventory**: export project, group and instance variables (`GET /projects/:id/variables`, `/groups/:id/variables`), noting `protected`/`masked`/environment scope for each.
2. **Drop what OIDC replaces**: cloud keys (AWS/GCP/Azure) become OIDC federation with short-lived role credentials; registry passwords become `GITHUB_TOKEN` for GHCR. Then revoke the old keys.
3. **Map scope**: group variables → organization secrets restricted to selected repos; protected/env-scoped variables → **environment secrets** with protection rules (required reviewers, branch restrictions), the closest match to GitLab's protected + `when: manual`.
4. **Non-secret config** → GitHub `vars` (configuration variables), not secrets, so they stay readable in logs.
5. **Rotate on cutover**: anything that lived in GitLab gets a new value in GitHub; the old one is revoked after the first green run. Never copy-paste live values through chat or tickets.
6. Load with `gh secret set NAME --env production < file` from a secure workstation. Never echo secrets in a workflow.
