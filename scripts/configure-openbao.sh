#!/bin/bash
# Configure OpenBao - Initialize, unseal, and enable KV v2 secrets engine
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

# configuration
OPENBAO_URL="http://localhost:${OPENBAO_PORT:-8200}"
INIT_KEYS_FILE="$PROJECT_ROOT/volumes/openbao/init-keys.json"

log_info "Configuring OpenBao..."
log_info "OpenBao URL: $OPENBAO_URL"

# wait for openbao to be accessible
log_info "Waiting for OpenBao API..."
MAX_WAIT=60
for ((i=0; i<MAX_WAIT; i+=2)); do
    if curl -sf "${OPENBAO_URL}/v1/sys/health?standbyok=true&uninitcode=200&sealedcode=200" &>/dev/null; then
        log_info "OpenBao is accessible"
        break
    fi
    if [ $i -ge $((MAX_WAIT - 2)) ]; then
        log_error "OpenBao not accessible after ${MAX_WAIT}s"
        exit 1
    fi
    sleep 2
done

# check initialization status
INIT_STATUS=$(curl -sf "${OPENBAO_URL}/v1/sys/init" 2>/dev/null) || {
    log_error "Failed to check initialization status"
    exit 1
}

IS_INITIALIZED=$(echo "$INIT_STATUS" | jq -r '.initialized')

if [ "$IS_INITIALIZED" = "false" ]; then
    log_info "OpenBao is not initialized, initializing..."

    # initialize with 1 key share and 1 threshold (suitable for dev/demo)
    # by default, 5 unseal keys get generated requiring 3 to unseal
    INIT_RESPONSE=$(curl -sf -X POST "${OPENBAO_URL}/v1/sys/init" \
        -H "Content-Type: application/json" \
        -d '{"secret_shares": 1, "secret_threshold": 1}' 2>/dev/null) || {
        log_error "Failed to initialize OpenBao"
        exit 1
    }

    # save keys to file
    echo "$INIT_RESPONSE" > "$INIT_KEYS_FILE"
    chmod 600 "$INIT_KEYS_FILE"
    log_info "Initialization keys saved to $INIT_KEYS_FILE"

    # extract root token and unseal key
    ROOT_TOKEN=$(echo "$INIT_RESPONSE" | jq -r '.root_token')
    UNSEAL_KEY=$(echo "$INIT_RESPONSE" | jq -r '.keys[0]')

    log_info "OpenBao initialized successfully"
else
    log_info "OpenBao is already initialized"

    # load keys from file
    if [ ! -f "$INIT_KEYS_FILE" ]; then
        log_error "Init keys file not found: $INIT_KEYS_FILE"
        log_error "OpenBao is initialized but keys are not available"
        log_info "You may need to unseal manually or reinitialize (make clean first)"
        exit 1
    fi

    ROOT_TOKEN=$(jq -r '.root_token' "$INIT_KEYS_FILE")
    UNSEAL_KEY=$(jq -r '.keys[0]' "$INIT_KEYS_FILE")
fi

# check seal status
SEAL_STATUS=$(curl -sf "${OPENBAO_URL}/v1/sys/seal-status" 2>/dev/null) || {
    log_error "Failed to check seal status"
    exit 1
}

IS_SEALED=$(echo "$SEAL_STATUS" | jq -r '.sealed')

if [ "$IS_SEALED" = "true" ]; then
    log_info "OpenBao is sealed, unsealing..."

    UNSEAL_RESPONSE=$(curl -sf -X POST "${OPENBAO_URL}/v1/sys/unseal" \
        -H "Content-Type: application/json" \
        -d "{\"key\": \"${UNSEAL_KEY}\"}" 2>/dev/null) || {
        log_error "Failed to unseal OpenBao"
        exit 1
    }

    IS_STILL_SEALED=$(echo "$UNSEAL_RESPONSE" | jq -r '.sealed')
    if [ "$IS_STILL_SEALED" = "true" ]; then
        log_error "OpenBao is still sealed after unseal attempt"
        exit 1
    fi

    log_info "OpenBao unsealed successfully"
else
    log_info "OpenBao is already unsealed"
fi

# check if KV v2 secrets engine is enabled at secret/
log_info "Checking secrets engines..."
MOUNTS_RESPONSE=$(curl -sf "${OPENBAO_URL}/v1/sys/mounts" \
    -H "X-Vault-Token: ${ROOT_TOKEN}" 2>/dev/null) || {
    log_warn "Could not list mounts (may need to enable secrets engine manually)"
    MOUNTS_RESPONSE="{}"
}

KV_ENABLED=$(echo "$MOUNTS_RESPONSE" | jq -r '.["secret/"] // empty')

