function ConvertTo-CmdArgument {
    param([string]$Value)

    $escaped = [string]$Value
    $escaped = $escaped -replace '"', '""'
    $escaped = $escaped -replace '%', '%%'
    $escaped = $escaped -replace '!', '^!'
    '"' + $escaped + '"'
}

function Resolve-McpLaunchSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @()
    )

    $path = $null
    if (Test-Path -LiteralPath $Command -PathType Leaf) {
        $path = (Resolve-Path -LiteralPath $Command).ProviderPath
    }
    else {
        $apps = @(Get-Command -Name $Command -CommandType Application -ErrorAction SilentlyContinue)
        if ($IsWindows) {
            # pwsh resolves 'npx' to npx.ps1 first; the .cmd shim is what actually runs via CreateProcess
            $preferred = $apps | Where-Object { [IO.Path]::GetExtension($_.Source) -in '.exe', '.com' } | Select-Object -First 1
            if (-not $preferred) { $preferred = $apps | Where-Object { [IO.Path]::GetExtension($_.Source) -in '.cmd', '.bat' } | Select-Object -First 1 }
            if (-not $preferred) { $preferred = $apps | Select-Object -First 1 }
        }
        else {
            $preferred = $apps | Select-Object -First 1
        }

        if ($preferred) {
            $path = $preferred.Source
        }
        else {
            $any = Get-Command -Name $Command -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($any -and $any.CommandType -in 'ExternalScript', 'Application') {
                $path = $any.Source
            }
        }
    }

    if (-not $path) {
        throw (New-McpError -ErrorId 'McpCommandNotFound' -Category ObjectNotFound -TargetObject $Command `
            -Message "Command '$Command' could not be resolved. Ensure it is on PATH or supply a full path.")
    }

    $extension = [IO.Path]::GetExtension($path).ToLowerInvariant()

    if ($extension -eq '.ps1') {
        $pwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        return @{ FileName = $pwsh; ArgumentList = @('-NoProfile', '-NonInteractive', '-File', $path) + $Arguments }
    }

    if ($IsWindows -and $extension -in '.cmd', '.bat') {
        # /s makes cmd strip only the outer quotes, so a quoted path plus quoted args survives intact
        $parts = @($path) + $Arguments | ForEach-Object { ConvertTo-CmdArgument $_ }
        return @{ FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'; RawArguments = '/d /s /c "' + ($parts -join ' ') + '"' }
    }

    @{ FileName = $path; ArgumentList = $Arguments }
}

function Start-McpProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @(),
        [System.Collections.IDictionary]$Environment,
        [string]$WorkingDirectory
    )

    $launch = Resolve-McpLaunchSpec -Command $Command -Arguments $Arguments

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $launch.FileName
    if ($launch.RawArguments) {
        $psi.Arguments = $launch.RawArguments
    }
    else {
        foreach ($argument in $launch.ArgumentList) { $psi.ArgumentList.Add([string]$argument) }
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardInputEncoding = $utf8
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8

    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    if ($Environment) {
        foreach ($key in $Environment.Keys) {
            $psi.Environment[[string]$key] = [string]$Environment[$key]
        }
    }

    $display = if ($launch.RawArguments) { "$($psi.FileName) $($launch.RawArguments)" } else { "$($psi.FileName) $($launch.ArgumentList -join ' ')" }
    Write-Verbose "Starting MCP server process: $display"

    $process = [System.Diagnostics.Process]::Start($psi)
    if (-not $process) {
        throw (New-McpError -ErrorId 'McpProcessStartFailed' -Category ResourceUnavailable -TargetObject $Command `
            -Message "Failed to start MCP server process: $display")
    }
    $process.StandardInput.AutoFlush = $true

    [pscustomobject]@{
        Process    = $process
        StdIn      = $process.StandardInput
        StdOut     = $process.StandardOutput
        StderrTask = $process.StandardError.ReadToEndAsync()
    }
}
