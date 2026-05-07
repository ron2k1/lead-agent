@echo off
REM lead-agent standalone launcher (double-click target)
REM Forwards to launch.ps1 via PowerShell (5.1 or 7+; whichever the box has).
REM
REM Standalone path means CallerCwd defaults to %CD% at double-click time and
REM CallerSessionId is unset (runner derives one when the lead writes its
REM first JSONL).
REM
REM Args (any order, all optional):
REM   [subdir-hint]   forwarded as -SubdirHint
REM   -Force          forwarded as -Force (reclaims orphaned lockfile via
REM                   F-01 PID + Win32_Process.CreationDate stale-detection)
REM
REM Examples:
REM   launch.cmd                          ADVISOR, no subdir, no force
REM   launch.cmd src                      ADVISOR, subdir-hint=src
REM   launch.cmd -Force                   reclaim orphaned lock, no subdir
REM   launch.cmd src -Force               reclaim + subdir-hint=src
REM   launch.cmd -Force src               reclaim + subdir-hint=src (order ok)

setlocal
set "PS=powershell.exe"
where pwsh.exe >nul 2>&1 && set "PS=pwsh.exe"

set "SUBDIR="
set "FORCE="

:parse
if "%~1"=="" goto run
if /I "%~1"=="-Force" (set "FORCE=-Force" & shift & goto parse)
set "SUBDIR=%~1"
shift
goto parse

:run
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" ^
  -CallerCwd "%CD%" ^
  -SubdirHint "%SUBDIR%" ^
  %FORCE% ^
  -Standalone
exit /b %ERRORLEVEL%
