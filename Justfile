set shell := ["bash", "-c"]

@init:
    tofu -chdir=bootstrap/cluster init && tofu -chdir=bootstrap/apps init

@up:
    tofu -chdir=bootstrap/cluster apply -auto-approve \
    && tofu -chdir=bootstrap/apps apply -auto-approve
    echo "Waiting for pods to stabilize..."
    sleep 5
    just status

@down:
    cd bootstrap && tofu destroy -auto-approve
    rm -f bootstrap/kubeconfig

@status:
    echo "--- Nodes ---"
    kubectl get nodes -o wide
    echo "\n--- CNI (Cilium) ---"
    kubectl get pods -n kube-system -l k8s-app=cilium
    echo "\n--- Ingress ---"
    kubectl get pods -n ingress-nginx

ssh:
    docker exec -it native-lab-control-plane bash