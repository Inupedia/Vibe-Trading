# ============================================================================
# Stage 1: Build frontend
# ============================================================================
# Override for China: docker.m.daocloud.io/library/node:20-slim
# Both ARGs must precede the first FROM so BuildKit can resolve every stage.
ARG NODE_IMAGE=node:20-slim
ARG PYTHON_IMAGE=python:3.11-slim
FROM ${NODE_IMAGE} AS frontend-build

ARG NPM_REGISTRY=https://registry.npmjs.org
WORKDIR /app/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm config set registry "${NPM_REGISTRY}" \
    && npm ci --ignore-scripts
COPY frontend/ ./
RUN npm run build

# ============================================================================
# Stage 2: Python runtime
# ============================================================================
# Override for China: docker.m.daocloud.io/library/python:3.11-slim
FROM ${PYTHON_IMAGE} AS runtime

ARG USE_CN_APT_MIRROR=0
ARG PIP_INDEX_URL=https://pypi.org/simple
# Re-declare global FROM args so they are visible inside this stage if needed.
ARG NODE_IMAGE
ARG PYTHON_IMAGE

LABEL org.opencontainers.image.title="Vibe-Trading" \
    org.opencontainers.image.description="Natural-language finance research AI agent with backtesting" \
    org.opencontainers.image.version="0.1.7" \
    org.opencontainers.image.source="https://github.com/HKUDS/Vibe-Trading" \
    org.opencontainers.image.licenses="MIT"

WORKDIR /app

# System deps
RUN if [ "${USE_CN_APT_MIRROR}" = "1" ]; then \
      for f in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources; do \
        [ -f "$f" ] && sed -i \
          's|deb.debian.org|mirrors.tuna.tsinghua.edu.cn|g; s|security.debian.org|mirrors.tuna.tsinghua.edu.cn|g' "$f" || true; \
      done; \
    fi \
    && apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Python deps (install before copying code for layer caching)
COPY agent/requirements.txt agent/requirements.txt
RUN pip install --no-cache-dir -i "${PIP_INDEX_URL}" -r agent/requirements.txt

# Copy project
COPY pyproject.toml LICENSE README.md ./
COPY agent/ agent/

# Copy built frontend
COPY --from=frontend-build /app/frontend/dist frontend/dist

# Install CLI entrypoint
RUN pip install --no-cache-dir -i "${PIP_INDEX_URL}" -e .

# Runtime should not run as root. Keep writable app data directories owned by
# the service user so named Docker volumes inherit usable permissions.
RUN useradd --create-home --shell /usr/sbin/nologin vibe \
    && mkdir -p agent/runs agent/sessions agent/uploads agent/.swarm/runs \
    && chown -R vibe:vibe /app
USER vibe

# Default port
EXPOSE 8899

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8899/health')" || exit 1

# Run API server (serves frontend/dist as static files)
CMD ["vibe-trading", "serve", "--host", "0.0.0.0", "--port", "8899"]
