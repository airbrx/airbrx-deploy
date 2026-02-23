#!/bin/bash
#
# prereq.sh - Airbrx Data Gateway Pre-Deployment Setup
#
# This script gathers configuration, generates IAM policies, and creates
# the config.env file needed for deploy.sh
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Output directory for generated files
OUTPUT_DIR="./generated"

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

prompt_required() {
    local var_name=$1
    local prompt_text=$2
    local default_value=$3
    local value=""

    while [[ -z "$value" ]]; do
        if [[ -n "$default_value" ]]; then
            read -p "$prompt_text [$default_value]: " value
            value="${value:-$default_value}"
        else
            read -p "$prompt_text: " value
        fi

        if [[ -z "$value" ]]; then
            print_error "This field is required"
        fi
    done

    eval "$var_name='$value'"
}

prompt_secret() {
    local var_name=$1
    local prompt_text=$2
    local value=""

    while [[ -z "$value" ]]; do
        read -s -p "$prompt_text: " value
        echo ""

        if [[ -z "$value" ]]; then
            print_error "This field is required"
        fi
    done

    eval "$var_name='$value'"
}

#------------------------------------------------------------------------------
# Main Script
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
echo "      Data Gateway Setup"
echo ""
echo "─────────────────────────────────────────────────────────────────"
echo ""
echo "This tool prepares your environment for deploying the Airbrx"
echo "Data Gateway stack, which includes:"
echo ""
echo "  • API Lambda        - Admin and configuration endpoints"
echo "  • Gateway Lambda    - Data proxy and request handling"
echo "  • Log Summary Lambda - Analytics and log aggregation"
echo "  • S3 Buckets        - Configuration and data storage"
echo "  • Frontend App      - Static website on S3 + CloudFront"
echo ""
echo "What this script does:"
echo "  1. Gather deployment configuration (company, environment, tokens)"
echo "  2. Generate IAM policies (to share with your AWS admin)"
echo "  3. Create config file for the deployment script"
echo ""
echo "─────────────────────────────────────────────────────────────────"
echo ""
read -p "Press Enter to continue..."
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

#------------------------------------------------------------------------------
# Step 1: Deployment Target
#------------------------------------------------------------------------------

print_header "Step 1: Deployment Target"

echo "Company/Organization Name"
echo "-------------------------"
echo "This will be used to create unique AWS resource names."
echo "  - S3 buckets:  {company}-{env}-airbrx-admin-storage"
echo "  - Lambdas:     {company}-{env}-airbrx-api"
echo "  - IAM roles:   {company}-{env}-airbrx-lambda-role"
echo ""
echo "IMPORTANT: S3 bucket names must be globally unique across ALL of AWS."
echo "Use your actual company/org name to avoid conflicts."
echo ""

while true; do
    prompt_required COMPANY "Company name (lowercase, e.g., acme, bigcorp)" ""

    # Convert to lowercase and validate
    COMPANY=$(echo "$COMPANY" | tr '[:upper:]' '[:lower:]')

    if [[ ! "$COMPANY" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
        print_error "Must be lowercase alphanumeric with hyphens (no leading/trailing hyphens)"
        echo ""
        continue
    fi

    # Warn if too generic
    if [[ "$COMPANY" =~ ^(app|data|api|test|company|org|client)$ ]]; then
        print_warning "This name is very generic and may conflict with existing S3 buckets"
        read -p "(Y) use anyway, (N) choose different, (exit) quit: " confirm
        confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
        case "$confirm" in
            y|yes)
                break
                ;;
            exit)
                echo "Exiting."
                exit 0
                ;;
            *)
                echo ""
                continue
                ;;
        esac
    fi

    break
done

echo ""
echo "Environment"
echo "-----------"
echo "Use arrow keys to select, Enter to confirm:"
echo ""

# Arrow key menu selection
ENV_OPTIONS=("dev" "stage" "prod" "custom")
ENV_DESCRIPTIONS=("Development" "Staging" "Production" "Enter custom tag")
ENV_SELECTED=0

