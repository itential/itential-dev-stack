# OpenBao

Configuration examples and usage guide for [OpenBao](https://openbao.org/) with the dev stack.

OpenBao is a Vault-compatible secrets management solution that provides secure storage for sensitive data like passwords, API keys, and certificates.

## Quick Start

### 1. Enable OpenBao

Add to your `.env` file:

```bash
OPENBAO_ENABLED=true
```

### 2. Start the Stack

```bash
make setup   # First time - initializes and unseals OpenBao
```

### 3. Verify OpenBao is Running

```bash
make status
# Should show: OpenBao: http://localhost:8200 (token: <your-root-token>)
```

### 4. Get Your Root Token

```bash
# View the root token
cat volumes/openbao/init-keys.json | jq -r '.root_token'

# Or check .env (auto-configured by setup)
grep ITENTIAL_VAULT_TOKEN .env
```

## Accessing OpenBao

### Web UI

Open http://localhost:8200 in your browser and sign in with:
- **Method**: Token
- **Token**: Your root token from `volumes/openbao/init-keys.json`

### CLI

#### Installation

Install the OpenBao CLI (`bao`) from [GitHub Releases](https://github.com/openbao/openbao/releases):

**Linux (Debian/Ubuntu):**
```bash
# Download latest release (check GitHub for current version)
wget https://github.com/openbao/openbao/releases/download/v2.1.0/bao_2.1.0_linux_amd64.deb
sudo dpkg -i bao_2.1.0_linux_amd64.deb
```

**macOS:**
```bash
brew install openbao
```

**Alternative:** The HashiCorp Vault CLI (`vault`) is also compatible - use `vault` instead of `bao` for all commands.

#### Configuration

Configure the CLI using environment variables:

```bash
# Point to your OpenBao server
export VAULT_ADDR=http://localhost:8200

# Authenticate with your root token
export VAULT_TOKEN=$(cat volumes/openbao/init-keys.json | jq -r '.root_token')
```

> **Note:** The CLI uses `VAULT_*` environment variables (not `BAO_*`) for backward compatibility with HashiCorp Vault tooling.

To persist these settings, add them to your shell profile (`~/.bashrc` or `~/.zshrc`).

#### Usage

```bash
# Check status
bao status

# Write a secret
bao kv put -mount=secret myapp/database username=admin password=secret123

# Read a secret
bao kv get -mount=secret myapp/database
```

### API

```bash
# Get your token
export VAULT_TOKEN=$(cat volumes/openbao/init-keys.json | jq -r '.root_token')

# Write a secret
curl -X POST http://localhost:8200/v1/secret/data/myapp/database \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "username": "admin",
      "password": "secret123"
    }
  }'

# Read a secret
curl -s http://localhost:8200/v1/secret/data/myapp/database \
  -H "X-Vault-Token: $VAULT_TOKEN" | jq .

# List secrets at a path
curl -s http://localhost:8200/v1/secret/metadata/myapp \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -X LIST | jq .
```

## Platform Integration

When `OPENBAO_ENABLED=true`, the setup script automatically:

1. **Configures Platform environment** - Adds these variables to `.env`:
   ```bash
   ITENTIAL_VAULT_URL=http://openbao:8200
   ITENTIAL_VAULT_AUTH_METHOD=token
   ITENTIAL_VAULT_TOKEN=<generated-root-token>
   ITENTIAL_VAULT_SECRETS_ENDPOINT=secret/data
   ITENTIAL_VAULT_READ_ONLY=true
   ```

2. **Installs HashiCorp Vault adapter** - Clones from GitLab and runs npm install:
   ```
   volumes/platform/adapters/adapter-hashicorp_vault/
   ```

3. **Configures the adapter** - Creates and configures via Platform API with OpenBao connection settings

### HashiCorp Vault Adapter

The adapter is automatically installed and configured to connect to OpenBao. After setup, you can:

- View the adapter status in Platform UI under **Admin > Adapters**
- Use adapter methods in workflows to read/write secrets
- Access secrets programmatically via the adapter API

### Using Secrets in Platform

Platform can reference secrets stored in OpenBao via:

1. **Vault Adapter** - Use adapter methods in workflows (recommended)
2. **Environment Variables** - Platform reads `ITENTIAL_VAULT_*` settings for native integration

Consult [Itential's Vault documentation](https://docs.itential.com/docs/configure-hashicorp-vault-itential-platform) for detailed usage.

## Example: Storing Adapter Credentials

Store credentials for an adapter in OpenBao:

```bash
export VAULT_TOKEN=$(cat volumes/openbao/init-keys.json | jq -r '.root_token')

# Store ServiceNow credentials
curl -X POST http://localhost:8200/v1/secret/data/adapters/servicenow \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -d '{
    "data": {
      "host": "dev12345.service-now.com",
      "username": "api_user",
      "password": "api_password"
    }
  }'

# Store Cisco DNA Center credentials
curl -X POST http://localhost:8200/v1/secret/data/adapters/dnac \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -d '{
    "data": {
      "host": "dnac.example.com",
      "username": "admin",
      "password": "admin123"
    }
  }'
```

## Configuration Options

| Variable | Description | Default |
|----------|-------------|---------|
| `OPENBAO_ENABLED` | Enable OpenBao service | `false` |
| `OPENBAO_VERSION` | OpenBao image version | `2` |
| `OPENBAO_PORT` | Host port for API | `8200` |

### Vault Integration Variables

These are automatically set when `OPENBAO_ENABLED=true`:

| Variable | Description | Auto Value |
|----------|-------------|------------|
| `ITENTIAL_VAULT_URL` | Vault API URL | `http://openbao:8200` |
| `ITENTIAL_VAULT_AUTH_METHOD` | Authentication method | `token` |
| `ITENTIAL_VAULT_TOKEN` | Authentication token | Generated root token |
| `ITENTIAL_VAULT_SECRETS_ENDPOINT` | KV secrets path | `secret/data` |
| `ITENTIAL_VAULT_READ_ONLY` | Read-only mode | `true` |

## Persistent Storage

OpenBao uses **file-based persistent storage**:

1. **Data persists** - Secrets survive container restarts in the `openbao-data` Docker volume
2. **Initialization** - Required on first run (handled automatically by `make setup`)
3. **Unsealing** - Required after restart (handled automatically by `configure-openbao.sh`)
4. **Keys stored locally** - Root token and unseal keys saved in `volumes/openbao/init-keys.json`

### After Container Restart

If OpenBao shows as "sealed" after a container restart, run:

```bash
./scripts/configure-openbao.sh
```

This script:
- Checks if OpenBao is initialized
- Unseals using saved keys from `volumes/openbao/init-keys.json`
- Is idempotent (safe to run multiple times)

### Starting Fresh

To completely reset OpenBao (removes all secrets):

```bash
make clean
make setup
```

This removes the `openbao-data` volume and `init-keys.json`, forcing reinitialization.

## Key Files

| File | Purpose |
|------|---------|
| `volumes/openbao/config/config.hcl` | OpenBao server configuration |
| `volumes/openbao/init-keys.json` | Root token and unseal keys (gitignored) |
| `scripts/configure-openbao.sh` | Initialize/unseal script |

## Troubleshooting

### OpenBao not starting

Check the logs:
```bash
make logs LOG=openbao
```

### OpenBao is sealed

Run the configure script to unseal:
```bash
./scripts/configure-openbao.sh
```

### Cannot connect to OpenBao

1. Verify the container is running:
   ```bash
   docker ps | grep openbao
   ```

2. Check the port is accessible:
   ```bash
   curl http://localhost:8200/v1/sys/health
   ```

### Lost init keys

If `volumes/openbao/init-keys.json` is deleted but the volume still exists, you'll need to reset:
```bash
make clean
make setup
```

### Platform not connecting to OpenBao

1. Verify environment variables are set:
   ```bash
   docker exec platform env | grep VAULT
   ```

2. Check Platform can reach OpenBao:
   ```bash
   docker exec platform wget -q -O - http://openbao:8200/v1/sys/health
   ```

## Additional Resources

- [OpenBao Documentation](https://openbao.org/docs/)
- [OpenBao API Reference](https://openbao.org/api-docs/)
- [KV Secrets Engine](https://openbao.org/docs/secrets/kv/)
- [Itential Vault Configuration](https://docs.itential.com/docs/configure-hashicorp-vault-itential-platform)
