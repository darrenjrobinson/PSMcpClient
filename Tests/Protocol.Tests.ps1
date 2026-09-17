BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $moduleRoot 'PSMcpClient.psd1') -Force
    $stubPath = Join-Path $PSScriptRoot 'Stub/stub-server.ps1'

    function Connect-Stub {
        param(
            [Parameter(Mandatory)][string]$Name,
            [string]$Mode = 'Legacy'
        )
        Connect-McpServer -Name $Name -Command pwsh -Arguments @('-NoProfile', '-NonInteractive', '-File', $stubPath, '-Mode', $Mode)
    }
}

AfterAll {
    Disconnect-McpServer -All -ErrorAction SilentlyContinue
}

Describe 'Get-McpTool' {
    BeforeAll { Connect-Stub -Name tools }
    AfterAll { Disconnect-McpServer -All -ErrorAction SilentlyContinue }

    It 'returns every tool with a hashtable InputSchema' {
        $tools = Get-McpTool -Server tools
        $tools.Count | Should -Be 9
        $tools | ForEach-Object {
            $_.Server | Should -Be 'tools'
            $_.InputSchema | Should -BeOfType [System.Collections.IDictionary]
            $_.InputSchema.type | Should -Be 'object'
        }
        ($tools | Where-Object Name -eq 'echo').InputSchema.properties.Keys | Should -Contain 'kebab-name'
    }

    It 'caches the tool list and reports the count' {
        (Get-McpServer -Server tools).ToolCount | Should -Be 9
        (Get-McpServer -Server tools).ToolsStale | Should -BeFalse
    }

    It 'filters by name with wildcards' {
        (Get-McpTool -Server tools -Name 'e*').Name | Should -Be 'echo'
        @(Get-McpTool -Server tools -Name 'echo', 'fail').Count | Should -Be 2
    }

    It 'errors for a literal name that does not exist' {
        $err = { Get-McpTool -Server tools -Name nope -ErrorAction Stop } | Should -Throw -PassThru
        $err.FullyQualifiedErrorId | Should -BeLike 'McpToolNotFound*'
    }

    It 'refreshes after notifications/tools/list_changed' {
        Invoke-McpTool -Server tools -Name notify_changed | Should -Be 'notified'
        (Get-McpServer -Server tools).ToolsStale | Should -BeTrue
        $null = Get-McpTool -Server tools
        (Get-McpServer -Server tools).ToolsStale | Should -BeFalse
    }
}

Describe 'Invoke-McpTool content flattening' {
    BeforeAll { Connect-Stub -Name content }
    AfterAll { Disconnect-McpServer -All -ErrorAction SilentlyContinue }

    It 'parses JSON text content into objects' {
        $result = Invoke-McpTool -Server content -Name echo -Arguments @{ message = 'hi'; count = 3 }
        $result | Should -BeOfType [System.Collections.IDictionary]
        $result.message | Should -Be 'hi'
        $result.count | Should -Be 3
    }

    It 'returns plain text as a string' {
        Invoke-McpTool -Server content -Name plain | Should -BeExactly 'hello world'
    }

    It 'returns multiple text blocks as an array and drops non-text blocks' {
        $result = @(Invoke-McpTool -Server content -Name multi)
        $result | Should -Be @('first', 'second')
    }

    It 'prefers structuredContent over text' {
        $result = Invoke-McpTool -Server content -Name structured
        $result.source | Should -Be 'structured'
        $result.answer | Should -Be 42
    }

    It 'returns the unmodified result with -Raw' {
        $result = Invoke-McpTool -Server content -Name multi -Raw
        $result.content.Count | Should -Be 3
        $result.content[1].type | Should -Be 'image'
    }

    It 'sends an empty arguments object when none are given' {
        Invoke-McpTool -Server content -Name echo | Should -BeOfType [System.Collections.IDictionary]
    }

    It 'accepts pipeline input from Get-McpTool' {
        Get-McpTool -Server content -Name plain | Invoke-McpTool | Should -Be 'hello world'
    }
}

Describe 'Invoke-McpTool error semantics' {
    BeforeAll { Connect-Stub -Name errors }
    AfterAll { Disconnect-McpServer -All -ErrorAction SilentlyContinue }

    It 'returns isError content as a string by default' {
        Invoke-McpTool -Server errors -Name fail -Arguments @{ reason = 'boom' } | Should -Be 'failure: boom'
    }

    It 'throws McpToolError for isError with -ThrowOnError' {
        $err = { Invoke-McpTool -Server errors -Name fail -Arguments @{ reason = 'boom' } -ThrowOnError } | Should -Throw -PassThru
        $err.FullyQualifiedErrorId | Should -BeLike 'McpToolError*'
        $err.Exception.Message | Should -Match 'failure: boom'
    }

    It 'returns JSON-RPC errors as a string by default' {
        Invoke-McpTool -Server errors -Name nope | Should -Be 'MCP error -32602: Unknown tool: nope'
    }

    It 'throws McpProtocolError for JSON-RPC errors with -ThrowOnError' {
        $err = { Invoke-McpTool -Server errors -Name nope -ThrowOnError } | Should -Throw -PassThru
        $err.FullyQualifiedErrorId | Should -BeLike 'McpProtocolError*'
        $err.TargetObject.code | Should -Be -32602
    }

    It 'keeps isError visible with -Raw' {
        (Invoke-McpTool -Server errors -Name fail -Arguments @{ reason = 'r' } -Raw).isError | Should -BeTrue
    }
}

Describe 'JSON-RPC session handling' {
    AfterEach { Disconnect-McpServer -All -ErrorAction SilentlyContinue }

    It 'skips interleaved notifications and correlates by id' {
        # the stub emits notifications/message before every response
        Connect-Stub -Name corr
        1..5 | ForEach-Object { Invoke-McpTool -Server corr -Name plain | Should -Be 'hello world' }
    }

    It 'declines server-initiated requests with -32601 instead of hanging' {
        Connect-Stub -Name srvreq
        Invoke-McpTool -Server srvreq -Name request_sampling | Should -Be 'client replied with error code -32601'
    }

    It 'attaches per-request _meta for modern servers' {
        # the modern stub rejects any request without _meta protocolVersion
        Connect-Stub -Name meta -Mode Modern
        (Invoke-McpTool -Server meta -Name echo -Arguments @{ message = 'm' }).message | Should -Be 'm'
        @(Get-McpTool -Server meta).Count | Should -Be 9
    }
}
