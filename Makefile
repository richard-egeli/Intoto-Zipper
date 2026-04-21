.DEFAULT_GOAL := help

# -----------------------------------------------------------------------------
# Local dev builds — tag the image for the *current* host architecture and
# use the *current* user's UID/GID so bind-mounted volumes line up.
# -----------------------------------------------------------------------------
APP_UID ?= $(shell id -u)
APP_GID ?= $(shell id -g)

# -----------------------------------------------------------------------------
# Synology deploy builds — cross-compile for the NAS architecture and bake in
# the UID/GID of the NAS user that owns the mounted volumes. Defaults match
# the first non-system user on a typical DSM 7 install; run `id` on your NAS
# and override if they don't match.
# -----------------------------------------------------------------------------
NAS_UID ?= 1026
NAS_GID ?= 100

IMAGE   ?= synology_zipper
TAG     ?= latest
DIST    ?= dist
COMPOSE ?= docker compose

.PHONY: help build up down restart logs ps shell migrate remote clean \
        build-amd64 build-arm64 bundle-source \
        nas-context nas-build nas-up nas-down nas-logs nas-ps nas-migrate nas-info $(DIST)

help: ## Show this help
	@awk 'BEGIN{FS=":.*##"; printf "Targets:\n"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build the image for the current host (uses local UID/GID)
	$(COMPOSE) build --build-arg APP_UID=$(APP_UID) --build-arg APP_GID=$(APP_GID)

up: ## Start the container in the background
	$(COMPOSE) up -d --wait

down: ## Stop and remove the container
	$(COMPOSE) down

restart: ## Restart the container (no rebuild)
	$(COMPOSE) restart

logs: ## Tail the container logs
	$(COMPOSE) logs -f --tail=200 zipper

ps: ## Show container status
	$(COMPOSE) ps

shell: ## Open a shell inside the running container
	$(COMPOSE) exec zipper /bin/bash

migrate: ## Run Ecto migrations inside the container
	$(COMPOSE) exec zipper /app/bin/migrate

remote: ## Attach an IEx remote shell to the running release
	$(COMPOSE) exec zipper /app/bin/synology_zipper remote

clean: ## Remove the image and the ./data volume (DESTRUCTIVE)
	@echo "This will delete ./data (the SQLite DB). Ctrl-C to abort."
	@sleep 3
	$(COMPOSE) down -v
	rm -rf data $(DIST)

# -----------------------------------------------------------------------------
# Synology deploy builds. `buildx` cross-compiles via QEMU, writes a tarball
# straight to $(DIST)/, and DOES NOT touch your local image store. scp the
# tarball to the NAS, then `docker load < <file>` + `docker compose up -d`.
#
# Override NAS_UID / NAS_GID to match the NAS user that owns the volumes
# you'll bind-mount (run `id` on the NAS).
#
# Apple Silicon: enable Rosetta in Docker Desktop for best cross-build
# speed (Settings → General → "Use Rosetta for x86/amd64 emulation on
# Apple Silicon", then Apply & restart). The Dockerfile already sets
# `TERM=dumb` to work around OTP 27+'s user-driver crash under both
# Rosetta and QEMU.
# -----------------------------------------------------------------------------
CROSS_ELIXIR ?= 1.19.5
CROSS_OTP    ?= 28.3.1
CROSS_DEBIAN ?= bookworm-20260406-slim

$(DIST):
	@mkdir -p $(DIST)

