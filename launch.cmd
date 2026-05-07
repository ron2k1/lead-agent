@echo off
REM lead-agent standalone launcher (double-click target)
REM Forwards to launch.ps1 via PowerShell (5.1 or 7+; whichever the box has).
REM
REM Standalone path means CallerCwd defaults to %CD% at double-click time and
REM CallerSessionId is unset (runner derives one when the lead writes its
REM first JSONL).
REM
REM Args: optional [subdir-hint] is forwarded as -SubdirHint.

setlocal
set "PS=powershell.exe"
where pwsh.exe >nul 2>&1 && set "PS=pwsh.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" ^
  -CallerCwd "%CD%" ^
  -SubdirHint "%~1" ^
  -Standalone
exit /b %ERRORLEVEL%
