#!/usr/bin/env bash
# =============================================================================
# [용도] slack_notify.sh — Slack Incoming Webhook 알림 (CI / ops)
# =============================================================================
# 무엇을 하나:
#   GitHub Actions 등에서 STATUS·TITLE·TEXT를 Slack 채널(봇 메시지)로 POST
#   - 성공: 멘션 없음
#   - 실패: SLACK_ALERT_TAGS (<!here> / <@U…>) 멘션
#   - footer: Environment / Project 태그
#
# 필수 env: SLACK_WEBHOOK_URL  (없으면 skip 후 종료 0)
# 선택 env: SLACK_ALERT_TAGS, ENV_TAG, PROJECT_TAG, STATUS, TITLE, TEXT, RUN_URL
#
# 호출처: .github/workflows/deploy.yml (if: always())
# 참고: 사람 계정이 아니라 Incoming Webhook → 채널 봇으로 표시됨
# =============================================================================
set -euo pipefail

if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
  echo "SLACK_WEBHOOK_URL empty — skip"
  exit 0
fi

STATUS="${STATUS:-unknown}"
ENV_TAG="${ENV_TAG:-dev}"
PROJECT_TAG="${PROJECT_TAG:-food-delivery}"
TITLE="${TITLE:-food_delivery_eks alert}"
TEXT="${TEXT:-}"
RUN_URL="${RUN_URL:-}"
SLACK_ALERT_TAGS="${SLACK_ALERT_TAGS:-}"

COLOR="good"
EMOJI=":white_check_mark:"
MENTION=""
if [[ "$STATUS" != "success" ]]; then
  COLOR="danger"
  EMOJI=":x:"
  MENTION="${SLACK_ALERT_TAGS}"
fi

export COLOR ENV_TAG PROJECT_TAG
export BODY="$(python3 - <<PY
status = """${STATUS}"""
emoji = """${EMOJI}"""
title = """${TITLE}"""
mention = """${MENTION}"""
text = """${TEXT}"""
run_url = """${RUN_URL}"""
env_tag = """${ENV_TAG}"""
project = """${PROJECT_TAG}"""
lines = []
if mention.strip():
    lines.append(mention.strip())
lines.append(f"{emoji} *{title}*")
lines.append(f"*Project:* `{project}`  *Env:* `{env_tag}`  *Status:* `{status}`")
if text.strip():
    lines.append(text.strip())
if run_url.strip():
    lines.append(f"<{run_url}|View run>")
print("\\n".join(lines))
PY
)"

python3 - <<'PY' | curl -sS -X POST -H 'Content-type: application/json' --data @- "$SLACK_WEBHOOK_URL"
import json, os
print(json.dumps({
  "attachments": [{
    "color": os.environ["COLOR"],
    "text": os.environ["BODY"],
    "mrkdwn_in": ["text"],
    "footer": f"tags: Environment={os.environ['ENV_TAG']}, Project={os.environ['PROJECT_TAG']}"
  }]
}))
PY

echo "slack notify sent (status=$STATUS env=$ENV_TAG)"
