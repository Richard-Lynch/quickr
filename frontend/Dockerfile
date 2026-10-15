# syntax=docker/dockerfile:1

# ---- build ------------------------------------------------------------------
FROM node:24-alpine AS build
WORKDIR /app
# Same pnpm as package.json#packageManager.
RUN npm install -g pnpm@10.28.0
COPY package.json pnpm-lock.yaml ./
RUN --mount=type=cache,id=pnpm,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile
COPY . .
# The generated API client (src/client) is committed, so no spec is needed here.
RUN pnpm build

# ---- serve ------------------------------------------------------------------
FROM nginx:alpine
ENV BACKEND_ORIGIN=http://backend:8000 \
    NGINX_RESOLVER=127.0.0.11
COPY nginx.conf /etc/nginx/templates/default.conf.template
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
HEALTHCHECK --interval=10s --timeout=3s --retries=5 \
    CMD wget -qO /dev/null http://127.0.0.1/ || exit 1
