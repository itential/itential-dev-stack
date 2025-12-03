# Usage Documentation

Configuration examples and usage guides for Itential Dev Stack.

## Claude Desktop Configuration

Configure [Claude Desktop](https://claude.ai/download) to use the Itential MCP server for interacting with your local Platform instance.

### Prerequisites

- Itential Dev Stack running (`make up`)
- Claude Desktop installed

### Configuration

Edit your Claude Desktop configuration file:

| OS | Path |
|----|------|
| macOS | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| Windows | `%APPDATA%\Claude\claude_desktop_config.json` |

Add the following configuration:

```json
{
  "mcpServers": {
    "itential": {
      "command": "docker",
      "args": [
        "run",
        "-i",
        "--rm",
        "--network", "itential",
        "-e", "ITENTIAL_MCP_PLATFORM_HOST=platform",
        "-e", "ITENTIAL_MCP_PLATFORM_PORT=3000",
        "-e", "ITENTIAL_MCP_PLATFORM_USER=admin",
        "-e", "ITENTIAL_MCP_PLATFORM_PASSWORD=admin",
        "-e", "ITENTIAL_MCP_PLATFORM_DISABLE_TLS=true",
        "-e", "ITENTIAL_MCP_SERVER_LOG_LEVEL=INFO",
        "ghcr.io/itential/itential-mcp:latest"
      ]
    }
  }
}
```

> **Note**: Replace `admin` / `admin` with your Platform credentials if different.

### How It Works

The configuration runs the MCP container on-demand when Claude Desktop starts. The container:

1. Connects to the `itential` Docker network (created by docker-compose)
2. Authenticates with Platform using the provided credentials
3. Exposes Itential Platform tools to Claude Desktop via stdio transport

### Verification

1. Restart Claude Desktop after saving the configuration
2. Look for the hammer icon in the chat input area
3. Click it to see available Itential tools

### Troubleshooting

**Container network not found**

Ensure the dev stack is running:
```bash
make status
```

**Authentication errors**

Verify your credentials work:
```bash
curl -X POST http://localhost:3000/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin"}'
```

**View MCP logs**

Check container logs for errors:
```bash
docker logs $(docker ps -q --filter "ancestor=ghcr.io/itential/itential-mcp") 2>/dev/null
```

## Claude Code Configuration

For [Claude Code](https://claude.ai/code), the MCP server can run as part of the dev stack.

### Enable MCP in Dev Stack

Add to your `.env` file:
```bash
MCP_ENABLED=true
```

Then restart:
```bash
make up
```

### Configure Claude Code

Add to your Claude Code MCP settings:

```json
{
  "mcpServers": {
    "itential": {
      "command": "docker",
      "args": [
        "exec", "-i", "mcp",
        "node", "dist/index.js"
      ]
    }
  }
}
```

This connects to the already-running MCP container in the dev stack.

## Additional Resources

- [itential-mcp GitHub](https://github.com/itential/itential-mcp) - MCP server documentation
- [MCP Protocol](https://modelcontextprotocol.io/) - Model Context Protocol specification
- [Claude Desktop](https://claude.ai/download) - Download Claude Desktop
