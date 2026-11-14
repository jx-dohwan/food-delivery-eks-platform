# -------------------------------------------------------------
# 1. Build Stage (Vite SPA 빌드)
# -------------------------------------------------------------
    FROM node:24.22.0-alpine AS builder
    WORKDIR /app

    COPY package*.json ./
    RUN npm ci

    COPY . .
    RUN npm run build

    # -------------------------------------------------------------
    # 2. Production Stage (Nginx Web Tier)
    # -------------------------------------------------------------
    FROM nginx:1.30.6-alpine@sha256:970364228b1e4f932abc22d321932816782cca8a20b85a77552a7cfe9acfb3b5
    STOPSIGNAL SIGQUIT
    # Security fixes newer than the pinned base image (CVE-2026-77214 / CVE-2026-88806).
    # Minimum versions, not exact pins: Alpine drops superseded builds (libexpat 2.9.0-r0 -> 2.10.0-r0).
    RUN apk add --no-cache 'libexpat>=2.9.0-r0' 'libx11>=1.8.14-r0' 'brotli-libs>=1.2.1-r0' 'curl>=8.23.0-r0' 'libcurl>=8.23.0-r0'
    WORKDIR /usr/share/nginx/html

    # 기본 설정 파일 정리
    RUN rm -rf /etc/nginx/conf.d/*
    # This directive belongs to the main context, not conf.d's http context.
    RUN sed -i '/worker_processes/a worker_shutdown_timeout 30s;' /etc/nginx/nginx.conf && \
        grep -q '^worker_shutdown_timeout 30s;' /etc/nginx/nginx.conf

    # 정적 산출물 및 Nginx 커스텀 설정 복사
    COPY --from=builder /app/dist /usr/share/nginx/html
    COPY nginx/default.conf /etc/nginx/conf.d/default.conf
    ARG SOURCE_SHA=unknown
    RUN printf '%s' "$SOURCE_SHA" | grep -Eq '^(unknown|[a-f0-9]{40})$' && \
        sed -i "s/default \"unknown\";/default \"${SOURCE_SHA}\";/" /etc/nginx/conf.d/default.conf
    COPY nginx/50x.html /usr/share/nginx/html/50x.html
    COPY public/errors/ /usr/share/nginx/html/errors/

    # 빌드 산출물 무결성 검증 (없으면 빌드 실패)
    RUN test -f /usr/share/nginx/html/index.html

    # [보안 통제] Nginx 캐시 및 PID 파일 권한을 nginx 사용자에게 부여
    RUN touch /var/run/nginx.pid && \
        chown -R nginx:nginx /var/run/nginx.pid /var/cache/nginx /usr/share/nginx/html

    USER nginx

    EXPOSE 80

    CMD ["nginx", "-g", "daemon off;"]