if [ -z "$KV_ENABLED" ]; then
    log_info "Enabling KV v2 secrets engine at secret/..."

    ENABLE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${OPENBAO_URL}/v1/sys/mounts/secret" \
        -H "X-Vault-Token: ${ROOT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"type": "kv", "options": {"version": "2"}}' 2>/dev/null)

    HTTP_CODE=$(echo "$ENABLE_RESPONSE" | tail -1)

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
        log_info "KV v2 secrets engine enabled at secret/"
    elif [ "$HTTP_CODE" = "400" ]; then

        # may already exist?
        log_info "KV secrets engine may already be enabled"
    else
        log_warn "Could not enable KV v2 secrets engine (HTTP $HTTP_CODE)"
    fi
else
    log_info "KV secrets engine already enabled at secret/"
fi

# update .env with root token if OPENBAO_ENABLED
if [ "$OPENBAO_ENABLED" = "true" ]; then

    # check if vault vars need to be added or updated
    if ! grep -q "^ITENTIAL_VAULT_URL=" "$PROJECT_ROOT/.env" 2>/dev/null; then

        # vault vars not present, add them
        log_info "Updating .env with OpenBao root token..."

        # NOTE: platform connects to OpenBao via Docker internal network where it always listens on 8200
        # the OPENBAO_PORT variable only affects the host port mapping for external access
        cat >> "$PROJECT_ROOT/.env" << EOF

# OpenBao Platform Integration (auto-configured)
# Platform connects via Docker internal network (always port 8200 internally)
ITENTIAL_VAULT_URL=http://openbao:8200
ITENTIAL_VAULT_AUTH_METHOD=token
ITENTIAL_VAULT_TOKEN=${ROOT_TOKEN}
ITENTIAL_VAULT_SECRETS_ENDPOINT=secret/data
ITENTIAL_VAULT_READ_ONLY=false
EOF
        log_info "Platform Vault integration configured with root token"
    elif [ "$ITENTIAL_VAULT_TOKEN" != "$ROOT_TOKEN" ]; then

        # vault vars present but token doesn't match, update it
        log_info "Updating .env with new OpenBao root token..."
        sed -i "s|^ITENTIAL_VAULT_TOKEN=.*|ITENTIAL_VAULT_TOKEN=${ROOT_TOKEN}|" "$PROJECT_ROOT/.env"
        log_info "Platform Vault token updated"
    else
        log_info "Platform Vault integration already configured"
    fi
fi

log_info "OpenBao configuration complete!"

# ==========================================================================
# VAULT ADAPTER INSTALLATION AND CONFIGURATION
# ==========================================================================

ADAPTER_DIR="$PROJECT_ROOT/volumes/platform/adapters"
VAULT_ADAPTER_DIR="$ADAPTER_DIR/adapter-hashicorp_vault"
VAULT_ADAPTER_REPO="https://gitlab.com/itentialopensource/adapters/adapter-hashicorp_vault.git"
ADAPTER_INSTALLED=false

# check for git and npm
if ! command -v git &>/dev/null; then
    log_warn "git not installed - skipping Vault adapter installation"
    log_info "Install manually: cd volumes/platform/adapters && git clone $VAULT_ADAPTER_REPO"
elif ! command -v npm &>/dev/null; then
    log_warn "npm not installed - skipping Vault adapter installation"
    log_info "Install manually: cd $VAULT_ADAPTER_DIR && npm install"
else

    # install adapter if not present
    if [ ! -d "$VAULT_ADAPTER_DIR" ]; then
        log_info "Installing HashiCorp Vault adapter..."
        git clone --depth 1 "$VAULT_ADAPTER_REPO" "$VAULT_ADAPTER_DIR" 2>/dev/null || {
            log_warn "Failed to clone Vault adapter repository"
            log_info "Install manually: git clone $VAULT_ADAPTER_REPO $VAULT_ADAPTER_DIR"
        }
        if [ -d "$VAULT_ADAPTER_DIR" ]; then
            (cd "$VAULT_ADAPTER_DIR" && npm install --production --silent 2>/dev/null) || {
                log_warn "Failed to install Vault adapter dependencies"
                log_info "Install manually: cd $VAULT_ADAPTER_DIR && npm install"
            }
            if [ -f "$VAULT_ADAPTER_DIR/node_modules/.package-lock.json" ]; then
                log_info "Vault adapter installed successfully"
                ADAPTER_INSTALLED=true
            fi
        fi
    else
        log_info "Vault adapter already installed"
    fi
fi