build-amd64: $(DIST) ## Build + bundle linux/amd64 tarball (Intel/AMD Plus series)
	@echo "→ Building $(IMAGE):$(TAG) for linux/amd64 (OTP $(CROSS_OTP) / Elixir $(CROSS_ELIXIR), UID=$(NAS_UID) GID=$(NAS_GID))"
	docker buildx build \
		--platform linux/amd64 \
		--build-arg APP_UID=$(NAS_UID) \
		--build-arg APP_GID=$(NAS_GID) \
		--build-arg ELIXIR_VERSION=$(CROSS_ELIXIR) \
		--build-arg OTP_VERSION=$(CROSS_OTP) \
		--build-arg DEBIAN_VERSION=$(CROSS_DEBIAN) \
		-t $(IMAGE):$(TAG) \
		--output type=docker,dest=$(DIST)/$(IMAGE)-$(TAG)-amd64.tar \
		.
	gzip -f $(DIST)/$(IMAGE)-$(TAG)-amd64.tar
	@echo
	@ls -lh $(DIST)/$(IMAGE)-$(TAG)-amd64.tar.gz
	@echo
	@echo "Ship it:"
	@echo "  scp $(DIST)/$(IMAGE)-$(TAG)-amd64.tar.gz nas:~/"
	@echo "  ssh nas 'docker load < $(IMAGE)-$(TAG)-amd64.tar.gz && cd /path/to/app && docker compose up -d'"

build-arm64: $(DIST) ## Build + bundle linux/arm64 tarball (ARM Value/J series, newer low-end)
	@echo "→ Building $(IMAGE):$(TAG) for linux/arm64 (OTP $(CROSS_OTP) / Elixir $(CROSS_ELIXIR), UID=$(NAS_UID) GID=$(NAS_GID))"
	docker buildx build \
		--platform linux/arm64 \
		--build-arg APP_UID=$(NAS_UID) \
		--build-arg APP_GID=$(NAS_GID) \
		--build-arg ELIXIR_VERSION=$(CROSS_ELIXIR) \
		--build-arg OTP_VERSION=$(CROSS_OTP) \
		--build-arg DEBIAN_VERSION=$(CROSS_DEBIAN) \
		-t $(IMAGE):$(TAG) \
		--output type=docker,dest=$(DIST)/$(IMAGE)-$(TAG)-arm64.tar \
		.
	gzip -f $(DIST)/$(IMAGE)-$(TAG)-arm64.tar
	@echo
	@ls -lh $(DIST)/$(IMAGE)-$(TAG)-arm64.tar.gz
	@echo
	@echo "Ship it:"
	@echo "  scp $(DIST)/$(IMAGE)-$(TAG)-arm64.tar.gz nas:~/"
	@echo "  ssh nas 'docker load < $(IMAGE)-$(TAG)-arm64.tar.gz && cd /path/to/app && docker compose up -d'"

# -----------------------------------------------------------------------------
# Remote Docker context pointing at the Synology. Lets `docker build` /
# `docker compose` run from the Mac against the NAS's native-amd64 daemon:
# the build context ships over SSH, compilation happens on the NAS
# (fast, no emulation), and the image lands in the NAS's image store.
#
# Prereqs on the NAS:
#   - SSH enabled in DSM (Control Panel → Terminal & SNMP → Enable SSH service)
#   - Key-based SSH auth set up (`ssh-copy-id nasuser@nas`) — Docker contexts
#     can't answer password prompts reliably
#   - Your SSH user is a member of the `administrators` group so it can
#     talk to /var/run/docker.sock
#
# Override NAS_HOST with `make NAS_HOST=192.168.1.42 nas-build` or set
# `NAS_HOST` in your shell. If your SSH config already has a Host alias
# for the NAS, use that; otherwise `user@host[:port]` works.
# -----------------------------------------------------------------------------
NAS_HOST        ?= nas
NAS_CONTEXT     ?= synology_zipper_nas

# Absolute paths on the NAS for the bind mounts. Relative paths would
# resolve against the SSH user's home dir which is usually wrong.
# `/volume1/docker/...` is the Synology convention for container data.
NAS_DATA_DIR    ?= /volume1/docker/zipper/data
NAS_SECRETS_DIR ?= /volume1/docker/zipper/secrets

define _require_nas_host
	@if [ -z "$(NAS_HOST)" ]; then echo "NAS_HOST not set"; exit 1; fi
endef

nas-context: ## Register a Docker context pointing at the NAS (idempotent)
	$(_require_nas_host)
	@if docker context inspect $(NAS_CONTEXT) >/dev/null 2>&1; then \
	   docker context update $(NAS_CONTEXT) --docker host=ssh://$(NAS_HOST) >/dev/null; \
	   echo "→ updated context $(NAS_CONTEXT) → ssh://$(NAS_HOST)"; \
	 else \
	   docker context create  $(NAS_CONTEXT) --docker host=ssh://$(NAS_HOST) >/dev/null; \
	   echo "→ created context $(NAS_CONTEXT) → ssh://$(NAS_HOST)"; \
	 fi

