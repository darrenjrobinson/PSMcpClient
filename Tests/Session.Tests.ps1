BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $moduleRoot 'PSMcpClient.psd1') -Force
    $stubPath = Join-Path $PSScriptRoot 'Stub/stub-server.ps1'

    function Connect-Stub {
        param(
            [Parameter(Mandatory)][string]$Name,
            [string]$Mode = 'Legacy',
            [hashtable]$Options = @{}
        )
        Connect-McpServer -Name $Name -Command pwsh -Arguments @('-NoProfile', '-NonInteractive', '-File', $stubPath, '-Mode', $Mode) @Options
    }
}

AfterAll {
    Disconnect-McpServer -All -ErrorAction SilentlyContinue
}

Describe 'Connect-McpServer' {
    AfterEach { Disconnect-McpServer -All -ErrorAction SilentlyContinue }

    It 'connects to a legacy server via the initialize handshake' {
        Connect-Stub -Name legacy
        $server = Get-McpServer -Server legacy
        $server.Era | Should -Be 'Legacy'
        $server.ProtocolVersion | Should -Be '2025-11-25'
        $server.ServerName | Should -Be 'stub-server'
        $server.ServerVersion | Should -Be '1.0.0'
        $server.Connected | Should -BeTrue
    }

    It 'connects to a modern server via server/discover without initialize' {
        Connect-Stub -Name modern -Mode Modern
        $server = Get-McpServer -Server modern
        $server.Era | Should -Be 'Modern'
        $server.ProtocolVersion | Should -Be '2026-07-28'
        $server.ServerName | Should -Be 'stub-server'
    }

    It 'falls back to legacy when the discover probe gets no answer' {
        Connect-Stub -Name silent -Mode Silent -Options @{ DiscoverTimeoutSec = 2 }
        (Get-McpServer -Server silent).Era | Should -Be 'Legacy'
    }

    It 'rejects duplicate session names before spawning' {
        Connect-Stub -Name dup
        $err = { Connect-Stub -Name dup } | Should -Throw -PassThru
        $err.FullyQualifiedErrorId | Should -BeLike 'McpSessionExists*'
        @(Get-McpServer).Count | Should -Be 1
    }

    It 'fails clearly for an unresolvable command' {
        $err = { Connect-McpServer -Name bad -Command 'no-such-binary-xyz' } | Should -Throw -PassThru
        $err.FullyQualifiedErrorId | Should -BeLike 'McpCommandNotFound*'
    }

    It 'returns the session object with -PassThru' {
        $session = Connect-Stub -Name pt -Options @{ PassThru = $true }
        $session.Name | Should -Be 'pt'
        $session.Process.Id | Should -BeGreaterThan 0
    }

    It 'passes environment variables to the child process' {
        Connect-Stub -Name envtest -Options @{ Environment = @{ STUB_MARKER = 'present' } }
        (Get-McpServer -Server envtest).Connected | Should -BeTrue
    }
}