draw_env_menu() {
    local redraw=$1
    # Move cursor up to redraw (4 options)
    if [[ $redraw -eq 1 ]]; then
        printf "\033[4A"
    fi
    for i in "${!ENV_OPTIONS[@]}"; do
        if [[ $i -eq $ENV_SELECTED ]]; then
            printf "  ${GREEN}> %-8s${NC} - %s\n" "${ENV_OPTIONS[$i]}" "${ENV_DESCRIPTIONS[$i]}"
        else
            printf "    %-8s - %s\n" "${ENV_OPTIONS[$i]}" "${ENV_DESCRIPTIONS[$i]}"
        fi
    done
}

# Hide cursor
tput civis 2>/dev/null || true

draw_env_menu 0

while true; do
    # Read single character
    IFS= read -rsn1 key

    # Check for escape sequence (arrow keys)
    if [[ $key == $'\e' ]]; then
        read -rsn2 key
        case "$key" in
            '[A') # Up arrow
                ((ENV_SELECTED--)) || true
                [[ $ENV_SELECTED -lt 0 ]] && ENV_SELECTED=3
                ;;
            '[B') # Down arrow
                ((ENV_SELECTED++)) || true
                [[ $ENV_SELECTED -gt 3 ]] && ENV_SELECTED=0
                ;;
        esac
        draw_env_menu 1
    elif [[ $key == '' ]]; then
        # Enter pressed
        break
    fi
done

# Show cursor
tput cnorm 2>/dev/null || true

ENV="${ENV_OPTIONS[$ENV_SELECTED]}"
echo ""

# Handle custom environment
if [[ "$ENV" == "custom" ]]; then
    while true; do
        read -p "Enter custom environment tag: " ENV
        ENV=$(echo "$ENV" | tr '[:upper:]' '[:lower:]')

        if [[ ! "$ENV" =~ ^[a-z0-9]+$ ]]; then
            print_error "Must be lowercase alphanumeric (no hyphens or spaces)"
            continue
        fi
        break
    done
fi

# Combine into prefix (also used as git branch)
PREFIX="${COMPANY}-${ENV}"
GIT_BRANCH="main"

echo ""
print_success "Prefix: ${PREFIX}"
print_success "Git branch: ${GIT_BRANCH}"

echo ""
echo "AWS Region"
echo "----------"
echo "Type to search, arrow keys to select, Enter to confirm"
echo ""

# All AWS regions sorted by popularity (parallel arrays for compatibility)
REGION_CODES=(
    "us-east-1"
    "us-west-2"
    "eu-west-1"
    "us-east-2"
    "eu-central-1"
    "ap-northeast-1"
    "ap-southeast-1"
    "eu-west-2"
    "ap-southeast-2"
    "us-west-1"
    "ca-central-1"
    "ap-south-1"
    "ap-northeast-2"
    "eu-north-1"
    "sa-east-1"
    "eu-west-3"
    "ap-southeast-3"
    "ap-northeast-3"
    "me-south-1"
    "af-south-1"
    "eu-south-1"
    "ap-east-1"
    "ap-south-2"
    "ap-southeast-4"
    "eu-central-2"
    "eu-south-2"
    "il-central-1"
    "me-central-1"
)

REGION_NAMES=(
    "N. Virginia"
    "Oregon"
    "Ireland"
    "Ohio"
    "Frankfurt"
    "Tokyo"
    "Singapore"
    "London"
    "Sydney"
    "N. California"
    "Canada"
    "Mumbai"
    "Seoul"
    "Stockholm"
    "Sao Paulo"
    "Paris"
    "Jakarta"
    "Osaka"
    "Bahrain"
    "Cape Town"
    "Milan"
    "Hong Kong"
    "Hyderabad"
    "Melbourne"
    "Zurich"
    "Spain"
    "Tel Aviv"
    "UAE"
)

# Get region name by code
get_region_name() {
    local code="$1"
    for i in "${!REGION_CODES[@]}"; do
        if [[ "${REGION_CODES[$i]}" == "$code" ]]; then
            echo "${REGION_NAMES[$i]}"
            return
        fi
    done
    echo ""
}

