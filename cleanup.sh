#!/bin/bash
#
# cleanup.sh - Airbrx Data Gateway Cleanup Script
#
# Removes all AWS resources created by deploy.sh
# USE WITH CAUTION - This will delete all data!
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
echo "     Data Gateway Cleanup"
echo ""
echo -e "${RED}─────────────────────────────────────────────────────────────────${NC}"
echo ""
echo -e "${RED}WARNING: This script will permanently delete:${NC}"
echo ""
echo "  • All S3 buckets and their contents"
echo "  • All Lambda functions"
echo "  • CloudFront distribution"
echo "  • IAM roles and policies"
echo ""
echo -e "${RED}THIS ACTION CANNOT BE UNDONE!${NC}"
echo ""
echo -e "${RED}─────────────────────────────────────────────────────────────────${NC}"
echo ""

#------------------------------------------------------------------------------
# Load Configuration
#------------------------------------------------------------------------------

CONFIG_FILE="${1:-}"
if [[ -z "$CONFIG_FILE" ]]; then
    CONFIG_FILE=$(ls generated/*-config.env 2>/dev/null | head -1)
    if [[ -z "$CONFIG_FILE" ]]; then
        die "Usage: ./cleanup.sh <config-file> or run prereq.sh first"
    fi
    print_step "Auto-detected config: $CONFIG_FILE"
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    die "Config file not found: $CONFIG_FILE"
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

echo "Configuration: $PREFIX in $AWS_REGION"
echo ""

# Confirm deletion
read -p "Type '${PREFIX}' to confirm deletion: " CONFIRM
if [[ "$CONFIRM" != "$PREFIX" ]]; then
    echo "Aborted."
    exit 0
fi

echo ""
print_warning "Starting cleanup..."

#------------------------------------------------------------------------------
# Get AWS Account ID
#------------------------------------------------------------------------------

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || die "AWS CLI not configured"

#------------------------------------------------------------------------------
# Delete CloudFront Distribution
#------------------------------------------------------------------------------

print_header "Deleting CloudFront Distribution"

APP_BUCKET="${PREFIX}-airbrx-app"

# Find distribution by S3 origin
DIST_ID=$(aws cloudfront list-distributions --query \
    "DistributionList.Items[?Origins.Items[?contains(DomainName, '${APP_BUCKET}')]].Id" \
    --output text 2>/dev/null | head -1)

if [[ -n "$DIST_ID" && "$DIST_ID" != "None" ]]; then
    print_step "Found distribution: $DIST_ID"

    # Check if enabled
    DIST_STATUS=$(aws cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.DistributionConfig.Enabled' --output text)

    if [[ "$DIST_STATUS" == "true" ]]; then
        print_step "Disabling distribution..."

        # Get current config
        ETAG=$(aws cloudfront get-distribution-config --id "$DIST_ID" --query 'ETag' --output text)
        aws cloudfront get-distribution-config --id "$DIST_ID" --query 'DistributionConfig' > /tmp/dist-config.json

        # Disable it
        jq '.Enabled = false' /tmp/dist-config.json > /tmp/dist-config-disabled.json
        aws cloudfront update-distribution --id "$DIST_ID" --if-match "$ETAG" \
            --distribution-config file:///tmp/dist-config-disabled.json > /dev/null

        print_step "Waiting for distribution to be disabled (this may take several minutes)..."
        aws cloudfront wait distribution-deployed --id "$DIST_ID" 2>/dev/null || true
    fi

    # Get fresh ETag and delete
    ETAG=$(aws cloudfront get-distribution --id "$DIST_ID" --query 'ETag' --output text)

    print_step "Deleting distribution..."
    if aws cloudfront delete-distribution --id "$DIST_ID" --if-match "$ETAG" 2>/dev/null; then
        print_success "Deleted CloudFront distribution"
    else
        print_warning "Could not delete distribution (may still be disabling)"
    fi

    rm -f /tmp/dist-config.json /tmp/dist-config-disabled.json
else
    print_step "No CloudFront distribution found"
fi

# Delete Origin Access Control
OAC_NAME="${PREFIX}-airbrx-app-oac"
OAC_ID=$(aws cloudfront list-origin-access-controls --query \
    "OriginAccessControlList.Items[?Name=='${OAC_NAME}'].Id" --output text 2>/dev/null)

if [[ -n "$OAC_ID" && "$OAC_ID" != "None" ]]; then
    print_step "Deleting Origin Access Control..."
    ETAG=$(aws cloudfront get-origin-access-control --id "$OAC_ID" --query 'ETag' --output text)
    aws cloudfront delete-origin-access-control --id "$OAC_ID" --if-match "$ETAG" 2>/dev/null || true
    print_success "Deleted OAC"
fi

#------------------------------------------------------------------------------
# Delete Lambda Functions
#------------------------------------------------------------------------------

print_header "Deleting Lambda Functions"

delete_lambda() {
    local func_name="$1"

    if aws lambda get-function --function-name "$func_name" &>/dev/null; then
        # Delete function URL first
        if aws lambda get-function-url-config --function-name "$func_name" &>/dev/null; then
            print_step "Deleting function URL: $func_name"
            aws lambda delete-function-url-config --function-name "$func_name" 2>/dev/null || true
        fi

        print_step "Deleting function: $func_name"
        aws lambda delete-function --function-name "$func_name"
        print_success "Deleted: $func_name"
    else
        print_step "Function not found: $func_name"
    fi
}

delete_lambda "${PREFIX}-airbrx-api"
delete_lambda "${PREFIX}-airbrx-gateway"
delete_lambda "${PREFIX}-airbrx-log-summary"

#------------------------------------------------------------------------------
# Delete S3 Buckets
#------------------------------------------------------------------------------

print_header "Deleting S3 Buckets"

delete_bucket() {
    local bucket_name="$1"

    if aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
        print_step "Deleting bucket: $bucket_name"

        # Empty bucket (handles current objects)
        aws s3 rm "s3://${bucket_name}" --recursive 2>/dev/null || true

        # Delete all object versions and delete markers (required for versioned buckets)
        local versions=$(aws s3api list-object-versions --bucket "$bucket_name" \
            --query '[Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers[].{Key:Key,VersionId:VersionId}][]' \
            --output json 2>/dev/null)

        if [[ -n "$versions" && "$versions" != "[]" ]]; then
            echo "$versions" | jq -c '.[]' 2>/dev/null | while read -r obj; do
                local key=$(echo "$obj" | jq -r '.Key')
                local vid=$(echo "$obj" | jq -r '.VersionId')
                [[ -n "$key" && "$key" != "null" ]] && \
                    aws s3api delete-object --bucket "$bucket_name" --key "$key" --version-id "$vid" 2>/dev/null || true
            done
        fi

        # Delete the bucket
        aws s3 rb "s3://${bucket_name}" 2>/dev/null || true
        print_success "Deleted: $bucket_name"
    else
        print_step "Bucket not found: $bucket_name"
    fi
}

delete_bucket "${PREFIX}-airbrx-admin-storage"
delete_bucket "${PREFIX}-airbrx-gateway-storage"
delete_bucket "${PREFIX}-airbrx-app"

#------------------------------------------------------------------------------
# Delete IAM Roles
#------------------------------------------------------------------------------

print_header "Deleting IAM Roles"

delete_role() {
    local role_name="$1"

    if aws iam get-role --role-name "$role_name" &>/dev/null; then
        # Delete inline policies
        print_step "Removing policies from: $role_name"
        POLICIES=$(aws iam list-role-policies --role-name "$role_name" --query 'PolicyNames' --output json)
        echo "$POLICIES" | jq -r '.[]' 2>/dev/null | while read -r policy; do
            aws iam delete-role-policy --role-name "$role_name" --policy-name "$policy" 2>/dev/null || true
        done

        # Detach managed policies
        ATTACHED=$(aws iam list-attached-role-policies --role-name "$role_name" --query 'AttachedPolicies[].PolicyArn' --output json)
        echo "$ATTACHED" | jq -r '.[]' 2>/dev/null | while read -r arn; do
            aws iam detach-role-policy --role-name "$role_name" --policy-arn "$arn" 2>/dev/null || true
        done

        print_step "Deleting role: $role_name"
        aws iam delete-role --role-name "$role_name"
        print_success "Deleted: $role_name"
    else
        print_step "Role not found: $role_name"
    fi
}

delete_role "${PREFIX}-airbrx-api-role"
delete_role "${PREFIX}-airbrx-gateway-role"
delete_role "${PREFIX}-airbrx-log-summary-role"

#------------------------------------------------------------------------------
# Cleanup Complete
#------------------------------------------------------------------------------

print_header "Cleanup Complete"

echo "
All Airbrx resources for '${PREFIX}' have been deleted:

  ✓ CloudFront distribution
  ✓ S3 buckets (admin-storage, gateway-storage, app)
  ✓ Lambda functions (api, gateway, log-summary)
  ✓ IAM roles and policies

Note: CloudWatch log groups may still exist and can be deleted manually:
  aws logs delete-log-group --log-group-name /aws/lambda/${PREFIX}-airbrx-api
  aws logs delete-log-group --log-group-name /aws/lambda/${PREFIX}-airbrx-gateway
  aws logs delete-log-group --log-group-name /aws/lambda/${PREFIX}-airbrx-log-summary
"

print_success "Cleanup complete!"
