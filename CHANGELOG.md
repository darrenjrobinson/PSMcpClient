# Changelog

## 0.1.0

Initial release.

- stdio transport: spawns `command`/`args`/`env` servers or entries from an `mcpServers` JSON config file.
- Dual-era protocol support: probes with `server/discover` (MCP 2026-07-28, per-request `_meta`) and falls back to the legacy `initialize` handshake (2025-11-25 and earlier).
- `Connect-McpServer`, `Disconnect-McpServer`, `Get-McpServer`, `Get-McpTool`, `Invoke-McpTool`.
- `ConvertTo-PSAISuiteTool`: emits PSAISuite `-Tools` hashtables and generates global proxy functions with parameters derived from each tool's `inputSchema`, so PSAISuite's `Get-Command` + splatting tool loop can call MCP tools directly.
- Errors returned as strings by default (opt-in `-ThrowOnError`) so LLM tool loops survive tool failures.
- Process-tree cleanup on disconnect, module removal and PowerShell exit.
- Windows `.cmd`/`.bat` shims (such as `npx.cmd`) are launched as `cmd.exe /d /e:on /v:off /s /c` with every argument quoted for both cmd.exe and the C runtime: embedded quotes become `""`, backslashes before a quote are doubled and `%` is rendered as `%%cd:~,%`. `%VAR%` and `!VAR!` expansion, including on hosts with delayed expansion enabled in the registry, and `&`/`|` command injection cannot reach the shim, and arguments containing a carriage return, line feed or NUL are rejected with `McpUnsafeCmdArgument` because cmd.exe truncates its command line at a line feed and strips carriage returns. Covered by a real cmd.exe round-trip test.
- Timed-out request IDs kept for late-response discarding are capped at 256 per session (oldest evicted first).
- Offline Pester suite driven by a PowerShell stub MCP server; `Live`-tagged tests against a published server.
