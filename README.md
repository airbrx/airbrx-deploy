# Airbrx Deploy-by-Bash

Self-service deployment toolkit for the Airbrx Data Gateway stack. Designed for customer environments where they manage their own AWS infrastructure.

## What Gets Deployed

| Component | Type | Purpose |
|-----------|------|---------|
| `{prefix}-airbrx-api` | Lambda + Function URL | Admin API, configuration management |
| `{prefix}-airbrx-gateway` | Lambda + Function URL | Data proxy, request handling |
| `{prefix}-airbrx-log-summary` | Lambda (internal) | AI-powered log analysis |
| `{prefix}-airbrx-admin-storage` | S3 Bucket | Config, tenant data, PATs |
| `{prefix}-airbrx-gateway-storage` | S3 Bucket | Cache, logs, summaries |
| `{prefix}-airbrx-app` | S3 + CloudFront | Frontend web application |

## Prerequisites

- AWS CloudShell access (or any environment with AWS CLI v2)
- User with deployer role permissions attached
- GitHub PAT with read access to:
  - `airbrx/data-proxy`
  - `airbrx/airbrx-api`
  - `airbrx/app-airbrx-com`
- Node.js 20+
- Descope account (optional, for OAuth)
- Anthropic API key (optional, for AI features)

## Quick Start

### 1. Run the prerequisite script

```bash
./prereq.sh
```

This interactive script will:
- Gather deployment configuration (company name, environment, AWS region)
- Collect required tokens (GitHub PAT) and optional config (Descope, Anthropic)
- Auto-generate secure credentials (JWT secret, God PAT)
- Generate IAM policies for your AWS admin
- Create the deployment config file

### 2. Share IAM policies with your AWS administrator

The script generates policy files in `generated/` that your AWS admin needs to create:

**Lambda Execution Roles** (one per lambda, least-privilege):
- `{prefix}-airbrx-api-role` - S3 access to both buckets + invoke log-summary
- `{prefix}-airbrx-gateway-role` - S3 access to gateway bucket only
- `{prefix}-airbrx-log-summary-role` - S3 access to gateway bucket only

**Deployer Policy** (optional - for EC2/CI deployments, or to document minimum permissions):
- S3 bucket creation and management
- Lambda function management
- CloudFront distribution setup
- IAM role management

### 3. Run the deployment script

After `prereq.sh` completes, you'll be prompted to deploy immediately. Or run manually:

```bash
./deploy.sh generated/{prefix}-config.env
```

The deploy script will:
- Create S3 buckets (admin, gateway, app)
- Create IAM roles for each Lambda
- Clone and build the three Lambda packages
- Deploy Lambdas with Function URLs
- Build and deploy the frontend to S3 + CloudFront
- Upload God PAT and initial tenant configuration
- Run health checks and output all URLs

## Generated Files

After running `prereq.sh`, the `generated/` folder contains:

| File | Purpose |
|------|---------|
| `{prefix}-config.env` | Deployment configuration (sensitive!) |
| `{prefix}-god-pat.json` | Admin API token (uploaded to S3) |
| `{prefix}-lambda-trust-policy.json` | Shared trust policy for lambda roles |
| `{prefix}-airbrx-api-policy.json` | API lambda permissions |
| `{prefix}-airbrx-gateway-policy.json` | Gateway lambda permissions |
| `{prefix}-airbrx-log-summary-policy.json` | Log-summary lambda permissions |
| `{prefix}-deployer-policy.json` | Permissions for deploy.sh executor |

> **Note:** The `generated/` folder is gitignored. Never commit these files.

## Configuration Variables

| Variable | Source | Description |
|----------|--------|-------------|
| `PREFIX` | User input | `{company}-{env}` (e.g., `acme-prod`) |
| `AWS_REGION` | User input | AWS region for deployment |
| `GIT_PAT` | User input | GitHub Personal Access Token |
| `GIT_BRANCH` | Auto (matches prefix) | Git branch to deploy |
| `GOD_PAT` | Auto-generated | Admin API authentication token |
| `JWT_SECRET` | Auto-generated | JWT signing key (64 hex chars) |
| `DESCOPE_PROJECT_ID` | User input (optional) | OAuth provider project ID |
| `ANTHROPIC_API_KEY` | User input (optional) | For AI-powered log analysis |
| `SLACK_WEBHOOK` | User input (optional) | Deployment notifications |

## Architecture

```
                                    ┌─────────────────────┐
                                    │   CloudFront CDN    │
                                    │  (Frontend App)     │
                                    └──────────┬──────────┘
                                               │
┌──────────────────────────────────────────────┼──────────────────────────────────────────────┐
│                                              │                                    AWS       │
│  ┌─────────────────────┐    ┌────────────────┴───────────────┐    ┌─────────────────────┐  │
│  │  S3: admin-storage  │◄───│      Lambda: airbrx-api        │───►│  S3: gateway-storage│  │
│  │  - tenant configs   │    │      (Function URL)            │    │  - cache            │  │
│  │  - PATs             │    └────────────────┬───────────────┘    │  - logs             │  │
│  └─────────────────────┘                     │                    │  - summaries        │  │
│                                              │ invoke             └──────────┬──────────┘  │
│                                              ▼                               │             │
│                              ┌───────────────────────────────┐               │             │
│                              │   Lambda: airbrx-log-summary  │───────────────┘             │
│                              │   (internal, no URL)          │                             │
│                              └───────────────────────────────┘                             │
│                                                                                            │
│  ┌───────────────────────────────────────┐                                                 │
│  │      Lambda: airbrx-gateway           │◄─── External clients (Snowflake, etc.)         │
│  │      (Function URL)                   │                                                 │
│  └───────────────────────────────────────┘                                                 │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

## Deployment Phases

1. **Setup & Validation** - Parse config, verify AWS access, check Node.js
2. **S3 Buckets** - Create storage buckets with appropriate policies
3. **IAM Roles** - Create/verify lambda execution roles
4. **Clone & Build** - Pull repos, install dependencies, create deployment packages
5. **Deploy Lambdas** - Create/update lambdas with Function URLs
6. **Deploy Frontend** - Build app with API URL, deploy to S3 + CloudFront
7. **Initial Config** - Upload God PAT, create initial tenant config
8. **Validation** - Health checks on all endpoints, generate deployment report

## Sample Files

The `samples/` folder contains template configuration files:

- `conf.json` - Tenant configuration template
- `rules.json` - Caching rules template

These are populated with actual values during deployment and uploaded to S3.

## Security Notes

- IAM roles follow least-privilege principle (separate role per lambda)
- No AWS keys in code - uses CloudShell session credentials and IAM roles for Lambda
- God PAT is auto-generated with cryptographically secure randomness
- JWT secret is auto-generated (64 hex characters)
- All sensitive files in `generated/` are gitignored
- Config files have restricted permissions (600)

## Source Repositories

| Repo | Contents |
|------|----------|
| `airbrx/data-proxy` | Gateway lambda (`airbrx-proxy/`) |
| `airbrx/airbrx-api` | API lambda (`api/`) and Log Summary (`log-summary-v2/`) |
| `airbrx/app-airbrx-com` | Frontend application |

## License

Proprietary - Airbrx Inc.
