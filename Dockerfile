# Start from the official Paperclip server image (prebuilt for each release)
# instead of compiling Paperclip here. It already ships the app in /app, the
# same env defaults as before, and tini/gosu/gh/git/ripgrep/jq/openssh.
# Pinned by digest so a re-pushed tag cannot change a build; bump both with
# scripts/bump-paperclip-ref.mjs.
FROM ghcr.io/paperclipai/paperclip:2026.1005.0@sha256:de762433b50d56ed9180fef96a13fa236b37856c5c7a7718e8f19afe3d1e8670
ENV CLAUDE_CODE_BUBBLEWRAP=1
# Managed runtime previews default to Tailscale HTTPS from v2026.831.0 on.
# This container has no tailnet, so keep the previous loopback behavior.
ENV PAPERCLIP_MANAGED_RUNTIME_HTTPS=off

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    make \
    util-linux \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /wrapper
COPY package.json /wrapper/package.json
RUN npm install --omit=dev && npm cache clean --force
COPY src /wrapper/src
COPY scripts/entrypoint.sh /wrapper/entrypoint.sh
COPY scripts/bootstrap-ceo.mjs /wrapper/template/bootstrap-ceo.mjs
RUN chmod +x /wrapper/entrypoint.sh

# Optional local adapters/tools parity with upstream Dockerfile.
# Pinned (not @latest): an unpinned upstream release could break builds for
# every new deploy of this template with no warning. Bump deliberately.
RUN npm install --global --omit=dev \
    @anthropic-ai/claude-code@2.1.280 \
    @openai/codex@0.156.1 \
    opencode-ai@1.18.32 \
    @google/gemini-cli@0.60.0 \
    @moonshot-ai/kimi-code@2.1.0 \
    @railway/cli@5.61.0
RUN npm install --global --omit=dev tsx@4.23.15

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
    && chown -R node:node /paperclip /wrapper

# Railway sets PORT at runtime and this process binds to it.
# Entrypoint runs as root, fixes /paperclip volume permissions, then execs as node.
EXPOSE 3100
# tini, not node, is PID 1. The entrypoint ends in `exec`, so without an init
# node inherits PID 1 and never wait()s the orphans the kernel re-parents onto
# it — agent runs spawn git/claude/esbuild/sh descendants that outlive their
# leader, so they pile up as permanent zombies until the cgroup pid limit is
# exhausted and every fork() in the container fails.
ENTRYPOINT ["/usr/bin/tini", "--", "/wrapper/entrypoint.sh"]
CMD ["node", "/wrapper/src/server.js"]
