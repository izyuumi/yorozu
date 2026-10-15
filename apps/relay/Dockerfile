# Build context is the repo root: docker build -f apps/relay/Dockerfile .
#
# Pinned by digest so a rebuild gets the image that was reviewed, not whatever the tag points
# at today. Refresh with:  docker buildx imagetools inspect node:26-alpine   (the index digest)
FROM node:26-alpine@sha256:0b36e8c136b94cd4fcf02188228e76c31ad5872eef3fec8cbd2eee500cfd9e80 AS build
WORKDIR /app
COPY apps/relay/package.json apps/relay/tsconfig.json ./
COPY tsconfig.base.json /tsconfig.base.json
RUN npm install --no-package-lock --ignore-scripts
COPY apps/relay/src ./src
# Compiled rather than type-stripped: the sources import each other as `./x.js`, which
# Node's type stripping does not rewrite, so `node src/index.ts` cannot find its neighbours.
RUN npx tsc -p .

FROM node:26-alpine@sha256:0b36e8c136b94cd4fcf02188228e76c31ad5872eef3fec8cbd2eee500cfd9e80
WORKDIR /app

COPY apps/relay/package.json ./
RUN npm install --omit=dev --no-package-lock --ignore-scripts
COPY --from=build /app/dist ./dist

ENV PORT=8787
EXPOSE 8787

# The image ships the `node` user; the relay needs nothing root can do.
USER node

# Alive means accepting TCP on the listening port. Plain `net` rather than an HTTP probe:
# the relay speaks only websockets, and the image carries no curl or wget to speak them.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["node", "-e", "const s=require('node:net').connect({port:Number(process.env.PORT||8787),host:'127.0.0.1'});s.setTimeout(2000);s.once('connect',()=>{s.destroy();process.exit(0)});s.once('timeout',()=>process.exit(1));s.once('error',()=>process.exit(1))"]

CMD ["node", "dist/index.js"]