# Search regions and return top 5 matches
search_regions() {
    local search="$1"
    local -a matches=()
    local search_lower=$(echo "$search" | tr '[:upper:]' '[:lower:]')

    for i in "${!REGION_CODES[@]}"; do
        local code="${REGION_CODES[$i]}"
        local name_lower=$(echo "${REGION_NAMES[$i]}" | tr '[:upper:]' '[:lower:]')

        if [[ "$code" == *"$search_lower"* ]] || [[ "$name_lower" == *"$search_lower"* ]]; then
            matches+=("$code")
        fi
        [[ ${#matches[@]} -ge 5 ]] && break
    done
    echo "${matches[@]}"
}

draw_region_menu() {
    local search="$1"
    local selected="$2"
    local matches_str="$3"
    local redraw="$4"
    local -a matches=($matches_str)

    # Move cursor up to redraw (search line + 5 options + blank)
    if [[ "$redraw" == "1" ]]; then
        printf "\033[7A"
    fi

    # Clear and redraw search line
    printf "\033[K> %s\n" "$search"

    # Draw matches (always 5 lines for consistent layout)
    for i in 0 1 2 3 4; do
        printf "\033[K"
        if [[ $i -lt ${#matches[@]} ]]; then
            local region="${matches[$i]}"
            local name=$(get_region_name "$region")
            if [[ $i -eq $selected ]]; then
                printf "  ${GREEN}▶ %-20s${NC} (%s)\n" "$region" "$name"
            else
                printf "    %-20s (%s)\n" "$region" "$name"
            fi
        else
            printf "\n"
        fi
    done
    printf "\033[K\n"
}

# Initialize
REGION_SEARCH=""
REGION_SELECTED=0
REGION_MATCHES=($(search_regions ""))

# Hide cursor
tput civis 2>/dev/null || true

# Initial draw
draw_region_menu "$REGION_SEARCH" "$REGION_SELECTED" "${REGION_MATCHES[*]}" "0"

# Interactive loop
while true; do
    IFS= read -rsn1 key

    if [[ $key == $'\e' ]]; then
        # Escape sequence (arrow keys)
        read -rsn2 key
        case "$key" in
            '[A') # Up arrow
                ((REGION_SELECTED > 0)) && ((REGION_SELECTED--)) || true
                ;;
            '[B') # Down arrow
                ((REGION_SELECTED < ${#REGION_MATCHES[@]} - 1)) && ((REGION_SELECTED++)) || true
                ;;
        esac
    elif [[ $key == '' ]]; then
        # Enter pressed
        if [[ ${#REGION_MATCHES[@]} -gt 0 ]]; then
            AWS_REGION="${REGION_MATCHES[$REGION_SELECTED]}"
            break
        fi
    elif [[ $key == $'\x7f' ]] || [[ $key == $'\b' ]]; then
        # Backspace
        if [[ -n "$REGION_SEARCH" ]]; then
            REGION_SEARCH="${REGION_SEARCH%?}"
            REGION_MATCHES=($(search_regions "$REGION_SEARCH"))
            REGION_SELECTED=0
        fi
    elif [[ $key =~ ^[a-zA-Z0-9-]$ ]]; then
        # Alphanumeric input
        REGION_SEARCH="${REGION_SEARCH}${key}"
        REGION_MATCHES=($(search_regions "$REGION_SEARCH"))
        REGION_SELECTED=0
    fi

    draw_region_menu "$REGION_SEARCH" "$REGION_SELECTED" "${REGION_MATCHES[*]}" "1"
done

# Show cursor
tput cnorm 2>/dev/null || true

AWS_REGION_NAME=$(get_region_name "$AWS_REGION")
echo ""
print_success "Selected region: ${AWS_REGION} (${AWS_REGION_NAME})"

echo ""
echo "AWS Account ID:"

# Try to auto-detect from AWS CLI
DETECTED_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || DETECTED_ACCOUNT_ID=""

if [[ -n "$DETECTED_ACCOUNT_ID" ]]; then
    print_step "Detected from AWS CLI: $DETECTED_ACCOUNT_ID"
fi

while true; do
    if [[ -n "$DETECTED_ACCOUNT_ID" ]]; then
        read -p "AWS Account ID [$DETECTED_ACCOUNT_ID]: " AWS_ACCOUNT_ID
        AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$DETECTED_ACCOUNT_ID}"
    else
        read -p "AWS Account ID (12-digit, or press Enter to skip): " AWS_ACCOUNT_ID
        if [[ -z "$AWS_ACCOUNT_ID" ]]; then
            AWS_ACCOUNT_ID="<ACCOUNT_ID>"
            break
        fi
    fi

    # Validate format
    if [[ ! "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
        print_error "AWS Account ID must be exactly 12 digits"
        echo ""
        continue
    fi

    break
done

print_success "Deployment target configured"

#------------------------------------------------------------------------------
# Step 2: Authentication Tokens
#------------------------------------------------------------------------------

print_header "Step 2: Authentication Tokens"

echo "GitHub PAT Requirements:"
echo "  - Read access to airbrx/data-proxy repository"
echo "  - Read access to airbrx/airbrx-api repository"
echo "  - Read access to airbrx/app-airbrx-com repository"
echo ""

prompt_secret GIT_PAT "GitHub Personal Access Token (input hidden)"

echo ""
echo "God PAT (Admin API Token):"
echo "  - Full-access token for API authentication"
echo "  - Will be auto-generated"
echo ""

# Generate random hex bytes (cross-platform)
generate_hex() {
    local num_bytes=$1
    if command -v xxd &> /dev/null; then
        head -c "$num_bytes" /dev/urandom | xxd -p | tr -d '\n'
    else
        # Fallback using od (available on both platforms)
        head -c "$num_bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

# Generate PAT ID and token
GOD_PAT_ID="pat_$(generate_hex 8)"
GOD_PAT="airbrx_pat_$(generate_hex 32)"

# Get current timestamp in ISO format (cross-platform)
if date --version &> /dev/null 2>&1; then
    # GNU date (Linux)
    GOD_PAT_CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
else
    # BSD date (macOS)
    GOD_PAT_CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
fi

print_success "Generated God PAT: ${GOD_PAT_ID}"

print_success "Authentication tokens configured"

#------------------------------------------------------------------------------
# Step 3: API Configuration
#------------------------------------------------------------------------------

print_header "Step 3: API Configuration"

echo "JWT Secret:"
echo "  - Used to sign authentication tokens"
echo "  - Will be auto-generated (64 hex characters)"
echo ""

JWT_SECRET=$(openssl rand -hex 32)
print_success "Generated JWT secret"

echo ""
echo "Descope Configuration (optional):"
echo "  - Descope handles Google + Microsoft 365 login"
echo "  - Get your Project ID from https://app.descope.com/settings/project"
echo "  - Press Enter to skip if not using Descope"
echo ""

read -p "Descope Project ID (or press Enter to skip): " DESCOPE_PROJECT_ID
if [[ -z "$DESCOPE_PROJECT_ID" ]]; then
    DESCOPE_PROJECT_ID="DESCOPE_NOT_CONFIGURED"
    print_step "Descope disabled (using placeholder)"
else
    print_success "Descope configured"
fi

echo ""
echo "Anthropic API Key (optional, for AI-powered features):"
echo "  - Used for log summarization and AI analysis"
echo "  - Get from https://console.anthropic.com/settings/keys"
echo "  - Press Enter to skip if not using AI features"
echo ""

read -s -p "Anthropic API Key (or press Enter to skip): " ANTHROPIC_API_KEY
echo ""
if [[ -z "$ANTHROPIC_API_KEY" ]]; then
    ANTHROPIC_API_KEY="ANTHROPIC_NOT_CONFIGURED"
    print_step "Anthropic disabled (using placeholder)"
else
    print_success "Anthropic API key configured"
fi

echo ""
echo "Slack Webhook (optional):"
echo "  - For deployment and error notifications"
echo "  - Press Enter to skip"
echo ""

read -p "Slack Webhook URL (or press Enter to skip): " SLACK_WEBHOOK
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

if [[ -n "$SLACK_WEBHOOK" ]]; then
    print_success "Slack webhook configured"
else
    print_step "Slack notifications disabled"
fi

print_success "API configuration complete"

#------------------------------------------------------------------------------
# Step 4: Generate IAM Policies
#------------------------------------------------------------------------------

print_header "Step 4: Generating IAM Policies"

# Lambda trust policy
TRUST_POLICY_FILE="$OUTPUT_DIR/${PREFIX}-lambda-trust-policy.json"
cat > "$TRUST_POLICY_FILE" <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "lambda.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
print_step "Created: $TRUST_POLICY_FILE"

# API Lambda execution policy (needs both S3 buckets + invoke log-summary)
API_POLICY_FILE="$OUTPUT_DIR/${PREFIX}-airbrx-api-policy.json"
cat > "$API_POLICY_FILE" <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "CloudWatchLogs",
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/lambda/${PREFIX}-airbrx-api:*"
        },
        {
            "Sid": "S3AdminAccess",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::${PREFIX}-airbrx-admin-storage",
                "arn:aws:s3:::${PREFIX}-airbrx-admin-storage/*"
            ]
        },
        {
            "Sid": "S3GatewayAccess",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::${PREFIX}-airbrx-gateway-storage",
                "arn:aws:s3:::${PREFIX}-airbrx-gateway-storage/*"
            ]
        },
        {
            "Sid": "LambdaInvoke",
            "Effect": "Allow",
            "Action": "lambda:InvokeFunction",
            "Resource": "arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${PREFIX}-airbrx-log-summary"
        }
    ]
}
EOF
print_step "Created: $API_POLICY_FILE"

# Gateway Lambda execution policy (needs gateway S3 bucket only)
GATEWAY_POLICY_FILE="$OUTPUT_DIR/${PREFIX}-airbrx-gateway-policy.json"
cat > "$GATEWAY_POLICY_FILE" <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "CloudWatchLogs",
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/lambda/${PREFIX}-airbrx-gateway:*"
        },
        {
            "Sid": "S3GatewayAccess",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::${PREFIX}-airbrx-gateway-storage",
                "arn:aws:s3:::${PREFIX}-airbrx-gateway-storage/*"
            ]
        }
    ]
}
EOF
print_step "Created: $GATEWAY_POLICY_FILE"

# Log Summary Lambda execution policy (needs gateway S3 bucket only)
LOGSUMMARY_POLICY_FILE="$OUTPUT_DIR/${PREFIX}-airbrx-log-summary-policy.json"
cat > "$LOGSUMMARY_POLICY_FILE" <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "CloudWatchLogs",
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/lambda/${PREFIX}-airbrx-log-summary:*"
        },
        {
            "Sid": "S3GatewayAccess",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::${PREFIX}-airbrx-gateway-storage",
                "arn:aws:s3:::${PREFIX}-airbrx-gateway-storage/*"
            ]
        }
    ]
}
EOF
print_step "Created: $LOGSUMMARY_POLICY_FILE"

