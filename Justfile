set shell := ["bash", "-c"]

kubeconfig := "bootstrap/kubeconfig"
kube := "kubectl --kubeconfig=bootstrap/kubeconfig"

# List available commands
@default:
    just --list

# Initialize Terraform providers
@init:
    tofu -chdir=bootstrap/cluster init && tofu -chdir=bootstrap/apps init

# Create cluster and bootstrap platform components
@up:
    tofu -chdir=bootstrap/cluster apply -auto-approve
    tofu -chdir=bootstrap/apps apply -auto-approve
    echo "Waiting for ArgoCD to be ready..."
    {{kube}} wait --for=condition=available deployment/argocd-server -n argocd --timeout=180s
    ls gitops/platform/*.yaml &>/dev/null && {{kube}} apply -f gitops/platform/ || true
    just status

# Destroy everything
@down:
    tofu -chdir=bootstrap/apps destroy -auto-approve || true
    tofu -chdir=bootstrap/cluster destroy -auto-approve || true
    rm -f {{kubeconfig}}

# Teardown and rebuild from scratch
@restart:
    just down
    just up

# Fix Terraform state drift, then re-run up
@fix:
    #!/usr/bin/env bash
    set -euo pipefail
    kube="kubectl --kubeconfig=bootstrap/kubeconfig"

    if ! kind get clusters 2>/dev/null | grep -q '^native-lab$'; then
        echo "Cluster 'native-lab' not found — removing stale Terraform state..."
        tofu -chdir=bootstrap/cluster state rm kind_cluster.default 2>/dev/null || true
        tofu -chdir=bootstrap/apps state rm helm_release.argocd 2>/dev/null || true
        tofu -chdir=bootstrap/apps state rm helm_release.cilium 2>/dev/null || true
    else
        # Cluster exists but apps state may have been cleared — uninstall stale Helm releases
        # so Terraform can re-create them cleanly (avoids "name already in use" errors).
        if ! tofu -chdir=bootstrap/apps state list 2>/dev/null | grep -q 'helm_release'; then
            echo "Apps state is empty but cluster exists — cleaning up stale Helm releases..."
            helm uninstall cilium -n kube-system --kubeconfig bootstrap/kubeconfig 2>/dev/null || true
            helm uninstall argocd -n argocd --kubeconfig bootstrap/kubeconfig 2>/dev/null || true
        fi
    fi
    just up

# Enable a stack — deploy its ArgoCD Applications (e.g. just stack-enable o11y)
@stack-enable name:
    {{kube}} apply -f gitops/stacks/{{name}}/
    echo "Stack '{{name}}' enabled."

# Disable a stack and remove all its resources (e.g. just stack-disable o11y)
@stack-disable name:
    {{kube}} delete -f gitops/stacks/{{name}}/
    echo "Stack '{{name}}' disabled."

# List currently active stacks
@stack-list:
    {{kube}} get applications -n argocd \
        --no-headers \
        -o custom-columns='STACK:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
        2>/dev/null || echo "(no stacks deployed)"

# Show cluster and component health
@status:
    echo "--- Nodes ---"
    {{kube}} get nodes -o wide
    echo ""
    echo "--- CNI (Cilium) ---"
    {{kube}} get pods -n kube-system -l k8s-app=cilium
    echo ""
    echo "--- Ingress ---"
    {{kube}} get pods -n ingress-nginx
    echo ""
    echo "--- ArgoCD ---"
    {{kube}} get pods -n argocd

# Trigger a hard refresh on all ArgoCD Applications
@sync:
    {{kube}} annotate applications -n argocd --all argocd.argoproj.io/refresh=hard --overwrite

# Stream logs for a component by label name (e.g. just logs grafana)
@logs name:
    {{kube}} logs -n observability -l app.kubernetes.io/name={{name}} --tail=100 -f

# Remove stuck Helm releases in pending/failed state
@clean-zombies:
    helm list -A -o json \
        | jq -r '.[] | select(.status | test("pending|fail")) | "\(.name) -n \(.namespace)"' \
        | xargs -r -L1 helm uninstall --no-hooks

# SSH into the control-plane node
ssh:
    docker exec -it native-lab-control-plane bash
