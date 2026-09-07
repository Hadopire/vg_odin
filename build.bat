@echo off
setlocal

cd /d "%~dp0"

set MODE=%1
if "%MODE%"=="" set MODE=debug

if /I "%MODE%"=="debug" (
    set OUT_DIR=bin\debug
    set FLAGS=-debug
    set SLANG_FLAGS=-O0 -g
) else if /I "%MODE%"=="release" (
    set OUT_DIR=bin\release
    set FLAGS=-o:speed -debug
    set SLANG_FLAGS=-O3
) else (
    echo Usage: build.bat [debug^|release]
    exit /b 1
)

if not exist %OUT_DIR% mkdir %OUT_DIR%
if not exist %OUT_DIR%\shaders mkdir %OUT_DIR%\shaders
if not exist %OUT_DIR%\D3D12 mkdir %OUT_DIR%\D3D12

copy /y vendor\d3d12\*.dll %OUT_DIR%\D3D12\ >nul || exit /b 1
copy /y vendor\d3d12\*.pdb %OUT_DIR%\D3D12\ >nul || exit /b 1

for %%f in (src\shaders\*.slang) do (
    vendor\slang\slangc.exe %%f -target dxil -profile sm_6_6 -entry vs_main -stage vertex %SLANG_FLAGS% -o %OUT_DIR%\shaders\%%~nf.vs.dxil || exit /b 1
    vendor\slang\slangc.exe %%f -target dxil -profile sm_6_6 -entry fs_main -stage fragment %SLANG_FLAGS% -o %OUT_DIR%\shaders\%%~nf.fs.dxil || exit /b 1
)

odin build src -out:%OUT_DIR%\vg_odin.exe %FLAGS%
