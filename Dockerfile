# Build upstream Paperclip from a pinned ref.
FROM node:24-trixie-slim AS paperclip-build
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    python3 \
    wget \
    # The server build drives a Rust target in packages/paperclip-runner
    # (upstream added these to their build stage after v2026.722.0).
    cargo \
    rustc \
    && rm -rf /var/lib/apt/lists/*
RUN corepack enable

ARG PAPERCLIP_REPO=https://github.com/paperclipai/paperclip.git
ARG PAPERCLIP_REF=v2026.831.1

WORKDIR /paperclip
RUN git clone --depth 1 --branch "${PAPERCLIP_REF}" "${PAPERCLIP_REPO}" .
RUN pnpm install --frozen-lockfile
RUN pnpm --filter @paperclipai/ui build
RUN pnpm --filter @paperclipai/plugin-sdk build
ENV NODE_OPTIONS=--max-old-space-size=4096
RUN pnpm --filter @paperclipai/server build
RUN test -f server/dist/index.js
# The runtime stage copies this whole tree; the Rust target dir is build-only.
RUN rm -rf packages/paperclip-runner/runner/target

# Runtime image (direct Paperclip server, no wrapper).
FROM node:24-trixie-slim
ENV NODE_ENV=production
ENV CLAUDE_CODE_BUBBLEWRAP=1
# Match upstream production image defaults (paperclipai/paperclip Dockerfile) so
# agent tooling, OpenCode, and config paths behave the same in containers.
# Railway service variables still override anything set here.
ENV HOME=/paperclip \
    HOST=0.0.0.0 \
    PORT=3100 \
    SERVE_UI=true \
    PAPERCLIP_HOME=/paperclip \
    PAPERCLIP_INSTANCE_ID=default \
    PAPERCLIP_CONFIG=/paperclip/instances/default/config.json \
    PAPERCLIP_DEPLOYMENT_MODE=authenticated \
    PAPERCLIP_DEPLOYMENT_EXPOSURE=private \
    OPENCODE_ALLOW_ALL_MODELS=true \
    GEMINI_SANDBOX=false
# Managed runtime previews default to Tailscale HTTPS from v2026.831.0 on.
# This container has no tailnet, so keep the previous loopback behavior.
ENV PAPERCLIP_MANAGED_RUNTIME_HTTPS=off

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gh \
    git \
    gosu \
    jq \
    openssh-client \
    python3 \
    make \
    ripgrep \
    tini \
    util-linux \
    wget \
    && rm -rf /var/lib/apt/lists/*
RUN corepack enable

# Give the node user the same home as HOME above, so a shell session opened
# with `railway ssh` lands on the mounted /paperclip volume.
RUN usermod -d /paperclip node

WORKDIR /app
COPY --from=paperclip-build /paperclip /app

WORKDIR /wrapper
COPY package.json /wrapper/package.json
RUN npm install --omit=dev && npm cache clean --force
COPY src /wrapper/src
COPY scripts/entrypoint.sh /wrapper/entrypoint.sh
COPY scripts/bootstrap-ceo.mjs /wrapper/template/bootstrap-ceo.mjs
RUN chmod +x /wrapper/entrypoint.sh

# Optional local adapters/tools parity with upstream Dockerfile.
RUN npm install --global --omit=dev @anthropic-ai/claude-code@latest @openai/codex@latest opencode-ai @google/gemini-cli@latest @moonshot-ai/kimi-code@latest @railway/cli@latest
RUN npm install --global --omit=dev tsx

# Go toolchain and build tooling.
ARG GO_VERSION=1.27.1
ARG ATLAS_VERSION=v1.2.0
ARG GOLANGCI_LINT_VERSION=v2.13.2
ARG MOCKGEN_VERSION=v0.6.0
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -o /tmp/go.tgz; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm /tmp/go.tgz; \
    curl -fsSL "https://release.ariga.io/atlas/atlas-community-linux-${ARCH}-${ATLAS_VERSION}" -o /usr/local/bin/atlas; \
    chmod +x /usr/local/bin/atlas
ENV PATH=/usr/local/go/bin:$PATH
# Install Go-based tools into /usr/local/bin: GOPATH points at the Railway volume
# at runtime, which would mask anything installed there during the build.
RUN set -eux; \
    GOBIN=/usr/local/bin GOFLAGS=-buildvcs=false \
      go install "github.com/golangci/golangci-lint/v2/cmd/golangci-lint@${GOLANGCI_LINT_VERSION}"; \
    GOBIN=/usr/local/bin GOFLAGS=-buildvcs=false \
      go install "go.uber.org/mock/mockgen@${MOCKGEN_VERSION}"; \
    go clean -cache -modcache
# Module and build caches live on the volume so they survive redeploys.
ENV GOPATH=/paperclip/go \
    GOMODCACHE=/paperclip/go/pkg/mod \
    GOCACHE=/paperclip/go/cache
ENV PATH=/paperclip/go/bin:$PATH

RUN mkdir -p /paperclip \
    && chown -R node:node /app /paperclip /wrapper

# Railway sets PORT at runtime and this process binds to it.
# Entrypoint runs as root, fixes /paperclip volume permissions, then execs as node.
EXPOSE 3100
# tini, not node, is PID 1. The entrypoint ends in `exec`, so without an init
# node inherits PID 1 and never wait()s the orphans the kernel re-parents onto
# it — agent runs spawn git/claude/esbuild/sh descendants that outlive their
# leader, so they pile up as permanent zombies (~79/h measured upstream) until
# the cgroup pid limit is exhausted and every fork() in the container fails.
ENTRYPOINT ["/usr/bin/tini", "--", "/wrapper/entrypoint.sh"]
CMD ["node", "/wrapper/src/server.js"]
