# Changelog

## 0.1.0

Initial release.

- stdio transport: spawns `command`/`args`/`env` servers or entries from an `mcpServers` JSON config file.
- Dual-era protocol support: probes with `server/discover` (MCP 2026-07-28, per-request `_meta`) and falls back to the legacy `initialize` handshake (2025-11-25 and earlier).
- `Connect-McpServer`, `Disconnect-McpServer`, `Get-McpServer`, `Get-McpTool`, `Invoke-McpTool`.
- `ConvertTo-PSAISuiteTool`: emits PSAISuite `-Tools` hashtables and generates global proxy functions with parameters derived from each tool's `inputSchema`, so PSAISuite's `Get-Command` + splatting tool loop can call MCP tools directly.
- Errors returned as strings by default (opt-in `-ThrowOnError`) so LLM tool loops survive tool failures.
- Process-tree cleanup on disconnect, module removal and PowerShell exit.
- Offline Pester suite driven by a PowerShell stub MCP server; `Live`-tagged tests against a published server.
