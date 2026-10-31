# AI Usage

## Tools

- **Claude Code** (Claude Opus 5.5, terminal agent) for everything: reading the brief, scaffolding the app, harness, chart,
  workflow, Terraform and Karpenter YAML, and drafting the docs. It ran the local checks itself (Go tests, `helm lint`, Semgrep, `terraform validate`,
  CRD schema validation, shellcheck) and looked up current versions from GitHub, Docker Hub and the k3s release channel instead of relying on memory.
- I reviewed every file, ran the cluster end to end myself, and own the decisions below.

## Prompts that moved things forward

1. *"Go through ASSIGNMENTS.md and analyze requirements"*: turned the brief into a checklist of hidden traps:
   the schedulable k3s server node, the Golden Rule implying `run-all.sh` runs on the host (so scripts must re-exec into the toolbox),
   the image-tag/commit-SHA chicken-and-egg for GitOps, and the conflict between "prefer spot" and "always one on on-demand".
2. *"Added missing files. Host does not have Docker/k3d"*: led to reading the provided files for faults before running anything
   (all 9 Part 3 faults identified statically, then confirmed on the cluster) and to designing the harness so the host needs nothing but Docker.
3. *"Work on all parts … note in NOTES.md if you have to"*: the end-to-end implementation, with an explicit rule to verify versions against live sources.

## Where the AI was wrong or suboptimal, and how it was caught

- **Mutable GitHub Action tags.** The first workflow draft used `actions/checkout@v7`-style tags. The Semgrep gate I'd just added
  failed its own pipeline on 13 `github-actions-mutable-action-tag` findings (the rule cites the real trivy-action tag hijack).
  Fixed by resolving each release tag to its commit SHA via the GitHub API and pinning them. Good evidence the gate is a real gate.
- **Assumed `terraform validate` checks nested attributes.** It doesn't for the Cloudflare v5 `rules` list: a deliberate typo
  (`defaultt`) inside `edge_ttl` still validated. Caught by testing the validator with a bad input instead of trusting a green run. Instead I checked every
  attribute against `terraform providers schema -json`. Lesson: `validate` proves syntax and types, not that the object keys exist.
- **Shell bugs that would only show up at runtime.** (a) `if (bootstrap); then` disables `set -e` inside the subshell, so a failed
  `k3d cluster create` would have been reported as success; fixed by running bootstrap as a child process. (b) The drill's node-picker
  ended a `while` loop with `[ … ] && echo`, which under `pipefail` aborts the script whenever the last pod isn't on spot; replaced with `grep -Fx`.
  (c) A missing git remote would have killed `20-deploy.sh` silently before its friendly error. All three were caught reviewing the scripts line by line before running them.
- **Placement design, first answer was heavier than needed.** The AI first proposed two Deployments (a pinned on-demand "anchor" plus a spot pool).
  Working through the scheduler's maths showed one Deployment with a hard `maxSkew: 1` spread on `acme.io/capacity` guarantees 2 spot + 1 on-demand
  at 3 replicas, matching the brief's "affinity weights + topology spread". The rollout case needed `matchLabelKeys: [pod-template-hash]` and the drain case
  needed `nodeTaintsPolicy: Honor`. The remaining gap (scale-down can remove the on-demand pod) is documented in the README instead of over-engineered away.
- **Predicted Part 3 symptoms didn't all match the live cluster.** From reading the YAML, the AI predicted the image pull failing first and
  the 16Gi request leaving pods `Pending`. On the cluster the ConfigMap mount failed first (the kubelet mounts volumes before pulling images),
  and the 16Gi pods *scheduled*, because each k3d node reports the whole host's 125 GB. I re-ran the faults one at a time, rewrote TROUBLESHOOTING.md
  from the real output, and kept the 16Gi fix: on a normal laptop or production node it is a hard `Pending`.
- **"Default-deny blocks DNS" looked false at first.** A test pod under default-deny resolved the Service name fine, which suggested the DNS
  allow rule was unnecessary. Instead of deleting the rule, I ran a pod that sleeps 20 s before the lookup: then DNS times out. kube-router programs
  a new pod's rules a few seconds after it starts. The DNS rule stays; without it the smoke test would pass or fail depending on timing.
- **GitOps bump deployed `latest`.** The first green pipeline committed `tag: latest` to `chart/values.yaml`: `docker/metadata-action`'s
  `version` output picks the highest-priority tag, and raw tags outrank `type=sha` by default. Caught by reading the bot's commit, not
  just the green checkmark. Fixed with `priority=1000` on the sha tag; the next run committed `sha-043bab2`.
- **First CI run was red on the AI's own Karpenter example**, a Deployment with no `securityContext` (writable root filesystem, root user).
  The gate did its job, and the example now shows the hardened pod spec with `emptyDir` scratch space.
- **Semgrep can't parse Helm templates.** The first scan reported the chart as "syntax errors" and silently scanned nothing in it. Now CI scans the
  rendered chart, verified by injecting `privileged: true` and confirming the job fails.
- **One false positive suppressed on purpose:** `math/rand` for picking a quote. Annotated `nosemgrep` with the reason rather than switching to
  `crypto/rand`, which would just silence the scanner.