# configure adapter via Platform API if adapter is installed
if [ -d "$VAULT_ADAPTER_DIR" ]; then
    log_info "Configuring Vault adapter in Platform..."

    # Platform API settings
    PLATFORM_URL="http://localhost:${PLATFORM_PORT:-3000}"
    ADMIN_USER="${PLATFORM_USER:-admin}"
    ADMIN_PASSWORD="${PLATFORM_PASSWORD:-admin}"
    COOKIE_JAR=$(mktemp)
    trap "rm -f $COOKIE_JAR" EXIT

    # if adapter was just installed, Platform needs to restart to load it
    if [ "$ADAPTER_INSTALLED" = "true" ]; then
        log_info "Restarting Platform to load newly installed Vault adapter..."
        docker restart platform 2>/dev/null || {
            log_warn "Failed to restart Platform"
        }

        # wait a bit for Platform to come back up
        sleep 5
    fi

    # wait for Platform API
    log_info "Waiting for Platform API..."
    MAX_WAIT=120
    PLATFORM_READY=false
    for ((i=0; i<MAX_WAIT; i+=2)); do
        if curl -sf "${PLATFORM_URL}/health" &>/dev/null; then
            log_info "Platform is accessible"
            PLATFORM_READY=true
            break
        fi
        sleep 2
    done

    if [ "$PLATFORM_READY" = "false" ]; then
        log_warn "Platform not accessible - skipping Vault adapter configuration"
        log_info "Configure manually after Platform starts"
    else

        # wait for internal services
        PLATFORM_INIT_DELAY="${PLATFORM_INIT_DELAY:-10}"
        log_info "Waiting ${PLATFORM_INIT_DELAY}s for Platform services to initialize..."
        sleep "$PLATFORM_INIT_DELAY"

        # authenticate - when LDAP is enabled, try LDAP admin first (local admin can't authenticate)
        log_info "Authenticating to Platform..."
        AUTH_SUCCESS=false

        if [ "$LDAP_ENABLED" = "true" ]; then

            # LDAP is enabled - use LDAP admin (local admin won't work)
            LOGIN_RESPONSE=$(curl -s -X POST "${PLATFORM_URL}/login" \
                -H "Content-Type: application/json" \
                -c "$COOKIE_JAR" \
                -d '{"username":"admin@itential","password":"admin"}' 2>/dev/null)
        else

            # no LDAP - use local admin
            LOGIN_RESPONSE=$(curl -s -X POST "${PLATFORM_URL}/login" \
                -H "Content-Type: application/json" \
                -c "$COOKIE_JAR" \
                -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASSWORD}\"}" 2>/dev/null)
        fi

        # verify authentication by testing an API call
        if [ -n "$LOGIN_RESPONSE" ]; then
            TEST_RESPONSE=$(curl -s -w "\n%{http_code}" "${PLATFORM_URL}/adapters?limit=1" -b "$COOKIE_JAR" 2>/dev/null)
            TEST_CODE=$(echo "$TEST_RESPONSE" | tail -1)
            if [ "$TEST_CODE" = "200" ]; then
                AUTH_SUCCESS=true
            fi
        fi

        if [ "$AUTH_SUCCESS" = "false" ]; then
            log_warn "Platform authentication failed - skipping Vault adapter configuration"
        else
            log_info "Authenticated successfully"

            # check if adapter exists
            log_info "Checking for HashiCorpVault adapter..."
            ADAPTER_CHECK=$(curl -s -w "\n%{http_code}" "${PLATFORM_URL}/adapters/HashiCorpVault" -b "$COOKIE_JAR" 2>/dev/null)
            ADAPTER_CODE=$(echo "$ADAPTER_CHECK" | tail -1)
            ADAPTER_RESPONSE=$(echo "$ADAPTER_CHECK" | sed '$d')

            if [ "$ADAPTER_CODE" = "200" ]; then

                # check if already configured
                EXISTING_HOST=$(echo "$ADAPTER_RESPONSE" | jq -r '.data.properties.properties.host // empty')
                IS_ACTIVE=$(echo "$ADAPTER_RESPONSE" | jq -r '.metadata.isActive // false')
                if [ -n "$EXISTING_HOST" ] && [ "$EXISTING_HOST" != "null" ] && [ "$IS_ACTIVE" = "true" ]; then
                    log_info "Vault adapter already configured and active (host: $EXISTING_HOST)"
                else

                    # adapter exists but needs configuration
                    ADAPTER_EXISTS=true
                fi
            elif [ "$ADAPTER_CODE" = "500" ]; then

                # adapter doesn't exist - create it
                ADAPTER_EXISTS=false
            else
                log_warn "Unexpected response checking Vault adapter (HTTP $ADAPTER_CODE)"
                ADAPTER_EXISTS=false
            fi

            # create adapter if needed
            if [ "$ADAPTER_EXISTS" = "false" ]; then
                log_info "Creating HashiCorpVault adapter..."
                CREATE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${PLATFORM_URL}/adapters" \
                    -H "Content-Type: application/json" \
                    -b "$COOKIE_JAR" \
                    -d '{
                      "properties": {
                        "name": "HashiCorpVault",
                        "type": "Adapter",
                        "properties": {
                          "id": "HashiCorpVault",
                          "type": "HashiCorpVault"
                        }
                      }
                    }' 2>/dev/null)

                CREATE_CODE=$(echo "$CREATE_RESPONSE" | tail -1)
                if [ "$CREATE_CODE" = "200" ]; then
                    log_info "Vault adapter created"
                else
                    log_warn "Failed to create Vault adapter (HTTP $CREATE_CODE)"
                fi
            fi

            # configure adapter properties
            if [ "$ADAPTER_EXISTS" = "false" ] || [ "$ADAPTER_EXISTS" = "true" ]; then
                log_info "Configuring Vault adapter properties..."
                VAULT_PROPERTIES=$(cat <<EOF
{
  "properties": {
    "host": "openbao",
    "port": ${OPENBAO_PORT:-8200},
    "protocol": "http",
    "base_path": "/",
    "version": "v1",
    "stub": false,
    "authentication": {
      "auth_method": "static_token",
      "token": "${ROOT_TOKEN}",
      "auth_field": "header.headers.X-Vault-Token",
      "auth_field_format": "{token}"
    },
    "healthcheck": {
      "type": "startup",
      "frequency": 60000
    }
  }
}
EOF
)
                CONFIG_RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "${PLATFORM_URL}/adapters/HashiCorpVault/properties" \
                    -H "Content-Type: application/json" \
                    -b "$COOKIE_JAR" \
                    -d "$VAULT_PROPERTIES" 2>/dev/null)

                CONFIG_CODE=$(echo "$CONFIG_RESPONSE" | tail -1)
                if [ "$CONFIG_CODE" = "200" ]; then
                    log_info "Vault adapter properties configured"

                    # wait for adapter to become active
                    log_info "Waiting for Vault adapter to activate..."
                    MAX_WAIT=30
                    for ((j=0; j<MAX_WAIT; j+=2)); do
                        ADAPTER_STATUS=$(curl -sf "${PLATFORM_URL}/adapters/HashiCorpVault" -b "$COOKIE_JAR" 2>/dev/null) || true
                        IS_ACTIVE=$(echo "$ADAPTER_STATUS" | jq -r '.metadata.isActive // false' 2>/dev/null) || true
                        if [ "$IS_ACTIVE" = "true" ]; then
                            log_info "Vault adapter is active"
                            break
                        fi
                        if [ $j -ge $((MAX_WAIT - 2)) ]; then
                            log_warn "Vault adapter not yet active after ${MAX_WAIT}s"
                            break
                        fi
                        sleep 2
                    done
                else
                    log_warn "Failed to configure Vault adapter (HTTP $CONFIG_CODE)"
                fi
            fi
        fi
    fi
