#!/bin/bash
# Configure LDAP Adapter for Platform
# Creates and configures the LDAP adapter via REST API for OpenLDAP auth

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

# configuration
PLATFORM_URL="${PLATFORM_URL:-http://localhost:${PLATFORM_PORT:-3000}}"
ADMIN_USER="admin"
ADMIN_PASSWORD="admin"

# LDAP connection settings (matching openldap.ldif)
LDAP_HOST="${LDAP_HOST:-openldap}"
LDAP_BIND_PASSWORD="${LDAP_ADMIN_PASSWORD:-admin}"

# cookie jar for authenticated api calls
COOKIE_JAR=$(mktemp)
trap "rm -f $COOKIE_JAR" EXIT

log_info "Configuring LDAP adapter..."
log_info "Platform URL: $PLATFORM_URL"

# wait for platform to be accessible
log_info "Waiting for Platform API..."
MAX_WAIT=60
for ((i=0; i<MAX_WAIT; i+=2)); do
    if curl -sf "${PLATFORM_URL}/" &>/dev/null; then
        log_info "Platform is accessible"
        break
    fi
    if [ $i -ge $((MAX_WAIT - 2)) ]; then
        log_error "Platform not accessible after ${MAX_WAIT}s"
        exit 1
    fi
    sleep 2
done

# wait for internal services
PLATFORM_INIT_DELAY="${PLATFORM_INIT_DELAY:-10}"
log_info "Waiting ${PLATFORM_INIT_DELAY}s for Platform services to initialize..."
sleep "$PLATFORM_INIT_DELAY"

# authenticate
log_info "Authenticating as admin..."
LOGIN_RESPONSE=$(curl -sf -X POST "${PLATFORM_URL}/login" \
    -H "Content-Type: application/json" \
    -c "$COOKIE_JAR" \
    -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASSWORD}\"}" 2>/dev/null) || {
    log_error "Authentication failed"
    exit 1
}
log_info "Authenticated successfully"

# fetch local admin's roles now (before LDAP takes over auth)
log_info "Fetching local admin roles..."
LOCAL_ADMIN_ID="000000000000000000000000"
ADMIN_ACCOUNT=$(curl -sf "${PLATFORM_URL}/authorization/accounts/${LOCAL_ADMIN_ID}" -b "$COOKIE_JAR" 2>/dev/null)
if [ -n "$ADMIN_ACCOUNT" ]; then
    ADMIN_ROLES=$(echo "$ADMIN_ACCOUNT" | jq -c '[.assignedRoles[].roleId]')
    ROLE_COUNT=$(echo "$ADMIN_ROLES" | jq 'length')
    log_info "Found $ROLE_COUNT roles to copy"
else
    ADMIN_ROLES="[]"
    log_warn "Could not fetch local admin roles"
fi

# check if LDAP adapter exists, create if not
log_info "Checking for LDAP adapter..."
ADAPTER_CHECK=$(curl -s -w "\n%{http_code}" "${PLATFORM_URL}/adapters/LDAP" -b "$COOKIE_JAR" 2>/dev/null)
ADAPTER_CODE=$(echo "$ADAPTER_CHECK" | tail -1)
ADAPTER_RESPONSE=$(echo "$ADAPTER_CHECK" | sed '$d')

if [ "$ADAPTER_CODE" = "200" ]; then
    ADAPTER_EXISTS=true
elif [ "$ADAPTER_CODE" = "403" ]; then
    # auth error likely means LDAP is already active (local admin can't access API)
    log_info "LDAP adapter appears to be already configured (session auth suggests LDAP is active)"
    log_info "Try logging in with LDAP credentials: admin@itential / admin"
    exit 0
elif [ "$ADAPTER_CODE" = "500" ]; then

    # 500 with "does not exist" message means adapter not created yet
    ADAPTER_EXISTS=false
else
    log_error "Unexpected response checking LDAP adapter (HTTP $ADAPTER_CODE)"
    log_error "Response: $ADAPTER_RESPONSE"
    exit 1
fi

