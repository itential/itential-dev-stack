#!/bin/bash
# Configure Gateway Manager - https://docs.itential.com/docs/gateway-manager-release-notes
# Uploads certificates and creates gateway cluster via REST

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# wait for gw manager api to be ready
wait_for_gateway_manager_api() {
    local max_wait=60
    local interval=3

    log_info "Waiting for Gateway Manager API to initialize..."

    for ((i=0; i<max_wait; i+=interval)); do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            "${PLATFORM_URL}/gateway_manager/v1/certificates" \
            -b "$COOKIE_JAR" 2>/dev/null)

        if [ "$http_code" = "200" ]; then
            log_info "Gateway Manager API is ready"
            return 0
        fi

        sleep "$interval"
    done

    log_warn "Gateway Manager API readiness timeout, proceeding anyway..."
    return 1
}

# check for jq (required for JSON handling)
if ! command -v jq &>/dev/null; then
    log_error "jq is required but not installed. Install with applicable package manager."
    exit 1
fi

# load env
if [ -f "$PROJECT_ROOT/.env" ]; then
    source "$PROJECT_ROOT/.env"
fi

# configuration
PLATFORM_URL="${PLATFORM_URL:-http://localhost:${PLATFORM_PORT:-3000}}"

# default admin credentials for initial setup
ADMIN_USER="admin"
ADMIN_PASSWORD="admin"

CLUSTER_ID="${GATEWAY5_CLUSTER_ID:-cluster_1}"
CERT_FILE="$PROJECT_ROOT/volumes/gateway5/certificates/gw-manager.pem"
KEY_FILE="$PROJECT_ROOT/volumes/gateway5/certificates/gw-manager-key.pem"

# cookie jar for authenticated api calls
COOKIE_JAR=$(mktemp)
trap "rm -f $COOKIE_JAR" EXIT

log_info "Configuring Gateway Manager..."
log_info "Platform URL: $PLATFORM_URL"
log_info "Cluster ID: $CLUSTER_ID"

# do certificate files exist?
if [ ! -f "$CERT_FILE" ]; then
    log_error "Certificate file not found: $CERT_FILE"
    log_info "Run: ./scripts/generate-certificates.sh"
    exit 1
fi

if [ ! -f "$KEY_FILE" ]; then
    log_error "Key file not found: $KEY_FILE"
    log_info "Run: ./scripts/generate-certificates.sh"
    exit 1
fi

log_info "Certificate files found"

# wait for platform to be accessible
log_info "Waiting for Platform API..."
MAX_WAIT=60
for ((i=0; i<MAX_WAIT; i+=2)); do

    # is platform responding?
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

# add additional time for internal services to fully initialize
PLATFORM_INIT_DELAY="${PLATFORM_INIT_DELAY:-10}"
log_info "Waiting ${PLATFORM_INIT_DELAY}s for Platform internal services to initialize..."
sleep "$PLATFORM_INIT_DELAY"

# initial setup done with `admin`
log_info "Authenticating as admin..."
LOGIN_RESPONSE=$(curl -sf -X POST "${PLATFORM_URL}/login" \
    -H "Content-Type: application/json" \
    -c "$COOKIE_JAR" \
    -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASSWORD}\"}" 2>/dev/null) || {
    log_warn "Could not authenticate (Platform may still be initializing)"
    LOGIN_RESPONSE=""
}

if [ -n "$LOGIN_RESPONSE" ]; then
    log_info "Authenticated successfully"

    # wait for gateway manager api before proceeding
    wait_for_gateway_manager_api
fi

# role ids for permissions (looked up dynamically)
ROLE_GATEWAY_READ=""
ROLE_GATEWAY_UPDATE=""
ROLE_GATEWAY_CREATE=""
ALL_ROLE_IDS=""

lookup_all_roles() {
    log_info "Looking up all role IDs..."
    local roles_response
    roles_response=$(curl -sf "${PLATFORM_URL}/authorization/roles?limit=200" -b "$COOKIE_JAR" 2>/dev/null)

    # build json array of all role ids -> for assignment
    ALL_ROLE_IDS=$(echo "$roles_response" | jq -c '[.results[] | {roleId: ._id}]')

    # still extract gateway roles for logging
    ROLE_GATEWAY_READ=$(echo "$roles_response" | jq -r '.results[] | select(.name == "gateway:read") | ._id')
    ROLE_GATEWAY_UPDATE=$(echo "$roles_response" | jq -r '.results[] | select(.name == "gateway:update") | ._id')
    ROLE_GATEWAY_CREATE=$(echo "$roles_response" | jq -r '.results[] | select(.name == "gateway:create") | ._id')

    local role_count
    role_count=$(echo "$roles_response" | jq '.results | length')
    log_info "Found $role_count roles total (including gateway:read, gateway:update, gateway:create)"

    if [ -z "$ALL_ROLE_IDS" ] || [ "$ALL_ROLE_IDS" = "[]" ]; then
        log_warn "Could not find any roles"
        return 1
    fi
    return 0
}

