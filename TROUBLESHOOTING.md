# Part 3 — Troubleshooting

`troubleshoot/broken-app.yaml` had **9 independent faults** across the `web` Deployment, its Service,
the `ai-inference` Deployment and the NetworkPolicy setup. Most hide behind the one in front of them
(a pod that can't mount its volume never gets to pull its image), so I fixed one at a time and re-read the
cluster after each fix. The output below is from that run on the k3d cluster (k3s v1.36.5).
Each fix is tagged `FIX #n` in `troubleshoot/fixed-app.yaml`; `scripts/30-troubleshoot.sh` replays broken → fixed → `verify.sh`.

First look at everything:

```bash
kubectl apply -f troubleshoot/broken-app.yaml
kubectl -n troubleshoot get pods -o wide
kubectl -n troubleshoot get events --sort-by=.lastTimestamp
```
```
ai-inference-77cfc6f99b-l2thx   0/1   Pending             <none>
web-5c8d87f7d8-bfcmx            0/1   ContainerCreating   k3d-quote-server-0
web-5c8d87f7d8-kjrb9            0/1   ContainerCreating   k3d-quote-agent-1
```

Side observation: one `web` pod landed on the k3s **server** node. `prepare.sh` only labels workers, and nothing in
these manifests constrains `web`, so the control plane is fair game. Harmless here; my own chart uses a required affinity to avoid it.

---

## web Deployment

### 1. ConfigMap name typo (surfaces first)
- **Symptom:** both pods stuck in `ContainerCreating`.
- **Diagnose:**
  ```bash
  kubectl -n troubleshoot describe pod -l app=web | grep -A2 Events   # or the events list above
  kubectl -n troubleshoot get configmap
  ```
  ```
  FailedMount  MountVolume.SetUp failed for volume "html" : configmap "web-conf" not found
  NAME         DATA
  web-config   1
  ```
- **Root cause:** the volume references `web-conf`; the ConfigMap is `web-config`. The kubelet mounts volumes *before* pulling images, so this hides fault #2.
- **Fix:** `configMap.name: web-config`.

### 2. Image tag does not exist
- **Symptom:** the new pod goes `ErrImagePull` → `ImagePullBackOff`.
- **Diagnose:** `kubectl -n troubleshoot describe pod <pod> | grep -A3 Failed`
  ```
  Failed to pull image "nginx:1.25.99": rpc error: code = NotFound desc = failed to pull and unpack image
  "docker.io/library/nginx:1.25.99": failed to resolve reference ...
  ```
- **Root cause:** `nginx:1.25.99` was never published (the 1.25 line ended at 1.25.5).
- **Fix:** an existing, pinned tag, `nginx:1.29.8-alpine` (checked on Docker Hub), not `latest`, so the fix is reproducible.

### 3. Probes check the wrong port
- **Symptom:** the container starts, never becomes Ready, restarts every few seconds, then `CrashLoopBackOff`.
- **Diagnose:**
  ```bash
  kubectl -n troubleshoot get pods -l app=web          # 0/1 Running, RESTARTS 2 (9s ago)
  kubectl -n troubleshoot describe pod <pod> | grep Unhealthy
  ```
  ```
  Liveness probe failed: Get "http://10.42.1.6:8080/": dial tcp 10.42.1.6:8080: connect: connection refused
  Readiness probe failed: Get "http://10.42.1.6:8080/": dial tcp 10.42.1.6:8080: connect: connection refused
  ```
- **Root cause:** both probes target `8080`; stock nginx listens on `80` (as the `containerPort` says).
- **Fix:** probes on port `80`. Pods go `1/1 Running`.

### 4. Memory request of 16Gi (environment-dependent)
- **Symptom on my machine:** none. The pods scheduled. **On a typical 8–16 GB laptop:** `Pending` with `Insufficient memory`.
- **Diagnose:**
  ```bash
  kubectl get nodes -o custom-columns=NODE:.metadata.name,ALLOCATABLE_MEM:.status.allocatable.memory
  ```
  ```
  k3d-quote-agent-0    131572488Ki     # every k3d node reports the *whole host's* RAM (125 GiB here)
  ```
- **Root cause:** `requests.memory: 16Gi` for a static nginx page. k3d nodes are containers that each advertise all host
  memory, so on a 125 GB host the scheduler happily places it (and would overcommit 5×), while on a 16 GB host no node can fit it.
  It's a latent bug that would pass on a big dev box and break in CI or on smaller nodes, which makes it the most dangerous kind.
- **Fix:** `32Mi` request / `64Mi` limit. nginx serving one file uses a few MiB.

## web-svc Service

### 5. Selector doesn't match the pods
- **Symptom:** Ready pods, but the Service has no endpoints.
- **Diagnose:**
  ```bash
  kubectl -n troubleshoot get endpointslices -l kubernetes.io/service-name=web-svc
  kubectl -n troubleshoot get svc web-svc -o jsonpath='{.spec.selector}'
  kubectl -n troubleshoot get pods --show-labels
  ```
  ```
  web-svc-8cxpv   IPv4   <unset>   <unset>
  {"app":"webapp"}
  web-694cc5d858-6w9bx   app=web,pod-template-hash=694cc5d858
  ```
- **Root cause:** selector `app: webapp` vs pod label `app: web`.
- **Fix:** selector `app: web`. Endpoints appear immediately, on port **8080** (fault #6).

### 6. targetPort points at a closed port
- **Symptom:** endpoints exist but connections are refused. With #5 fixed, the EndpointSlice shows `PORTS 8080`.
- **Diagnose:** the smoke Job and a throwaway client:
  ```bash
  kubectl -n troubleshoot get endpointslices -l kubernetes.io/service-name=web-svc   # PORTS 8080
  kubectl -n troubleshoot logs job/smoke-test
  ```
  ```
  curl: (7) Failed to connect to web-svc.troubleshoot.svc.cluster.local port 80 after 0 ms: Couldn't connect to server
  ```
- **Root cause:** `targetPort: 8080`; nginx listens on 80. It's the same 8080 mix-up as #3 but in a separate field, so fixing one doesn't fix the other.
- **Fix:** `targetPort: 80`.

## ai-inference Deployment

### 7 + 8. Wrong selector key, and no toleration for the GPU taint
- **Symptom:** `Pending` from the start.
- **Diagnose:**
  ```bash
  kubectl -n troubleshoot get events --field-selector reason=FailedScheduling
  kubectl get nodes -L acme.io/node-type
  kubectl get node -l acme.io/node-type=gpu -o jsonpath='{.items[0].spec.taints}'
  ```
  ```
  0/5 nodes are available: 1 node(s) had untolerated taint(s), 4 node(s) didn't match Pod's node affinity/selector.
  [{"effect":"NoSchedule","key":"nvidia.com/gpu","value":"true"}]
  ```
  The scheduler reports both filters at once. The message is identical before and after fixing only the selector, because the GPU node is
  then excluded by the taint instead of the selector. You have to read *which* node fails *which* filter.
- **Root causes:** (7) selector `node-type: gpu`, but `prepare.sh` labels `acme.io/node-type=gpu`, so no node matches.
  (8) the GPU node is tainted `nvidia.com/gpu=true:NoSchedule`, and the pod has no toleration.
- **Fix:** `nodeSelector: {acme.io/node-type: gpu}` plus a toleration for `nvidia.com/gpu=true:NoSchedule`. Both are needed:
  the toleration lets the pod *onto* the GPU node, the selector keeps it *off* the others. Lands on `k3d-quote-agent-3`.

## NetworkPolicy

### 9. default-deny with no allow rules
- **Symptom:** with #1–#8 fixed, `verify.sh` step 7 (smoke Job) fails.
- **Diagnose:** I tested each rule in isolation with a client carrying the smoke Job's label:
  ```bash
  kubectl -n troubleshoot get networkpolicy           # only default-deny (podSelector {}, Ingress+Egress, no rules)
  kubectl -n troubleshoot run t --rm -i --restart=Never --image=curlimages/curl:8.7.1 --labels=app=smoke-client \
    --command -- sh -c 'curl -sS -m5 http://web-svc'
  ```
  | Policies present | Result |
  |---|---|
  | default-deny only | `Failed to connect ... port 80 after 1 ms` (rejected by web's ingress) |
  | + DNS egress | same |
  | + DNS + egress to web | same: web's own ingress still denies |
  | + ingress on web from smoke-client | `TROUBLESHOOT-OK` |

  **Gotcha found on the way:** with *only* default-deny, the client still resolved `web-svc` (DNS seemed allowed). A pod that
  sleeps 20 s first shows the truth:
  ```
  Address: 10.43.202.253                                   # first lookup, right after pod start
  ---after 20s
  ;; connection timed out; no servers could be reached    # same lookup once kube-router has synced
  ```
  k3s enforces policy with kube-router, which programs a new pod's rules a few seconds after the pod starts. Early
  traffic slips through. DNS really is blocked by default-deny, and the DNS allow rule is required. Skipping it
  would work by accident on the first `curl` and fail on retries.
- **Root cause:** `default-deny` selects every pod and denies all ingress *and* egress, with nothing allowed back.
- **Fix:** kept `default-deny`; added three narrow policies:
  - `smoke-client-allow-dns`: smoke-client → `kube-system/k8s-app=kube-dns` on 53/UDP+TCP
  - `smoke-client-allow-web`: smoke-client → `app=web` on 80/TCP
  - `web-allow-smoke-client`: `app=web` ← smoke-client on 80/TCP

  The ports are the *pod* port (80), not the Service port, because policies are evaluated after kube-proxy's DNAT. Kubelet probes keep working
  under default-deny because kube-router allows traffic from a pod's own node.

---

## Verification

```
$ ./scripts/30-troubleshoot.sh
...
[5/7] ai-inference pod must be running ON the GPU node...
[6/7] Service must have ready endpoints...
[7/7] In-cluster smoke test through the Service...

PASS
```

## Issues in the provided harness (not in the workloads)

- `verify.sh` waits only 60 s per rollout; on a cold cluster the nginx pull can exceed that. `30-troubleshoot.sh` waits up to 300 s itself before calling `verify.sh`, which I left unmodified.
- `verify.sh` uses `kubectl get endpoints`, which prints `Warning: v1 Endpoints is deprecated in v1.33+`. It still works, so I left it alone.
