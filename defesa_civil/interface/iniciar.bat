@echo off
REM Painel web da APS - instala as dependencias (na 1a vez) e abre o painel no navegador
cd /d "%~dp0"
set PY=python
where python >nul 2>nul || set PY=py
%PY% --version >nul 2>nul || (echo Python nao encontrado. Instale em https://www.python.org/downloads/ marcando "Add python.exe to PATH". & pause & exit /b)
echo Instalando/verificando dependencias...
%PY% -m pip install --quiet -r requirements.txt
echo Abrindo o painel em http://localhost:8501 ...
%PY% -m streamlit run app.py
pause
