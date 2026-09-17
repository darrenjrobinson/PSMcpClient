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

Describe 'ConvertTo-PSAISuiteTool definitions' {
    BeforeAll {
        Connect-Stub -Name bridge
        $tools = @(ConvertTo-PSAISuiteTool -Server bridge -Prefix stub)
    }
    AfterAll { Disconnect-McpServer -All -ErrorAction SilentlyContinue }

    It 'emits one hashtable per tool in PSAISuite shape' {
        $tools.Count | Should -Be 9
        $tools | ForEach-Object {
            $_ | Should -BeOfType [hashtable]
            $_.Keys | Should -Contain 'Name'
            $_.Keys | Should -Contain 'Description'
            $_.Keys | Should -Contain 'Parameters'
            $_.Parameters | Should -BeOfType [System.Collections.IDictionary]
            $_.Parameters.type | Should -Be 'object'
        }
    }

    It 'prefixes tool names' {
        $tools.Name | Should -Contain 'stub_echo'
        $tools.Name | ForEach-Object { $_ | Should -BeLike 'stub_*' }
    }

    It 'passes inputSchema through unchanged as Parameters' {
        $echo = $tools | Where-Object Name -eq 'stub_echo'
        $echo.Parameters.properties.Keys | Should -Contain 'kebab-name'
        $echo.Parameters.properties.count.type | Should -Be 'integer'
    }

    It 'filters tools with -Name' {
        $subset = @(ConvertTo-PSAISuiteTool -Server bridge -Name echo, plain -Prefix sub)
        ($subset.Name | Sort-Object) | Should -Be @('sub_echo', 'sub_plain')
        Get-Command sub_fail -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'is accepted by PSAISuite ConvertTo-ProviderToolSchema' -Skip:(-not (Get-Module -ListAvailable PSAISuite)) {
        Import-Module PSAISuite
        $echo = @(ConvertTo-PSAISuiteTool -Server bridge -Name echo -Prefix ps)
        $anthropic = @(ConvertTo-ProviderToolSchema -Tools $echo -Provider anthropic)
        $anthropic.Count | Should -Be 1
        $anthropic[0].name | Should -Be 'ps_echo'
        $anthropic[0].input_schema.properties.Keys | Should -Contain 'message'
        $openai = @(ConvertTo-ProviderToolSchema -Tools $echo -Provider openai)
        $openai[0].function.name | Should -Be 'ps_echo'
    }
}

Describe 'Proxy functions' {
    BeforeAll {
        Connect-Stub -Name proxy
        $null = ConvertTo-PSAISuiteTool -Server proxy -Prefix px
    }
    AfterAll { Disconnect-McpServer -All -ErrorAction SilentlyContinue }

    It 'creates one global function per tool' {
        Get-Command px_echo -CommandType Function | Should -Not -BeNullOrEmpty
        Get-Command px_fail -CommandType Function | Should -Not -BeNullOrEmpty
    }

    It 'derives typed parameters from inputSchema properties' {
        $parameters = (Get-Command px_echo).Parameters
        $parameters['message'].ParameterType | Should -Be ([string])
        $parameters['flag'].ParameterType | Should -Be ([switch])
        $parameters['count'].ParameterType | Should -Be ([long])
        $parameters['ratio'].ParameterType | Should -Be ([double])
        $parameters['tags'].ParameterType | Should -Be ([object[]])
        $parameters.Keys | Should -Contain 'kebab-name'
        $parameters.Values | ForEach-Object { $_.Attributes.Mandatory | Should -Not -Contain $true }
    }

    It 'forwards splatted arguments the way PSAISuite invokes tools' {
        $arguments = @{ message = 'splat'; 'kebab-name' = 'k'; ratio = 1.5; tags = @('a', 'b'); nested = @{ x = 1 }; flag = $false; count = 7 }
        $result = & 'px_echo' @arguments
        $result.message | Should -Be 'splat'
        $result.'kebab-name' | Should -Be 'k'
        $result.ratio | Should -Be 1.5
        $result.tags | Should -Be @('a', 'b')
        $result.nested.x | Should -Be 1
        $result.flag | Should -BeFalse
        $result.count | Should -Be 7
    }

    It 'converts switch parameters to booleans' {
        (px_echo -flag).flag | Should -BeTrue
    }

    It 'returns tool errors as strings so a tool loop can continue' {
        px_fail -reason 'nope' | Should -Be 'failure: nope'
    }

    It 're-registers proxies when the tool list is refreshed' {
        Invoke-McpTool -Server proxy -Name notify_changed | Should -Be 'notified'
        $null = Get-McpTool -Server proxy
        Get-Command px_echo -CommandType Function | Should -Not -BeNullOrEmpty
        (px_echo -message again).message | Should -Be 'again'
    }

    It 'does not create functions with -NoProxyFunction' {
        $defs = @(ConvertTo-PSAISuiteTool -Server proxy -Prefix np -NoProxyFunction)
        $defs.Count | Should -Be 9
        Get-Command np_echo -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'warns when a tool name collides with an existing alias' {
        $null = ConvertTo-PSAISuiteTool -Server proxy -Name echo -WarningVariable warnings -WarningAction SilentlyContinue
        ($warnings -join ' ') | Should -Match 'alias'
        ($warnings -join ' ') | Should -Match 'Prefix'
    }

    It 'removes proxy functions on disconnect' {
        $null = ConvertTo-PSAISuiteTool -Server proxy -Prefix px
        Disconnect-McpServer -Server proxy
        Get-Command px_echo -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Command px_fail -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}
