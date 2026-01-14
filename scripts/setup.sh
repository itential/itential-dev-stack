#!/bin/bash
# First-time setup - creates env, generates certs, starts services

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${BLUE}--- $1 ---${NC}"; }

# load defaults (single source of truth for default values)
source "$PROJECT_ROOT/defaults.env"

# are images present locally?
check_images_present() {
    local images=(
        "$PLATFORM_IMAGE"
        "$GATEWAY4_IMAGE"
        "$GATEWAY5_IMAGE"
    )

    for img in "${images[@]}"; do
        if ! docker image inspect "$img" &>/dev/null; then
            return 1
        fi
    done
    return 0
}

cd "$PROJECT_ROOT"

echo -e "${BLUE}"
echo "  ___  _             _   _       _"
echo " |_ _|| |_ ___ _ __ | |_(_) __ _| |"
echo "  | | | __/ _ \ '_ \| __| |/ _\` | |"
echo "  | | | ||  __/ | | | |_| | (_| | |"
echo " |___||_| \___|_| |_|\__|_|\__,_|_|"
echo ""
echo " Dev Stack Setup"
echo -e "${NC}"

log_section "pre-flight checks"

# docker installed?
if ! command -v docker &>/dev/null; then
    log_error "Docker is not installed. Please install Docker first."
    exit 1
fi
log_info "Docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"

# docker compose available?
if ! docker compose version &>/dev/null; then
    log_error "Docker Compose is not available. Please install Docker Compose v2+."
    exit 1
fi
log_info "Docker Compose: $(docker compose version --short)"

# check images early to skip aws cli if not needed
IMAGES_PRESENT=false
if check_images_present; then
    IMAGES_PRESENT=true
fi

# aws cli (only if images need pulling)
if [ "$IMAGES_PRESENT" = false ]; then
    if ! command -v aws &>/dev/null; then
        log_error "AWS CLI is not installed. Required for ECR authentication."
        exit 1
    fi
    log_info "AWS CLI: installed"
else
    log_info "AWS CLI: skipped (images already present)"
fi

# openssl installed?
if ! command -v openssl &>/dev/null; then
    log_error "OpenSSL is not installed. Required for certificate generation."
    exit 1
fi
log_info "OpenSSL: installed"

log_section "environment setup"

if [ ! -f "$PROJECT_ROOT/.env" ]; then
    log_info "Creating .env from template..."
    cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"

    # generate encryption key
    KEY=$(openssl rand -hex 32)

    # macos vs linux sed syntax
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/^ITENTIAL_ENCRYPTION_KEY=$/ITENTIAL_ENCRYPTION_KEY=$KEY/" "$PROJECT_ROOT/.env"
    else
        sed -i "s/^ITENTIAL_ENCRYPTION_KEY=$/ITENTIAL_ENCRYPTION_KEY=$KEY/" "$PROJECT_ROOT/.env"
    fi

    log_info "Generated encryption key"
else
    log_info ".env file already exists"

    # is encryption key set?
    source "$PROJECT_ROOT/.env"
    if [ -z "$ITENTIAL_ENCRYPTION_KEY" ]; then
        KEY=$(openssl rand -hex 32)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s/^ITENTIAL_ENCRYPTION_KEY=$/ITENTIAL_ENCRYPTION_KEY=$KEY/" "$PROJECT_ROOT/.env"
        else
            sed -i "s/^ITENTIAL_ENCRYPTION_KEY=$/ITENTIAL_ENCRYPTION_KEY=$KEY/" "$PROJECT_ROOT/.env"
        fi
        log_info "Generated missing encryption key"
    fi
fi

# load env
source "$PROJECT_ROOT/.env"

log_section "aws ecr authentication"

# extract registry from PLATFORM_IMAGE (everything before the first /)
ECR_REGISTRY="${PLATFORM_IMAGE%%/*}"

if [ "$IMAGES_PRESENT" = true ]; then
    log_info "All required images already present locally, skipping ECR authentication"
elif [[ "$ECR_REGISTRY" == *".ecr."*".amazonaws.com" ]]; then
    log_info "Authenticating with AWS ECR..."
    if aws ecr get-login-password --region us-east-2 2>/dev/null | \
       docker login --username AWS --password-stdin "$ECR_REGISTRY" &>/dev/null; then
        log_info "ECR authentication successful"
    else
        log_error "ECR authentication failed. Check your AWS credentials."
        log_info "Run: aws configure"
        exit 1
    fi
else
    log_info "Non-ECR registry detected ($ECR_REGISTRY), skipping AWS authentication"
fi

log_section "certificate generation"

"$SCRIPT_DIR/generate-certificates.sh" --quiet

log_section "file permissions"

# make iag4 playbooks/scripts executable
if [ -d "$PROJECT_ROOT/volumes/gateway4/playbooks" ]; then
    find "$PROJECT_ROOT/volumes/gateway4/playbooks" -type f \( -name "*.yml" -o -name "*.yaml" \) \
        -exec chmod +x {} \; 2>/dev/null || true
    log_info "Gateway4 playbooks: permissions set"
fi

if [ -d "$PROJECT_ROOT/volumes/gateway4/scripts" ]; then
    find "$PROJECT_ROOT/volumes/gateway4/scripts" -type f \( -name "*.py" -o -name "*.sh" \) \
        -exec chmod +x {} \; 2>/dev/null || true
    log_info "Gateway4 scripts: permissions set"
fi

# make openbao config readable by container (runs as uid 100)
if [ -f "$PROJECT_ROOT/volumes/openbao/config/config.hcl" ]; then
    chmod 644 "$PROJECT_ROOT/volumes/openbao/config/config.hcl" 2>/dev/null || true
    log_info "OpenBao config: permissions set"
