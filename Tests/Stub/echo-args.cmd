:: Test shim modelled on npm's npx.cmd: forwards %* to a real executable, which is where cmd.exe parsing bites.
@ECHO OFF
SETLOCAL
"%PSMCP_ECHO_PWSH%" -NoProfile -NonInteractive -File "%~dp0echo-args.ps1" %*
