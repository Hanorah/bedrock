import boto3
import os
import json
from datetime import datetime, timedelta, timezone
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["USAGE_TABLE_NAME"])
sns = boto3.client("sns")
bedrock = boto3.client("bedrock-runtime")

TOPIC_ARN = os.environ["ALERT_TOPIC_ARN"]
SUMMARY_MODEL_ID = os.environ.get("SUMMARY_MODEL_ID", "amazon.nova-micro-v1:0")
BUDGETS_USD_24H = json.loads(os.environ["BUDGETS_USD_24H"])  # {"growth": 5.0, "platform": 10.0}
ANOMALY_MULTIPLIER = float(os.environ.get("ANOMALY_MULTIPLIER", "1.5"))

def get_team_spend(team, hours):
    cutoff = str(int((datetime.now(timezone.utc) - timedelta(hours=hours)).timestamp() * 1000))
    resp = table.query(
        KeyConditionExpression=Key("team").eq(team) & Key("sort_key").gte(cutoff)
    )
    return sum(float(item["estimated_cost_usd"]) for item in resp["Items"])

def draft_summary(alert):
    prompt = (
        f"Team {alert['team']} has spent ${alert['spend_24h']} on Bedrock in the last 24 hours "
        f"against a budget of ${alert['budget']}. In the last hour they spent ${alert['spend_1h']}, "
        f"versus a rolling hourly baseline of ${alert['baseline_hourly']}. "
        "Write a 2 to 3 sentence plain English alert for a finance or engineering lead, "
        "stating whether this is a budget overage, a spend spike, or both, in a neutral factual tone."
    )
    response = bedrock.converse(
        modelId=SUMMARY_MODEL_ID,
        messages=[{"role": "user", "content": [{"text": prompt}]}],
    )
    return response["output"]["message"]["content"][0]["text"]

def lambda_handler(event, context):
    alerts_sent = 0
    for team, budget in BUDGETS_USD_24H.items():
        spend_24h = get_team_spend(team, 24)
        spend_1h = get_team_spend(team, 1)
        baseline_hourly = spend_24h / 24 if spend_24h else 0

        over_budget = spend_24h > budget
        spend_spike = baseline_hourly > 0 and spend_1h > baseline_hourly * ANOMALY_MULTIPLIER

        if not (over_budget or spend_spike):
            continue

        alert = {
            "team": team,
            "spend_24h": round(spend_24h, 4),
            "budget": budget,
            "spend_1h": round(spend_1h, 4),
            "baseline_hourly": round(baseline_hourly, 4),
        }
        summary = draft_summary(alert)
        sns.publish(
            TopicArn=TOPIC_ARN,
            Subject=f"Bedrock spend alert: {team}",
            Message=summary,
        )
        alerts_sent += 1

    return {"alerts_sent": alerts_sent}
