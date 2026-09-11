# Build context is the repo root: docker build -f apps/relay/Dockerfile .
FROM node:26-alpine
WORKDIR /app

COPY apps/relay/package.json ./
RUN npm install --omit=dev --no-package-lock

# Node 26 strips TypeScript types natively, so the image needs no build step.
COPY apps/relay/src ./src

ENV PORT=8787
EXPOSE 8787
CMD ["node", "src/index.ts"]
