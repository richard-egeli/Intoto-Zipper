# Multi-stage build. Stage 1 compiles the release; stage 2 holds only
# the runtime bits so the final image stays small.
#
# Builder + runner images are pinned by ARG so you can bump OTP / Elixir
# without editing two FROM lines. Tags are the ones Hex publishes at
# https://hub.docker.com/r/hexpm/elixir/tags.
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.3.1
ARG DEBIAN_VERSION=bookworm-20260406-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# UID / GID for the runtime user. Set these to match the owner of your
# Synology volumes (e.g. `--build-arg APP_UID=$(id -u)`) so bind-mounted
# source folders are readable without chown-ing them on the host.
ARG APP_UID=1000
ARG APP_GID=1000

# -----------------------------------------------------------------------------
# Builder
# -----------------------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends build-essential git \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# `TERM=dumb` keeps OTP's `user` (terminal I/O) driver from crashing
# when the builder stage runs in a non-TTY BuildKit context. Biting
# this under emulation (Rosetta or QEMU) without it produces a
# `failed_to_start_child,user,nouser` shutdown on OTP 27+.
ENV TERM=dumb

RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV="prod"

# Deps first so their layer caches across app-code edits.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config. runtime.exs comes in later so its edits don't
# invalidate this layer.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

# Asset digest (tailwind + esbuild → priv/static/assets/*).
RUN mix assets.deploy

RUN mix compile

COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# -----------------------------------------------------------------------------
# Runner
# -----------------------------------------------------------------------------
FROM ${RUNNER_IMAGE}

ARG APP_UID
ARG APP_GID

# tini — reaps zombies and forwards signals to the BEAM so `docker stop`
# triggers a clean shutdown instead of SIGKILL after 10s.
# curl — for the container HEALTHCHECK.
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates tini curl \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod

# Non-root runtime user. Match the owner of your host-mounted volumes
# (Synology folders, ./data, ./secrets) so reads/writes Just Work
# without chmod/chown gymnastics.
#
# On macOS builds, the builder's GID is 20 (staff) which collides with
# Debian's pre-seeded `dialout` group — so only create the group/user
# when the requested UID/GID isn't already present.
RUN if ! getent group  ${APP_GID} >/dev/null; then groupadd --system --gid ${APP_GID} app; fi \
 && if ! getent passwd ${APP_UID} >/dev/null; then useradd  --system --uid ${APP_UID} --gid ${APP_GID} --home /app --shell /usr/sbin/nologin app; fi

# /data holds the SQLite DB (DATABASE_PATH). /run/secrets holds the
# Drive service-account JSON (GOOGLE_APPLICATION_CREDENTIALS). Both are
# created up-front with the right ownership so bind mounts don't flip
# to root on first boot.
RUN mkdir -p /app /data /run/secrets \
 && chown -R ${APP_UID}:${APP_GID} /app /data

WORKDIR /app

COPY --from=builder --chown=${APP_UID}:${APP_GID} /app/_build/prod/rel/synology_zipper ./

USER ${APP_UID}:${APP_GID}

ENV PHX_SERVER=true \
    PORT=4000 \
    DATABASE_PATH=/data/synology_zipper.db

EXPOSE 4000

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/bin/server"]
