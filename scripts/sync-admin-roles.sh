#!/bin/bash
# Sync all roles to admin_group and admin@itential
# Run after adapter setup to ensure admin users have all adapter roles
# This script = idempotent meaning, it's safe to run multiple times

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# check for jq
if ! command -v jq &>/dev/null; then
    log_error "jq is required but not installed"
    exit 1
fi

# load env
if [ -f "$PROJECT_ROOT/.env" ]; then
    source "$PROJECT_ROOT/.env"
fi

log_info "Syncing admin roles..."

# check if mongodb container is running
if ! docker ps --format '{{.Names}}' | grep -q '^mongodb$'; then
    log_warn "MongoDB container not running - skipping role sync"
    exit 0
fi

# sync admin_group with all available roles
log_info "Syncing admin_group with all available roles..."
MONGO_SYNC_RESULT=$(docker exec mongodb mongosh --quiet --eval '
    db = db.getSiblingDB("itential");
    var group = db.groups.findOne({ name: "admin_group" });
    if (!group) {
        print(JSON.stringify({ error: "admin_group not found" }));
    } else {
        var allRoles = db.roles.find({}, { _id: 1 }).toArray();
        var allRoleIds = allRoles.map(r => ({ roleId: r._id }));
        var result = db.groups.updateOne(
            { name: "admin_group" },
            { $set: { assignedRoles: allRoleIds } }
        );
        print(JSON.stringify({ result: result, roleCount: allRoleIds.length }));
    }
' 2>/dev/null)

if echo "$MONGO_SYNC_RESULT" | grep -q '"error"'; then
    log_warn "admin_group not found - run Gateway Manager setup first"
else
    SYNC_ROLE_COUNT=$(echo "$MONGO_SYNC_RESULT" | jq -r '.roleCount // 0' 2>/dev/null)
    if [ "$SYNC_ROLE_COUNT" -gt 0 ]; then
        log_info "admin_group synced with $SYNC_ROLE_COUNT roles"
    else
        log_warn "Failed to sync admin_group roles"
    fi
fi

# if LDAP is enabled, sync roles to admin@itential user
if [ "$LDAP_ENABLED" = "true" ]; then
    log_info "Syncing roles to admin@itential..."
    MONGO_USER_RESULT=$(docker exec mongodb mongosh --quiet --eval '
        db = db.getSiblingDB("itential");
        var user = db.accounts.findOne({ username: "admin@itential", provenance: "LDAP" });
        if (!user) {
            print(JSON.stringify({ error: "user not found" }));
        } else {
            var allRoles = db.roles.find({}, { _id: 1 }).toArray();
            var allRoleIds = allRoles.map(r => ({ roleId: r._id }));
            var result = db.accounts.updateOne(
                { username: "admin@itential", provenance: "LDAP" },
                { $set: { assignedRoles: allRoleIds } }
            );
            print(JSON.stringify({ result: result, roleCount: allRoleIds.length }));
        }
    ' 2>/dev/null)

    if echo "$MONGO_USER_RESULT" | grep -q '"error"'; then
        log_warn "admin@itential not found - user may not have logged in yet"
    else
        USER_ROLE_COUNT=$(echo "$MONGO_USER_RESULT" | jq -r '.roleCount // 0' 2>/dev/null)
        if [ "$USER_ROLE_COUNT" -gt 0 ]; then
            log_info "admin@itential synced with $USER_ROLE_COUNT roles"
        else
            log_warn "Failed to sync admin@itential roles"
        fi
    fi
fi

log_info "Role sync complete"
