# Itential MCP

Configuration examples for using [Itential MCP](https://github.com/itential/itential-mcp) with the dev stack.

## Application Configuration _(Host)_

Any _MCP-compatible_ host application can **connect to** and **utilize** any independent _MCP server_. As an example, let's configure [Claude Desktop](https://claude.ai/download) to use the Itential MCP server for interacting with your local Platform instance.

### Prerequisites

- Itential Dev Stack running (`make up`)
- Claude Desktop installed

### Configuration

Edit your Claude Desktop configuration file:

| OS | Path |
|----|------|
| macOS | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| Windows | `%APPDATA%\Claude\claude_desktop_config.json` |

Add the following configuration (see [claude_desktop_config.example.json](claude_desktop_config.example.json)):

```json
{
  "mcpServers": {
    "itential": {
      "command": "docker",
      "args": [
        "run",
        "-i",
        "--rm",
        "--network", "devstack",
        "-e", "ITENTIAL_MCP_PLATFORM_HOST=platform",
        "-e", "ITENTIAL_MCP_PLATFORM_PORT=3000",
        "-e", "ITENTIAL_MCP_PLATFORM_USER=admin@itential",
        "-e", "ITENTIAL_MCP_PLATFORM_PASSWORD=admin",
        "-e", "ITENTIAL_MCP_PLATFORM_DISABLE_TLS=true",
        "-e", "ITENTIAL_MCP_SERVER_LOG_LEVEL=INFO",
        "ghcr.io/itential/itential-mcp:latest"
      ]
    }
  }
}
```

> **Note**: Replace `admin@itential` / `admin` with your Platform credentials if different.

### How It Works

The configuration runs the MCP container on-demand when Claude Desktop starts. The container:

1. Connects to the `devstack` docker network _(created by docker-compose)_
2. Authenticates with Platform using the provided credentials
3. Exposes Itential Platform tools to Claude Desktop via stdio

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
  -d '{"username":"admin@itential","password":"admin"}'
```

**View MCP logs**

Check container logs for errors:
```bash
docker logs $(docker ps -q --filter "ancestor=ghcr.io/itential/itential-mcp") 2>/dev/null
```

## Additional Resources

- [itential-mcp GitHub](https://github.com/itential/itential-mcp) - MCP server documentation
- [MCP Protocol](https://modelcontextprotocol.io/) - Model Context Protocol specification
- [Claude Desktop](https://claude.ai/download) - Download Claude Desktop
