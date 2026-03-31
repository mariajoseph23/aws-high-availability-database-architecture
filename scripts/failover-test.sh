#!/usr/bin/env bash
# =============================================================================
# RDS Failover Test Script
# =============================================================================
# Simulates a database failover on a Multi-AZ RDS instance and monitors
# the switchover process, measuring actual downtime.
#
# Usage:
#   ./failover-test.sh [--db-identifier <identifier>] [--region <region>]
#
# Prerequisites:
#   - AWS CLI v2 configured with appropriate IAM permissions
#   - jq installed for JSON parsing
#   - psql (optional) for connection-level failover measurement
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

DB_IDENTIFIER="${DB_IDENTIFIER:-production-ha-postgresql-primary}"
AWS_REGION="${AWS_REGION:-us-east-1}"
LOG_FILE="failover-test-$(date +%Y%m%d-%H%M%S).log"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# -----------------------------------------------------------------------------
# Argument Parsing
# -----------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case $1 in
    --db-identifier) DB_IDENTIFIER="$2"; shift 2 ;;
    --region)        AWS_REGION="$2";     shift 2 ;;
    --help)
      echo "Usage: $0 [--db-identifier <id>] [--region <region>]"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "${timestamp} | $1" | tee -a "$LOG_FILE"
}

get_db_status() {
  aws rds describe-db-instances \
    --db-instance-identifier "$DB_IDENTIFIER" \
    --region "$AWS_REGION" \
    --query 'DBInstances[0].DBInstanceStatus' \
    --output text 2>/dev/null
}

get_db_az() {
  aws rds describe-db-instances \
    --db-instance-identifier "$DB_IDENTIFIER" \
    --region "$AWS_REGION" \
    --query 'DBInstances[0].AvailabilityZone' \
    --output text 2>/dev/null
}

get_db_endpoint() {
  aws rds describe-db-instances \
    --db-instance-identifier "$DB_IDENTIFIER" \
    --region "$AWS_REGION" \
    --query 'DBInstances[0].Endpoint.Address' \
    --output text 2>/dev/null
}

get_multi_az_status() {
  aws rds describe-db-instances \
    --db-instance-identifier "$DB_IDENTIFIER" \
    --region "$AWS_REGION" \
    --query 'DBInstances[0].MultiAZ' \
    --output text 2>/dev/null
}

wait_for_status() {
  local target_status="$1"
  local timeout="${2:-600}" # default 10 minute timeout
  local elapsed=0
  local interval=10

  while [[ $elapsed -lt $timeout ]]; do
    local current_status
    current_status=$(get_db_status)

    if [[ "$current_status" == "$target_status" ]]; then
      return 0
    fi

    log "${YELLOW}[WAITING]${NC} Status: ${current_status} (target: ${target_status}) — ${elapsed}s elapsed"
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  log "${RED}[TIMEOUT]${NC} Timed out after ${timeout}s waiting for status: ${target_status}"
  return 1
}

# -----------------------------------------------------------------------------
# Pre-Flight Checks
# -----------------------------------------------------------------------------

log "${BLUE}============================================${NC}"
log "${BLUE}  RDS FAILOVER TEST${NC}"
log "${BLUE}============================================${NC}"
log ""
log "${BLUE}[CONFIG]${NC} DB Identifier : ${DB_IDENTIFIER}"
log "${BLUE}[CONFIG]${NC} AWS Region    : ${AWS_REGION}"
log "${BLUE}[CONFIG]${NC} Log File      : ${LOG_FILE}"
log ""

# Check AWS CLI
if ! command -v aws &> /dev/null; then
  log "${RED}[ERROR]${NC} AWS CLI not found. Install it first."
  exit 1
fi

# Check jq
if ! command -v jq &> /dev/null; then
  log "${RED}[ERROR]${NC} jq not found. Install it: sudo apt install jq"
  exit 1
fi