if [ "$ADAPTER_EXISTS" = "false" ]; then

    # adapter doesn't exist - create it
    log_info "LDAP adapter not found, creating..."

    CREATE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${PLATFORM_URL}/adapters" \
        -H "Content-Type: application/json" \
        -b "$COOKIE_JAR" \
        -d '{
          "properties": {
            "name": "LDAP",
            "type": "Adapter",
            "properties": {
              "id": "LDAP",
              "type": "LDAP"
            }
          }
        }' 2>/dev/null)

    CREATE_CODE=$(echo "$CREATE_RESPONSE" | tail -1)
    CREATE_BODY=$(echo "$CREATE_RESPONSE" | sed '$d')

    if [ "$CREATE_CODE" != "200" ]; then
        log_error "Failed to create LDAP adapter (HTTP $CREATE_CODE)"
        log_error "Response: $CREATE_BODY"
        exit 1
    fi

    log_info "LDAP adapter created"

    # fetch adapter info after creation
    ADAPTER_RESPONSE=$(curl -sf "${PLATFORM_URL}/adapters/LDAP" -b "$COOKIE_JAR" 2>/dev/null) || {
        log_error "Failed to fetch LDAP adapter after creation"
        exit 1
    }
fi

ADAPTER_NAME=$(echo "$ADAPTER_RESPONSE" | jq -r '.data.name // empty')
if [ "$ADAPTER_NAME" != "LDAP" ]; then
    log_error "LDAP adapter not available"
    exit 1
fi
log_info "LDAP adapter ready"

# check if already configured and active
EXISTING_URL=$(echo "$ADAPTER_RESPONSE" | jq -r '.data.properties.properties.url // empty')
IS_ACTIVE=$(echo "$ADAPTER_RESPONSE" | jq -r '.metadata.isActive // false')
if [ -n "$EXISTING_URL" ] && [ "$EXISTING_URL" != "null" ] && [ "$IS_ACTIVE" = "true" ]; then
    log_info "LDAP adapter already configured and active (url: $EXISTING_URL)"
    exit 0
fi

# LDAP properties to configure
LDAP_PROPERTIES=$(cat <<EOF
{
  "properties": {
    "url": "ldap://${LDAP_HOST}:389",
    "domain": "cn={0},dc=itential,dc=io",
    "bindUsername": "cn=admin,dc=itential,dc=io",
    "bindPassword": "${LDAP_BIND_PASSWORD}",
    "baseDN": "dc=itential,dc=io",
    "baseUserDN": "dc=itential,dc=io",
    "baseGroupDN": "dc=itential,dc=io",
    "userSearchFilter": "cn",
    "groupSearchFilter": "(objectClass=groupOfNames)",
    "userMembershipAttribute": "memberOf",
    "healthCheckInterval": 5000,
    "timeout": 5000,
    "connectTimeout": 5000,
    "idleTimeout": 5000,
    "timeLimit": 10,
    "reconnect": true,
    "activeDirectory": false,
    "tlsOptions": {
      "requestCert": false
    }
  }
}
EOF
)

# configure LDAP adapter properties (this activates it)
log_info "Configuring LDAP adapter properties..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "${PLATFORM_URL}/adapters/LDAP/properties" \
    -H "Content-Type: application/json" \
    -b "$COOKIE_JAR" \
    -d "$LDAP_PROPERTIES" 2>/dev/null)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
    log_error "Failed to configure LDAP adapter (HTTP $HTTP_CODE)"
    log_error "Response: $RESPONSE_BODY"
    exit 1
fi
log_info "LDAP adapter properties configured"

# wait for adapter to become active
log_info "Waiting for LDAP adapter to activate..."
MAX_WAIT=30
for ((i=0; i<MAX_WAIT; i+=2)); do
    ADAPTER_STATUS=$(curl -sf "${PLATFORM_URL}/adapters/LDAP" -b "$COOKIE_JAR" 2>/dev/null) || true
    IS_ACTIVE=$(echo "$ADAPTER_STATUS" | jq -r '.metadata.isActive // false' 2>/dev/null) || true
    if [ "$IS_ACTIVE" = "true" ]; then
        log_info "LDAP adapter is active"
        break
    fi
    if [ $i -ge $((MAX_WAIT - 2)) ]; then
        log_warn "LDAP adapter not yet active after ${MAX_WAIT}s"
        break
    fi
    sleep 2
done

