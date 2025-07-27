# Contributing

Thanks for your interest in contributing to Bedrock Spend Sentinel.

## Getting started

1. Fork the repository and create your branch from `main`.
2. Make your changes in `src/proxy/` or `src/aggregator/`.
3. Test the change against a real AWS account (see [docs/SETUP.md](./docs/SETUP.md)).
4. Open a pull request with a clear description of what changed and why.

## What to work on

Check [Known limitations](./README.md#known-limitations) and [Possible next steps](./README.md#possible-next-steps) in the README for ideas. Issues are also a good place to start.

## Code style

- Python: follow PEP 8. Keep functions small and focused.
- Keep dependencies to the AWS SDK (`boto3`) only — no third-party packages. Lambda cold starts matter.
- Pricing constants in `src/proxy/lambda_function.py` must match the [Bedrock pricing page](https://aws.amazon.com/bedrock/pricing/). Include a comment with the date you last verified them.

## Changing infrastructure

Infrastructure changes go in `infrastructure/template.yaml`. Run a CloudFormation change-set preview before including it in a PR:

```bash
aws cloudformation deploy \
  --stack-name bedrock-spend-sentinel-pr-preview \
  --template-file infrastructure/template.yaml \
  --parameter-overrides AlertEmail="test@example.com" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-execute-changeset
```

## Pull request checklist

- [ ] Tested end-to-end in a real AWS account
- [ ] Pricing constants updated and dated (if changed)
- [ ] CloudFormation change-set reviewed (if infrastructure changed)
- [ ] README / SETUP.md updated if behaviour or config changed

## Reporting issues

Open a GitHub issue with:
- What you were trying to do
- What happened
- The relevant Lambda log output (CloudWatch Logs) or CloudFormation event
- Your AWS region and the model IDs involved
