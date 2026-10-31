# debian, not alpine: glibc resolver (see NOTES), and the scripts need bash; distroless has no shell
FROM debian:trixie-slim

ARG TARGETARCH
ARG KUBECTL_VERSION=v1.36.6
ARG HELM_VERSION=v4.3.1
ARG K3D_VERSION=v5.9.0
ARG TERRAFORM_VERSION=1.17.1
ARG K6_VERSION=v2.3.0

# no docker CLI: k3d talks to the mounted docker.sock through the API
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash curl git jq ca-certificates unzip \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && curl -fsSLo /usr/local/bin/k3d "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-${TARGETARCH}" \
 && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" | tar -xz -C /usr/local/bin --strip-components=1 "linux-${TARGETARCH}/helm" \
 && curl -fsSL "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-${TARGETARCH}.tar.gz" | tar -xz -C /usr/local/bin --strip-components=1 "k6-${K6_VERSION}-linux-${TARGETARCH}/k6" \
 && curl -fsSLo /tmp/tf.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip" \
 && unzip -o /tmp/tf.zip terraform -d /usr/local/bin && rm /tmp/tf.zip \
 && chmod +x /usr/local/bin/* \
 && git config --system --add safe.directory '*'

# scripts check this to decide whether to re-exec themselves inside the toolbox
ENV IN_TOOLBOX=1
WORKDIR /work
