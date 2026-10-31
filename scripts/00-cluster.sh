#!/usr/bin/env bash
# create the k3d cluster (1 server + 4 agents), write kubeconfig, label/taint nodes via prepare.sh
# runs automatically as the toolbox entrypoint (--serve); safe to re-run by hand
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

bootstrap() {
  # serialize with the entrypoint run in case run-all.sh starts while bootstrap is in progress
  exec 9>/tmp/cluster.lock
  flock 9

  if k3d cluster get "$CLUSTER" >/dev/null 2>&1; then
    log "cluster $CLUSTER exists, making sure it is started"
    k3d cluster start "$CLUSTER"
  else
    log "creating cluster $CLUSTER"
    k3d cluster create "$CLUSTER" \
      --image rancher/k3s:v1.36.5-k3s1 \
      --servers 1 --agents 4 \
      --network k3d-quote \
      -p "${HOST_PORT:-8080}:80@loadbalancer" \
      --k3s-arg "--tls-san=${LB}@server:*" \
      --kubeconfig-update-default=false \
      --wait
  fi

  mkdir -p "$(dirname "$KUBECONFIG")"
  # k3d writes the host-mapped API address; inside the docker network we go through the lb by name
  k3d kubeconfig get "$CLUSTER" | sed -E "s#server: https://[^ ]+#server: https://${LB}:6443#" >"$KUBECONFIG"
  kubectl wait --for=condition=Ready nodes --all --timeout=180s

  log "preparing nodepools"
  sh /work/troubleshoot/prepare.sh
}

if [ "${1:-}" = "--serve" ]; then
  # run as a child so set -e still applies inside bootstrap, and keep the container up on failure for debugging
  rm -f /tmp/bootstrap-done /tmp/bootstrap-failed
  "$0" || touch /tmp/bootstrap-failed
  exec sleep infinity
fi

bootstrap
rm -f /tmp/bootstrap-failed
touch /tmp/bootstrap-done
