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

# ADR 0009: halogen is this branch's Backend. Pinned here rather than in .env
# because .env is gitignored and therefore shared across branches -- setting it
# there would break `main`, which has no docker-compose.backends-halogen.yml.
# Overridable on the command line as usual:
#   make COMPOSE_FILE=docker-compose.yml:docker-compose.backends.yml up
COMPOSE_FILE := docker-compose.yml:docker-compose.backends-halogen.yml

.DEFAULT_GOAL := help

.PHONY: help env up down restart halogen-fetch halogen-health restart-backend restart-frontend restart-monitoring restart-imagegen logs ps pull config vulkaninfo stats monitoring monitoring-down imagegen imagegen-down darkmode darkmode-up darkmode-down test clean

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

# --- Restart groups (down && up per compose file) ---
# Full stop/start cycle — picks up compose changes. Keeps volumes.

restart-backend: ## Full restart of the Backend (docker-compose.backends-halogen.yml)
	$(COMPOSE) -f docker-compose.yml -f docker-compose.backends-halogen.yml down halogen litellm
	$(COMPOSE) -f docker-compose.yml -f docker-compose.backends-halogen.yml up -d --no-deps halogen litellm

restart-frontend: ## Full restart of frontend (docker-compose.yml)
	$(COMPOSE) -f docker-compose.yml down
	$(COMPOSE) -f docker-compose.yml up -d

restart-monitoring: ## Full restart of monitoring (docker-compose.monitoring.yml)
	$(COMPOSE) -f docker-compose.monitoring.yml down
	$(COMPOSE) -f docker-compose.monitoring.yml up -d

restart-imagegen: ## Full restart of Imagegen Mode (docker-compose.comfyui.yml)
	$(COMPOSE) -f docker-compose.comfyui.yml down
	$(COMPOSE) -f docker-compose.comfyui.yml up -d

# Total bytes of the --exclude'd file set below, straight from the HF API.
# Only used for the progress line; a stale value costs an inaccurate percentage,
# nothing more.
HALOGEN_REPO  := peonist-ai/halogen-qwen3.8-flash-next
HALOGEN_BYTES := 127466848820

halogen-fetch: ## Download the ~127 GB halogen weights into HALOGEN_MODELS_DIR (resumable)
	@test -n "$(HALOGEN_MODELS_DIR)" || { echo "HALOGEN_MODELS_DIR is not set in .env"; exit 1; }
	@mkdir -p "$(HALOGEN_MODELS_DIR)"
	@echo "Fetching $(HALOGEN_REPO) into $(HALOGEN_MODELS_DIR) -- resumes if interrupted."
	# `hf download` prints nothing at all until it is finished: no progress bar,
	# not even attached to an interactive terminal (verified against hf 1.28.0 --
	# 816 MB moved for 65 bytes of output). Unusable for a 127 GB transfer, so
	# poll the target directory instead. Partial chunks land under it too, so its
	# size is an honest fraction of the total.
	#
	# --exclude keeps the speed overlay out: the quality overlay is what the
	# engine loads by default, and the speed one buys ~2% decode for the
	# calibration it drops. The 0.9 GB vision sidecar IS fetched -- dead weight
	# on disk until HALOGEN_VISION_TOWER is set, but cheaper than a second trip.
	#
	# EXACTLY ONE pattern after --exclude. hf 1.28.0 gives it nargs="*" while a
	# positional FILENAMES list sits behind it, so a second pattern is parsed as
	# an explicit filename -- at which point --exclude is discarded with a
	# warning and that "pattern" is the only thing downloaded. Verified.
	#
	# HF_TOKEN comes from .env via the `export` above; the repo is public, so it
	# only buys rate limit.
	@hf download $(HALOGEN_REPO) --local-dir "$(HALOGEN_MODELS_DIR)" \
		--exclude "*.overlay-speed.hgn" & \
	dl=$$!; \
	while kill -0 $$dl 2>/dev/null; do \
		now=$$(du -sb "$(HALOGEN_MODELS_DIR)" 2>/dev/null | cut -f1); \
		printf '\r  %s / %s GB  (%s%%)  ' \
			"$$((now/1000000000))" "$$(($(HALOGEN_BYTES)/1000000000))" \
			"$$((now*100/$(HALOGEN_BYTES)))"; \
		sleep 5; \
	done; \
	wait $$dl; rc=$$?; printf '\n'; \
	test $$rc -eq 0 && echo "Done. Next: make up && make halogen-health"; \
	exit $$rc