nas-info: nas-context ## Smoke test — prove the remote context works (runs `docker info` on NAS)
	DOCKER_CONTEXT=$(NAS_CONTEXT) docker info --format 'Server: {{.ServerVersion}}  Arch: {{.Architecture}}  OS: {{.OperatingSystem}}'

# Env vars passed to every nas-* compose invocation. Sets absolute NAS
# paths for the bind mounts via the `${DATA_DIR}` / `${SECRETS_DIR}`
# indirection in docker-compose.yml.
_NAS_ENV = DOCKER_CONTEXT=$(NAS_CONTEXT) \
           DATA_DIR=$(NAS_DATA_DIR) \
           SECRETS_DIR=$(NAS_SECRETS_DIR)

nas-build: nas-context ## Build the image natively on the NAS via SSH (no emulation)
	@echo "→ Building on $(NAS_HOST) (UID=$(NAS_UID) GID=$(NAS_GID))"
	$(_NAS_ENV) $(COMPOSE) build \
		--build-arg APP_UID=$(NAS_UID) --build-arg APP_GID=$(NAS_GID)

nas-up: nas-context ## Start the container on the NAS (volumes resolve against NAS paths)
	@echo "→ Ensuring $(NAS_DATA_DIR) and $(NAS_SECRETS_DIR) exist on $(NAS_HOST)"
	@ssh $(NAS_HOST) "mkdir -p $(NAS_DATA_DIR) $(NAS_SECRETS_DIR)" || \
	   (echo "!! Could not mkdir on NAS — ensure SSH works and directories exist"; exit 1)
	$(_NAS_ENV) $(COMPOSE) up -d --wait

nas-down: nas-context ## Stop the container on the NAS
	$(_NAS_ENV) $(COMPOSE) down

nas-logs: nas-context ## Tail the NAS container's logs
	$(_NAS_ENV) $(COMPOSE) logs -f --tail=200 zipper

nas-ps: nas-context ## Show NAS container status
	$(_NAS_ENV) $(COMPOSE) ps

nas-migrate: nas-context ## Run Ecto migrations inside the NAS container
	$(_NAS_ENV) $(COMPOSE) exec zipper /app/bin/migrate

bundle-source: $(DIST) ## Tar up the source tree for on-NAS `make build` (escape hatch when cross-compile fails)
	@echo "→ Bundling source tree for on-NAS build"
	@echo "  (including tracked + untracked files, respecting .gitignore)"
	@tmp=$$(mktemp -d); \
	 cp -R . $$tmp/synology_zipper; \
	 cd $$tmp && \
	   rm -rf synology_zipper/.git \
	          synology_zipper/_build \
	          synology_zipper/deps \
	          synology_zipper/.elixir_ls \
	          synology_zipper/.claude \
	          synology_zipper/dist \
	          synology_zipper/data \
	          synology_zipper/secrets \
	          synology_zipper/.env \
	          synology_zipper/priv/static/assets \
	          synology_zipper/priv/static/cache_manifest.json \
	          synology_zipper/assets/node_modules && \
	   find synology_zipper -name '*.db' -delete && \
	   find synology_zipper -name '*.db-*' -delete && \
	   find synology_zipper -name 'erl_crash.dump' -delete && \
	   tar -czf $(CURDIR)/$(DIST)/synology_zipper-src-$(TAG).tar.gz synology_zipper; \
	 rm -rf $$tmp
	@echo
	@ls -lh $(DIST)/synology_zipper-src-$(TAG).tar.gz
	@echo
	@echo "Ship + build on the NAS:"
	@echo "  scp $(DIST)/synology_zipper-src-$(TAG).tar.gz nas:~/"
	@echo "  ssh nas 'tar xf synology_zipper-src-$(TAG).tar.gz && cd synology_zipper && NAS_UID=\$$(id -u) NAS_GID=\$$(id -g) make build && make up'"