# Deployer policy (optional - for EC2/CI deployments, or to document minimum required permissions)
# CloudShell users typically have broader permissions via their console session
DEPLOYER_POLICY_FILE="$OUTPUT_DIR/${PREFIX}-deployer-policy.json"
cat > "$DEPLOYER_POLICY_FILE" <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "S3BucketManagement",
            "Effect": "Allow",
            "Action": [
                "s3:CreateBucket",
                "s3:PutBucketVersioning",
                "s3:PutBucketPublicAccessBlock",
                "s3:GetBucketLocation",
                "s3:ListBucket",
                "s3:PutObject",
                "s3:GetObject",
                "s3:DeleteObject"
            ],
            "Resource": [
                "arn:aws:s3:::${PREFIX}-airbrx-admin-storage",
                "arn:aws:s3:::${PREFIX}-airbrx-admin-storage/*",
                "arn:aws:s3:::${PREFIX}-airbrx-gateway-storage",
                "arn:aws:s3:::${PREFIX}-airbrx-gateway-storage/*"
            ]
        },
        {
            "Sid": "S3AppBucketManagement",
            "Effect": "Allow",
            "Action": [
                "s3:CreateBucket",
                "s3:PutBucketVersioning",
                "s3:PutBucketPublicAccessBlock",
                "s3:PutBucketWebsite",
                "s3:GetBucketWebsite",
                "s3:PutBucketPolicy",
                "s3:GetBucketPolicy",
                "s3:DeleteBucketPolicy",
                "s3:GetBucketLocation",
                "s3:ListBucket",
                "s3:PutObject",
                "s3:GetObject",
                "s3:DeleteObject"
            ],
            "Resource": [
                "arn:aws:s3:::${PREFIX}-airbrx-app",
                "arn:aws:s3:::${PREFIX}-airbrx-app/*"
            ]
        },
        {
            "Sid": "CloudFrontManagement",
            "Effect": "Allow",
            "Action": [
                "cloudfront:CreateDistribution",
                "cloudfront:UpdateDistribution",
                "cloudfront:GetDistribution",
                "cloudfront:GetDistributionConfig",
                "cloudfront:ListDistributions",
                "cloudfront:CreateInvalidation",
                "cloudfront:GetInvalidation",
                "cloudfront:ListInvalidations",
                "cloudfront:CreateOriginAccessControl",
                "cloudfront:GetOriginAccessControl",
                "cloudfront:ListOriginAccessControls",
                "cloudfront:TagResource"
            ],
            "Resource": "*"
        },
        {
            "Sid": "ACMReadAccess",
            "Effect": "Allow",
            "Action": [
                "acm:DescribeCertificate",
                "acm:ListCertificates"
            ],
            "Resource": "*"
        },
        {
            "Sid": "LambdaManagement",
            "Effect": "Allow",
            "Action": [
                "lambda:CreateFunction",
                "lambda:UpdateFunctionCode",
                "lambda:UpdateFunctionConfiguration",
                "lambda:GetFunction",
                "lambda:GetFunctionConfiguration",
                "lambda:CreateFunctionUrlConfig",
                "lambda:GetFunctionUrlConfig",
                "lambda:AddPermission",
                "lambda:GetPolicy"
            ],
            "Resource": "arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${PREFIX}-airbrx-*"
        },
        {
            "Sid": "IAMPassRole",
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": [
                "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PREFIX}-airbrx-api-role",
                "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PREFIX}-airbrx-gateway-role",
                "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PREFIX}-airbrx-log-summary-role"
            ]
        },
        {
            "Sid": "IAMRoleManagement",
            "Effect": "Allow",
            "Action": [
                "iam:CreateRole",
                "iam:GetRole",
                "iam:PutRolePolicy",
                "iam:AttachRolePolicy"
            ],
            "Resource": [
                "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PREFIX}-airbrx-api-role",
                "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PREFIX}-airbrx-gateway-role",
                "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PREFIX}-airbrx-log-summary-role"
            ]
        },
        {
            "Sid": "IAMPolicyManagement",
            "Effect": "Allow",
            "Action": [
                "iam:CreatePolicy",
                "iam:GetPolicy"
            ],
            "Resource": "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${PREFIX}-airbrx-*"
        }
    ]
}
EOF
print_step "Created: $DEPLOYER_POLICY_FILE"

