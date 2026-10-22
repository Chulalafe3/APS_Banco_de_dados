-- =====================================================================
-- APS - rodar_tudo.sql
-- Recria o banco do zero e roda os scripts 01 a 05, na ordem.
--
-- Como usar (pgAdmin): botão direito no banco aps_defesa_civil ->
-- PSQL Tool -> digite (com o caminho da sua pasta, barras normais):
--   \i 'C:/caminho/APS_Banco_de_dados/defesa_civil/rodar_tudo.sql'
--
-- ATENÇÃO: apaga TUDO o que existe no schema public deste banco.
-- Tempo: ~2 minutos (a carga simula 6 meses de dados).
-- =====================================================================
\encoding UTF8
\set ON_ERROR_STOP on
SET client_min_messages TO WARNING;

DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;

\echo '>> 01 - estrutura'
\ir 01_estrutura.sql
\echo '>> 02 - regras'
\ir 02_regras.sql
\echo '>> 03 - simulador'
\ir 03_simulador.sql
\echo '>> 04 - carga inicial (aguarde ~2 min)'
\ir 04_carga_inicial.sql
\echo '>> 05 - consultas'
\ir 05_consultas.sql
\echo '>> Pronto. Banco carregado.'
