# Requires Node.js/npx and network access. Run with: Invoke-Pester -Path ./Tests/LiveServer.Tests.ps1 -Tag Live
BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $moduleRoot 'PSMcpClient.psd1') -Force
    $configPath = Join-Path $moduleRoot 'mcp.example.json'
}

Describe 'Live: @modelcontextprotocol/server-everything' -Tag Live {
    BeforeAll {
        Connect-McpServer -ConfigPath $configPath -Name everything -DiscoverTimeoutSec 90 -InitializeTimeoutSec 180
    }
    AfterAll { Disconnect-McpServer -All -ErrorAction SilentlyContinue }

    It 'completes the handshake and reports serverInfo' {
        $server = Get-McpServer -Server everything
        $server.Connected | Should -BeTrue
        $server.ServerName | Should -Not -BeNullOrEmpty
        $server.ProtocolVersion | Should -Not -BeNullOrEmpty
    }

    It 'lists tools whose inputSchema.type is object' {
        $tools = @(Get-McpTool -Server everything)
        $tools.Count | Should -BeGreaterThan 0
        $tools | ForEach-Object { $_.InputSchema.type | Should -Be 'object' }
        $tools.Name | Should -Contain 'echo'
    }

    It 'round-trips a known-safe tool call' {
        Invoke-McpTool -Server everything -Name echo -Arguments @{ message = 'ping from PSMcpClient' } | Should -Match 'ping from PSMcpClient'
    }

    It 'returns a non-error raw result' {
        (Invoke-McpTool -Server everything -Name echo -Arguments @{ message = 'raw' } -Raw).isError | Should -Not -BeTrue
    }

    It 'exposes tools to PSAISuite through proxy functions' {
        $tools = @(ConvertTo-PSAISuiteTool -Server everything -Prefix live)
        $tools.Count | Should -BeGreaterThan 0
        Get-Command live_echo -CommandType Function | Should -Not -BeNullOrEmpty
        $arguments = @{ message = 'proxied' }
        & live_echo @arguments | Should -Match 'proxied'
    }

    It 'terminates the whole process tree on disconnect' {
        $serverPid = (Get-McpServer -Server everything).ProcessId
        Disconnect-McpServer -Server everything
        Start-Sleep -Milliseconds 800
        Get-Process -Id $serverPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        if ($IsWindows) {
            @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -match 'server-everything' }).Count | Should -Be 0
        }
    }
}
