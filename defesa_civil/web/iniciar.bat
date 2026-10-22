@echo off
chcp 65001 >nul
REM Painel web da APS (Node.js): instala as dependencias na 1a vez e abre o navegador
cd /d "%~dp0"
where node >nul 2>nul || (echo Node.js nao encontrado. Instale a versao LTS em https://nodejs.org e rode de novo. & pause & exit /b)
if not exist node_modules (
  echo Instalando dependencias, so na primeira vez...
  call npm install --omit=dev
)
if not exist config.json copy config.exemplo.json config.json >nul
start "" http://127.0.0.1:8080
node servidor.js
pause