# global vars to store certificate id for gateway creation
CERT_ID=""

# --- API Functions ---

upload_certificate() {
    local cert_name="gateway5-${CLUSTER_ID}"
    local cert_content
    cert_content=$(jq -Rs '.' "$CERT_FILE")

    # do certs already exist?
    local existing_id
    existing_id=$(curl -sf "${PLATFORM_URL}/gateway_manager/v1/certificates" \
        -b "$COOKIE_JAR" 2>/dev/null | jq -r ".results[] | select(.alias == \"${cert_name}\") | ._id") || true

    if [ -n "$existing_id" ]; then
        log_info "Certificate '$cert_name' already exists (ID: $existing_id)"
        CERT_ID="$existing_id"
        return 0
    fi

    log_info "Uploading certificate '$cert_name'..."

    local max_attempts=5
    local delay=3

    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        local response http_code
        response=$(curl -s -w "\n%{http_code}" -X POST "${PLATFORM_URL}/gateway_manager/v1/certificates" \
            -H "Content-Type: application/json" \
            -b "$COOKIE_JAR" \
            -d "{\"raw_certificate\":${cert_content},\"contract_id\":\"${cert_name}\",\"alias\":\"${cert_name}\"}" 2>/dev/null)

        http_code=$(echo "$response" | tail -1)
        response=$(echo "$response" | head -n -1)

        # success!
        if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then

            # try different response formats
            CERT_ID=$(echo "$response" | jq -r '.data._id // .results.upsertedIds["0"] // empty')
            if [ -n "$CERT_ID" ] && [ "$CERT_ID" != "null" ]; then
                log_info "Certificate uploaded (ID: $CERT_ID)"
                return 0
            fi
            # if id extraction fails but http returns 200, certificate may still be uploaded
            # does it exist now?
            sleep 1
            existing_id=$(curl -sf "${PLATFORM_URL}/gateway_manager/v1/certificates" \
                -b "$COOKIE_JAR" 2>/dev/null | jq -r ".results[] | select(.alias == \"${cert_name}\") | ._id") || true
            if [ -n "$existing_id" ]; then
                log_info "Certificate '$cert_name' uploaded (ID: $existing_id)"
                CERT_ID="$existing_id"
                return 0
            fi
        fi

        # already exists!
        if [ "$http_code" = "409" ]; then
            existing_id=$(curl -sf "${PLATFORM_URL}/gateway_manager/v1/certificates" \
                -b "$COOKIE_JAR" 2>/dev/null | jq -r ".results[] | select(.alias == \"${cert_name}\") | ._id") || true
            if [ -n "$existing_id" ]; then
                log_info "Certificate '$cert_name' already exists (ID: $existing_id)"
                CERT_ID="$existing_id"
                return 0
            fi
        fi

        # retry on connection errors or service unavailable
        if [ $attempt -lt $max_attempts ]; then
            case "$http_code" in
                000|502|503|504)
                    log_warn "Gateway Manager not ready (HTTP $http_code), retrying in ${delay}s... ($attempt/$max_attempts)"
                    sleep "$delay"
                    delay=$((delay + 2))
                    continue
                    ;;
            esac
        fi

        log_warn "Certificate upload failed (HTTP $http_code)"
        return 1
    done

    log_warn "Certificate upload failed after $max_attempts attempts"
    return 1
}

ensure_admin_group() {
    local group_name="admin_group"

    # does group exist?
    local existing
    existing=$(curl -sf "${PLATFORM_URL}/authorization/groups?limit=100" \
        -b "$COOKIE_JAR" 2>/dev/null | jq -r ".results[] | select(.name == \"${group_name}\") | ._id") || true

    if [ -n "$existing" ]; then
        log_info "Group '$group_name' already exists (ID: $existing), updating with all roles..." >&2

        # update group with ALL roles
        curl -sf -X PATCH "${PLATFORM_URL}/authorization/groups/${existing}" \
            -H "Content-Type: application/json" \
            -b "$COOKIE_JAR" \
            -d "{\"updates\":{\"assignedRoles\":${ALL_ROLE_IDS}}}" 2>/dev/null > /dev/null || true
        echo "$existing"
        return 0
    fi

    # create group with ALL roles
    log_info "Creating group '$group_name' with all roles..." >&2
    local response
    response=$(curl -sf -X POST "${PLATFORM_URL}/authorization/groups" \
        -H "Content-Type: application/json" \
        -b "$COOKIE_JAR" \
        -d "{\"group\":{\"name\":\"${group_name}\",\"provenance\":\"Pronghorn\",\"description\":\"Admin group with full permissions\",\"assignedRoles\":${ALL_ROLE_IDS},\"memberOf\":[],\"inactive\":false}}" 2>/dev/null) || {
        log_warn "Failed to create group"
        return 1
    }

    local group_id
    group_id=$(echo "$response" | jq -r '.data._id // empty')
    if [ -n "$group_id" ]; then
        log_info "Group '$group_name' created (ID: $group_id)" >&2
        echo "$group_id"
        return 0
    fi

    log_warn "Group creation response unexpected"
    return 1
}

