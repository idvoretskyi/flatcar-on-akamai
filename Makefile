# flatcar-on-akamai — convenience targets.
# Most targets read configuration from .env (copy from .env.example).

SHELL := /usr/bin/env bash
TOFU  := tofu
TOFU_DIR := tofu

# Ignition generator backend: knuckle (default, needs Go) or butane.
BACKEND ?= knuckle

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: tooling
tooling: ## Print/install host tooling notes (Go via snap, etc.)
	@echo "Required: tofu, linode-cli, jq, git"
	@echo "knuckle backend also needs Go:   sudo snap install go --classic"
	@echo "butane backend needs:            curl, envsubst (gettext)"

.PHONY: image
image: ## One-time: upload the Flatcar image to Linode (prints private/<id>)
	scripts/upload-image.sh

.PHONY: ignition
ignition: ## Render build/ignition.json (BACKEND=knuckle|butane)
	scripts/render-ignition.sh --backend $(BACKEND)

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

.PHONY: fmt
fmt: ## tofu fmt
	cd $(TOFU_DIR) && $(TOFU) fmt

.PHONY: validate
validate: ## Offline validation: tofu fmt -check + validate, shellcheck, jq
	cd $(TOFU_DIR) && $(TOFU) fmt -check && $(TOFU) init -backend=false >/dev/null && $(TOFU) validate
	shellcheck scripts/*.sh scripts/lib/*.sh
	jq -e . knuckle/config.json >/dev/null

.PHONY: clean
clean: ## Remove build artifacts
	rm -rf build
