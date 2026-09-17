# PSMcpClient

A PowerShell 7 **MCP client**. Connect to published stdio [Model Context Protocol](https://modelcontextprotocol.io) servers (typically launched with `npx`), list and call their tools from PowerShell, and hand those tools to a frontier LLM through [PSAISuite](https://github.com/dfinke/PSAISuite) `Invoke-ChatCompletion -Tools`.

PowerShell-as-MCP-*server* is well covered (PSMCP, PowerShell.MCP). This module is the other direction: PowerShell as the *host* that consumes MCP servers. It never calls an LLM itself and has no module dependencies; PSAISuite is only needed for the bridge scenario.

| Concern | Owner |
|---|---|
| Provider auth, model selection, `Invoke-ChatCompletion`, the tool-calling loop | PSAISuite |
| Spawning stdio servers, JSON-RPC session, `tools/list`, `tools/call`, emitting tool definitions and proxy functions | PSMcpClient |

## Requirements

- PowerShell 7.2+ (Windows, Linux, macOS)
- Node.js for `npx`-published servers
- PSAISuite 0.8+ (optional, for the LLM bridge)

## Install

From source while unpublished:

```powershell
Import-Module ./PSMcpClient/PSMcpClient.psd1
```

## Quick start

```powershell
Connect-McpServer -Name everything -Command npx -Arguments '-y','@modelcontextprotocol/server-everything'

Get-McpServer                              # Name, ServerName, ProtocolVersion, Era, ProcessId, Connected, ToolCount
Get-McpTool -Server everything             # Name, Description, InputSchema (hashtable)
Invoke-McpTool -Server everything -Name get-sum -Arguments @{ a = 2; b = 40 }
# The sum of 2 and 40 is 42.

Disconnect-McpServer -Server everything    # kills the whole process tree
```

Add `-Verbose` to any command to see the raw JSON-RPC lines in both directions.

### Config file

`Connect-McpServer -ConfigPath` reads the same `mcpServers` JSON used by Claude Desktop, Claude Code and VS Code, so server authors' existing snippets paste straight in:

```json
{
  "mcpServers": {
    "everything": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-everything"],
      "env": { "SOME_SETTING": "value" }
    }
  }
}
```

```powershell
Connect-McpServer -ConfigPath ./mcp.json                 # every server in the file
Connect-McpServer -ConfigPath ./mcp.json -Name everything
```

Keys become session names. `env` merges over the current environment, `cwd` sets the working directory, `disabled: true` entries are skipped, and `type: http`/`sse` entries are skipped with a warning (stdio only in this release).

## Bridging tools into PSAISuite

```powershell
Install-Module PSAISuite
Import-Module PSAISuite
$env:AnthropicKey = '<your-anthropic-key>'     # or OpenAIKey, GeminiKey, xAIKey, ... for other providers

Connect-McpServer -ConfigPath ./mcp.json -Name everything

$tools = ConvertTo-PSAISuiteTool -Server everything -Prefix ev
icc -Messages 'What is 17 plus 25? Use the tool.' -Tools $tools -Model anthropic:claude-sonnet-5   # icc = Invoke-ChatCompletion

Disconnect-McpServer -Server everything
```

PSAISuite authenticates from its own per-provider environment variables (`$env:AnthropicKey`, `$env:OpenAIKey`, `$env:GeminiKey`, ...), not the vendor SDK names such as `ANTHROPIC_API_KEY`. See the [PSAISuite README](https://github.com/dfinke/PSAISuite) for the variable your provider expects.

### How it works

`ConvertTo-PSAISuiteTool` emits one hashtable per tool in the shape PSAISuite accepts:

```powershell
@{ Name = 'ev_get-sum'; Description = '...'; Parameters = <inputSchema hashtable> }
```

PSAISuite executes a tool call by resolving `Name` with `Get-Command` and **splatting** the model's JSON arguments as named parameters (`& $Name @arguments`). So the bridge also creates one global function per tool whose `param()` block mirrors the tool's `inputSchema.properties` — `string`→`[string]`, `boolean`→`[switch]`, `integer`→`[long]`, `number`→`[double]`, `array`→`[object[]]`, anything else untyped — and forwards to `Invoke-McpTool`. Hyphenated property names work (`${kebab-name}`), nothing is mandatory so a missing argument never prompts, and the functions are removed by `Disconnect-McpServer` (and re-created if the server announces `tools/list_changed`).

Use `-NoProxyFunction` to get the definitions only.

### Use `-Prefix`

Tool names such as `echo`, `sort` or `type` collide with built-in PowerShell aliases, and aliases outrank functions — PSAISuite would run `Write-Output` instead of your MCP tool. `ConvertTo-PSAISuiteTool` warns when this happens; `-Prefix <server>` sidesteps it and also keeps two servers' tools apart.

## Error semantics

`Invoke-McpTool` (and therefore every proxy function) returns errors as **strings** by default, so an LLM tool loop sees the message and can recover instead of the whole completion aborting:

| Server response | Default | `-ThrowOnError` |
|---|---|---|
| JSON-RPC `error` (unknown tool, invalid params) | `"MCP error <code>: <message>"` | throws `McpProtocolError` |
| `tools/call` result with `isError: true` | the flattened error text | throws `McpToolError` |
| Server process exits mid-call | always throws `McpProcessExited` with the last stderr lines | same |
| No response within the timeout | always throws `McpRequestTimeout` | same |

## Results

By default `Invoke-McpTool` flattens content: `structuredContent` is returned when present; otherwise `text` blocks that parse as JSON become objects and other text stays a string (several blocks → array). `image`, `audio` and `resource` blocks are dropped with a `-Verbose` note. `-Raw` returns the untouched result (`content[]`, `isError`, `structuredContent`).

## Protocol support

MCP `2026-07-28` replaced the `initialize` handshake with per-request `_meta` (protocol version, client info, capabilities); `2025-11-25` and earlier still use the handshake. Almost every published npx server speaks the older "legacy" flavour today, so the client is **dual-era**, following the spec's stdio compatibility procedure:

1. Send `server/discover` as a modern client.
2. `DiscoverResult` → modern; pick a mutually supported version and attach `_meta` to every request.
3. `UnsupportedProtocolVersion` (`-32022`) → modern; retry with a version from the server's `supported` list.
4. Any other error, or no reply within `-DiscoverTimeoutSec` → legacy; run `initialize` → `notifications/initialized` with `protocolVersion: 2025-11-25`.

The era is cached per session and shown by `Get-McpServer`. Server-initiated requests (sampling, elicitation, roots) are declined with `-32601` so legacy servers never hang waiting; modern `input_required` results are rejected as unsupported.

### Timeouts and cold `npx`

`-InitializeTimeoutSec` (default 120) covers the first-run `npx -y` download; `-DiscoverTimeoutSec` defaults to the same value; `-RequestTimeoutSec` (default 30) covers everything else. A legacy server that is still downloading cannot answer the discover probe, so a cold first connect can wait out the probe before falling back to `initialize`. For predictable startup, `npm i -g` the server and point `command` at the bin (or `node <path>`).

## Cleanup

`Disconnect-McpServer` closes stdin, waits briefly, then kills the entire process tree (on Windows `npx` runs as `cmd.exe → node.exe`). The same happens on `Remove-Module PSMcpClient` and on PowerShell exit.

## Testing

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser

# Offline: uses Tests/Stub/stub-server.ps1 (a PowerShell MCP server with Legacy / Modern / Silent modes)
Invoke-Pester -Path ./PSMcpClient/Tests -ExcludeTagFilter Live

# Live: needs npx and network, connects to @modelcontextprotocol/server-everything from mcp.example.json
Invoke-Pester -Path ./PSMcpClient/Tests/LiveServer.Tests.ps1 -Tag Live
```

No LLM API key is needed for either suite. When PSAISuite is installed the bridge tests also run the emitted definitions through its `ConvertTo-ProviderToolSchema`.

## Not in this release. Potentially future enhancements.

- Streamable HTTP transport (bearer / Entra auth)
- Resources, prompts, sampling, elicitation, subscriptions
- Concurrent in-flight requests (PSAISuite's tool loop is sequential)
- `${env:VAR}` substitution in config values
- OpenAI strict-mode schema scrubbing (`$schema`, unusual `format` values)
- Windows PowerShell 5.1

PSAISuite and PSMCP are Doug Finke's projects; PSMcpClient is an independent companion module and is not affiliated with either.
