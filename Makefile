# Itential Dev Stack
# run 'make help' to see available commands

.PHONY: help setup up down logs status certs login clean generate-key

.DEFAULT_GOAL := help

# load .env if exists
-include .env
export

# auto-detect user/group IDs for volume ownership
UID ?= $(shell id -u)
GID ?= $(shell id -g)

# default values
ECR_REGISTRY ?= 497639811223.dkr.ecr.us-east-2.amazonaws.com
PLATFORM_PORT ?= 3000
GATEWAY4_PORT ?= 8083
LDAP_PORT ?= 3389
MCP_SSE_PORT ?= 8000
OPENBAO_PORT ?= 8200

# build profile list based on enabled services
PROFILES := --profile full
ifeq ($(LDAP_ENABLED),true)
  PROFILES += --profile ldap
endif
ifeq ($(MCP_ENABLED),true)
  PROFILES += --profile mcp
endif
ifeq ($(OPENBAO_ENABLED),true)
  PROFILES += --profile openbao
endif

help: ## Show available commands
	@echo "Itential Dev Stack"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "First time? Run: make setup"

setup: ## First-time setup (generates key, certs, starts services, configures Gateway Manager)
	@./scripts/setup.sh

up: ## Start all services
	@docker compose $(PROFILES) up -d
	@$(MAKE) --no-print-directory status

down: ## Stop all services
	@docker compose $(PROFILES) down

logs: ## Follow logs (all services, or: make logs LOG=platform)
	@docker compose logs -f $(LOG)

status: ## Show service status and URLs
	@echo ""
	@docker compose --profile full --profile ldap --profile mcp --profile openbao ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
	@echo ""
	@echo "URLs:"
	@echo "  Platform:  http://localhost:$(PLATFORM_PORT)  (admin/admin)"
	@echo "  Gateway4:  http://localhost:$(GATEWAY4_PORT)  (admin@itential/admin)"
	@if docker ps --format '{{.Names}}' | grep -q '^openldap$$'; then \
		echo "  OpenLDAP:  localhost:$(LDAP_PORT)  (cn=admin,dc=itential,dc=io/admin)"; \
	fi
	@if docker ps --format '{{.Names}}' | grep -q '^mcp$$'; then \
		echo "  MCP:       http://localhost:$(MCP_SSE_PORT)  (SSE transport)"; \
	fi
	@if docker ps --format '{{.Names}}' | grep -q '^openbao$$'; then \
		TOKEN=$$(cat volumes/openbao/init-keys.json 2>/dev/null | jq -r '.root_token // "see init-keys.json"'); \
		echo "  OpenBao:   http://localhost:$(OPENBAO_PORT)  (token: $$TOKEN)"; \
	fi
	@echo ""

certs: ## Generate SSL certificates
	@./scripts/generate-certificates.sh

login: ## Login to AWS ECR
	@aws ecr get-login-password --region us-east-2 | \
		docker login --username AWS --password-stdin $(ECR_REGISTRY)
	@echo "ECR login successful"

clean: ## Stop services and remove data (destructive)
	@echo "WARNING: This will delete all container data."
	@echo "Press Ctrl+C within 3 seconds to cancel..."
	@sleep 3
	@docker compose --profile full --profile ldap --profile mcp --profile openbao down -v
	@docker rm -f $$(docker ps -aq --filter "ancestor=ghcr.io/itential/itential-mcp") 2>/dev/null || true
	@docker volume rm itential-dev-stack_gateway5-data 2>/dev/null || true
	@docker volume rm itential-dev-stack_openbao-data 2>/dev/null || true
	@docker volume rm itential-dev-stack_platform-logs 2>/dev/null || true
	@rm -f volumes/openbao/init-keys.json 2>/dev/null || true
	@sed -i '/^# OpenBao Platform Integration/d' .env 2>/dev/null || true
	@sed -i '/^ITENTIAL_VAULT_/d' .env 2>/dev/null || true
	@docker run --rm -u root -v $(PWD)/dependencies/mongodb-data:/data alpine sh -c 'rm -rf /data/* /data/.*' 2>/dev/null || true
	@rm -rf volumes/gateway4/data/*.db 2>/dev/null || true
	@echo "Cleanup complete"

generate-key: ## Generate a new 64-character encryption key
	@openssl rand -hex 32
