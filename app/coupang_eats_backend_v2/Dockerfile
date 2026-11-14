# -------------------------------------------------------------
# 1. Build Stage (TypeScript 컴파일 & 네이티브 모듈 빌드)
# -------------------------------------------------------------
    FROM node:24.22.0-alpine AS builder

    # bcrypt 등 C++ 네이티브 모듈 빌드 툴체인
    RUN apk add --no-cache python3 make g++

    WORKDIR /app

    COPY package*.json ./
    RUN npm ci

    COPY . .
    # NestJS 빌드 (dist/src/main.js 생성)
    RUN npm run build

    # 프로덕션 전용 라이브러리만 남기고 devDependencies 즉시 정리
    RUN npm prune --omit=dev --omit=optional
    # Runtime needs JS, not compiler metadata or application source maps.
    RUN find dist -type f \( -name "*.map" -o -name "*.d.ts" -o -name "*.tsbuildinfo" \) -delete

    # -------------------------------------------------------------
    # 2. Production Stage (경량화 런타임)
    # -------------------------------------------------------------
    FROM node:24.22.0-alpine AS runner
ARG SOURCE_SHA=unknown
ENV DEPLOYMENT_VERSION=$SOURCE_SHA

    WORKDIR /app

    ENV NODE_ENV=production
    ENV PORT=3000

    # RDS Proxy TLS 검증용 CA 및 SIGTERM 정상 전파용 dumb-init 설치
    # (python3, make, g++는 더 이상 필요 없음!)
    RUN apk add --no-cache ca-certificates dumb-init && \
        rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx

    # 보안 통제: node 비루트 사용자 사용
    USER node

    # 빌더 스테이지에서 경량화 완료된 node_modules와 빌드 결과물만 복사
    COPY --chown=node:node --from=builder /app/node_modules ./node_modules
    COPY --chown=node:node --from=builder /app/dist ./dist
    COPY --chown=node:node --from=builder /app/package*.json ./

    EXPOSE 3000

    # dumb-init이 PID 1을 점유하여 K8s의 정지 시그널을 node 프로세스에 정확히 전파
    ENTRYPOINT ["dumb-init", "--"]

    # [권장] 멀티 파드 충돌을 피하기 위해 앱 실행을 기본 CMD로 설정
    # 마이그레이션은 Phase 3의 K8s Job / InitContainer로 분리 실행 권장
    CMD ["node", "dist/src/main.js"]
