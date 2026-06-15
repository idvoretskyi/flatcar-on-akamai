# flatcar-on-akamai — convenience targets.
# Most targets read configuration from .env (copy from .env.example).

SHELL := /usr/bin/env bash
TOFU  := tofu
TOFU_DIR := tofu

# Ignition generator backend: knuckle (default, needs Go) or butane.
BACKEND ?= knuckle

# Kubernetes cluster overlay: none (default, pure Flatcar) or k3s.
CLUSTER ?= none

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: tooling
tooling: ## Print/install host tooling notes (Go via snap, etc.)
	@echo "Required: tofu, linode-cli, jq, git, openssl, curl, envsubst (gettext)"
	@echo "knuckle backend also needs Go:   sudo snap install go --classic"
	@echo "kubectl (optional):              https://kubernetes.io/docs/tasks/tools/"

.PHONY: image
image: ## One-time: upload the Flatcar image to Linode (prints private/<id>)
	scripts/upload-image.sh

.PHONY: ignition
ignition: ## Render build/ignition.json (BACKEND=knuckle|butane  CLUSTER=none|k3s)
	scripts/render-ignition.sh --backend $(BACKEND) --cluster $(CLUSTER)

.PHONY: init
init: ## tofu init
	cd $(TOFU_DIR) && $(TOFU) init

.PHONY: plan
plan: ## tofu plan
	cd $(TOFU_DIR) && $(TOFU) plan

.PHONY: apply
apply: ## tofu apply (creates the instance — costs money)
	cd $(TOFU_DIR) && $(TOFU) apply

.PHONY: destroy
destroy: ## tofu destroy
	cd $(TOFU_DIR) && $(TOFU) destroy

.PHONY: ssh
ssh: ## SSH into the running instance
	cd $(TOFU_DIR) && $$($(TOFU) output -raw ssh_command)

.PHONY: kubeconfig
kubeconfig: ## Fetch k3s kubeconfig from the running instance (requires CLUSTER=k3s)
	@command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found — https://kubernetes.io/docs/tasks/tools/"; exit 1; }
	@PUBLIC_IP=$$(cd $(TOFU_DIR) && $(TOFU) output -raw ip_address 2>/dev/null) && \
	  [ -n "$$PUBLIC_IP" ] || { echo "error: could not read ip_address from tofu state (run make apply first)"; exit 1; } && \
	  echo "==> fetching kubeconfig from core@$$PUBLIC_IP" && \
	  ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	    "core@$$PUBLIC_IP" "sudo cat /etc/rancher/k3s/k3s.yaml" \
	  | sed "s|https://127.0.0.1:6443|https://$$PUBLIC_IP:6443|g" \
	  | sed 's|certificate-authority-data:.*|insecure-skip-tls-verify: true|g' \
	  > kubeconfig && \
	  chmod 600 kubeconfig && \
	  echo "==> written to ./kubeconfig" && \
	  echo "    export KUBECONFIG=\$$(pwd)/kubeconfig" && \
	  KUBECONFIG="$$(pwd)/kubeconfig" kubectl get nodes

.PHONY: fmt
fmt: ## tofu fmt
	cd $(TOFU_DIR) && $(TOFU) fmt

.PHONY: validate
validate: ## Offline validation: tofu fmt -check + validate, shellcheck, jq, butane
	cd $(TOFU_DIR) && $(TOFU) fmt -check && $(TOFU) init -backend=false >/dev/null && $(TOFU) validate
	shellcheck scripts/*.sh scripts/lib/*.sh
	jq -e . knuckle/config.json >/dev/null
	scripts/validate-butane.sh

.PHONY: clean
clean: ## Remove build artifacts
	rm -rf build