Describe 'Connect-McpServer -ConfigPath' {
    BeforeAll {
        $configPath = Join-Path $TestDrive 'mcp.json'
        @{
            mcpServers = @{
                cfgstub  = @{ command = 'pwsh'; args = @('-NoProfile', '-NonInteractive', '-File', $stubPath, '-Mode', 'Legacy'); env = @{ STUB_ENV = '1' }; extraKey = $true }
                cfgstub2 = @{ command = 'pwsh'; args = @('-NoProfile', '-NonInteractive', '-File', $stubPath, '-Mode', 'Modern') }
                remote   = @{ type = 'http'; url = 'https://example.invalid/mcp' }
                off      = @{ command = 'pwsh'; disabled = $true }
            }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $configPath -Encoding utf8
    }
    AfterEach { Disconnect-McpServer -All -ErrorAction SilentlyContinue }

    It 'connects every stdio entry and skips http and disabled entries' {
        $sessions = @(Connect-McpServer -ConfigPath $configPath -PassThru -WarningVariable warnings -WarningAction SilentlyContinue)
        ($sessions.Name | Sort-Object) | Should -Be @('cfgstub', 'cfgstub2')
        ($warnings -join ' ') | Should -Match "transport type 'http'"
        (Get-McpServer -Server cfgstub2).Era | Should -Be 'Modern'
    }

    It 'connects only the named entries' {
        Connect-McpServer -ConfigPath $configPath -Name cfgstub
        @(Get-McpServer).Name | Should -Be 'cfgstub'
    }

    It 'errors for names missing from the file' {
        $err = { Connect-McpServer -ConfigPath $configPath -Name nope } | Should -Throw -PassThru
        $err.FullyQualifiedErrorId | Should -BeLike 'McpConfigServerNotFound*'
    }

    It 'errors when the file has no mcpServers object' {
        $badPath = Join-Path $TestDrive 'bad.json'
        '{ "servers": {} }' | Set-Content -Path $badPath
        $err = { Connect-McpServer -ConfigPath $badPath } | Should -Throw -PassThru
        $err.FullyQualifiedErrorId | Should -BeLike 'McpConfigInvalid*'
    }
}

Describe 'Disconnect-McpServer' {
    AfterEach { Disconnect-McpServer -All -ErrorAction SilentlyContinue }

    It 'kills the server process and removes the session' {
        Connect-Stub -Name gone
        $serverPid = (Get-McpServer -Server gone).ProcessId
        Disconnect-McpServer -Server gone
        Get-Process -Id $serverPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-McpServer | Should -BeNullOrEmpty
    }

    It 'accepts pipeline input from Get-McpServer' {
        Connect-Stub -Name p1
        Connect-Stub -Name p2
        Get-McpServer | Disconnect-McpServer
        Get-McpServer | Should -BeNullOrEmpty
    }

    It 'disconnects everything with -All' {
        Connect-Stub -Name a1
        Connect-Stub -Name a2
        Disconnect-McpServer -All
        Get-McpServer | Should -BeNullOrEmpty
    }

    It 'errors for unknown sessions' {
        $err = { Disconnect-McpServer -Server ghost -ErrorAction Stop } | Should -Throw -PassThru
        $err.FullyQualifiedErrorId | Should -BeLike 'McpSessionNotFound*'
    }
}

Describe 'Session failure handling' {
    AfterEach { Disconnect-McpServer -All -ErrorAction SilentlyContinue }

    It 'throws McpProcessExited with the stderr tail when the server dies mid-request' {
        Connect-Stub -Name crash
        $err = { Invoke-McpTool -Server crash -Name crash } | Should -Throw -PassThru
        $err.FullyQualifiedErrorId | Should -BeLike 'McpProcessExited*'
        $err.Exception.Message | Should -Match 'crashing on request'
        (Get-McpServer -Server crash).Connected | Should -BeFalse
    }

    It 'throws McpProcessExited for calls on a dead session' {
        Connect-Stub -Name dead
        { Invoke-McpTool -Server dead -Name crash } | Should -Throw
        $err = { Invoke-McpTool -Server dead -Name plain } | Should -Throw -PassThru
        $err.FullyQualifiedErrorId | Should -BeLike 'McpProcessExited*'
    }

    It 'times out slow requests and discards the late response' {
        Connect-Stub -Name slow
        $err = { Invoke-McpTool -Server slow -Name sleep -Arguments @{ seconds = 3 } -TimeoutSec 1 } | Should -Throw -PassThru
        $err.FullyQualifiedErrorId | Should -BeLike 'McpRequestTimeout*'
        Start-Sleep -Seconds 3
        Invoke-McpTool -Server slow -Name plain -WarningVariable warnings | Should -Be 'hello world'
        $warnings | Should -BeNullOrEmpty
    }

    It 'errors for unknown session names' {
        $err = { Get-McpTool -Server ghost } | Should -Throw -PassThru
        $err.FullyQualifiedErrorId | Should -BeLike 'McpSessionNotFound*'
    }
}

Describe 'Internal request/session helpers' {
    It 'caps timed-out request id retention' {
        InModuleScope PSMcpClient {
            $session = [pscustomobject]@{
                IgnoredIds = [System.Collections.Generic.List[string]]::new()
            }

            1..300 | ForEach-Object { Add-IgnoredMcpRequestId -Session $session -Id "$_" }

            $session.IgnoredIds.Count | Should -Be 256
            $session.IgnoredIds[0] | Should -Be '45'
            $session.IgnoredIds[255] | Should -Be '300'
        }
    }

    It 'quotes cmd arguments so cmd.exe, %VAR% expansion and the CRT argv parser all see them literally' {
        InModuleScope PSMcpClient {
            ConvertTo-CmdArgument 'abc'         | Should -BeExactly '"abc"'
            ConvertTo-CmdArgument 'has space'   | Should -BeExactly '"has space"'
            ConvertTo-CmdArgument ''            | Should -BeExactly '""'
            ConvertTo-CmdArgument 'x"y'         | Should -BeExactly '"x""y"'
            ConvertTo-CmdArgument '100%'        | Should -BeExactly '"100%%cd:~,%"'
            ConvertTo-CmdArgument '%PATH%'      | Should -BeExactly '"%%cd:~,%PATH%%cd:~,%"'
            ConvertTo-CmdArgument 'trailing\'   | Should -BeExactly '"trailing\\"'
            ConvertTo-CmdArgument 'back\"slash' | Should -BeExactly '"back\\""slash"'
            ConvertTo-CmdArgument 'a&b|c'       | Should -BeExactly '"a&b|c"'
            # ! is neutralised by /v:off on the cmd.exe launch, not by escaping
            ConvertTo-CmdArgument '!PATH!'      | Should -BeExactly '"!PATH!"'
        }
    }

    It 'launches .cmd shims through cmd.exe with delayed expansion off and command extensions on' -Skip:(-not $IsWindows) {
        $shim = (Resolve-Path (Join-Path $PSScriptRoot 'Stub' 'echo-args.cmd')).ProviderPath
        InModuleScope PSMcpClient -Parameters @{ Shim = $shim } {
            param($Shim)
            $spec = Resolve-McpLaunchSpec -Command $Shim -Arguments @('a b', '100%')
            $spec.FileName | Should -BeLike '*\cmd.exe'
            $spec.RawArguments | Should -BeExactly ('/d /e:on /v:off /s /c ""' + $Shim + '" "a b" "100%%cd:~,%""')
        }
    }

    It 'rejects cmd arguments containing a carriage return, line feed or NUL' {
        InModuleScope PSMcpClient {
            foreach ($bad in "a`nb", "a`rb", "a`r`nb", "a`0b") {
                $err = { ConvertTo-CmdArgument $bad } | Should -Throw -PassThru
                $err.FullyQualifiedErrorId | Should -BeLike 'McpUnsafeCmdArgument*'
            }
        }
    }

    It 'refuses to launch a .cmd shim with a multiline argument instead of handing it to cmd.exe' -Skip:(-not $IsWindows) {
        $shim = (Resolve-Path (Join-Path $PSScriptRoot 'Stub' 'echo-args.cmd')).ProviderPath
        InModuleScope PSMcpClient -Parameters @{ Shim = $shim } {
            param($Shim)
            $err = { Resolve-McpLaunchSpec -Command $Shim -Arguments @('ok', "first line`necho injected") } | Should -Throw -PassThru
            $err.FullyQualifiedErrorId | Should -BeLike 'McpUnsafeCmdArgument*'
            $err.Exception.Message | Should -BeLike '*first line\necho injected*'
        }
    }
}

Describe 'Windows .cmd shim argument round trip' -Skip:(-not $IsWindows) {
    It 'delivers every argument verbatim through cmd.exe and the shim''s %* forwarding' {
        # Modelled on npx.cmd -> node.exe. Includes the BatBadBut injection shapes, %VAR% and !VAR! expansion probes,
        # the escape trick itself as input, CRT backslash/quote edge cases, an empty argument and non-ASCII text.
        $values = @(
            '', 'abc', 'has space', '-y', '--flag=value with "quotes" and %percent% and !bang!'
            'x"y', '"', 'a"b"c', '\', 'trailing\', 'C:\dir with space\', 'back\"slash', '\\"'
            '100%', '%', '%%', '%PATH%', '%cd%', '%~dp0', '%*', '%1', '%%cd:~,%'
            '!PATH!', '!', '^!', 'a!b!c'
            'a&b', 'a&&b', 'a|b', 'a<b>c', 'a^b', '(x)', ')', '&calc', '/c calc', 'a b & calc & c'
            'héllo wörld', '日本語', "tab`tsep", 'semi;colon,comma=eq', '~x', '@echo off'
        )
        $pwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $shim = (Resolve-Path (Join-Path $PSScriptRoot 'Stub' 'echo-args.cmd')).ProviderPath

        $received = InModuleScope PSMcpClient -Parameters @{ Shim = $shim; Values = $values; Pwsh = $pwsh } {
            param($Shim, $Values, $Pwsh)
            $launch = Start-McpProcess -Command $Shim -Arguments $Values -Environment @{ PSMCP_ECHO_PWSH = $Pwsh }
            $shimPid = $launch.Process.Id
            $streamsClosed = $false
            try {
                # Read asynchronously and bound every wait: if a quoting regression leaves the shim running, or cmd.exe
                # exits while a descendant still holds a redirected pipe, the test fails instead of hanging the suite.
                # Neither stream task's Result is touched until both bounded waits have succeeded.
                $stdoutTask = $launch.StdOut.ReadToEndAsync()
                if (-not $launch.Process.WaitForExit(30000)) {
                    throw 'echo-args.cmd did not exit within 30 seconds'
                }
                $streams = [System.Threading.Tasks.Task[]]@($stdoutTask, $launch.StderrTask)
                if (-not [System.Threading.Tasks.Task]::WaitAll($streams, 5000)) {
                    throw 'echo-args.cmd exited but its stdout or stderr pipe is still held open by a descendant process'
                }
                $streamsClosed = $true
                $launch.Process.ExitCode | Should -Be 0 -Because $launch.StderrTask.Result
                , @($stdoutTask.Result | ConvertFrom-Json)
            }
            finally {
                if (-not $launch.Process.HasExited) { try { $launch.Process.Kill($true) } catch { } }
                if (-not $streamsClosed) {
                    # cmd.exe may already be gone while the pwsh it spawned still holds a pipe. Process.Kill(true) cannot
                    # reach descendants of an exited process, but they keep the dead shim's PID as ParentProcessId, so
                    # walk that relationship and stop whatever is left.
                    $stopDescendants = {
                        param($ParentId)
                        Get-CimInstance Win32_Process -Filter "ParentProcessId = $ParentId" -ErrorAction SilentlyContinue | ForEach-Object {
                            & $stopDescendants $_.ProcessId
                            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { }
                        }
                    }
                    & $stopDescendants $shimPid
                }
                $launch.Process.Dispose()
            }
        }

        $received.Count | Should -Be $values.Count
        for ($i = 0; $i -lt $values.Count; $i++) {
            $received[$i] | Should -BeExactly $values[$i] -Because "argument $i must reach the executable untouched"
        }
    }
}
