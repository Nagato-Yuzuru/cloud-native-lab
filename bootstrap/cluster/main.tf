terraform {
  required_providers {
    kind = { source = "tehcyx/kind", version = "0.10.0" }
  }
}

provider "kind" {}

resource "kind_cluster" "default" {
  name           = "native-lab"
  node_image     = "kindest/node:v1.35.0"
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"
    node {
      role = "control-plane"
      kubeadm_config_patches = [
        <<-EOT
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
        EOT
      ]
      extra_port_mappings {
        container_port = 80
        host_port      = 80
        protocol       = "TCP"
      }
      extra_port_mappings {
        container_port = 443
        host_port      = 443
        protocol       = "TCP"
      }
    }
    networking {
      disable_default_cni = true
      kube_proxy_mode     = "iptables"
    }
  }
}

resource "local_file" "kubeconfig" {
  content  = kind_cluster.default.kubeconfig
  filename = "${path.module}/../../kubeconfig"
}
