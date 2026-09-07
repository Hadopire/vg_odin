@echo off
setlocal

cd /d "%~dp0"

cl /nologo /c /EHsc /MT /O2 /std:c++17 D3D12MemAlloc.cpp d3d12ma_c.cpp || exit /b 1
lib /nologo /OUT:d3d12ma.lib D3D12MemAlloc.obj d3d12ma_c.obj || exit /b 1
del D3D12MemAlloc.obj d3d12ma_c.obj