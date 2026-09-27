# stillwiki — Vite SPA + thin Express API in one image (the server serves ./dist).
#
#   docker build \
#     --build-arg VITE_SUPABASE_URL=https://YOUR.supabase.co \
#     --build-arg VITE_SUPABASE_ANON_KEY=... \
#     --build-arg VITE_SITE_URL=https://your-app.example.com \
#     -t stillwiki .
#
# VITE_* args are inlined into the SPA at build time (the anon key is public).
# Server-only secrets (SUPABASE_SERVICE_ROLE_KEY, EMBEDDINGS_*/CHAT_*/OPENAI_*,
# MCP_API_TOKEN) are provided at runtime as env vars.

FROM node:22-alpine AS build
WORKDIR /app
# Install in the build stage so the workspace package's local devDeps (kb-core's
# tsup) are present when `npm run build` builds it.
COPY package.json package-lock.json ./
COPY packages/kb-core/package.json ./packages/kb-core/
RUN npm ci --ignore-scripts
COPY . .
ARG VITE_SUPABASE_URL
ARG VITE_SUPABASE_ANON_KEY
ARG VITE_SITE_URL
ARG VITE_BASE_PATH=/
ARG VITE_OAUTH_PROVIDERS
ARG VITE_ALLOW_SIGNUP
ENV VITE_SUPABASE_URL=$VITE_SUPABASE_URL \
    VITE_SUPABASE_ANON_KEY=$VITE_SUPABASE_ANON_KEY \
    VITE_SITE_URL=$VITE_SITE_URL \
    VITE_BASE_PATH=$VITE_BASE_PATH \
    VITE_OAUTH_PROVIDERS=$VITE_OAUTH_PROVIDERS \
    VITE_ALLOW_SIGNUP=$VITE_ALLOW_SIGNUP
# prebuild hook builds @stillwiki/core (tsup), then `vite build` emits ./dist.
RUN npm run build

FROM node:22-alpine AS run
WORKDIR /app
ENV NODE_ENV=production PORT=8787
# Runtime needs node_modules (express + tsx + the @stillwiki/core symlink), the
# kb-core build, the built SPA, and the server + src/lib modules it imports.
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/packages/kb-core/package.json ./packages/kb-core/package.json
COPY --from=build /app/packages/kb-core/dist ./packages/kb-core/dist
COPY --from=build /app/dist ./dist
COPY --from=build /app/server ./server
COPY --from=build /app/src ./src
COPY --from=build /app/package.json /app/tsconfig.json ./
EXPOSE 8787
# `npm start` -> tsx server/index.ts: serves dist + the /api/* endpoints.
CMD ["npm", "start"]