"""Slack notifier for CI/infra alerts. Footer includes Environment/Project tags."""
import json
import os
import re
from datetime import datetime, timezone
import urllib.request


def _post(webhook: str, color: str, title: str, text: str, env_tag: str, project_tag: str, mention: str = ""):
    # The mention stays outside the attachment: an extra line there makes Slack fold the
    # attachment and hide the Runbook line on ALARM messages.
    payload = {
        "attachments": [
            {
                "color": color,
                "title": title,
                "text": text,
                "mrkdwn_in": ["text"],
                "footer": f"tags: Environment={env_tag}, Project={project_tag}",
            }
        ]
    }
    if mention:
        payload["text"] = mention
    req = urllib.request.Request(
        webhook,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return {"status": resp.status}


def handler(event, context):
    webhook = os.environ["SLACK_WEBHOOK_URL"]
    env_tag = os.environ.get("ENV_TAG", "dev")
    project_tag = os.environ.get("PROJECT_TAG", "food-delivery")
    mention = os.environ.get("SLACK_ALERT_TAGS", "")

    color = "danger"
    title = f":warning: Alert [{env_tag}]"
    text = ""

    # SNS (CloudWatch alarm)
    if "Records" in event and event["Records"] and event["Records"][0].get("EventSource") == "aws:sns":
        msg = event["Records"][0]["Sns"].get("Message", "{}")
        try:
            detail = json.loads(msg)
        except Exception:
            detail = {"raw": msg}
        state = detail.get('NewStateValue', 'UNKNOWN')
        state = state if state in ('ALARM', 'OK', 'INSUFFICIENT_DATA') else 'UNKNOWN'
        color = 'good' if state == 'OK' else 'warning' if state == 'INSUFFICIENT_DATA' else 'danger'
        if state == 'OK': mention = ''
        name = str(detail.get('AlarmName', 'unknown'))
        name = name if re.fullmatch(r'[A-Za-z0-9_.:/-]{1,160}', name) else 'unknown'
        title = f"CloudWatch {state} [{env_tag}]"
        text = (
            f"*Project:* `{project_tag}`  *Env:* `{env_tag}`\n"
            f"*Target:* {name}  *State:* {state}\n"
            f"*UTC:* {datetime.now(timezone.utc).isoformat()}\n"
            f"*Severity:* {'resolved' if state == 'OK' else 'warning' if state == 'INSUFFICIENT_DATA' else 'critical'}  *Owner:* project-operator\n"
            f"*Runbook:* observability-triage — inspect the exact CloudWatch alarm."
        )
    else:
        detail = event.get("detail", event)
        source = event.get("source", "aws")
        detail_type = event.get("detail-type", "Alert")
        event_name = ""
        if isinstance(detail, dict):
            event_name = str(detail.get("eventName", ""))

        if "RotationSucceeded" in event_name:
            color = "good"
            mention = ""
            title = f":white_check_mark: Secrets rotation succeeded [{env_tag}]"
        elif source == "aws.secretsmanager":
            title = f":rotating_light: Secrets Manager event [{env_tag}]"
        else:
            title = f":warning: Alert [{env_tag}]"

        text = (
            f"*Project:* `{project_tag}`  *Env:* `{env_tag}`\n"
            f"*Source:* `{source}`  *Type:* {detail_type}\n"
            f"*Event:* {event_name if re.fullmatch(r'[A-Za-z0-9_.-]{0,80}', event_name) else 'unknown'}\n"
            f"*UTC:* {datetime.now(timezone.utc).isoformat()}  *Owner:* project-operator\n"
            f"*Runbook:* secret-rotation"
        )

    return _post(webhook, color, title, text, env_tag, project_tag, mention)