assign_user_permissions() {
    local account_id="$1"
    local group_id="$2"

    log_info "Assigning group membership and all roles in single operation..."

    # build json payload using jq / avoid string interpolation issues
    local payload
    payload=$(jq -n -c \
        --arg gid "$group_id" \
        --argjson roles "$ALL_ROLE_IDS" \
        '{updates: {memberOf: [{aaaManaged: false, groupId: $gid}], assignedRoles: $roles}}')

    local response
    response=$(curl -s -X PATCH "${PLATFORM_URL}/authorization/accounts/${account_id}" \
        -H "Content-Type: application/json" \
        -b "$COOKIE_JAR" \
        -d "$payload" 2>/dev/null)

    if echo "$response" | jq -e '.status == "OK"' &>/dev/null; then
        log_info "User permissions assigned successfully"
        return 0
    else
        log_warn "Failed to assign user permissions: $response"
        return 1
    fi
}

create_gateway() {
    log_info "Creating gateway cluster '$CLUSTER_ID'..."

    # does gateway already exist?
    local existing
    existing=$(curl -sf "${PLATFORM_URL}/gateway_manager/v1/gateways" \
        -b "$COOKIE_JAR" 2>/dev/null | jq -r ".results[]? | select(.cluster_id == \"${CLUSTER_ID}\") | .cluster_id") || true

    if [ "$existing" = "$CLUSTER_ID" ]; then
        log_info "Gateway cluster '$CLUSTER_ID' already exists"
        return 0
    fi

    # verify certificate id
    if [ -z "$CERT_ID" ]; then
        log_warn "No certificate ID available - gateway may not connect properly"
    fi

    # gateway requires a group and certificate reference for link to work
    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X POST "${PLATFORM_URL}/gateway_manager/v1/gateways" \
        -H "Content-Type: application/json" \
        -b "$COOKIE_JAR" \
        -d "{\"gateway\":{\"cluster_id\":\"${CLUSTER_ID}\",\"description\":\"Auto-configured gateway\",\"enabled\":true,\"readonly\":false,\"certificates\":[\"${CERT_ID}\"],\"groups\":[\"admin_group\"]}}" 2>/dev/null)

    http_code=$(echo "$response" | tail -1)
    response=$(echo "$response" | head -n -1)

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        log_info "Gateway cluster created with certificate and enabled"
        return 0
    elif [ "$http_code" = "409" ]; then
        log_info "Gateway cluster '$CLUSTER_ID' already exists"
        return 0
    else
        log_warn "Gateway cluster creation failed (HTTP $http_code): $response"
        return 1
    fi
}

verify_connection() {
    log_info "Waiting for Gateway5 to connect..."
    for i in {1..12}; do
        local response

        # check all connections and look for our cluster
        response=$(curl -sf "${PLATFORM_URL}/gateway_manager/v1/connections" \
            -b "$COOKIE_JAR" 2>/dev/null) || true
        if [ -n "$response" ] && echo "$response" | jq -e ".\"${CLUSTER_ID}\"" &>/dev/null; then
            log_info "Gateway5 connected successfully!"
            return 0
        fi
        sleep 5
    done
    log_warn "Gateway5 not yet connected (will connect when container starts)"
    return 0
}

# --- phase 1: setup ---
# upload cert / create admin group

CERT_UPLOADED=false
GROUP_CREATED=false
GATEWAY_CREATED=false

