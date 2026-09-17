# Companion to echo-args.cmd: prints the arguments it received as a JSON array so tests can check what survived cmd.exe.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$args | ConvertTo-Json -Compress -AsArray
