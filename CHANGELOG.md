# Changelog

All notable changes to this project will be documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- CloudFormation template (`infrastructure/template.yaml`) covering all resources: DynamoDB, two Lambda functions, two IAM roles, SNS topic, and EventBridge rule
- One-command deploy script (`infrastructure/deploy.sh`)
- Full setup and troubleshooting guide (`docs/SETUP.md`)
- `CONTRIBUTING.md` and `LICENSE`
- Organized source into `src/proxy/` and `src/aggregator/`
- Images moved to `images/`

## [0.1.0] - 2025-07-20

### Added
- Proxy Lambda (`spend-sentinel-proxy`) — routes Bedrock `converse` calls and logs token usage and estimated cost to DynamoDB
- Aggregator Lambda (`spend-sentinel-aggregator`) — checks 24-hour team spend against configurable budgets and detects hourly spend spikes using a rolling baseline multiplier
- DynamoDB table (`spend-sentinel-usage`) for per-call usage records
- SNS topic (`spend-sentinel-alerts`) for email (and optionally Slack webhook) notifications
- EventBridge rule (`spend-sentinel-schedule`) running every 15 minutes
- Bedrock-drafted alert summaries via `us.anthropic.claude-haiku-4-5-20251001-v1:0`
- Pricing constants for `amazon.nova-micro-v1:0` and `us.anthropic.claude-haiku-4-5-20251001-v1:0`
- End-to-end test with three teams (`growth`, `rise`, `fall`) confirming usage logging and alerting