halogen-health: ## Ask the Backend what the running build actually supports
	# /health is authoritative over the README: sampling fields, whether images
	# are accepted, token budget aliases and defaults, tool-call wire format.
	curl -sf http://127.0.0.1:8731/health | jq .

logs: ## Follow logs for the stack, or one service: make logs SERVICE=litellm
	$(COMPOSE) logs -f $(SERVICE)

ps: ## Show service status
	$(COMPOSE) ps

pull: ## Pull the latest images for all services
	$(COMPOSE) pull

config: ## Validate and print the merged compose config
	$(COMPOSE) config

vulkaninfo: ## Verify Vulkan/RADV passthrough of the ARCHIVED llama.cpp Backends (ADR 0003)
	# Only meaningful with docker-compose.backends.yml. halogen is ROCm, not
	# Vulkan (ADR 0009) -- use `make halogen-health` for that one.
	# The llama.cpp server-vulkan image ships libvulkan + the RADV ICD but not
	# the vulkaninfo CLI itself, so install vulkan-tools in the ephemeral
	# container before running it.
	$(COMPOSE) run --rm --entrypoint sh $(or $(SERVICE),llama-chat) -c \
		'apt-get update -qq && apt-get install -y -qq vulkan-tools >/dev/null && vulkaninfo --summary'

stats: ## Snapshot memory/CPU usage of the Backend (see README: Memory budget)
	# Do not trust this number on its own: the kernel counts halogen's locked
	# weights as reclaimable file cache, so free(1) and MemAvailable both
	# under-report by roughly the size of the model. The startup log line
	# "host memory left for everything else" is the authoritative one.
	$(CONTAINER_BIN) stats --no-stream $$($(COMPOSE) ps -q halogen)

monitoring: ## Add optional Grafana/Prometheus monitoring on top of the running stack
	COMPOSE_FILE="$(COMPOSE_FILE):docker-compose.monitoring.yml" $(COMPOSE) up -d

monitoring-down: ## Stop the optional Grafana/Prometheus monitoring services
	COMPOSE_FILE="$(COMPOSE_FILE):docker-compose.monitoring.yml" $(COMPOSE) stop prometheus grafana

imagegen: ## Add optional Imagegen Mode (ComfyUI, LAN :8188) on top; builds the ROCm image on first run
	COMPOSE_FILE="$(COMPOSE_FILE):docker-compose.comfyui.yml" $(COMPOSE) up -d --build

imagegen-down: ## Stop the optional Imagegen Mode (ComfyUI) service
	COMPOSE_FILE="$(COMPOSE_FILE):docker-compose.comfyui.yml" $(COMPOSE) stop comfyui

darkmode: ## Build litellm-dark-mode:local from the pinned litellm base (github.com/delorenj/litellm-dark-mode)
	@BASE_IMAGE=$$(grep -m1 'image: ghcr.io/berriai/litellm' docker-compose.yml | awk '{print $$2}'); \
	echo "Pinning digest for $$BASE_IMAGE..."; \
	$(CONTAINER_BIN) pull -q $$BASE_IMAGE >/dev/null; \
	DIGEST=$$($(CONTAINER_BIN) inspect --format='{{index .RepoDigests 0}}' $$BASE_IMAGE); \
	npx --yes litellm-dark-mode docker --image $$DIGEST --tag litellm-dark-mode:local

darkmode-up: darkmode ## Build (if needed) and start the stack with the dark-mode litellm image (docker-compose.darkmode.yml)
	COMPOSE_FILE="$(COMPOSE_FILE):docker-compose.darkmode.yml" $(COMPOSE) up -d

darkmode-down: ## Switch the litellm service back to the pinned upstream image
	COMPOSE_FILE="$(COMPOSE_FILE):docker-compose.darkmode.yml" $(COMPOSE) down litellm
	$(COMPOSE) up -d --no-deps litellm

test: ## Run the integration test suite against stub Backends
	tests/run.sh

clean: ## Stop the stack and DELETE its volumes (Postgres/Prometheus/Grafana data)
	$(COMPOSE) down -v
