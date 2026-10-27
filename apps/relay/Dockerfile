FROM node:26-alpine@sha256:0b36e8c136b94cd4fcf02188228e76c31ad5872eef3fec8cbd2eee500cfd9e80 AS build
WORKDIR /app
COPY apps/relay/package.json apps/relay/tsconfig.json ./
COPY tsconfig.base.json /tsconfig.base.json
RUN npm install --no-package-lock --ignore-scripts
COPY apps/relay/src ./src
RUN npx tsc -p .

FROM node:26-alpine@sha256:0b36e8c136b94cd4fcf02188228e76c31ad5872eef3fec8cbd2eee500cfd9e80
WORKDIR /app

COPY apps/relay/package.json ./
RUN npm install --omit=dev --no-package-lock --ignore-scripts
COPY --from=build /app/dist ./dist

ENV PORT=8787
EXPOSE 8787

USER node

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["node", "-e", "const s=require('node:net').connect({port:Number(process.env.PORT||8787),host:'127.0.0.1'});s.setTimeout(2000);s.once('connect',()=>{s.destroy();process.exit(0)});s.once('timeout',()=>process.exit(1));s.once('error',()=>process.exit(1))"]

CMD ["node", "dist/index.js"]
