@echo off
rem Livepatch reload tests. Windows/x64 only -- `-livepatch` is rejected elsewhere.
rem
rem Builds a host from v1, swaps in v2 (which calls procedures v1 never referenced), and lets the
rem running process patch itself. The preload case proves those procedures became reachable; the
rem -livepatch-no-preload case proves preloading is what did it.

setlocal
set HERE=%~dp0
set ODIN=%HERE%..\..\odin.exe

if exist "%HERE%build" rmdir /s /q "%HERE%build"

echo === preload (default) ===
mkdir "%HERE%build\lp\dep"
copy /y "%HERE%dep\dep.odin" "%HERE%build\lp\dep\" >nul
copy /y "%HERE%v1\main.odin" "%HERE%build\lp\" >nul
"%ODIN%" build "%HERE%build\lp" -livepatch -debug "-out:%HERE%build\lp\t.exe" || exit /b
copy /y "%HERE%v2\main.odin" "%HERE%build\lp\" >nul
"%HERE%build\lp\t.exe" "%ODIN%" || exit /b

echo === no preload (the same patch must fail to resolve) ===
mkdir "%HERE%build\lean\dep"
copy /y "%HERE%dep\dep.odin" "%HERE%build\lean\dep\" >nul
copy /y "%HERE%v1\main.odin" "%HERE%build\lean\" >nul
"%ODIN%" build "%HERE%build\lean" -livepatch -livepatch-no-preload -debug "-out:%HERE%build\lean\t.exe" || exit /b
copy /y "%HERE%v2\main.odin" "%HERE%build\lean\" >nul
"%HERE%build\lean\t.exe" "%ODIN%" --expect-fail || exit /b

rem raylib.lib's members are coarse enough that referencing anything drags most of it into the
rem image either way, so the reload above cannot discriminate on /WHOLEARCHIVE. Check the flag.
echo === /WHOLEARCHIVE for non-system foreign libraries ===
"%ODIN%" build "%HERE%build\lp" -livepatch -debug "-out:%HERE%build\probe1.exe" -show-system-calls 2>&1 | findstr /c:"/WHOLEARCHIVE:" >nul || exit /b
"%ODIN%" build "%HERE%build\lean" -livepatch -livepatch-no-preload -debug "-out:%HERE%build\probe2.exe" -show-system-calls 2>&1 | findstr /c:"/WHOLEARCHIVE:" >nul && exit /b 1

echo SUCCESSFUL