fi

# create vault token directory before docker compose (prevents root ownership)
if [ "$OPENBAO_ENABLED" = "true" ]; then
    mkdir -p "$PROJECT_ROOT/volumes/platform/vault"
    log_info "Vault token directory: created"
fi

log_section "starting services"

# build profile list based on enabled services
PROFILES="--profile full"
if [ "$LDAP_ENABLED" = "true" ]; then
    PROFILES="$PROFILES --profile ldap"
    log_info "LDAP enabled"
fi
if [ "$MCP_ENABLED" = "true" ]; then
    PROFILES="$PROFILES --profile mcp"
    log_info "MCP enabled"
fi
if [ "$OPENBAO_ENABLED" = "true" ]; then
    PROFILES="$PROFILES --profile openbao"
    log_info "OpenBao enabled"
fi

log_info "Starting all services..."
docker compose $PROFILES up -d

log_section "waiting for platform"

PLATFORM_URL="http://localhost:${PLATFORM_PORT:-3000}"
MAX_WAIT=180
WAIT_INTERVAL=5

log_info "Waiting for Platform to be healthy (max ${MAX_WAIT}s)..."

for ((i=0; i<MAX_WAIT; i+=WAIT_INTERVAL)); do
    if curl -sf "${PLATFORM_URL}/health" &>/dev/null; then
        log_info "Platform is healthy!"
        break
    fi

    if [ $i -ge $((MAX_WAIT - WAIT_INTERVAL)) ]; then
        log_warn "Platform health check timeout. It may still be starting."
        log_info "Check logs with: make logs LOG=platform"
        break
    fi

    echo -n "."
    sleep $WAIT_INTERVAL
done
echo ""

log_section "gateway manager configuration"

if [ -f "$SCRIPT_DIR/configure-gateway-manager.sh" ]; then
    "$SCRIPT_DIR/configure-gateway-manager.sh" || {
        log_warn "Gateway Manager configuration skipped (Platform may not be ready)"
        log_info "Run manually later: ./scripts/configure-gateway-manager.sh"
    }
else
    log_warn "configure-gateway-manager.sh not found"
fi

# configure LDAP adapter if enabled
if [ "$LDAP_ENABLED" = "true" ]; then
    log_section "ldap configuration"

    if [ -f "$SCRIPT_DIR/configure-ldap.sh" ]; then
        "$SCRIPT_DIR/configure-ldap.sh" || {
            log_warn "LDAP configuration skipped"
            log_info "Run manually later: ./scripts/configure-ldap.sh"
        }
    else
        log_warn "configure-ldap.sh not found"
    fi
fi

# configure OpenBao if enabled
if [ "$OPENBAO_ENABLED" = "true" ]; then
    log_section "openbao configuration"

    if [ -f "$SCRIPT_DIR/configure-openbao.sh" ]; then
        "$SCRIPT_DIR/configure-openbao.sh" || {
            log_warn "OpenBao configuration skipped"
            log_info "Run manually later: ./scripts/configure-openbao.sh"
        }
    else
        log_warn "configure-openbao.sh not found"
    fi
fi

# sync admin roles after all adapters are configured
log_section "admin role sync"

if [ -f "$SCRIPT_DIR/sync-admin-roles.sh" ]; then
    "$SCRIPT_DIR/sync-admin-roles.sh" || {
        log_warn "Admin role sync skipped"
        log_info "Run manually later: ./scripts/sync-admin-roles.sh"
    }
else
    log_warn "sync-admin-roles.sh not found"
fi

log_section "setup complete"

echo ""
echo -e "${GREEN}Services are starting. Check status with: make status${NC}"
echo ""
echo "URLs:"
echo "  Platform:  http://localhost:${PLATFORM_PORT:-3000}"
echo "             Username: admin"
echo "             Password: admin"
echo ""
echo "  Gateway4:  http://localhost:${GATEWAY4_PORT:-8083}"
echo "             Username: admin@itential"
echo "             Password: admin"
echo ""
echo "  Gateway5:  localhost:${GATEWAY5_PORT:-50051} (gRPC)"
echo "             Use iagctl client to interact"
echo ""
if [ "$LDAP_ENABLED" = "true" ]; then
    echo "  OpenLDAP:  localhost:${LDAP_PORT:-3389}"
    echo "             Admin DN: cn=admin,dc=itential,dc=io"
    echo "             Password: admin"
    echo ""
fi
if [ "$MCP_ENABLED" = "true" ]; then
    echo "  MCP:       http://localhost:${MCP_SSE_PORT:-8000} (SSE transport)"
    echo "             See: https://github.com/itential/itential-mcp"
    echo ""
fi
if [ "$OPENBAO_ENABLED" = "true" ]; then
    OPENBAO_TOKEN=""
    if [ -f "$PROJECT_ROOT/volumes/openbao/init-keys.json" ]; then
        OPENBAO_TOKEN=$(jq -r '.root_token' "$PROJECT_ROOT/volumes/openbao/init-keys.json" 2>/dev/null)
    fi
    echo "  OpenBao:   http://localhost:${OPENBAO_PORT:-8200}"
    echo "             Token: ${OPENBAO_TOKEN:-see volumes/openbao/init-keys.json}"
    echo "             Platform is configured to use OpenBao for secrets"
    echo ""
fi
echo "Common commands:"
echo "  make up      - Start services"
echo "  make down    - Stop services"
echo "  make logs    - View logs"
echo "  make status  - Check status"
echo ""
