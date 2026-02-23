#!/bin/bash
#
# deploy.sh - Airbrx Data Gateway Deployment Script
#
# Deploys the full Airbrx stack: 3 Lambdas, 3 S3 buckets, CloudFront
# Designed to run in AWS CloudShell after prereq.sh generates config
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_step() {
    echo -e "${GREEN}▶${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

die() {
    print_error "$1"
    exit 1
}

#------------------------------------------------------------------------------
# Intro
#------------------------------------------------------------------------------

echo ""
echo "  +=========================  "
echo "  =========================== "
echo " ===========      -========== "
echo " ==========.      .========== "
echo " =========:   ..  .:========= "
echo " ========-   .--.:=-:======== "
echo " ========.   .==.   .======== "
echo " =======.   .----.   .======= "
echo " ======:              :====== "
echo " =====-.   .::::::.    -===== "
echo " =====.   .========.   .===== "
echo " ============================ "
echo "  =========================== "
echo "  ==========================  "
echo ""
echo "        A I R B R X"
echo "     Data Gateway Deploy"
echo ""
echo "─────────────────────────────────────────────────────────────────"
echo ""
echo "This script deploys the full Airbrx Data Gateway stack:"
echo ""
echo "  • S3 Buckets         - Admin storage, gateway storage, app hosting"
echo "  • IAM Roles          - Least-privilege roles for each Lambda"
echo "  • API Lambda         - Admin and configuration endpoints"
echo "  • Gateway Lambda     - Data proxy and request handling"
echo "  • Log Summary Lambda - AI-powered analytics and log aggregation"
echo "  • CloudFront         - CDN for frontend application"
echo ""
echo "Deployment phases:"
echo "  1. Load & validate configuration"
echo "  2. Verify AWS access"
echo "  3. Check Node.js 20+"
echo "  4. Create S3 buckets"
echo "  5. Create IAM roles"
echo "  6. Clone repositories"
echo "  7. Build Lambda packages"
echo "  8. Deploy Lambdas with Function URLs"
echo "  9. Build & deploy frontend to CloudFront"
echo "  10. Upload initial configuration"
echo "  11. Validate & generate report"
echo ""
echo "─────────────────────────────────────────────────────────────────"
echo ""
read -p "Press Enter to begin deployment..."
echo ""

#------------------------------------------------------------------------------
# Phase 1: Load Configuration & Validate
#------------------------------------------------------------------------------

print_header "Phase 1: Loading Configuration"

CONFIG_FILE="${1:-}"
if [[ -z "$CONFIG_FILE" ]]; then
    # Look for configs in generated folder
    CONFIG_FILES=(generated/*-config.env)
    if [[ ! -e "${CONFIG_FILES[0]}" ]]; then
        die "No config files found. Run prereq.sh first."
    elif [[ ${#CONFIG_FILES[@]} -eq 1 ]]; then
        CONFIG_FILE="${CONFIG_FILES[0]}"
        print_step "Using config: $CONFIG_FILE"
    else
        echo "Multiple config files found:"
        echo ""
        for i in "${!CONFIG_FILES[@]}"; do
            echo "  $((i+1))) ${CONFIG_FILES[$i]}"
        done
        echo ""
        read -p "Select config [1-${#CONFIG_FILES[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#CONFIG_FILES[@]} ]]; then
            CONFIG_FILE="${CONFIG_FILES[$((choice-1))]}"
        else
            die "Invalid selection"
        fi
    fi
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    die "Config file not found: $CONFIG_FILE"
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Validate required variables
for var in PREFIX AWS_REGION GIT_PAT GIT_BRANCH GOD_PAT JWT_SECRET; do
    if [[ -z "${!var}" ]]; then
        die "Missing required variable: $var"
    fi
done

print_success "Loaded configuration for: $PREFIX"
print_step "Region: $AWS_REGION"
print_step "Git branch: $GIT_BRANCH"

# Derive paths (use absolute paths to survive cd)
GENERATED_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"
GOD_PAT_FILE="$GENERATED_DIR/${PREFIX}-god-pat.json"

if [[ ! -f "$GOD_PAT_FILE" ]]; then
    die "God PAT file not found: $GOD_PAT_FILE"
fi

#------------------------------------------------------------------------------
# Phase 2: Verify AWS Access
#------------------------------------------------------------------------------

print_header "Phase 2: Verifying AWS Access"

if ! command -v aws &> /dev/null; then
    die "AWS CLI not found. Please install AWS CLI v2."
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || die "AWS CLI not configured or no access"
AWS_IDENTITY=$(aws sts get-caller-identity --query Arn --output text)

print_success "AWS Account: $AWS_ACCOUNT_ID"
print_step "Identity: $AWS_IDENTITY"

#------------------------------------------------------------------------------
# Phase 3: Check Node.js
#------------------------------------------------------------------------------

print_header "Phase 3: Checking Node.js"

if ! command -v node &> /dev/null; then
    die "Node.js not found. Please install Node.js 20+"
fi

NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
if [[ "$NODE_VERSION" -lt 20 ]]; then
    die "Node.js 20+ required. Found: $(node -v)"
fi

print_success "Node.js $(node -v)"

#------------------------------------------------------------------------------
# Phase 4: Create S3 Buckets
#------------------------------------------------------------------------------

print_header "Phase 4: Creating S3 Buckets"

create_bucket() {
    local bucket_name="$1"
    local enable_website="${2:-false}"

    if aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
        print_step "Bucket exists: $bucket_name"
    else
        print_step "Creating bucket: $bucket_name"
        if [[ "$AWS_REGION" == "us-east-1" ]]; then
            aws s3api create-bucket --bucket "$bucket_name" --region "$AWS_REGION"
        else
            aws s3api create-bucket --bucket "$bucket_name" --region "$AWS_REGION" \
                --create-bucket-configuration LocationConstraint="$AWS_REGION"
        fi
    fi

    # Block public access (except for app bucket if website enabled)
    if [[ "$enable_website" != "true" ]]; then
        aws s3api put-public-access-block --bucket "$bucket_name" \
            --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    fi

    # Enable versioning
    aws s3api put-bucket-versioning --bucket "$bucket_name" \
        --versioning-configuration Status=Enabled

    print_success "Configured: $bucket_name"
}

ADMIN_BUCKET="${PREFIX}-airbrx-admin-storage"
GATEWAY_BUCKET="${PREFIX}-airbrx-gateway-storage"
APP_BUCKET="${PREFIX}-airbrx-app"

create_bucket "$ADMIN_BUCKET"
create_bucket "$GATEWAY_BUCKET"
create_bucket "$APP_BUCKET" "true"

#------------------------------------------------------------------------------
# Phase 5: Create IAM Roles
#------------------------------------------------------------------------------

print_header "Phase 5: Creating IAM Roles"

TRUST_POLICY_FILE="$GENERATED_DIR/${PREFIX}-lambda-trust-policy.json"

create_lambda_role() {
    local role_name="$1"
    local policy_file="$2"

    if aws iam get-role --role-name "$role_name" &>/dev/null; then
        print_step "Role exists: $role_name"
    else
        print_step "Creating role: $role_name"
        aws iam create-role --role-name "$role_name" \
            --assume-role-policy-document "file://$TRUST_POLICY_FILE" \
            --description "Airbrx Lambda execution role"
    fi

    # Attach/update inline policy
    local policy_name="${role_name}-policy"
    aws iam put-role-policy --role-name "$role_name" \
        --policy-name "$policy_name" \
        --policy-document "file://$policy_file"

    print_success "Configured: $role_name"
}

API_ROLE="${PREFIX}-airbrx-api-role"
GATEWAY_ROLE="${PREFIX}-airbrx-gateway-role"
LOGSUMMARY_ROLE="${PREFIX}-airbrx-log-summary-role"

create_lambda_role "$API_ROLE" "$GENERATED_DIR/${PREFIX}-airbrx-api-policy.json"
create_lambda_role "$GATEWAY_ROLE" "$GENERATED_DIR/${PREFIX}-airbrx-gateway-policy.json"
create_lambda_role "$LOGSUMMARY_ROLE" "$GENERATED_DIR/${PREFIX}-airbrx-log-summary-policy.json"

# Wait for roles to propagate
print_step "Waiting for IAM roles to propagate..."
sleep 10

#------------------------------------------------------------------------------
# Phase 6: Clone Repositories
#------------------------------------------------------------------------------

print_header "Phase 6: Cloning Repositories"

WORK_DIR="/tmp/airbrx-deploy-$$"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

clone_repo() {
    local repo="$1"
    local target="$2"

    if [[ -d "$target" ]]; then
        print_step "Already cloned: $target"
    else
        print_step "Cloning: $repo -> $target"
        git clone --depth 1 --branch "$GIT_BRANCH" \
            "https://${GIT_PAT}@github.com/airbrx/${repo}.git" "$target"
    fi
    print_success "Ready: $target"
}

clone_repo "data-proxy" "data-proxy"
clone_repo "airbrx-api" "airbrx-api"
clone_repo "app-airbrx-com" "app-airbrx-com"

#------------------------------------------------------------------------------
# Phase 7: Build Lambda Packages
#------------------------------------------------------------------------------

print_header "Phase 7: Building Lambda Packages"

build_lambda() {
    local name="$1"
    local src_dir="$2"
    local zip_file="$3"

    print_step "Building: $name"
    (
        cd "$src_dir"
        npm install --omit=dev
        zip -rq "$zip_file" . -x "*.git*"
    )
    print_success "Built: $zip_file ($(du -h "$zip_file" | cut -f1))"
}

# Build API
build_lambda "api" "$WORK_DIR/airbrx-api/api" "$WORK_DIR/api.zip"

# Build Gateway
build_lambda "gateway" "$WORK_DIR/data-proxy/airbrx-proxy" "$WORK_DIR/gateway.zip"

# Build Log Summary
build_lambda "log-summary" "$WORK_DIR/airbrx-api/log-summary-v2" "$WORK_DIR/log-summary.zip"

#------------------------------------------------------------------------------
# Phase 8: Deploy Lambdas
#------------------------------------------------------------------------------

print_header "Phase 8: Deploying Lambdas"

deploy_lambda() {
    local func_name="$1"
    local role_arn="$2"
    local handler="$3"
    local zip_file="$4"
    local memory="$5"
    local timeout="$6"
    local env_json="$7"
    local create_url="${8:-false}"

    if aws lambda get-function --function-name "$func_name" &>/dev/null; then
        echo -e "${GREEN}▶${NC} Updating: $func_name" >&2
        aws lambda update-function-code --function-name "$func_name" \
            --zip-file "fileb://$zip_file" > /dev/null

        # Wait for update to complete
        aws lambda wait function-updated --function-name "$func_name"

        aws lambda update-function-configuration --function-name "$func_name" \
            --runtime nodejs20.x \
            --handler "$handler" \
            --memory-size "$memory" \
            --timeout "$timeout" \
            --environment "$env_json" > /dev/null
    else
        echo -e "${GREEN}▶${NC} Creating: $func_name" >&2
        aws lambda create-function --function-name "$func_name" \
            --runtime nodejs20.x \
            --role "$role_arn" \
            --handler "$handler" \
            --zip-file "fileb://$zip_file" \
            --memory-size "$memory" \
            --timeout "$timeout" \
            --environment "$env_json" > /dev/null
    fi

    # Wait for function to be active
    aws lambda wait function-active --function-name "$func_name"

    # Create function URL if requested (NONE auth - Lambda handles auth via JWT)
    if [[ "$create_url" == "true" ]]; then
        # Create or update URL with NONE auth (matches production pattern)
        if ! aws lambda get-function-url-config --function-name "$func_name" &>/dev/null; then
            aws lambda create-function-url-config --function-name "$func_name" \
                --auth-type NONE > /dev/null
            # Allow public access to function URL
            aws lambda add-permission --function-name "$func_name" \
                --statement-id "FunctionURLAllowPublicAccess" \
                --action lambda:InvokeFunctionUrl \
                --principal "*" \
                --function-url-auth-type NONE >/dev/null 2>&1 || true
        fi

        local url=$(aws lambda get-function-url-config --function-name "$func_name" \
            --query 'FunctionUrl' --output text)
        echo -e "${GREEN}✓${NC} Deployed: $func_name -> $url" >&2
        echo "$url"
    else
        echo -e "${GREEN}✓${NC} Deployed: $func_name" >&2
    fi
}

# Helper function to build environment JSON (handles optional vars properly)
build_env_json() {
    local json='{"Variables":{'
    local first=true

    while [[ $# -gt 0 ]]; do
        local key="$1"
        local value="$2"
        shift 2

        # Skip empty values or placeholder values
        if [[ -n "$value" && "$value" != "DESCOPE_NOT_CONFIGURED" && "$value" != "ANTHROPIC_NOT_CONFIGURED" ]]; then
            if [[ "$first" != "true" ]]; then
                json+=','
            fi
            # Escape special characters in value
            value=$(echo "$value" | sed 's/\\/\\\\/g; s/"/\\"/g')
            json+="\"$key\":\"$value\""
            first=false
        fi
    done

    json+='}}'
    echo "$json"
}

# Deploy API Lambda
API_FUNC="${PREFIX}-airbrx-api"
API_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${API_ROLE}"
API_ENV=$(build_env_json \
    "NODE_ENV" "production" \
    "AIRBRX_ENV" "${PREFIX#*-}" \
    "AIRBRX_LOG_DISK" "false" \
    "AIRBRX_S3_BUCKET" "${GATEWAY_BUCKET}" \
    "AWS_ADMIN_BUCKET" "${ADMIN_BUCKET}" \
    "AWS_ADMIN_REGION" "${AWS_REGION}" \
    "AIRBRX_CONFIG_STORAGE_TYPE" "s3" \
    "LOG_SUMMARY_LAMBDA_ARN" "${PREFIX}-airbrx-log-summary" \
    "AIRBRX_JWT_SECRET" "${JWT_SECRET}" \
    "AIRBRX_JWT_EXPIRY" "7d" \
    "AIRBRX_JWT_ISSUER" "airbrx.com" \
    "DESCOPE_PROJECT_ID" "${DESCOPE_PROJECT_ID:-}" \
    "ANTHROPIC_API_KEY" "${ANTHROPIC_API_KEY:-}" \
    "SLACK_WEBHOOK" "${SLACK_WEBHOOK:-}" \
)

API_URL=$(deploy_lambda "$API_FUNC" "$API_ROLE_ARN" "reportingapi.handler" \
    "$WORK_DIR/api.zip" 512 30 "$API_ENV" "true")

# Deploy Gateway Lambda
GATEWAY_FUNC="${PREFIX}-airbrx-gateway"
GATEWAY_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${GATEWAY_ROLE}"
GATEWAY_ENV=$(build_env_json \
    "AWS_S3_BUCKET" "${GATEWAY_BUCKET}" \
    "AIRBRX_CONFIG_STORAGE_TYPE" "s3" \
    "AIRBRX_CONFIG_API_URL" "${API_URL}" \
    "AIRBRX_CONFIG_API_TOKEN" "${GOD_PAT}" \
    "AIRBRX_LOG_LEVEL" "info" \
)

GATEWAY_URL=$(deploy_lambda "$GATEWAY_FUNC" "$GATEWAY_ROLE_ARN" "data-proxy.handler" \
    "$WORK_DIR/gateway.zip" 1024 60 "$GATEWAY_ENV" "true")

# Deploy Log Summary Lambda (no URL)
LOGSUMMARY_FUNC="${PREFIX}-airbrx-log-summary"
LOGSUMMARY_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${LOGSUMMARY_ROLE}"
LOGSUMMARY_ENV=$(build_env_json \
    "AIRBRX_API_BASE" "${API_URL}" \
    "AIRBRX_S3_BUCKET" "${GATEWAY_BUCKET}" \
    "ANTHROPIC_API_KEY" "${ANTHROPIC_API_KEY:-}" \
)

deploy_lambda "$LOGSUMMARY_FUNC" "$LOGSUMMARY_ROLE_ARN" "lambda-handler.handler" \
    "$WORK_DIR/log-summary.zip" 1536 900 "$LOGSUMMARY_ENV" "false"

#------------------------------------------------------------------------------
# Phase 8b: Create CloudFront Distributions for APIs
#------------------------------------------------------------------------------

print_header "Phase 8b: Creating CloudFront for API Endpoints"

# Helper to create CloudFront distribution for Lambda Function URL (no OAC - matches production pattern)
# Note: All print output goes to stderr so stdout can return the URL
create_lambda_cloudfront() {
    local name="$1"
    local lambda_url="$2"
    local func_name="$3"
    local origin_domain=$(echo "$lambda_url" | sed 's|https://||' | sed 's|/$||')
    local dist_id=""
    local dist_domain=""

    # Check if distribution already exists
    local existing_dist=$(aws cloudfront list-distributions --query \
        "DistributionList.Items[?Origins.Items[?DomainName=='${origin_domain}']].Id" \
        --output text 2>/dev/null | head -1)

    if [[ -n "$existing_dist" && "$existing_dist" != "None" ]]; then
        echo -e "${GREEN}▶${NC} $name: Distribution exists ($existing_dist)" >&2
        dist_id="$existing_dist"
        dist_domain=$(aws cloudfront get-distribution --id "$dist_id" --query 'Distribution.DomainName' --output text)
    else
        echo -e "${GREEN}▶${NC} Creating CloudFront distribution for $name..." >&2

        # Simple CloudFront -> Lambda URL (no OAC, Lambda handles auth via JWT)
        local dist_config=$(cat <<EOFCF
{
    "CallerReference": "${PREFIX}-${name}-$(date +%s)",
    "Comment": "Airbrx ${name} - ${PREFIX}",
    "Origins": {
        "Quantity": 1,
        "Items": [{
            "Id": "lambda-${name}",
            "DomainName": "${origin_domain}",
            "CustomOriginConfig": {
                "HTTPPort": 80,
                "HTTPSPort": 443,
                "OriginProtocolPolicy": "https-only",
                "OriginSslProtocols": { "Quantity": 1, "Items": ["TLSv1.2"] }
            }
        }]
    },
    "DefaultCacheBehavior": {
        "TargetOriginId": "lambda-${name}",
        "ViewerProtocolPolicy": "redirect-to-https",
        "AllowedMethods": {
            "Quantity": 7,
            "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
            "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] }
        },
        "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
        "OriginRequestPolicyId": "b689b0a8-53d0-40ab-baf2-68738e2966ac",
        "Compress": true
    },
    "Enabled": true,
    "PriceClass": "PriceClass_100"
}
EOFCF
)

        dist_id=$(aws cloudfront create-distribution --distribution-config "$dist_config" \
            --query 'Distribution.Id' --output text)

        dist_domain=$(aws cloudfront get-distribution --id "$dist_id" \
            --query 'Distribution.DomainName' --output text)

        echo -e "${GREEN}✓${NC} $name CloudFront: https://${dist_domain}" >&2
    fi

    echo "https://${dist_domain}/"
}

API_CF_URL=$(create_lambda_cloudfront "api" "$API_URL" "$API_FUNC")
GATEWAY_CF_URL=$(create_lambda_cloudfront "gateway" "$GATEWAY_URL" "$GATEWAY_FUNC")

# Update API with derived URLs
print_step "Updating API with derived URLs..."
API_FQDN=$(echo "$API_CF_URL" | sed 's|https://||' | sed 's|/$||')

#------------------------------------------------------------------------------
# Phase 9: Build & Deploy Frontend App
#------------------------------------------------------------------------------

print_header "Phase 9: Building & Deploying Frontend App"

# Verify the frontend directory exists
if [[ ! -d "$WORK_DIR/app-airbrx-com" ]]; then
    die "Frontend directory not found: $WORK_DIR/app-airbrx-com (clone may have failed)"
fi

cd "$WORK_DIR/app-airbrx-com"
print_step "Working in: $(pwd)"

# Update conf.json with API CloudFront URL
print_step "Configuring frontend with API endpoint..."
# Sanitize URL - remove trailing slashes and whitespace
API_CF_URL_CLEAN=$(echo "$API_CF_URL" | tr -d '[:space:]' | sed 's|/$||')
print_step "API URL: $API_CF_URL_CLEAN"
if [[ -f "lib/conf.json" ]]; then
    # Use # as sed delimiter to avoid conflicts with URL characters
    sed -i.bak "s#\"defaultApiUrl\":.*#\"defaultApiUrl\": \"${API_CF_URL_CLEAN}\"#" lib/conf.json
    rm -f lib/conf.json.bak
    print_success "Updated lib/conf.json"
else
    print_warning "lib/conf.json not found - skipping API URL configuration"
fi

# Sync static files to S3
print_step "Uploading to S3: ${APP_BUCKET}"
aws s3 sync . "s3://${APP_BUCKET}/" --delete --exclude ".git/*"
print_success "Frontend files uploaded to S3"

# Create CloudFront Origin Access Control
print_step "Configuring CloudFront OAC..."

OAC_NAME="${PREFIX}-airbrx-app-oac"
OAC_ID=$(aws cloudfront list-origin-access-controls --query \
    "OriginAccessControlList.Items[?Name=='${OAC_NAME}'].Id" --output text 2>/dev/null || echo "")

if [[ -z "$OAC_ID" || "$OAC_ID" == "None" ]]; then
    print_step "Creating OAC: $OAC_NAME"
    OAC_ID=$(aws cloudfront create-origin-access-control --origin-access-control-config \
        "Name=${OAC_NAME},SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
        --query 'OriginAccessControl.Id' --output text)
    print_success "Created OAC: $OAC_ID"
else
    print_step "OAC exists: $OAC_ID"
fi

# Check if distribution exists (search by Comment for reliability)
print_step "Checking for existing CloudFront distribution..."
DIST_ID=$(aws cloudfront list-distributions --query \
    "DistributionList.Items[?contains(Comment, 'Airbrx App - ${PREFIX}')].Id" \
    --output text 2>/dev/null | head -1 || echo "")

if [[ -z "$DIST_ID" || "$DIST_ID" == "None" ]]; then
    print_step "Creating new CloudFront distribution..."

    DIST_CONFIG=$(cat <<EOF
{
    "CallerReference": "${PREFIX}-$(date +%s)",
    "Comment": "Airbrx App - ${PREFIX}",
    "DefaultRootObject": "index.html",
    "Origins": {
        "Quantity": 1,
        "Items": [{
            "Id": "S3-${APP_BUCKET}",
            "DomainName": "${APP_BUCKET}.s3.${AWS_REGION}.amazonaws.com",
            "S3OriginConfig": { "OriginAccessIdentity": "" },
            "OriginAccessControlId": "${OAC_ID}"
        }]
    },
    "DefaultCacheBehavior": {
        "TargetOriginId": "S3-${APP_BUCKET}",
        "ViewerProtocolPolicy": "redirect-to-https",
        "AllowedMethods": {
            "Quantity": 2,
            "Items": ["GET", "HEAD"],
            "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] }
        },
        "Compress": true,
        "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
        "OriginRequestPolicyId": "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf"
    },
    "CustomErrorResponses": {
        "Quantity": 1,
        "Items": [{
            "ErrorCode": 403,
            "ResponsePagePath": "/index.html",
            "ResponseCode": "200",
            "ErrorCachingMinTTL": 10
        }]
    },
    "Enabled": true,
    "PriceClass": "PriceClass_100"
}
EOF
)

    DIST_ID=$(aws cloudfront create-distribution --distribution-config "$DIST_CONFIG" \
        --query 'Distribution.Id' --output text)
    print_success "Created distribution: $DIST_ID"
else
    print_step "Distribution exists: $DIST_ID"
fi

CLOUDFRONT_DOMAIN=$(aws cloudfront get-distribution --id "$DIST_ID" \
    --query 'Distribution.DomainName' --output text)

print_success "CloudFront: https://${CLOUDFRONT_DOMAIN}"

# Update S3 bucket policy for CloudFront access
print_step "Updating bucket policy..."
BUCKET_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [{
        "Sid": "AllowCloudFrontServicePrincipal",
        "Effect": "Allow",
        "Principal": { "Service": "cloudfront.amazonaws.com" },
        "Action": "s3:GetObject",
        "Resource": "arn:aws:s3:::${APP_BUCKET}/*",
        "Condition": {
            "StringEquals": {
                "AWS:SourceArn": "arn:aws:cloudfront::${AWS_ACCOUNT_ID}:distribution/${DIST_ID}"
            }
        }
    }]
}
EOF
)
aws s3api put-bucket-policy --bucket "$APP_BUCKET" --policy "$BUCKET_POLICY"

# Invalidate CloudFront cache
print_step "Invalidating cache..."
aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/*" > /dev/null

# Update API Lambda with final URLs
print_step "Updating API with dashboard URL..."
DASHBOARD_URL="https://${CLOUDFRONT_DOMAIN}"
ALLOWED_DOMAINS="${API_FQDN},${CLOUDFRONT_DOMAIN}"

# Build final API environment with derived URLs
API_ENV_FINAL=$(build_env_json \
    "NODE_ENV" "production" \
    "AIRBRX_ENV" "${PREFIX#*-}" \
    "AIRBRX_LOG_DISK" "false" \
    "AIRBRX_S3_BUCKET" "${GATEWAY_BUCKET}" \
    "AWS_ADMIN_BUCKET" "${ADMIN_BUCKET}" \
    "AWS_ADMIN_REGION" "${AWS_REGION}" \
    "AIRBRX_CONFIG_STORAGE_TYPE" "s3" \
    "LOG_SUMMARY_LAMBDA_ARN" "${PREFIX}-airbrx-log-summary" \
    "AIRBRX_JWT_SECRET" "${JWT_SECRET}" \
    "AIRBRX_JWT_EXPIRY" "7d" \
    "AIRBRX_JWT_ISSUER" "airbrx.com" \
    "DESCOPE_PROJECT_ID" "${DESCOPE_PROJECT_ID:-}" \
    "DESCOPE_REDIRECT_URI" "${API_URL}auth/callback" \
    "DASHBOARD_URL" "${DASHBOARD_URL}" \
    "ALLOWED_REDIRECT_DOMAINS" "${ALLOWED_DOMAINS}" \
    "ANTHROPIC_API_KEY" "${ANTHROPIC_API_KEY:-}" \
    "SLACK_WEBHOOK" "${SLACK_WEBHOOK:-}" \
)

aws lambda update-function-configuration --function-name "$API_FUNC" \
    --environment "$API_ENV_FINAL" > /dev/null

#------------------------------------------------------------------------------
# Phase 10: Upload Initial Configuration
#------------------------------------------------------------------------------

print_header "Phase 10: Uploading Initial Configuration"

# Upload God PAT
print_step "Uploading God PAT..."
aws s3 cp "$GOD_PAT_FILE" "s3://${ADMIN_BUCKET}/pats/${GOD_PAT}.json"
print_success "Uploaded: s3://${ADMIN_BUCKET}/pats/${GOD_PAT}.json"

# Create initial tenant config
GATEWAY_FQDN=$(echo "$GATEWAY_URL" | sed 's|https://||' | sed 's|/$||')
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

print_step "Creating tenant configuration..."

TENANT_CONF=$(cat <<EOF
{
  "tenantId": "${GATEWAY_FQDN}",
  "tenantName": "${PREFIX}",
  "dataAdapter": {
    "type": "snowflake",
    "server_hostname": "your-account.snowflakecomputing.com",
    "http_path": "",
    "cloudFilesBaseUrl": "https://${GATEWAY_FQDN}",
    "disableSessionSpoofing": false,
    "disableOperationSpoofing": false
  },
  "storage": {
    "type": "s3",
    "bucket": "${GATEWAY_BUCKET}",
    "region": "${AWS_REGION}",
    "basePath": "storage"
  },
  "logging": {
    "logToFile": true,
    "logRequests": true,
    "logLevel": "info"
  }
}
EOF
)

TENANT_RULES=$(cat <<EOF
{
  "version": "1.0",
  "tenantId": "${GATEWAY_FQDN}",
  "lastUpdated": "${TIMESTAMP}",
  "defaults": {
    "cacheKeyElements": ["userId", "standardizedSql"],
    "ttlSeconds": 3600,
    "version": 1
  },
  "rules": [
    {
      "id": "no-cache-writes",
      "name": "No Cache for Write Operations",
      "enabled": true,
      "priority": 5,
      "mode": "all",
      "conditions": { "statementType": { "in": ["INSERT","UPDATE","DELETE","CREATE","DROP","ALTER","TRUNCATE"] } },
      "actions": { "cacheKeyElements": [], "cache": { "ttlSeconds": 0 }, "version": 1 }
    },
    {
      "id": "cache-select-queries",
      "name": "Cache SELECT Queries",
      "enabled": true,
      "priority": 15,
      "mode": "all",
      "conditions": { "statementType": { "equals": "SELECT" } },
      "actions": { "cacheKeyElements": ["userId","standardizedSql"], "cache": { "ttlSeconds": 86400 }, "version": 1 }
    }
  ]
}
EOF
)

TENANT_PATH="config/tenants/${GATEWAY_FQDN}"
echo "$TENANT_CONF" | aws s3 cp - "s3://${ADMIN_BUCKET}/${TENANT_PATH}/conf.json"
echo "$TENANT_RULES" | aws s3 cp - "s3://${ADMIN_BUCKET}/${TENANT_PATH}/rules.json"

print_success "Uploaded tenant config to: s3://${ADMIN_BUCKET}/${TENANT_PATH}/"

#------------------------------------------------------------------------------
# Phase 11: Validation & Report
#------------------------------------------------------------------------------

print_header "Phase 11: Validation & Deployment Report"

echo ""
echo "Testing endpoints..."
echo ""

# Test API via CloudFront
API_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "${API_CF_URL}health" 2>/dev/null || echo "000")
if [[ "$API_HEALTH" == "200" ]]; then
    print_success "API Health: OK"
else
    print_warning "API Health: $API_HEALTH (CloudFront may take a few minutes to deploy)"
fi

# Test Gateway via CloudFront
GW_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "${GATEWAY_CF_URL}" 2>/dev/null || echo "000")
if [[ "$GW_HEALTH" != "000" ]]; then
    print_success "Gateway: Responding ($GW_HEALTH)"
else
    print_warning "Gateway: Not responding yet (CloudFront may take a few minutes)"
fi

# Frontend CloudFront status
CF_STATUS=$(aws cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.Status' --output text)
if [[ "$CF_STATUS" == "Deployed" ]]; then
    print_success "Frontend CloudFront: Deployed"
else
    print_warning "Frontend CloudFront: $CF_STATUS (may take 5-10 minutes)"
fi

echo ""
print_header "Deployment Complete!"

echo "
┌─────────────────────────────────────────────────────────────────┐
│                        DEPLOYMENT URLS                         │
├─────────────────────────────────────────────────────────────────┤
│  Frontend App:  https://${CLOUDFRONT_DOMAIN}
│  API Endpoint:  ${API_CF_URL}
│  Gateway:       ${GATEWAY_CF_URL}
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                        S3 BUCKETS                              │
├─────────────────────────────────────────────────────────────────┤
│  Admin Storage:   s3://${ADMIN_BUCKET}
│  Gateway Storage: s3://${GATEWAY_BUCKET}
│  App Assets:      s3://${APP_BUCKET}
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                      AUTHENTICATION                            │
├─────────────────────────────────────────────────────────────────┤
│  God PAT: ${GOD_PAT}
│  Use in API calls: Authorization: Bearer \$GOD_PAT
└─────────────────────────────────────────────────────────────────┘
"

# Cleanup
print_step "Cleaning up build artifacts..."
rm -rf "$WORK_DIR"

print_success "Deployment complete!"