if [[ "$AWS_ACCOUNT_ID" == "<ACCOUNT_ID>" ]]; then
    echo ""
    print_warning "Policies contain <ACCOUNT_ID> placeholder - admin must substitute their 12-digit account ID"
fi

print_success "IAM policies generated"

# Generate God PAT JSON file
GOD_PAT_FILE="$OUTPUT_DIR/${PREFIX}-god-pat.json"
cat > "$GOD_PAT_FILE" <<EOF
{
    "id": "${GOD_PAT_ID}",
    "name": "God PAT",
    "token": "${GOD_PAT}",
    "issuedBy": "prereq.sh",
    "createdAt": "${GOD_PAT_CREATED_AT}",
    "expiresAt": null,
    "scopes": {},
    "tenants": ["*"]
}
EOF
print_step "Created: $GOD_PAT_FILE"

print_success "God PAT JSON generated"

#------------------------------------------------------------------------------
# Step 5: Generate config.env
#------------------------------------------------------------------------------

print_header "Step 5: Generating Configuration File"

CONFIG_FILE="$OUTPUT_DIR/${PREFIX}-config.env"
cat > "$CONFIG_FILE" <<EOF
# Airbrx Data Gateway - Deployment Configuration
# Generated by prereq.sh on $(date)
#
# IMPORTANT: Keep this file secure - it contains sensitive tokens

