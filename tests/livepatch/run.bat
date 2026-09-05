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

rem A same-length string-literal edit ("aaaa" -> "bbbb") must still flip the proc's
rem content hash so the reload re-patches it. Regression test for the constant-identity
rem fix in lb_livepatch_proc_content_hash.
echo === same-length string-literal edit is detected ===
mkdir "%HERE%build\strlit"
copy /y "%HERE%strlit_v1\main.odin" "%HERE%build\strlit\" >nul
"%ODIN%" build "%HERE%build\strlit" -livepatch -debug "-out:%HERE%build\strlit\t.exe" || exit /b
copy /y "%HERE%strlit_v2\main.odin" "%HERE%build\strlit\" >nul
"%HERE%build\strlit\t.exe" "%ODIN%" || exit /b

rem A proc signature change must NOT be rejected (Live++ parity; the F8 ABI guard was removed).
rem v2 changes add(x: int) -> add(x, y: int) and updates its caller; both re-patch in one reload,
rem so compute() reaches add's new body through the new ABI and returns 16.
echo === signature change reloads ===
mkdir "%HERE%build\sig"
copy /y "%HERE%sig_v1\main.odin" "%HERE%build\sig\" >nul
"%ODIN%" build "%HERE%build\sig" -livepatch -debug "-out:%HERE%build\sig\t.exe" || exit /b
copy /y "%HERE%sig_v2\main.odin" "%HERE%build\sig\" >nul
"%HERE%build\sig\t.exe" "%ODIN%" || exit /b

echo SUCCESSFUL
