@echo off
rem Lets PowerShell and cmd find ./mirai: runs the bash launcher with Git Bash. The path goes with
rem forward slashes because the launcher finds the engine root from the slashes of $0.
setlocal
rem Git for Windows is found by its git, as tools/mirai finds it: git --exec-path names
rem <root>\mingw64\libexec\git-core, and its bash is <root>\bin\bash.exe.
set "bash="
for /f "delims=" %%i in ('git --exec-path 2^>nul') do set "bash=%%~fi\..\..\..\bin\bash.exe"
if not defined bash goto missing
if not exist "%bash%" goto missing

:run
set "launcher=%~dp0mirai"
"%bash%" "%launcher:\=/%" %*
exit /b %errorlevel%

:missing
echo mirai: Git Bash is missing; install Git for Windows with git on the PATH, or run ./mirai from bash 1>&2
exit /b 1
