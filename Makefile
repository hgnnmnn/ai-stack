# Shortcuts around `docker compose` for this stack. On a podman host, override
# both on the command line, e.g.:
#   make COMPOSE="podman compose" CONTAINER_BIN=podman up
COMPOSE ?= docker compose
CONTAINER_BIN ?= docker

# podman-compose (unlike docker compose) doesn't read COMPOSE_FILE from
# .env, only from the shell environment. Load .env and export it so
# COMPOSE_FILE=docker-compose.yml:docker-compose.backends.yml takes effect.
-include .env
export

.DEFAULT_GOAL := help

.PHONY: help env up down restart logs ps pull config vulkaninfo stats monitoring monitoring-down test clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

env: ## Create .env from .env.example if it doesn't exist yet
	@test -f .env || cp .env.example .env

up: ## Start the stack (Gateway, Postgres, monitoring, and Backends per COMPOSE_FILE)
	$(COMPOSE) up -d

down: ## Stop the stack, keeping volumes
	$(COMPOSE) down

restart: ## Restart the stack, or one service: make restart SERVICE=litellm
	$(COMPOSE) restart $(SERVICE)

logs: ## Follow logs for the stack, or one service: make logs SERVICE=litellm
	$(COMPOSE) logs -f $(SERVICE)

ps: ## Show service status
	$(COMPOSE) ps

pull: ## Pull the latest images for all services
	$(COMPOSE) pull

config: ## Validate and print the merged compose config
	$(COMPOSE) config

vulkaninfo: ## Verify Vulkan/RADV passthrough (ADR 0003): make vulkaninfo [SERVICE=llama-coder]
	$(COMPOSE) run --rm --entrypoint vulkaninfo $(or $(SERVICE),llama-qwen35) --summary

stats: ## Snapshot memory/CPU usage of both Backends (see README: Memory budget)
	$(CONTAINER_BIN) stats --no-stream $$($(COMPOSE) ps -q llama-qwen35 llama-coder)

monitoring: ## Add optional Grafana/Prometheus monitoring on top of the running stack
	COMPOSE_FILE="$(COMPOSE_FILE):docker-compose.monitoring.yml" $(COMPOSE) up -d

monitoring-down: ## Stop the optional Grafana/Prometheus monitoring services
	COMPOSE_FILE="$(COMPOSE_FILE):docker-compose.monitoring.yml" $(COMPOSE) stop prometheus grafana

test: ## Run the integration test suite against stub Backends
	tests/run.sh

clean: ## Stop the stack and DELETE its volumes (Postgres/Prometheus/Grafana data)
	$(COMPOSE) down -v
