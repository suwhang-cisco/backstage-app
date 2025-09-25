# Stage 1 - Create yarn install skeleton layer
FROM node:20-bookworm-slim AS packages

WORKDIR /app
COPY package.json ./
COPY yarn.lock ./

COPY packages packages

# Comment this out if you don't have any internal plugins
COPY plugins plugins

RUN find packages \! -name "package.json" -mindepth 2 -maxdepth 2 -exec rm -rf {} \+

# Stage 2 - Install dependencies and build packages
FROM node:20-bookworm-slim AS build

RUN corepack enable
RUN mkdir -p /home/node/.cache/node/corepack && chown -R node:node /home/node/.cache

# Install Python and build tools needed for native modules
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-pip python3-venv g++ build-essential

USER node
WORKDIR /app

# Set Python path for node-gyp
RUN yarn config set python /usr/bin/python3

COPY --from=packages --chown=node:node /app .

RUN --mount=type=cache,target=/home/node/.cache/yarn,sharing=locked,uid=1000,gid=1000 \
    yarn install --network-timeout 600000

COPY --chown=node:node . .

RUN yarn install --network-timeout 600000

# Skip TypeScript check for Docker build due to unused React import warnings
# RUN yarn tsc
RUN yarn --cwd packages/backend build
# If you have not yet migrated to package roles, use the following command instead:
# RUN yarn --cwd packages/backend backstage-cli backend:bundle --build-dependencies

RUN mkdir packages/backend/dist/skeleton packages/backend/dist/bundle \
    && tar xzf packages/backend/dist/skeleton.tar.gz -C packages/backend/dist/skeleton \
    && tar xzf packages/backend/dist/bundle.tar.gz -C packages/backend/dist/bundle

# Stage 3 - Build the actual backend image and install production dependencies
FROM node:20-bookworm-slim

# Install isolate-vm dependencies, these are needed by the @backstage/plugin-scaffolder-backend.
# Install packages needed to get utility binaries
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-pip python3-venv g++ build-essential ca-certificates curl

RUN yarn config set python /usr/bin/python3

# Add kubectl for the kube apply plugin.
# Add cnoe-cli
# Add mkdocs for the TechDocs plugin.
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then KUBECTL_ARCH="amd64"; \
    elif [ "$ARCH" = "aarch64" ]; then KUBECTL_ARCH="arm64"; \
    else echo "Unsupported architecture: $ARCH" && exit 1; fi && \
    curl -L -o /usr/local/bin/kubectl "https://dl.k8s.io/release/v1.29.9/bin/linux/${KUBECTL_ARCH}/kubectl" && \
    chmod +x /usr/local/bin/kubectl

RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then CNOE_ARCH="x86_64"; \
    elif [ "$ARCH" = "aarch64" ]; then CNOE_ARCH="arm64"; \
    else echo "Unsupported architecture: $ARCH" && exit 1; fi && \
    curl -L -O "https://github.com/cnoe-io/cnoe-cli/releases/download/v0.1.0/cnoe_Linux_${CNOE_ARCH}.tar.gz" && \
    curl -L -O https://github.com/cnoe-io/cnoe-cli/releases/download/v0.1.0/checksums.txt && \
    sha256sum -c --strict --status --ignore-missing checksums.txt && \
    tar -xzf "cnoe_Linux_${CNOE_ARCH}.tar.gz" && \
    mv cnoe /usr/bin/cnoe-cli && \
    chmod +x /usr/bin/cnoe-cli && \
    rm checksums.txt "cnoe_Linux_${CNOE_ARCH}.tar.gz"
COPY ./cnoe-wrapper.sh /usr/bin/cnoe
RUN chmod +x /usr/bin/cnoe

ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
RUN pip3 install 'mkdocs-techdocs-core==1.4.2'

RUN corepack enable
RUN mkdir -p /home/node/.cache/node/corepack && chown -R node:node /home/node/.cache

# From here on we use the least-privileged `node` user to run the backend.
USER node

# This should create the app dir as `node`.
# If it is instead created as `root` then the `tar` command below will
# fail: `can't create directory 'packages/': Permission denied`.
# If this occurs, then ensure BuildKit is enabled (`DOCKER_BUILDKIT=1`)
# so the app dir is correctly created as `node`.
WORKDIR /app

# Copy the install dependencies from the build stage and context
COPY --from=build --chown=node:node /app/yarn.lock /app/package.json /app/packages/backend/dist/skeleton/ ./

RUN --mount=type=cache,target=/home/node/.cache/yarn,sharing=locked,uid=1000,gid=1000 \
    yarn workspaces focus --production

# Copy the built packages from the build stage
COPY --from=build --chown=node:node /app/packages/backend/dist/bundle/ ./

# Copy any other files that we need at runtime
COPY --chown=node:node app-config.yaml ./

# This switches many Node.js dependencies to production mode.
ENV NODE_ENV production

CMD ["node", "packages/backend", "--config", "app-config.yaml"]
