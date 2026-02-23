#!/bin/bash
#
# status.sh - Airbrx Data Gateway Status Check
#
# Shows deployment status, URLs, and resource health
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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

print_section() {
    echo ""
    echo -e "${CYAN}── $1 ──${NC}"
    echo ""
}

print_ok() {
    echo -e "  ${GREEN}✓${NC} $1"
}

print_warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
}

print_fail() {
    echo -e "  ${RED}✗${NC} $1"
}

print_info() {
    echo -e "  ${BLUE}ℹ${NC} $1"
}

print_url() {
    echo -e "  ${GREEN}→${NC} $1"
}

die() {
    echo -e "${RED}Error:${NC} $1"
    exit 1
}

#------------------------------------------------------------------------------
# Load Configuration
#------------------------------------------------------------------------------

CONFIG_FILE="${1:-}"
if [[ -z "$CONFIG_FILE" ]]; then
    CONFIG_FILE=$(ls generated/*-config.env 2>/dev/null | head -1)
    if [[ -z "$CONFIG_FILE" ]]; then
        die "Usage: ./status.sh <config-file> or run prereq.sh first"
    fi
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    die "Config file not found: $CONFIG_FILE"
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

#------------------------------------------------------------------------------
# Header
#------------------------------------------------------------------------------

echo ""
echo -e "${CYAN}Airbrx Data Gateway Status${NC}"
echo -e "Deployment: ${GREEN}${PREFIX}${NC} in ${GREEN}${AWS_REGION}${NC}"
echo ""

#------------------------------------------------------------------------------
# AWS Account
#------------------------------------------------------------------------------

print_section "AWS Account"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || die "AWS CLI not configured"
AWS_IDENTITY=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)

print_ok "Account: $AWS_ACCOUNT_ID"
print_info "Identity: $AWS_IDENTITY"

#------------------------------------------------------------------------------
# S3 Buckets
#------------------------------------------------------------------------------

print_section "S3 Buckets"

check_bucket() {
    local bucket="$1"
    local desc="$2"

    if aws s3api head-bucket --bucket "$bucket" &>/dev/null; then
        local count=$(aws s3 ls "s3://${bucket}" --recursive 2>/dev/null | wc -l | tr -d ' ')
        print_ok "$desc: $bucket ($count objects)"
    else
        print_fail "$desc: $bucket (not found)"
    fi
}

check_bucket "${PREFIX}-airbrx-admin-storage" "Admin Storage"
check_bucket "${PREFIX}-airbrx-gateway-storage" "Gateway Storage"
check_bucket "${PREFIX}-airbrx-app" "App (Frontend)"

#------------------------------------------------------------------------------
# IAM Roles
#------------------------------------------------------------------------------

print_section "IAM Roles"

check_role() {
    local role="$1"

    if aws iam get-role --role-name "$role" &>/dev/null; then
        print_ok "$role"
    else
        print_fail "$role (not found)"
    fi
}

check_role "${PREFIX}-airbrx-api-role"
check_role "${PREFIX}-airbrx-gateway-role"
check_role "${PREFIX}-airbrx-log-summary-role"

#------------------------------------------------------------------------------
# Lambda Functions
#------------------------------------------------------------------------------

print_section "Lambda Functions"

check_lambda() {
    local func="$1"
    local desc="$2"

    local info=$(aws lambda get-function --function-name "$func" 2>/dev/null)

    if [[ -n "$info" ]]; then
        local state=$(echo "$info" | jq -r '.Configuration.State')
        local memory=$(echo "$info" | jq -r '.Configuration.MemorySize')
        local runtime=$(echo "$info" | jq -r '.Configuration.Runtime')
        local last_modified=$(echo "$info" | jq -r '.Configuration.LastModified' | cut -d'T' -f1)

        if [[ "$state" == "Active" ]]; then
            print_ok "$desc: $func"
            print_info "  Runtime: $runtime | Memory: ${memory}MB | Updated: $last_modified"
        else
            print_warn "$desc: $func (State: $state)"
        fi

        # Check for function URL
        local url_config=$(aws lambda get-function-url-config --function-name "$func" 2>/dev/null)
        if [[ -n "$url_config" ]]; then
            local url=$(echo "$url_config" | jq -r '.FunctionUrl')
            print_url "$url"
        fi
    else
        print_fail "$desc: $func (not found)"
    fi
}

check_lambda "${PREFIX}-airbrx-api" "API"
check_lambda "${PREFIX}-airbrx-gateway" "Gateway"
check_lambda "${PREFIX}-airbrx-log-summary" "Log Summary"

#------------------------------------------------------------------------------
# CloudFront Distributions
#------------------------------------------------------------------------------

print_section "CloudFront Distributions"

check_cloudfront() {
    local name="$1"
    local search="$2"
    local var_name="$3"

    local dist_id=$(aws cloudfront list-distributions --query \
        "DistributionList.Items[?contains(Comment, '${search}')].Id" \
        --output text 2>/dev/null | head -1)

    if [[ -n "$dist_id" && "$dist_id" != "None" ]]; then
        local info=$(aws cloudfront get-distribution --id "$dist_id" 2>/dev/null)
        local status=$(echo "$info" | jq -r '.Distribution.Status')
        local domain=$(echo "$info" | jq -r '.Distribution.DomainName')
        local enabled=$(echo "$info" | jq -r '.Distribution.DistributionConfig.Enabled')

        if [[ "$status" == "Deployed" && "$enabled" == "true" ]]; then
            print_ok "$name: $dist_id"
        else
            print_warn "$name: $dist_id (Status: $status, Enabled: $enabled)"
        fi
        print_url "https://${domain}"

        # Export for later use
        eval "${var_name}='https://${domain}'"
        eval "${var_name}_DOMAIN='${domain}'"
    else
        print_fail "$name: Not found"
        eval "${var_name}=''"
    fi
}

check_cloudfront "Frontend" "Airbrx App - ${PREFIX}" "FRONTEND_CF"
check_cloudfront "API" "Airbrx api - ${PREFIX}" "API_CF"
check_cloudfront "Gateway" "Airbrx gateway - ${PREFIX}" "GATEWAY_CF"

#------------------------------------------------------------------------------
# Health Checks (via CloudFront)
#------------------------------------------------------------------------------

print_section "Endpoint Health"

if [[ -n "$API_CF" ]]; then
    API_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${API_CF}/health" 2>/dev/null || echo "000")
    if [[ "$API_HEALTH" == "200" ]]; then
        print_ok "API Health: OK (200)"
    elif [[ "$API_HEALTH" == "000" ]]; then
        print_fail "API Health: Connection failed"
    else
        print_warn "API Health: HTTP $API_HEALTH"
    fi
else
    print_fail "API: No CloudFront distribution"
fi

if [[ -n "$GATEWAY_CF" ]]; then
    GW_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${GATEWAY_CF}/" 2>/dev/null || echo "000")
    if [[ "$GW_HEALTH" != "000" ]]; then
        print_ok "Gateway: Responding (HTTP $GW_HEALTH)"
    else
        print_fail "Gateway: Connection failed"
    fi
else
    print_fail "Gateway: No CloudFront distribution"
fi

if [[ -n "$FRONTEND_CF" ]]; then
    CF_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${FRONTEND_CF}/" 2>/dev/null || echo "000")
    if [[ "$CF_HEALTH" == "200" ]]; then
        print_ok "Frontend: OK (200)"
    elif [[ "$CF_HEALTH" == "000" ]]; then
        print_fail "Frontend: Connection failed"
    else
        print_warn "Frontend: HTTP $CF_HEALTH"
    fi
fi

#------------------------------------------------------------------------------
# Summary URLs
#------------------------------------------------------------------------------

print_header "Deployment URLs"

echo -e "  ${CYAN}Frontend App:${NC}"
if [[ -n "$FRONTEND_CF" ]]; then
    echo -e "    ${FRONTEND_CF}"
else
    echo -e "    ${RED}Not deployed${NC}"
fi

echo ""
echo -e "  ${CYAN}API Endpoint:${NC}"
if [[ -n "$API_CF" ]]; then
    echo -e "    ${API_CF}"
else
    echo -e "    ${RED}Not deployed${NC}"
fi

echo ""
echo -e "  ${CYAN}Gateway Endpoint:${NC}"
if [[ -n "$GATEWAY_CF" ]]; then
    echo -e "    ${GATEWAY_CF}"
else
    echo -e "    ${RED}Not deployed${NC}"
fi

echo ""
