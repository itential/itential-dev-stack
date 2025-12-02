# 🔬 Itential - Local Development Stack

A local development environment for [Itential Platform](https://www.itential.com/cloud-platform/overview/) and other related technologies.

> **Note**: This environment is for development and testing only. Do not use in production.

## ⏰ Quick Start

```bash
# First-time setup (generates key, certs, starts services, connects IAG to Gateway Manager)
make setup

# Daily usage
make up       # Start all services
make down     # Stop all services
make logs     # View logs
make status   # Check status and URLs
```

## ✅ Prerequisites

**Container Runtime** (one of the following):
- [Docker](https://docs.docker.com/get-docker/) (v20.10+) with [Docker Compose](https://docs.docker.com/compose/install/) (v2.0+)
- [Podman](https://podman.io/docs/installation) (v4.0+) with [Podman Compose](https://github.com/containers/podman-compose) — see [Using Podman](#using-podman)

**Other Requirements:**
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) configured with Itential ECR access (only required if images need to be pulled)

### AWS ECR Access

Before first use, ensure you have access to Itential's AWS ECR repository. See [Repository Access](https://docs.itential.com/docs/running-containers-itential-platform#docker-repository-access).

> **Note**: If all required Itential images are already present locally, `make setup` will skip AWS CLI and ECR authentication automatically.

## 🫛 Using Podman

This project is OCI-compliant and works with Podman _(and other container runtimes)_. The scripts and Makefile reference `docker` commands directly, so choose one of these approaches:

### Option 1: Docker CLI Emulation (Recommended)

Install the compatibility package that creates a `docker` symlink:

```bash
# Fedora/RHEL/CentOS
sudo dnf install podman-docker

# Ubuntu/Debian
sudo apt install podman-docker
```

With this installed, all `make` commands and scripts work unchanged.

### Option 2: Manual Command Substitution

Replace `docker` with `podman` and `docker compose` with `podman-compose`:

```bash
# Instead of: make up
podman-compose --profile full up -d

# Instead of: make down
podman-compose --profile full down

# Instead of: make logs
podman-compose --profile full logs -f
```

### ECR Authentication with Podman

```bash
aws ecr get-login-password --region us-east-2 | \
  podman login --username AWS --password-stdin 497639811223.dkr.ecr.us-east-2.amazonaws.com
```

### Known Considerations

- **Rootless mode**: Works with proper volume permissions (containers run as your user ID)
- **podman-compose**: Feature parity with Docker Compose v2 is good but verify version 1.0.6+
- **Compose profiles**: Fully supported in podman-compose 1.0.6+
- **Health checks**: Work identically to Docker

## 💻 Configuration

Configuration is managed via `.env` file. On first run, `make setup` creates this from `.env.example`.

### Essential Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ITENTIAL_ENCRYPTION_KEY` | 64-char hex encryption key (auto-generated) | Required |
| `GATEWAY5_CLUSTER_ID` | Gateway Manager cluster identifier | `cluster_1` |

### Optional Overrides

```bash
# Image versions (defaults to latest stable)
PLATFORM_VERSION=6
GATEWAY4_VERSION=4.3.7
GATEWAY5_VERSION=5.1.0-amd64
MONGO_VERSION=8.0
REDIS_VERSION=7.4

# Ports (if defaults conflict)
PLATFORM_PORT=3000
GATEWAY4_PORT=8083
GATEWAY5_PORT=50051

# Logging
LOG_LEVEL=debug

# Gateway Manager timing (seconds to wait after Platform API responds)
PLATFORM_INIT_DELAY=15
```

## 📋 Services

| Service | URL | Credentials |
|---------|-----|-------------|
| Platform | http://localhost:3000 | admin / admin |
| Gateway4 | http://localhost:8083 | admin@itential / admin |
| Gateway5 | localhost:50051 (gRPC) | Use `iagctl` client |
| OpenLDAP | localhost:3389 | cn=admin,dc=itential,dc=io / admin |
| MongoDB | localhost:27017 | N/A |
| Redis | localhost:6379 | N/A |

## 🔍 Docker Compose Profiles

Start specific service combinations:

```bash
# All services (default)
docker compose --profile full up -d

# Platform + dependencies only (most common for development)
docker compose --profile platform up -d

# Dependencies only (MongoDB + Redis)
docker compose --profile deps up -d

# Add Gateway4 to running stack
docker compose --profile gateway4 up -d

# Add Gateway5 to running stack
docker compose --profile gateway5 up -d

# Platform with LDAP (for enterprise auth testing)
docker compose --profile platform --profile ldap up -d
```

## 🪾 File Structure

```
itential-dev-stack/
├── docker-compose.yml      # Unified compose configuration
├── .env                    # Your configuration (git-ignored)
├── .env.example            # Configuration template
├── Makefile                # Common commands
├── scripts/
│   ├── setup.sh            # First-time setup
│   ├── generate-certificates.sh
│   └── configure-gateway-manager.sh
├── volumes/
│   ├── platform/
│   │   ├── adapters/       # Custom adapters
│   │   └── ssl/            # SSL certificates
│   │   # Note: Platform logs use a named Docker volume (platform-logs)
│   ├── gateway4/
│   │   ├── data/           # SQLite databases
│   │   ├── playbooks/      # Ansible playbooks
│   │   ├── scripts/        # Python scripts
│   │   └── ssl/            # SSL certificates
│   ├── gateway5/
│   │   ├── certificates/   # Gateway Manager certs
│   │   └── scripts/        # Custom scripts
│   │   # Note: Gateway5 database uses a named Docker volume (gateway5-data)
│   └── ldap/
│       └── openldap.ldif   # LDAP users & groups
└── dependencies/
    └── mongodb-data/       # MongoDB persistent data
```

## 🍚 Make Commands

```bash
make help           # Show all commands
make setup          # First-time setup
make up             # Start all services
make down           # Stop all services
make logs           # Follow all logs (or: make logs LOG=platform)
make status         # Show status and URLs
make certs          # Generate SSL certificates
make login          # Login to AWS ECR
make clean          # Stop and remove all data (destructive)
make generate-key   # Generate new encryption key
```

## 🔧 Installing Adapters

```bash
cd volumes/platform/adapters/
git clone https://gitlab.com/itentialopensource/adapters/adapter-servicenow.git
cd adapter-servicenow && npm install
cd ../../..
make up  # Restart to load adapter
```

Find adapters at [Itential Automation Marketplace](https://www.itential.com/automation-marketplace/).

## 📋 Gateway4 Assets

Playbooks and scripts must be executable to appear in the Gateway4 UI:

```bash
chmod +x volumes/gateway4/playbooks/*.yml
chmod +x volumes/gateway4/scripts/*.py
```

> **Note**: `make setup` handles this automatically.

## 🔑 LDAP Authentication

OpenLDAP is available as an optional service for testing enterprise LDAP authentication with Itential Platform.

### Enabling LDAP (Automatic Configuration)

Add to your `.env` file:
```bash
LDAP_ENABLED=true
```

Then run `make setup` - the LDAP adapter will be configured automatically via API.

After setup completes, you can log in with any LDAP user:

| User | Password | Access |
|------|----------|--------|
| admin@itential | admin | Full admin (all roles + Gateway Manager) |
| builder@itential | builder | LDAP group: builders |
| operator@itential | operator | LDAP group: operators |

> **Note**: The `admin@itential` user automatically receives all roles from the local admin account and is added to `admin_group` for Gateway Manager access.

### Manual LDAP Start (without auto-config)

```bash
# Start Platform with LDAP container only
docker compose --profile platform --profile ldap up -d

# Configure LDAP adapter manually
./scripts/configure-ldap.sh
```

### LDAP Connection Details

| Property | Value |
|----------|-------|
| Host (from containers) | openldap |
| Host (from host) | localhost |
| Port | 389 (container) / 3389 (host) |
| Admin DN | cn=admin,dc=itential,dc=io |
| Admin Password | admin |
| Base DN | dc=itential,dc=io |

For advanced LDAP configuration, see the [official documentation](https://docs.itential.com/docs/configuring-open-ldap-iap).

## 🔐 Gateway5 / Gateway Manager

Gateway5 connects to Platform via Gateway Manager. The setup is fully automated:

1. Generates client certificates (`volumes/gateway5/certificates/`)
2. Uploads certificates to Platform via API
3. Configures RBAC (assigns gateway roles to admin)
4. Creates and enables the gateway cluster

If automatic configuration fails, the script displays manual instructions.

See [Gateway Manager Documentation](https://docs.itential.com/docs/iag5-deploy-container#step-3-create-gateway-manager-certificates).

## 🐞 Debugging

```bash
# Shell access (use podman instead of docker for Podman users)
docker exec -it platform /bin/sh
docker exec -it gateway4 /bin/sh
docker exec -it gateway5 sh

# MongoDB shell
docker exec -it mongodb mongosh

# Redis CLI
docker exec -it redis redis-cli

# Check environment
docker exec platform env | grep ITENTIAL
```

> **Podman users**: Replace `docker` with `podman` in the commands above, or use `podman-docker` for automatic compatibility.

## 📚 Additional Resources

- [Platform Environment Variables](https://docs.itential.com/docs/itential-platform-properties-environment-variables)
- [Gateway4 Configuration](https://docs.itential.com/docs/configuration-for-iag)
- [Gateway5 Configuration](https://docs.itential.com/docs/iag5-config-variables)
- [Adapter Documentation](https://docs.itential.com/opensource/docs/adapters)