if [ -n "$LOGIN_RESPONSE" ]; then
    log_info "=== Phase 1: Initial Setup (as built-in admin) ==="

    # look up ALL role ids (they vary per instance)
    if ! lookup_all_roles; then
        log_warn "Could not look up roles, gateway creation may fail"
    fi

    # upload cert
    if upload_certificate; then
        CERT_UPLOADED=true
    fi

    # create admin_group with ALL roles
    GROUP_ID=$(ensure_admin_group)
    if [ -n "$GROUP_ID" ]; then
        GROUP_CREATED=true

        # assign roles and group membership to admin user
        ROLES_ASSIGNED=false
        ADMIN_ACCOUNT_ID="000000000000000000000000"  # built-in admin has fixed id
        if assign_user_permissions "$ADMIN_ACCOUNT_ID" "$GROUP_ID"; then
            ROLES_ASSIGNED=true
            log_info "Admin user configured with roles and group membership"
        else
            log_warn "Failed to configure admin permissions - gateway creation may fail"
        fi
    fi

    # attempt gateway creation (requires roles to be assigned)
    if [ "$CERT_UPLOADED" = true ] && [ "$GROUP_CREATED" = true ] && [ "$ROLES_ASSIGNED" = true ]; then
        log_info "Attempting gateway cluster creation..."
        if create_gateway; then
            GATEWAY_CREATED=true
        fi
    else
        if [ "$ROLES_ASSIGNED" != true ]; then
            log_warn "Skipping gateway creation - admin roles not assigned"
        fi
    fi

    if [ "$GATEWAY_CREATED" = true ]; then
        verify_connection
        log_info "Gateway Manager configured successfully via API!"
        echo ""
        log_info "Configuration complete. Verify with: make status"
        log_info "Login as: admin / admin"
        exit 0
    fi
fi

# show status and any remaining manual steps
echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  Gateway Manager Configuration Status${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# show what was accomplished
if [ "$CERT_UPLOADED" = true ]; then
    echo -e "${GREEN}✓${NC} Certificate '${BOLD}gateway5-${CLUSTER_ID}${NC}' uploaded"
else
    echo -e "${RED}✗${NC} Certificate upload failed"
fi

if [ "$GROUP_CREATED" = true ]; then
    echo -e "${GREEN}✓${NC} Group '${BOLD}admin_group${NC}' configured with gateway roles"
else
    echo -e "${YELLOW}○${NC} Group 'admin_group' may need configuration"
fi

if [ "$GATEWAY_CREATED" = true ]; then
    echo -e "${GREEN}✓${NC} Gateway cluster '${BOLD}${CLUSTER_ID}${NC}' created"
    echo ""
    log_info "Configuration complete. Verify with: make status"
    exit 0
fi

# gateway not created - show manual steps (failback)
echo ""
echo -e "${BOLD}${CYAN}───────────────────────────────────────────────────────────────${NC}"
echo -e "${BOLD}Remaining Manual Step:${NC} Create the gateway cluster in the UI"
echo -e "${BOLD}${CYAN}───────────────────────────────────────────────────────────────${NC}"
echo ""
echo -e "  ${CYAN}1.${NC} Login to Platform: ${BOLD}${PLATFORM_URL}${NC}"
echo -e "     (admin / admin)"
echo ""

STEP=2
if [ "$GROUP_CREATED" = false ]; then
    echo -e "  ${CYAN}${STEP}.${NC} Navigate to: ${BOLD}Admin Essentials → Authorization → Groups${NC}"
    echo -e "     - Create group '${BOLD}admin_group${NC}'"
    echo -e "     - Under ${BOLD}Roles${NC} tab, add: gateway:read, gateway:update, gateway:create"
    echo -e "     - Click ${BOLD}Save${NC}"
    echo ""
    STEP=$((STEP + 1))
fi

echo -e "  ${CYAN}${STEP}.${NC} Navigate to: ${BOLD}Admin Essentials → Gateway Manager${NC}"
STEP=$((STEP + 1))

echo ""
echo -e "  ${CYAN}${STEP}.${NC} Create new cluster:"
echo -e "     - Cluster ID: ${BOLD}${CLUSTER_ID}${NC}"
echo -e "     - Select certificate: ${BOLD}gateway5-${CLUSTER_ID}${NC}"
echo -e "     - Assign to group: ${BOLD}admin_group${NC}"
echo -e "     - Enable the cluster"
echo ""

if [ "$CERT_UPLOADED" = false ]; then
    echo -e "${BOLD}${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}Certificate Content (copy/paste into Platform):${NC}"
    echo -e "${BOLD}${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo ""
    cat "$CERT_FILE"
    echo ""
    echo -e "${BOLD}${CYAN}───────────────────────────────────────────────────────────────${NC}"
fi

echo ""
echo -e "${BOLD}After configuration:${NC}"
echo -e "  - Gateway5 will connect automatically when started"
echo -e "  - Check logs: ${BOLD}docker logs platform${NC}"
echo -e "  - Verify status: ${BOLD}make status${NC}"
echo ""

log_info "Manual steps required to complete gateway cluster setup"
