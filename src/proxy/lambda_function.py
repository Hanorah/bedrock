import boto3
import time
import uuid
import os
from decimal import Decimal

bedrock = boto3.client("bedrock-runtime")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["USAGE_TABLE_NAME"])

# Approximate on demand pricing per 1,000 tokens, us-east-1.
# Check the Bedrock pricing page before you rely on these for anything real,
# prices change and vary by region.
PRICING_PER_1K_TOKENS = {
    "amazon.nova-micro-v1:0": {"input": 0.000035, "output": 0.00014},
    "us.anthropic.claude-haiku-4-5-20251001-v1:0": {"input": 0.0008, "output": 0.004},
}

def estimate_cost(model_id, input_tokens, output_tokens):
    prices = PRICING_PER_1K_TOKENS.get(model_id, {"input": 0, "output": 0})
    return (input_tokens / 1000 * prices["input"]) + (output_tokens / 1000 * prices["output"])

def lambda_handler(event, context):
    team = event["team"]
    model_id = event["model_id"]
    messages = event["messages"]  # Bedrock converse message format

    response = bedrock.converse(modelId=model_id, messages=messages)

    usage = response["usage"]
    input_tokens = usage["inputTokens"]
    output_tokens = usage["outputTokens"]
    cost = estimate_cost(model_id, input_tokens, output_tokens)

    table.put_item(Item={
        "team": team,
        "sort_key": f"{int(time.time() * 1000)}#{uuid.uuid4().hex[:8]}",
        "model_id": model_id,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "estimated_cost_usd": Decimal(str(round(cost, 6))),
    })

    return {
        "output_text": response["output"]["message"]["content"][0]["text"],
        "estimated_cost_usd": round(cost, 6),
    }
