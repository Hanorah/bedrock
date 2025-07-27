# Setup Guide

This guide walks you through deploying Bedrock Spend Sentinel from scratch in your AWS account. The whole stack — two Lambda functions, a DynamoDB table, an SNS topic, and an EventBridge rule — deploys in under five minutes.

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| AWS CLI | v2.x | [Install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| Python | 3.10+ | For local testing only; Lambda runtime is Python 3.12 |
| zip | any | Packaged with macOS/Linux; Windows: use WSL |
| AWS credentials | — | Must have the permissions listed below |

### Required IAM permissions for the deploying principal

The identity you deploy with needs to be able to create and manage:
- CloudFormation stacks
- IAM roles and policies
- Lambda functions
- DynamoDB tables
- SNS topics and subscriptions
- EventBridge rules
- S3 buckets (for the deployment bucket)

A simple way to satisfy this during initial setup is `AdministratorAccess`. For production environments, scope the deploying role down to the exact actions above.

### Bedrock model access

The proxy Lambda and the aggregator both call Bedrock. You need to enable model access in the AWS Console before deploying:

1. Open the [Amazon Bedrock console](https://console.aws.amazon.com/bedrock).
2. Choose **Model access** in the left navigation.
3. Enable at minimum:
   - `Anthropic / Claude Haiku` (used by the aggregator for alert summaries)
   - Any model your teams want to route through the proxy (e.g. `Amazon Nova Micro`)
4. Wait for access to become **Active** (usually under a minute).

---

## Quick deploy (automated)

The `deploy.sh` script handles packaging, S3 upload, and CloudFormation in one command.

```bash
# Clone and enter the repo
git clone https://github.com/<your-org>/bedrock-spend-sentinel.git
cd bedrock-spend-sentinel

# Deploy (replace with a real email address)
./infrastructure/deploy.sh bedrock-spend-sentinel ops@example.com us-east-1
```

**After deploy:**

1. Check your inbox for an SNS subscription confirmation email and click **Confirm subscription** — alerts will not arrive until you do.
2. Invoke the proxy once to verify end-to-end wiring (the script prints the exact command).

---

## Manual deploy (step by step)

Use this path if you want full control or are deploying via CI/CD.

### Step 1 — Package the Lambda functions

```bash
cd src/proxy
zip ../../.build/proxy.zip lambda_function.py
cd -

cd src/aggregator
zip ../../.build/aggregator.zip lambda_function.py
cd -
```

### Step 2 — Create an S3 bucket for deployment artifacts

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
BUCKET="bedrock-sentinel-deploy-${ACCOUNT}-${REGION}"

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

### Step 3 — Upload the ZIPs

```bash
aws s3 cp .build/proxy.zip       "s3://$BUCKET/proxy.zip"
aws s3 cp .build/aggregator.zip  "s3://$BUCKET/aggregator.zip"
```

### Step 4 — Deploy the CloudFormation stack

```bash
aws cloudformation deploy \
  --stack-name bedrock-spend-sentinel \
  --template-file infrastructure/template.yaml \
  --parameter-overrides \
      AlertEmail="ops@example.com" \
      BudgetsJson='{"growth":5.0,"platform":10.0}' \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION"
```

### Step 5 — Push the real Lambda code

The CloudFormation template uses an inline placeholder. Replace it:

```bash
aws lambda update-function-code \
  --function-name spend-sentinel-proxy \
  --s3-bucket "$BUCKET" --s3-key proxy.zip

aws lambda update-function-code \
  --function-name spend-sentinel-aggregator \
  --s3-bucket "$BUCKET" --s3-key aggregator.zip
```

---

## Configuration

All runtime configuration is via Lambda environment variables. You can change these in the AWS Console or by redeploying the stack with updated parameters.

### Proxy Lambda (`spend-sentinel-proxy`)

| Variable | Description | Default |
|---|---|---|
| `USAGE_TABLE_NAME` | DynamoDB table name | Set by CloudFormation |

**Hardcoded pricing** — `src/proxy/lambda_function.py` contains a `PRICING_PER_1K_TOKENS` dict. Update it when AWS publishes pricing changes. The [Bedrock pricing page](https://aws.amazon.com/bedrock/pricing/) is the authoritative source.

### Aggregator Lambda (`spend-sentinel-aggregator`)

| Variable | Description | Default |
|---|---|---|
| `USAGE_TABLE_NAME` | DynamoDB table name | Set by CloudFormation |
| `ALERT_TOPIC_ARN` | SNS topic ARN | Set by CloudFormation |
| `SUMMARY_MODEL_ID` | Bedrock model for alert drafts | `us.anthropic.claude-haiku-4-5-20251001-v1:0` |
| `BUDGETS_USD_24H` | JSON map of team to 24h budget in USD | `{"default": 5.0}` |
| `ANOMALY_MULTIPLIER` | Multiple of hourly baseline that triggers a spike alert | `1.5` |

**Changing a team budget** — edit `BUDGETS_USD_24H` in the aggregator's environment variables and save. No code change or redeploy needed (this is a known limitation noted in the README; a future version will move budgets to DynamoDB).

---

## Testing the deployment

### 1. Send a test request through the proxy

```bash
aws lambda invoke \
  --function-name spend-sentinel-proxy \
  --payload '{"team":"growth","model_id":"us.anthropic.claude-haiku-4-5-20251001-v1:0","messages":[{"role":"user","content":[{"text":"Say hello in one word."}]}]}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/sentinel-out.json

cat /tmp/sentinel-out.json
```

Expected response shape:

```json
{
  "output_text": "Hello!",
  "estimated_cost_usd": 0.000038
}
```

### 2. Verify the DynamoDB record

```bash
aws dynamodb query \
  --table-name spend-sentinel-usage \
  --key-condition-expression "#t = :team" \
  --expression-attribute-names '{"#t":"team"}' \
  --expression-attribute-values '{":team":{"S":"growth"}}' \
  --scan-index-forward false \
  --limit 1
```

### 3. Trigger the aggregator manually

```bash
aws lambda invoke \
  --function-name spend-sentinel-aggregator \
  --payload '{}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/aggregator-out.json

cat /tmp/aggregator-out.json
# {"alerts_sent": 0}  <- expected when spend is below budget and baseline
```

To force an alert without real spend, temporarily lower `BUDGETS_USD_24H` to `{"growth": 0.000001}` in the aggregator environment variables, invoke it, then restore the original value.

---

## Tearing down

To remove all resources and avoid ongoing charges:

```bash
aws cloudformation delete-stack --stack-name bedrock-spend-sentinel --region us-east-1
```

The deployment S3 bucket is not managed by the stack and must be emptied and deleted separately if you no longer need it:

```bash
aws s3 rm "s3://$BUCKET" --recursive
aws s3api delete-bucket --bucket "$BUCKET"
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Proxy returns `ResourceNotFoundException` | `USAGE_TABLE_NAME` env var is wrong or table doesn't exist yet | Check CloudFormation stack status; verify env var matches table name |
| Aggregator returns `AccessDeniedException` on Bedrock | Model access not enabled | Enable the model in the Bedrock console (see Prerequisites) |
| No alert emails received | SNS subscription not confirmed | Check inbox including spam; re-send confirmation from SNS console |
| `ValidationException` from Bedrock | Model ID typo or wrong region | Cross-region inference profiles require the `us.` prefix; verify the model ID |
| CloudFormation deploy fails with `ROLLBACK_COMPLETE` | Parameter or permission error | Check the Events tab in the CloudFormation console for the root cause |