# Verify instance exists
log "${BLUE}[PRE-FLIGHT]${NC} Verifying RDS instance exists..."
CURRENT_STATUS=$(get_db_status)
if [[ -z "$CURRENT_STATUS" || "$CURRENT_STATUS" == "None" ]]; then
  log "${RED}[ERROR]${NC} RDS instance '${DB_IDENTIFIER}' not found in ${AWS_REGION}"
  exit 1
fi

# Verify Multi-AZ is enabled
MULTI_AZ=$(get_multi_az_status)
if [[ "$MULTI_AZ" != "True" ]]; then
  log "${RED}[ERROR]${NC} Multi-AZ is NOT enabled on '${DB_IDENTIFIER}'. Failover requires Multi-AZ."
  exit 1
fi

# Capture pre-failover state
PRE_AZ=$(get_db_az)
PRE_ENDPOINT=$(get_db_endpoint)
log "${GREEN}[PRE-FAILOVER]${NC} Status   : ${CURRENT_STATUS}"
log "${GREEN}[PRE-FAILOVER]${NC} AZ       : ${PRE_AZ}"
log "${GREEN}[PRE-FAILOVER]${NC} Endpoint : ${PRE_ENDPOINT}"
log ""

# Confirm with user
read -p "$(echo -e "${YELLOW}Proceed with failover? This WILL cause brief downtime. (yes/no): ${NC}")" CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  log "${YELLOW}[ABORT]${NC} Failover cancelled by user."
  exit 0
fi

# -----------------------------------------------------------------------------
# Trigger Failover
# -----------------------------------------------------------------------------

log ""
log "${RED}[FAILOVER]${NC} Triggering reboot with failover..."
FAILOVER_START=$(date +%s)

aws rds reboot-db-instance \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --force-failover \
  --region "$AWS_REGION" \
  > /dev/null 2>&1

log "${YELLOW}[FAILOVER]${NC} Failover initiated. Monitoring status..."
log ""

# -----------------------------------------------------------------------------
# Monitor Failover Progress
# -----------------------------------------------------------------------------

# Wait for the instance to leave 'available' status (rebooting)
sleep 5
wait_for_status "available" 600

FAILOVER_END=$(date +%s)
FAILOVER_DURATION=$((FAILOVER_END - FAILOVER_START))

# -----------------------------------------------------------------------------
# Post-Failover Verification
# -----------------------------------------------------------------------------

POST_AZ=$(get_db_az)
POST_ENDPOINT=$(get_db_endpoint)
POST_STATUS=$(get_db_status)

log ""
log "${BLUE}============================================${NC}"
log "${BLUE}  FAILOVER RESULTS${NC}"
log "${BLUE}============================================${NC}"
log ""
log "${GREEN}[POST-FAILOVER]${NC} Status   : ${POST_STATUS}"
log "${GREEN}[POST-FAILOVER]${NC} AZ       : ${POST_AZ}"
log "${GREEN}[POST-FAILOVER]${NC} Endpoint : ${POST_ENDPOINT}"
log ""

if [[ "$PRE_AZ" != "$POST_AZ" ]]; then
  log "${GREEN}[SUCCESS]${NC} AZ changed: ${PRE_AZ} → ${POST_AZ}"
else
  log "${YELLOW}[WARNING]${NC} AZ did NOT change. Failover may not have completed as expected."
fi

log ""
log "${GREEN}[TIMING]${NC} Total failover duration: ${FAILOVER_DURATION} seconds"
log ""

# Check recent RDS events for failover confirmation
log "${BLUE}[EVENTS]${NC} Recent RDS events:"
aws rds describe-events \
  --source-identifier "$DB_IDENTIFIER" \
  --source-type db-instance \
  --duration 30 \
  --region "$AWS_REGION" \
  --query 'Events[*].[Date,Message]' \
  --output table 2>/dev/null | tee -a "$LOG_FILE"

log ""
log "${BLUE}============================================${NC}"
log "${BLUE}  TEST COMPLETE${NC}"
log "${BLUE}============================================${NC}"
log "Full log saved to: ${LOG_FILE}"