# provision LDAP user by doing a login (this creates the account in Platform)
log_info "Provisioning LDAP user admin@itential..."
LDAP_LOGIN=$(curl -sf -X POST "${PLATFORM_URL}/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"admin@itential","password":"admin"}' 2>/dev/null) || {
    log_warn "LDAP login failed (user may need to be provisioned manually)"
    log_info "LDAP configuration complete. Users can log in with LDAP credentials."
    exit 0
}
log_info "LDAP user provisioned successfully"

# copy roles from local admin to LDAP admin@itential user via MongoDB - direct db update
if [ "$ADMIN_ROLES" = "[]" ] || [ -z "$ADMIN_ROLES" ]; then
    log_warn "No roles to copy to admin@itential"
else
    log_info "Copying roles to admin@itential via database..."

    # convert role IDs to MongoDB format: [{roleId: ObjectId("...")}, ...]
    MONGO_ROLES=$(echo "$ADMIN_ROLES" | jq -r '[.[] | "{ roleId: ObjectId(\"\(.)\")}"] | join(", ")')

    # update the LDAP user's assignedRoles in MongoDB
    MONGO_RESULT=$(docker exec mongodb mongosh --quiet --eval "
        db = db.getSiblingDB('itential');
        result = db.accounts.updateOne(
            { username: 'admin@itential', provenance: 'LDAP' },
            { \$set: { assignedRoles: [$MONGO_ROLES] } }
        );
        print(JSON.stringify(result));
    " 2>/dev/null)

    if echo "$MONGO_RESULT" | grep -q '"modifiedCount":1'; then
        log_info "Roles copied to admin@itential successfully"
    elif echo "$MONGO_RESULT" | grep -q '"matchedCount":1'; then
        log_info "Roles already assigned to admin@itential"
    else
        log_warn "Failed to copy roles via database: $MONGO_RESULT"
    fi
fi

# add admin@itential to admin_group for Gateway Manager access
log_info "Adding admin@itential to admin_group..."
MONGO_GROUP_RESULT=$(docker exec mongodb mongosh --quiet --eval "
    db = db.getSiblingDB('itential');
    // find admin_group ID
    var group = db.groups.findOne({ name: 'admin_group' }, { _id: 1 });
    if (!group) {
        print(JSON.stringify({ error: 'admin_group not found' }));
    } else {
        // add to user's memberOf if not already present
        var result = db.accounts.updateOne(
            { username: 'admin@itential', provenance: 'LDAP', 'memberOf.groupId': { \$ne: group._id } },
            { \$push: { memberOf: { aaaManaged: false, groupId: group._id } } }
        );
        print(JSON.stringify(result));
    }
" 2>/dev/null)

if echo "$MONGO_GROUP_RESULT" | grep -q '"modifiedCount":1'; then
    log_info "admin@itential added to admin_group"
elif echo "$MONGO_GROUP_RESULT" | grep -q '"matchedCount":0'; then
    log_info "admin@itential already in admin_group"
elif echo "$MONGO_GROUP_RESULT" | grep -q 'error'; then
    log_warn "admin_group not found - run Gateway Manager setup first"
else
    log_warn "Failed to add to admin_group: $MONGO_GROUP_RESULT"
fi

# ensure admin_group has ALL roles (new roles may have been added by adapters)
log_info "Syncing admin_group with all available roles..."
MONGO_SYNC_RESULT=$(docker exec mongodb mongosh --quiet --eval '
    db = db.getSiblingDB("itential");
    var allRoles = db.roles.find({}, { _id: 1 }).toArray();
    var allRoleIds = allRoles.map(r => ({ roleId: r._id }));
    var result = db.groups.updateOne(
        { name: "admin_group" },
        { $set: { assignedRoles: allRoleIds } }
    );
    print(JSON.stringify({ result: result, roleCount: allRoleIds.length }));
' 2>/dev/null)

SYNC_ROLE_COUNT=$(echo "$MONGO_SYNC_RESULT" | jq -r '.roleCount // 0' 2>/dev/null)
if [ "$SYNC_ROLE_COUNT" -gt 0 ]; then
    log_info "admin_group synced with $SYNC_ROLE_COUNT roles"
else
    log_warn "Failed to sync admin_group roles"
fi

log_info "LDAP configuration complete!"
echo ""
echo "LDAP Users:"
echo "  admin@itential / admin"
echo "  builder@itential / builder"
echo "  operator@itential / operator"
echo ""