fi

# export ADAPTER_INSTALLED for setup.sh to detect if Platform restart is needed
export ADAPTER_INSTALLED

# ==========================================================================
# CREATE EXAMPLE SECRETS FOR TESTING MANUAL PROPERTY ENCRYPTION
# ==========================================================================

log_info "Creating example secrets for manual property encryption testing..."

# create example secret for demonstrating $SECRET syntax
EXAMPLE_SECRET_PATH="secret/data/example/credentials"
EXAMPLE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${OPENBAO_URL}/v1/${EXAMPLE_SECRET_PATH}" \
    -H "X-Vault-Token: ${ROOT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"data": {"username": "demo_user", "password": "demo_password", "api_key": "demo_api_key_12345"}}' 2>/dev/null)

EXAMPLE_CODE=$(echo "$EXAMPLE_RESPONSE" | tail -1)
if [ "$EXAMPLE_CODE" = "200" ] || [ "$EXAMPLE_CODE" = "204" ]; then
    log_info "Example secrets created at secret/example/credentials"
    log_info "  Use in adapter properties: \"\$SECRET_example/credentials \$KEY_password\""
else
    log_warn "Could not create example secrets (HTTP $EXAMPLE_CODE)"
fi

echo ""
echo "OpenBao Details:"
echo "  URL:        $OPENBAO_URL"
echo "  Root Token: $ROOT_TOKEN"
echo "  Keys File:  $INIT_KEYS_FILE"
echo ""
echo "Usage:"
echo "  export VAULT_ADDR=$OPENBAO_URL"
echo "  export VAULT_TOKEN=$ROOT_TOKEN"
echo "  bao kv put -mount=secret myapp/config key=value"
echo ""
echo "Example secrets available for testing:"
echo "  Path: secret/example/credentials"
echo "  Keys: username, password, api_key"
echo "  Usage: \"\$SECRET_example/credentials \$KEY_password\""
echo ""
