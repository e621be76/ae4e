# Part 7 — Ops Answers

## 1. EKS 1.33 → 1.35, zero downtime

EKS upgrades the control plane one minor at a time, so it's two hops. Kubelet may lag the API server by up to 3 minors,
so nodes can stay on 1.33 until the control plane reaches 1.35 and then roll **once**.

1. **Prep (per hop):** EKS Upgrade Insights + `kubent`/`pluto` for removed APIs; check every controller and webhook (ingress, cert-manager, Karpenter, ESO, ...) for a release that supports 1.35; PDBs exist and allow at least 1 disruption; rehearse on staging.
2. **Control plane** 1.33 → 1.34 (in-place, API stays available; clients may see brief reconnects).
3. **Add-ons** to the 1.34-compatible versions: vpc-cni first, then kube-proxy (never newer than the control plane), CoreDNS, EBS/EFS CSI.
4. Repeat 2–3 for **1.35**.
5. **Data plane**: Karpenter — bump the EC2NodeClass AMI alias; drift replaces nodes within the disruption budgets. Managed node groups — surge update. Spot pools first, on-demand and stateful last.
6. Bump cluster-scoped tooling and remove the deprecated-API shims.

**Top 3 risks**
- **Removed or changed APIs / incompatible operators**: a webhook that fails on the new API server can block *all* writes. Mitigation: scan beforehand, upgrade operators first, `failurePolicy: Ignore` on non-critical webhooks.
- **Drains causing downtime**: workloads without PDBs or with a single replica, PDBs that block drains forever (`maxUnavailable: 0`), EBS-backed pods that can only reschedule in the same AZ. Mitigation: audit PDBs and replicas, surge capacity per AZ.
- **Networking add-on regressions**: vpc-cni IP exhaustion while surging (2x pods for a while), CoreDNS config changes. Mitigation: check free subnet IPs/prefix delegation; watch DNS error rate and pod `ContainerCreating` counts during the roll.

## 2. Spot reclaims paging at 3 AM

Page on **user impact**, not on a node going away. Spot nodes disappearing is expected behavior.

- **Handle the interruption properly:** Karpenter's interruption queue (or the Node Termination Handler) cordons and drains on the 2-minute notice, so the node leaves cleanly and the Node object is deleted. That alone removes most "unreachable" noise.
- **Split by capacity type:** `KubeNodeUnreachable` for `acme.io/capacity=on-demand` (and control-plane-critical nodes) still pages, after `for: 5m`. For spot: inhibit via Alertmanager when a `SpotInterruptionReceived` alert (from the Karpenter/NTH metric) exists for the same node; otherwise route to a **ticket** with `for: 15m` (a reclaimed node is normally deleted well within that).
- **Symptom alerts that page regardless of cause:** SLO burn rate (error ratio / latency), `kube_deployment_status_replicas_unavailable > 0 for 10m` on tier-1 services, pods `Pending` > 10m (no capacity to replace), and a **fleet-level** alert like ">30% of spot capacity lost in 10 min" (AZ/market event).
- Result: a single reclaim generates no page; a real failure — an on-demand node down, replicas not recovering, users affected — still pages.

## 3. Cloudflare in front, mobile LCP 5s

1. **Split the LCP:** CrUX/PageSpeed field data + a WebPageTest mobile run. Is the time in TTFB (origin/cache) or in rendering (hero image, render-blocking JS/CSS)? Only fix caching if TTFB is a big share.
2. **Check what Cloudflare does with the HTML:**
   `curl -sI -H 'User-Agent: <mobile UA>' https://site/ | grep -iE 'cf-cache-status|cache-control|age|set-cookie|vary|cf-ray'`
   - `cf-cache-status: DYNAMIC` → Cloudflare doesn't cache HTML by default; there must be a Cache Rule ("eligible for cache") for HTML paths.
   - `MISS` every time / `Age` always 0 → cached but evicted, or split by a cache key that varies (query strings, cookies, device type).
   - `BYPASS` → the origin sent `Set-Cookie`, or `Cache-Control: private/no-store`, or a rule bypasses on a cookie.
3. **Review the rules:** Cache Rules order (later matches override earlier ones), leftover legacy Page Rules, "Bypass cache on cookie", cache key settings (device type, query string), Edge TTL "respect origin" vs override. Then Cloudflare's Cache analytics: hit ratio for `text/html`.
4. **Check the origin:** the response headers it actually sends (`curl --resolve site:443:<origin-ip>`): `Cache-Control: no-cache` from the framework, session cookies on anonymous pages, `Vary: User-Agent` fragmenting the cache. Also origin TTFB on a miss, which sets the floor for uncached visitors.
5. **Fix and verify:** make anonymous HTML cacheable (`s-maxage` + `stale-while-revalidate`, or an edge TTL in a Cache Rule, bypassing only on a real session cookie), purge on deploy; confirm `HIT` from several colos (`cf-ray` suffix), then watch field LCP over the next 28 days. In parallel: fix the hero image (`fetchpriority=high`, right size, AVIF/WebP) if rendering was part of the 5s.

## 4. Application secrets on EKS

| | **External Secrets Operator + AWS Secrets Manager** | **Sealed Secrets / SOPS in git** |
|---|---|---|
| Source of truth | Secrets Manager (per account/region) | encrypted blobs in the GitOps repo |
| Rotation | Rotate in AWS (incl. managed RDS rotation); ESO refreshes on an interval | re-encrypt + commit + sync for every rotation |
| Multi-cluster | each cluster reads the same secret by name with its own IAM role | per-cluster controller keys (Sealed) or KMS key management (SOPS) |
| Access control and audit | IAM per service account (EKS Pod Identity), CloudTrail per read | whoever can decrypt; git history keeps old ciphertexts forever |
| Failure mode | AWS API outage → existing k8s Secrets keep working, only refresh stops | controller key loss → nothing can be decrypted |

**Pick: ESO + Secrets Manager, with EKS Pod Identity.** For a startup with several production clusters it
gives one place to rotate, IAM-scoped access per app, and audit for free, and the GitOps repo only holds
`ExternalSecret` references (safe to make public). Pair it with KMS envelope encryption for k8s Secrets
and RBAC that keeps `get secrets` away from humans. Secrets Store CSI driver is the option if apps must never
see secrets as k8s Secrets at all. That's more friction than most startups need.
