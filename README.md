# 🔬 Itential - Local Development Stack

A local development environment for [Itential Platform](https://www.itential.com/cloud-platform/overview/) and related technologies.

> **Note**: This environment is for development and testing only. Do not use in production.

## ⏰ Getting Started

### 1. Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (v20.10+) with [Docker Compose](https://docs.docker.com/compose/install/) (v2.0+)
- Access to an image registry — either **AWS ECR** or **JFrog** (see [Image Registries](#image-registries))

### 2. Configure your environment

```bash
cp .env.example .env    # make setup also does this if .env doesn't exist
```

Open `.env` and configure:

**Choose what to run** — pick a base profile and enable the services you need:

```bash
# Base profile: full | platform | deps
#   full     = MongoDB, Redis, Platform, Gateway4, Gateway5
#   platform = MongoDB, Redis, Platform (most common)
#   deps     = MongoDB, Redis only
STACK_PROFILE=platform

# Enable individual services on top of the base profile
GATEWAY5_ENABLED=true
LDAP_ENABLED=true
# MCP_ENABLED=true
# OPENBAO_ENABLED=true
```

**Choose your image registry** — uncomment one set:

```bash
# AWS ECR (default — requires: make login)
PLATFORM_IMAGE=497639811223.dkr.ecr.us-east-2.amazonaws.com/automation-platform-config-lcm:6
GATEWAY5_IMAGE=497639811223.dkr.ecr.us-east-2.amazonaws.com/automation-gateway5:5.1.0-amd64

# JFrog (requires: docker login itential.jfrog.io)
PLATFORM_IMAGE=itential.jfrog.io/flowai/itential_flowai:v0.0.6
GATEWAY5_IMAGE=itential.jfrog.io/flowai/itential_flowai_gateway5:5.3.0-amd64
```

### 3. Run setup

```bash
make setup
```

This generates an encryption key, creates SSL certificates, starts your services, and configures Gateway Manager and any enabled optional services.

### 4. Daily usage

```bash
make up       # Start services
make down     # Stop services
make logs     # View logs (or: make logs LOG=platform)
make status   # Check status and URLs
```

## 🔍 Stack Profiles

The profile system has two layers that let you run exactly what you need:

**Base profile** (`STACK_PROFILE`) determines the core services:

| Profile | Services | Use Case |
|---------|----------|----------|
| `full` | MongoDB, Redis, Platform, Gateway4, Gateway5 | Complete stack |
| `platform` | MongoDB, Redis, Platform | Platform development (most common) |
| `deps` | MongoDB, Redis | Dependencies only |

**Enable flags** add individual services on top of the base profile:

| Variable | Service |
|----------|---------|
| `GATEWAY4_ENABLED=true` | Automation Gateway 4 |
| `GATEWAY5_ENABLED=true` | Automation Gateway 5 |
| `LDAP_ENABLED=true` | OpenLDAP |
| `MCP_ENABLED=true` | MCP Server (LLM integration) |
| `OPENBAO_ENABLED=true` | OpenBao (secrets management) |

### Examples

```bash
# Platform + Gateway5 + LDAP (no Gateway4)
STACK_PROFILE=platform
GATEWAY5_ENABLED=true
LDAP_ENABLED=true

# Full stack (everything)
STACK_PROFILE=full

# Platform only (minimal)
STACK_PROFILE=platform
```

Both `make setup` and `make up` respect these settings automatically.

### Direct Docker Compose

You can also use `docker compose` directly with profiles:

```bash
docker compose --profile platform up -d
docker compose --profile platform --profile ldap up -d
docker compose --profile full --profile openbao up -d
```

## 📋 Services

| Service | Default URL | Credentials |
|---------|-------------|-------------|
| Platform | http://localhost:3000 | admin / admin |
| Gateway4 | http://localhost:8083 | admin@itential / admin |
| Gateway5 | localhost:50051 (gRPC) | Use `iagctl` client |
| MongoDB | localhost:27017 | N/A |
| Redis | localhost:6379 | N/A |
| OpenLDAP | localhost:3389 | cn=admin,dc=itential,dc=io / admin |
| MCP | http://localhost:8000 (SSE) | N/A |
| OpenBao | http://localhost:8200 | Token from `volumes/openbao/init-keys.json` |

> All ports are configurable via `.env` — see [Port Configuration](#port-configuration).

## 💻 Configuration Reference

All configuration is managed via `.env` (see [Getting Started](#2-configure-your-environment)).

The configuration loads in two layers:
1. **`defaults.env`** — Version-controlled defaults (ECR images, dependency versions). Do not edit.
2. **`.env`** — Your overrides (git-ignored). Any variable set here takes precedence.

> Always use `make` commands (`make up`, `make down`, etc.) to ensure both files are loaded correctly.

### Image Registries

Image defaults are in `defaults.env` (version-controlled) and point to AWS ECR. Override in your `.env`:

**AWS ECR** (default):
```bash
# Requires: make login (or AWS CLI configured with ECR access)
PLATFORM_IMAGE=497639811223.dkr.ecr.us-east-2.amazonaws.com/automation-platform-config-lcm:6
GATEWAY4_IMAGE=497639811223.dkr.ecr.us-east-2.amazonaws.com/automation-gateway:4.3.7
GATEWAY5_IMAGE=497639811223.dkr.ecr.us-east-2.amazonaws.com/automation-gateway5:5.1.0-amd64
```

**JFrog**:
```bash
# Requires: docker login itential.jfrog.io
PLATFORM_IMAGE=itential.jfrog.io/flowai/itential_flowai:v0.0.6
GATEWAY5_IMAGE=itential.jfrog.io/flowai/itential_flowai_gateway5:5.3.0-amd64
```

> When using non-ECR images, `make setup` automatically skips AWS authentication.

### Port Configuration

Override in `.env` if defaults conflict with existing services on your machine:

| Variable | Service | Default |
|----------|---------|---------|
| `PLATFORM_PORT` | Platform UI | `3000` |
| `GATEWAY_MANAGER_PORT` | Gateway Manager API | `8080` |
| `MONGO_PORT` | MongoDB | `27017` |
| `REDIS_PORT` | Redis | `6379` |
| `GATEWAY4_PORT` | Automation Gateway 4 | `8083` |
| `GATEWAY5_PORT` | Automation Gateway 5 (gRPC) | `50051` |
| `LDAP_PORT` | OpenLDAP | `3389` |
| `MCP_SSE_PORT` | MCP Server | `8000` |
| `OPENBAO_PORT` | OpenBao | `8200` |

### Platform UID/GID

Different platform images may run as different UIDs. The init container sets log directory ownership based on these variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `PLATFORM_UID` | Platform container user ID | `1001` |
| `PLATFORM_GID` | Platform container group ID | `1001` |

> The standard ECR image uses UID `1001`. JFrog flowai images use UID `1000`. To check an image: `docker inspect <image> --format '{{.Config.User}}'`

### Other Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ITENTIAL_ENCRYPTION_KEY` | 64-char hex encryption key | Auto-generated |
| `STACK_PROFILE` | Base service profile (`full`, `platform`, `deps`) | `full` |
| `GATEWAY5_CLUSTER_ID` | Gateway Manager cluster ID | `cluster_1` |
| `LOG_LEVEL` | Application log level | `debug` |
| `BIND_ADDRESS` | Network binding (`""` = all, `"127.0.0.1:"` = localhost) | `""` |

## 🍚 Make Commands

| Command | Description |
|---------|-------------|
| `make setup` | First-time setup (key, certs, start, configure) |
| `make up` | Start services |
| `make down` | Stop services |
| `make logs` | Follow all logs (or: `make logs LOG=platform`) |
| `make status` | Show status and URLs |
| `make certs` | Generate SSL certificates |
| `make login` | Login to AWS ECR |
| `make clean` | Stop and remove all data (destructive) |
| `make generate-key` | Generate new encryption key |

## 🔑 LDAP Authentication

OpenLDAP provides enterprise LDAP authentication testing.

**Enable**: Set `LDAP_ENABLED=true` in `.env`, then `make setup`.

After setup, log in with any pre-configured user:

| User | Password | Access |
|------|----------|--------|
| admin@itential | admin | Full admin (all roles + Gateway Manager) |
| builder@itential | builder | LDAP group: builders |
| operator@itential | operator | LDAP group: operators |

<details>
<summary>LDAP connection details</summary>

| Property | Value |
|----------|-------|
| Host (from containers) | openldap |
| Host (from host) | localhost |
| Port | 389 (container) / 3389 (host) |
| Admin DN | cn=admin,dc=itential,dc=io |
| Admin Password | admin |
| Base DN | dc=itential,dc=io |

For advanced configuration, see the [official documentation](https://docs.itential.com/docs/configuring-open-ldap-iap).
</details>

## 🤖 MCP Server (LLM Integration)

The [MCP](https://github.com/itential/itential-mcp) server enables LLM tools (Claude Code, Claude Desktop) to interact with Itential Platform.

**Enable**: Set `MCP_ENABLED=true` in `.env`, then `make setup` or `make up`.

| Variable | Description | Default |
|----------|-------------|---------|
| `MCP_TRANSPORT` | Transport mode: `sse` or `stdio` | `sse` |
| `MCP_PLATFORM_USER` | Platform username | `admin` |
| `MCP_PLATFORM_PASSWORD` | Platform password | `admin` |

See [docs/itential-mcp](docs/itential-mcp/) for Claude Desktop configuration examples.

## 🔐 OpenBao (Secrets Management)

[OpenBao](https://openbao.org/) provides Vault-compatible secrets management.

**Enable**: Set `OPENBAO_ENABLED=true` in `.env`, then `make setup`.

Setup automatically initializes OpenBao, saves the root token, enables KV v2, configures Platform integration, and installs the Vault adapter.

```bash
# Get your root token after setup
cat volumes/openbao/init-keys.json | jq -r '.root_token'

# Access the UI
open http://localhost:8200
```

<details>
<summary>Working with secrets</summary>

```bash
export VAULT_TOKEN=$(cat volumes/openbao/init-keys.json | jq -r '.root_token')

# Write a secret
curl -X POST http://localhost:8200/v1/secret/data/myapp/config \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -d '{"data": {"username": "admin", "password": "secret"}}'

# Read a secret
curl http://localhost:8200/v1/secret/data/myapp/config \
  -H "X-Vault-Token: $VAULT_TOKEN"
```

**Property encryption** — Two methods for encrypting adapter properties:
- **Automatic**: Adapters with `propertiesDecorators.json` auto-encrypt marked properties. See [docs](https://docs.itential.com/docs/automatic-property-encryption-itential-platform).
- **Manual**: Use `$SECRET_path $KEY_key` syntax in adapter properties. See [docs](https://docs.itential.com/docs/manual-property-encryption-itential-platform).

If OpenBao is sealed after restart: `./scripts/configure-openbao.sh`
</details>

For detailed usage, see [docs/openbao](docs/openbao/).

## 🔑 Gateway5 / Gateway Manager

Gateway5 connects to Platform via Gateway Manager. `make setup` handles everything automatically:

1. Generates client certificates (`volumes/gateway5/certificates/`)
2. Uploads certificates to Platform via API
3. Configures RBAC (assigns gateway roles to admin)
4. Creates and enables the gateway cluster

If automatic configuration fails, the script displays manual instructions. See [Gateway Manager docs](https://docs.itential.com/docs/iag5-deploy-container#step-3-create-gateway-manager-certificates).

## 🔧 Installing Adapters

```bash
cd volumes/platform/adapters/
git clone https://gitlab.com/itentialopensource/adapters/adapter-servicenow.git
cd adapter-servicenow && npm install
cd ../../..
make up  # Restart to load adapter
```

Find adapters at [Itential Automation Marketplace](https://www.itential.com/automation-marketplace/).

## 🐞 Debugging

```bash
# Shell access
docker exec -it platform /bin/sh
docker exec -it gateway4 /bin/sh
docker exec -it gateway5 sh

# Database access
docker exec -it mongodb mongosh
docker exec -it redis redis-cli

# Check platform environment
docker exec platform env | grep ITENTIAL
```

## 🫛 Using Podman

This project is OCI-compliant and works with Podman. The simplest approach is to install Docker CLI emulation:

```bash
# Fedora/RHEL/CentOS
sudo dnf install podman-docker

# Ubuntu/Debian
sudo apt install podman-docker
```

With this installed, all `make` commands work unchanged.

<details>
<summary>Manual podman commands</summary>

```bash
podman-compose --profile platform up -d
podman-compose --profile platform down
podman-compose logs -f

# ECR auth
aws ecr get-login-password --region us-east-2 | \
  podman login --username AWS --password-stdin 497639811223.dkr.ecr.us-east-2.amazonaws.com
```
</details>

## 🪾 File Structure

```
itential-dev-stack/
├── docker-compose.yml      # Service definitions
├── .env                    # Your configuration (git-ignored)
├── .env.example            # Configuration template
├── defaults.env            # Default values (version-controlled)
├── Makefile                # Make commands
├── scripts/
│   ├── setup.sh                     # First-time setup orchestrator
│   ├── generate-certificates.sh     # SSL cert generation
│   ├── configure-gateway-manager.sh # Gateway Manager config
│   ├── configure-ldap.sh           # LDAP adapter config
│   ├── configure-openbao.sh        # OpenBao init/unseal
│   └── sync-admin-roles.sh         # Admin role sync
├── docs/                   # Additional documentation
├── volumes/
│   ├── platform/           # Adapters, SSL certs, vault token
│   ├── gateway4/           # Playbooks, scripts, data
│   ├── gateway5/           # Certificates, scripts
│   ├── ldap/               # LDAP bootstrap config
│   ├── mcp/                # MCP logs
│   └── openbao/            # OpenBao config
└── dependencies/
    └── mongodb-data/       # MongoDB persistent data
```

## 📚 Additional Resources

- [Platform Environment Variables](https://docs.itential.com/docs/itential-platform-properties-environment-variables)
- [Gateway4 Configuration](https://docs.itential.com/docs/configuration-for-iag)
- [Gateway5 Configuration](https://docs.itential.com/docs/iag5-config-variables)
- [Adapter Documentation](https://docs.itential.com/opensource/docs/adapters)
