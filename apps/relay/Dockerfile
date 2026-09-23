# Build context is the repo root: docker build -f apps/relay/Dockerfile .
FROM node:26-alpine AS workspace
WORKDIR /app

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/relay/package.json ./apps/relay/package.json
# Keep the package manager aligned with local development and CI.
RUN npm install --global "$(node -p 'require("./package.json").packageManager')"

FROM workspace AS production-dependencies
RUN pnpm --filter @yorozu/relay install --prod --frozen-lockfile --ignore-scripts

FROM workspace AS build
RUN pnpm --filter @yorozu/relay install --frozen-lockfile --ignore-scripts
COPY tsconfig.base.json ./
COPY apps/relay/tsconfig.json ./apps/relay/tsconfig.json
COPY apps/relay/src ./apps/relay/src
# Compile the .js import paths; native type stripping does not resolve them to .ts.
RUN pnpm --filter @yorozu/relay build

FROM node:26-alpine
WORKDIR /app/apps/relay
COPY --from=production-dependencies /app/node_modules /app/node_modules
COPY --from=production-dependencies /app/apps/relay/node_modules ./node_modules
COPY --from=production-dependencies /app/apps/relay/package.json ./
COPY --from=build /app/apps/relay/dist ./dist

ENV PORT=8787
EXPOSE 8787
CMD ["node", "dist/index.js"]
