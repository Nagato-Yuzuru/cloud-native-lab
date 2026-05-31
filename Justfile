set shell := ["bash", "-euo", "pipefail", "-c"]

kubeconfig := "bootstrap/kubeconfig"
kube := "kubectl --kubeconfig=bootstrap/kubeconfig"
helm := "helm --kubeconfig=bootstrap/kubeconfig"

# List available commands
@default:
    just --list

# Initialize Terraform providers and add Helm repos
@init:
    tofu -chdir=bootstrap/cluster init
    helm repo add cilium https://helm.cilium.io/         2>/dev/null || true
    helm repo add argo   https://argoproj.github.io/argo-helm 2>/dev/null || true
    helm repo update

# Create cluster and bootstrap platform components
@up:
    just _create-cluster
    just _install-cilium
    just _tmpfs-storage
    just _install-argocd
    echo "Waiting for ArgoCD to be ready..."
    {{ kube }} wait --for=condition=available deployment/argocd-server -n argocd --timeout=180s
    ls gitops/platform/*.yaml &>/dev/null && {{ kube }} apply -f gitops/platform/ || true
    just status

# Destroy everything
@down:
    {{ helm }} uninstall argocd -n argocd     2>/dev/null || true
    {{ helm }} uninstall cilium -n kube-system 2>/dev/null || true
    tofu -chdir=bootstrap/cluster destroy -auto-approve || true
    rm -f {{ kubeconfig }}

# Teardown and rebuild from scratch
@restart:
    just down
    just up

# Create the kind cluster.
# If the container runtime injects an HTTP proxy into containers (OrbStack does this
# by default under `network_proxy: auto`), kind must *see* that proxy so it adds the
# cluster's pod/service/node CIDRs to the node's NO_PROXY. Otherwise in-cluster
# apiserver traffic (e.g. 192.168.97.2:6443) is routed through the proxy, which can't
# reach the kind-created docker network and returns 502 -> kubeadm init fails.
# We read whatever proxy the runtime already injects (never hardcoded) and forward it
# only for this command — no global OrbStack/Docker change, nothing leaks to other repos.
_create-cluster:
    #!/usr/bin/env bash
    set -euo pipefail
    inj="$(docker run --rm busybox sh -c 'echo "$HTTP_PROXY|$NO_PROXY"' 2>/dev/null || echo '|')"
    proxy="${inj%%|*}"; noproxy="${inj#*|}"
    if [ -n "$proxy" ]; then
        export HTTP_PROXY="$proxy" HTTPS_PROXY="$proxy" NO_PROXY="$noproxy"
        echo "→ container-injected proxy detected; kind will exempt cluster CIDRs from it (this run only)."
    fi
    tofu -chdir=bootstrap/cluster apply -auto-approve

# Apply the declarative RAM-backed storage (tmpfs DaemonSet) and wait until mounted.
# Makes the default storageClass RAM-backed so the lab never writes data to the SSD.
# Must run after the CNI is up (the pod needs networking) and before any PVC workload.
@_tmpfs-storage:
    {{ kube }} apply -f bootstrap/storage/
    {{ kube }} rollout status daemonset/tmpfs-local-path -n kube-system --timeout=180s
    echo "Storage: default storageClass is RAM-backed (tmpfs, zero SSD writes)."

# Install / upgrade Cilium (idempotent)
@_install-cilium:
    {{ helm }} upgrade --install cilium cilium/cilium \
        --version 1.18.6 \
        --namespace kube-system \
        --cleanup-on-fail \
        --set ipam.mode=kubernetes \
        --set operator.replicas=1 \
        --set hubble.relay.enabled=true \
        --set hubble.ui.enabled=true

# Install / upgrade ArgoCD (idempotent)
@_install-argocd:
    {{ helm }} upgrade --install argocd argo/argo-cd \
        --version 9.3.7 \
        --namespace argocd \
        --create-namespace \
        --cleanup-on-fail \
        --set applicationSet.enabled=true \
        --set redis-ha.enabled=false \
        --set controller.replicas=1 \
        --set server.replicas=1 \
        --set repoServer.replicas=1

# Enable a stack — deploy its ArgoCD Applications (e.g. just stack-enable o11y)
@stack-enable name:
    {{ kube }} apply -f gitops/stacks/{{ name }}/
    echo "Stack '{{ name }}' enabled."

# Disable a stack and remove all its resources (e.g. just stack-disable o11y)
@stack-disable name:
    {{ kube }} delete -f gitops/stacks/{{ name }}/
    echo "Stack '{{ name }}' disabled."

# List currently active stacks
@stack-list:
    {{ kube }} get applications -n argocd \
        --no-headers \
        -o custom-columns='STACK:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
        2>/dev/null || echo "(no stacks deployed)"

# Show cluster and component health
@status:
    echo "--- Nodes ---"
    {{ kube }} get nodes -o wide
    echo ""
    echo "--- CNI (Cilium) ---"
    {{ kube }} get pods -n kube-system -l k8s-app=cilium
    echo ""
    echo "--- ArgoCD ---"
    {{ kube }} get pods -n argocd

# Trigger a hard refresh on all ArgoCD Applications
@sync:
    {{ kube }} annotate applications -n argocd --all argocd.argoproj.io/refresh=hard --overwrite

# Stream logs for a component by label name (e.g. just logs grafana)
@logs name:
    {{ kube }} logs -n observability -l app.kubernetes.io/name={{ name }} --tail=100 -f

# Remove stuck Helm releases in pending/failed state
@clean-zombies:
    {{ helm }} list -A -o json \
        | jq -r '.[] | select(.status | test("pending|fail")) | "\(.name) -n \(.namespace)"' \
        | xargs -r -L1 {{ helm }} uninstall --no-hooks

# SSH into the control-plane node
ssh:
    docker exec -it native-lab-control-plane bash
