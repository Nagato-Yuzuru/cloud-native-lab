terraform {
  required_providers {
    helm       = { source = "hashicorp/helm", version = "3.1.1" }
    kubernetes = { source = "hashicorp/kubernetes", version = "3.0.1" }
  }
}

provider "helm" {
  kubernetes = {
    config_path = "${path.module}/../../kubeconfig"
  }
}

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = "1.18.6"
  namespace  = "kube-system"

  set = [
    {
      name  = "ipam.mod"
      value = "kubernetes"
    },
    {
      name  = "operator.replicas"
      value = "1"
    },
    {
      name  = "hubble.relay.enabled"
      value = "true"
    },
    {
      name  = "hubble.ui.enabled"
      value = "true"
    }
  ]
}

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.14.2"
  namespace        = "ingress-nginx"
  create_namespace = true

  set = [
    {
      name  = "controller.hostNetwork"
      value = "true"
    },
    {
      name  = "controller.service.type"
      value = "NodePort"
    },
    {
      name  = "controller.publishService.enabled"
      value = "false"
    }
  ]


  depends_on = [helm_release.cilium]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "9.3.7"
  namespace        = "argocd"
  create_namespace = true

  set = [{
    name  = "applicationSet.enabled"
    value = "true"
  },
    {
      name  = "redis-ha.enabled"
      value = "false"
    },
    {
      name  = "controller.replicas"
      value = "1"
    },
    {
      name  = "server.replicas"
      value = "1"
    },
    {
      name  = "repoServer.replicas"
      value = "1"
    }]

  depends_on = [helm_release.cilium]
}