# Deployment Target
PREFIX="${PREFIX}"
AWS_REGION="${AWS_REGION}"

# Git Configuration
GIT_PAT="${GIT_PAT}"
GIT_BRANCH="${GIT_BRANCH}"

# API Authentication
GOD_PAT="${GOD_PAT}"

# JWT Configuration (auto-generated)
JWT_SECRET="${JWT_SECRET}"

# Descope (OAuth provider)
DESCOPE_PROJECT_ID="${DESCOPE_PROJECT_ID}"

# Anthropic (AI features)
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"

# Slack (optional notifications)
SLACK_WEBHOOK="${SLACK_WEBHOOK}"
EOF

chmod 600 "$CONFIG_FILE"
print_step "Created: $CONFIG_FILE (permissions: 600)"

print_success "Configuration file generated"

#------------------------------------------------------------------------------
# Summary & Next Steps
#------------------------------------------------------------------------------

print_header "Setup Complete"

echo "Generated Files:"
echo ""
echo "  IAM Policies (share with AWS admin):"
echo "    - $TRUST_POLICY_FILE (shared trust policy for all lambda roles)"
echo "    - $API_POLICY_FILE"
echo "    - $GATEWAY_POLICY_FILE"
echo "    - $LOGSUMMARY_POLICY_FILE"
echo "    - $DEPLOYER_POLICY_FILE"
echo ""
echo "  God PAT (will be uploaded to S3 by deploy.sh):"
echo "    - $GOD_PAT_FILE"
echo ""
echo "  Deployment Config (keep secure):"
echo "    - $CONFIG_FILE"
echo ""

