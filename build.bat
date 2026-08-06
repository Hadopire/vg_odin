@echo off
setlocal

cd /d "%~dp0"

set MODE=%1
if "%MODE%"=="" set MODE=debug

if /I "%MODE%"=="debug" (
    set OUT_DIR=bin\debug
    set FLAGS=-debug
) else if /I "%MODE%"=="release" (
    set OUT_DIR=bin\release
    set FLAGS=-o:speed -debug
) else (
    echo Usage: build.bat [debug^|release]
    exit /b 1
)

if not exist %OUT_DIR% mkdir %OUT_DIR%

odin build src -out:%OUT_DIR%\vg_odin.exe %FLAGS%
