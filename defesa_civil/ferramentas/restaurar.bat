@echo off
chcp 65001 >nul
setlocal
REM =====================================================================
REM Restaura uma copia de seguranca (.dump) num banco NOVO, sem mexer
REM no banco atual. Depois confira e aponte o web\config.json para ele.
REM =====================================================================
set "PGBIN="
for /d %%v in ("C:\Program Files\PostgreSQL\*") do if exist "%%v\bin\pg_restore.exe" set "PGBIN=%%v\bin"
if "%PGBIN%"=="" (echo PostgreSQL nao encontrado em C:\Program Files\PostgreSQL & pause & exit /b)
echo Usando %PGBIN%
echo.
set /p ARQ=Arraste aqui o arquivo .dump e tecle Enter: 
set ARQ=%ARQ:"=%
if not exist "%ARQ%" (echo Arquivo nao encontrado. & pause & exit /b)
set BANCO=aps_defesa_civil_restaurado
set /p BANCO=Nome do banco novo [aps_defesa_civil_restaurado]: 
echo.
echo 1/3 Criando o banco %BANCO% ...
"%PGBIN%\createdb.exe" -U postgres -h localhost "%BANCO%" || (echo Nao foi possivel criar o banco. Ele ja existe? & pause & exit /b)
echo 2/3 Restaurando a copia...
"%PGBIN%\pg_restore.exe" -U postgres -h localhost -d "%BANCO%" --no-owner --exit-on-error "%ARQ%" || (echo Falha na restauracao. & pause & exit /b)
echo 3/3 Recriando papeis e permissoes (07_seguranca.sql)...
"%PGBIN%\psql.exe" -U postgres -h localhost -d "%BANCO%" -q -v ON_ERROR_STOP=1 -f "%~dp0..\07_seguranca.sql"
echo.
echo Pronto. Contagens no banco restaurado:
"%PGBIN%\psql.exe" -U postgres -h localhost -d "%BANCO%" -c "SELECT (SELECT count(*) FROM leitura) AS leituras_recentes, (SELECT count(*) FROM leitura_arquivo) AS arquivadas, (SELECT count(*) FROM evento) AS eventos, (SELECT count(*) FROM auditoria) AS auditoria;"
echo Para usar: mude "nome" em web\config.json para %BANCO% e reinicie o painel.
pause