print_header "Next Steps"

echo "1. Share IAM policies with your AWS administrator"
echo ""
echo "   They need to create three Lambda execution roles:"
echo ""
echo "   a) IAM Role: ${PREFIX}-airbrx-api-role"
echo "      - Trust policy: ${PREFIX}-lambda-trust-policy.json"
echo "      - Attach policy: ${PREFIX}-airbrx-api-policy.json"
echo ""
echo "   b) IAM Role: ${PREFIX}-airbrx-gateway-role"
echo "      - Trust policy: ${PREFIX}-lambda-trust-policy.json"
echo "      - Attach policy: ${PREFIX}-airbrx-gateway-policy.json"
echo ""
echo "   c) IAM Role: ${PREFIX}-airbrx-log-summary-role"
echo "      - Trust policy: ${PREFIX}-lambda-trust-policy.json"
echo "      - Attach policy: ${PREFIX}-airbrx-log-summary-policy.json"
echo ""
echo "   d) (Optional) IAM Policy for deployer - for EC2/CI or to limit permissions:"
echo "      - ${PREFIX}-deployer-policy.json"
echo ""
echo "2. Once IAM resources are created, run:"
echo "   ./deploy.sh $CONFIG_FILE"
echo ""

print_warning "Keep ${PREFIX}-config.env secure - it contains your API tokens!"

#------------------------------------------------------------------------------
# Offer to Deploy Now
#------------------------------------------------------------------------------

echo ""
echo ""
read -p "Deploy now? (Requires IAM roles to be created first) [y/N]: " DEPLOY_NOW
DEPLOY_NOW=$(echo "$DEPLOY_NOW" | tr '[:upper:]' '[:lower:]')

if [[ "$DEPLOY_NOW" == "y" || "$DEPLOY_NOW" == "yes" ]]; then
    echo ""
    exec ./deploy.sh "$CONFIG_FILE"
fi

echo ""
print_success "Setup complete. Run ./deploy.sh $CONFIG_FILE when ready."
