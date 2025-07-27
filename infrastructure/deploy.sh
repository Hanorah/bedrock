#!/usr/bin/env bash
# deploy.sh - Package and deploy Bedrock Spend Sentinel to AWS
#
# Usage:
#   ./infrastructure/deploy.sh [STACK_NAME] [ALERT_EMAIL] [REGION]
#
# Defaults:
#   STACK_NAME  = bedrock-spend-sentinel
#   ALERT_EMAIL = (required if stack does not already exist)
#   REGION      = us-east-1
#
# Example:
#   ./infrastructure/deploy.sh bedrock-spend-sentinel ops@example.com us-east-1
#
# Prerequisites: AWS CLI v2, Python 3, zip

set -euo pipefail

STACK_NAME="${1:-bedrock-spend-sentinel}"
ALERT_EMAIL="${2:-}"
REGION="${3:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build"

# --------------------------------------------------------------------------
# Validate
# --------------------------------------------------------------------------
if [[ -z "$ALERT_EMAIL" ]]; then
  echo "ERROR: alert email is required as the second argument."
  echo "Usage: $0 [stack-name] <alert-email> [region]"
  exit 1
fi

command -v aws  >/dev/null 2>&1 || { echo "ERROR: AWS CLI not found."; exit 1; }
command -v zip  >/dev/null 2>&1 || { echo "ERROR: zip not found."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found."; exit 1; }

AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
echo "Deploying to account $AWS_ACCOUNT in $REGION as stack '$STACK_NAME'"

# --------------------------------------------------------------------------
# Build Lambda ZIPs
# --------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"

build_zip() {
  local name="$1"
  local src="$2"
  local out="$BUILD_DIR/${name}.zip"
  echo "  Packaging $name ..."
  rm -f "$out"
  (cd "$src" && zip -q "$out" lambda_function.py)
  echo "  -> $out"
}

echo ""
echo "== Building Lambda packages =="
build_zip "proxy"       "$REPO_ROOT/src/proxy"
build_zip "aggregator"  "$REPO_ROOT/src/aggregator"

# --------------------------------------------------------------------------
# S3 bucket for Lambda code (reuse if exists)
# --------------------------------------------------------------------------
BUCKET="bedrock-sentinel-deploy-${AWS_ACCOUNT}-${REGION}"
echo ""
echo "== Ensuring S3 bucket: $BUCKET =="
if ! aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    $([ "$REGION" != "us-east-1" ] && echo "--create-bucket-configuration LocationConstraint=$REGION") \
    --output text > /dev/null
  aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled \
    --region "$REGION"
  aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
    --region "$REGION"
  echo "  Bucket created."
else
  echo "  Bucket already exists."
fi

# --------------------------------------------------------------------------
# Upload ZIPs
# --------------------------------------------------------------------------
TIMESTAMP=$(date +%Y%m%d%H%M%S)
PROXY_KEY="releases/${TIMESTAMP}/proxy.zip"
AGGREGATOR_KEY="releases/${TIMESTAMP}/aggregator.zip"

echo ""
echo "== Uploading Lambda packages =="
aws s3 cp "$BUILD_DIR/proxy.zip"       "s3://$BUCKET/$PROXY_KEY"       --region "$REGION"
aws s3 cp "$BUILD_DIR/aggregator.zip"  "s3://$BUCKET/$AGGREGATOR_KEY"  --region "$REGION"

# --------------------------------------------------------------------------
# Deploy/update CloudFormation stack
# --------------------------------------------------------------------------
BUDGETS_JSON='{"growth":5.0,"platform":10.0}'

echo ""
echo "== Deploying CloudFormation stack =="
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$REPO_ROOT/infrastructure/template.yaml" \
  --parameter-overrides \
      AlertEmail="$ALERT_EMAIL" \
      BudgetsJson="$BUDGETS_JSON" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --no-fail-on-empty-changeset

# --------------------------------------------------------------------------
# Update Lambda code (CloudFormation ZipFile placeholder is replaced here)
# --------------------------------------------------------------------------
echo ""
echo "== Updating Lambda function code =="
aws lambda update-function-code \
  --function-name spend-sentinel-proxy \
  --s3-bucket "$BUCKET" \
  --s3-key "$PROXY_KEY" \
  --region "$REGION" \
  --output text > /dev/null

aws lambda update-function-code \
  --function-name spend-sentinel-aggregator \
  --s3-bucket "$BUCKET" \
  --s3-key "$AGGREGATOR_KEY" \
  --region "$REGION" \
  --output text > /dev/null

echo ""
echo "== Done =="
echo "Stack:         $STACK_NAME"
echo "Region:        $REGION"
echo "Alert email:   $ALERT_EMAIL (check inbox to confirm SNS subscription)"
PROXY_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='ProxyLambdaArn'].OutputValue" \
  --output text \
  --region "$REGION")
echo "Proxy Lambda:  $PROXY_ARN"
echo ""
echo "Invoke the proxy to test:"
echo "  aws lambda invoke --function-name spend-sentinel-proxy \\"
echo "    --payload '{\"team\":\"growth\",\"model_id\":\"us.anthropic.claude-haiku-4-5-20251001-v1:0\",\"messages\":[{\"role\":\"user\",\"content\":[{\"text\":\"Hello\"}]}]}' \\"
echo "    --cli-binary-format raw-in-base64-out /tmp/out.json && cat /tmp/out.json"
