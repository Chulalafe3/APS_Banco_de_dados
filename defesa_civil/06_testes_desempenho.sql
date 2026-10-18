-- =====================================================================
-- APS - 06_testes_desempenho.sql
-- Testes de desempenho de escrita e consulta.
-- Metodologia adaptada de Grzesik e Mrozek (2020):
--   * escrita: inserção um a um x em lotes de 10 pontos
--   * consulta: agregações típicas repetidas N vezes
-- Cenários de otimização (mesma massa de dados, ~6 meses):
--   A) tabela comum, sem índice
--   B) + índice composto (estação, data_hora)
--   C) + particionamento mensal
--   D) + view materializada (resumo por hora)
--
-- Rodar com psql (usa variáveis do psql):
--   psql -d aps_defesa_civil -f 06_testes_desempenho.sql
-- No pgAdmin, use a ferramenta "PSQL Tool" (não a Query Tool).
-- Tempo esperado: ~5 a 10 minutos.
-- =====================================================================
SET TIME ZONE 'America/Sao_Paulo';
\set reps 500
\set reps_escrita 20

-- ---------------------------------------------------------------------
-- 0. Tabela de resultados e procedimentos de medição
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS bench_resultado;
CREATE TABLE bench_resultado (
    id           BIGSERIAL     PRIMARY KEY,
    experimento  VARCHAR(50)   NOT NULL,
    cenario      VARCHAR(30)   NOT NULL,
    repeticao    INTEGER       NOT NULL,
    registros    INTEGER,
    duracao_ms   NUMERIC(12,3) NOT NULL
);

-- Executa uma consulta N vezes e grava o tempo de cada execução
CREATE OR REPLACE PROCEDURE sp_bench_consulta(
    p_experimento VARCHAR, p_cenario VARCHAR, p_sql TEXT, p_reps INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    r      INTEGER;
    v_ini  TIMESTAMPTZ;
    v_lin  RECORD;
BEGIN
    FOR r IN 1..p_reps LOOP
        v_ini := clock_timestamp();
        FOR v_lin IN EXECUTE p_sql LOOP NULL; END LOOP;      -- lê todo o resultado
        INSERT INTO bench_resultado (experimento, cenario, repeticao, duracao_ms)
        VALUES (p_experimento, p_cenario, r,
                EXTRACT(EPOCH FROM clock_timestamp() - v_ini) * 1000);
    END LOOP;
    COMMIT;
END;
$$;

-- Escrita pelo caminho real (fn_receber_lote, com todas as triggers ativas)
-- p_modo: 'UNITARIO' (1 leitura por envio) ou 'LOTE' (10 leituras por envio)
CREATE OR REPLACE PROCEDURE sp_bench_escrita(
    p_modo VARCHAR, p_id_dispositivo INTEGER, p_pontos INTEGER, p_reps INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_base   TIMESTAMPTZ := date_trunc('month', now()) + INTERVAL '2 months';
    v_tam    INTEGER := CASE p_modo WHEN 'UNITARIO' THEN 1 ELSE 10 END;
    v_lote   JSONB;
    v_ini    TIMESTAMPTZ;
    r        INTEGER;
    i        INTEGER;
BEGIN
    FOR r IN 1..p_reps LOOP
        DELETE FROM evento  WHERE id_dispositivo = p_id_dispositivo;
        DELETE FROM leitura WHERE id_dispositivo = p_id_dispositivo;
        UPDATE dispositivo SET ultima_comunicacao = NULL, status = 'OPERACIONAL'
         WHERE id_dispositivo = p_id_dispositivo;
        COMMIT;

        v_ini := clock_timestamp();
        i := 0;
        WHILE i < p_pontos LOOP
            SELECT jsonb_agg(jsonb_build_object(
                       'data_hora',        v_base + make_interval(mins => i + g),
                       'temperatura_ar',   ROUND((20 + random() * 10)::NUMERIC, 2),
                       'umidade_ar',       ROUND((50 + random() * 40)::NUMERIC, 2),
                       'chuva',            ROUND((random() * 0.2)::NUMERIC, 2),
                       'direcao_vento',    ROUND((random() * 360)::NUMERIC, 1),
                       'velocidade_vento', ROUND((random() * 8)::NUMERIC, 2),
                       'radiacao_solar',   ROUND((random() * 1000)::NUMERIC, 2))
                     ORDER BY g)
              INTO v_lote
              FROM generate_series(0, v_tam - 1) AS g;

            PERFORM fn_receber_lote(p_id_dispositivo, v_lote,
                                    v_base + make_interval(mins => i + v_tam));
            COMMIT;                                   -- cada envio é uma transação
            i := i + v_tam;
        END LOOP;

        INSERT INTO bench_resultado (experimento, cenario, repeticao, registros, duracao_ms)
        VALUES ('ESCRITA_' || p_modo, 'leitura (real)', r, p_pontos,
                EXTRACT(EPOCH FROM clock_timestamp() - v_ini) * 1000);
        COMMIT;
    END LOOP;

    DELETE FROM evento  WHERE id_dispositivo = p_id_dispositivo;
    DELETE FROM leitura WHERE id_dispositivo = p_id_dispositivo;
    COMMIT;
END;
$$;

-- ---------------------------------------------------------------------
-- 1. TESTE DE ESCRITA
--    Usa um dispositivo de bancada, removido no fim do teste
-- ---------------------------------------------------------------------
-- garante a partição do mês usado na bancada (2 meses à frente)
CALL sp_criar_particoes((date_trunc('month', now()) + INTERVAL '2 months')::DATE, 1);

INSERT INTO dispositivo (id_cliente, nome, ativo)
VALUES (1, 'Bancada de testes', TRUE)
RETURNING id_dispositivo AS id_bancada \gset

INSERT INTO sensor (id_dispositivo, parametro, unidade, limite_min, limite_max)
SELECT :id_bancada, parametro, unidade, limite_min, limite_max
  FROM sensor WHERE id_dispositivo = 1;

INSERT INTO regra_alarme (id_dispositivo, parametro, condicao, limite, nivel, nota)
SELECT :id_bancada, parametro, condicao, limite, nivel, nota
  FROM regra_alarme WHERE id_dispositivo = 1;

CALL sp_bench_escrita('UNITARIO', :id_bancada, 1000, :reps_escrita);
CALL sp_bench_escrita('LOTE',     :id_bancada, 1000, :reps_escrita);

DELETE FROM regra_alarme WHERE id_dispositivo = :id_bancada;
DELETE FROM sensor       WHERE id_dispositivo = :id_bancada;
DELETE FROM dispositivo  WHERE id_dispositivo = :id_bancada;

-- ---------------------------------------------------------------------
-- 2. CENÁRIOS DE CONSULTA (cópias da massa completa: recentes + arquivo)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS bench_a_sem_indice, bench_b_indice, bench_c_particionada CASCADE;
DROP MATERIALIZED VIEW IF EXISTS bench_d_mv_horaria;

-- A) tabela comum, sem nenhum índice
CREATE TABLE bench_a_sem_indice AS
SELECT * FROM leitura UNION ALL SELECT * FROM leitura_arquivo
 ORDER BY data_hora, id_dispositivo;

-- B) mesma tabela + índice composto
CREATE TABLE bench_b_indice AS SELECT * FROM bench_a_sem_indice;
CREATE INDEX ON bench_b_indice (id_dispositivo, data_hora);

-- C) particionada por mês + índice composto
CREATE TABLE bench_c_particionada (LIKE bench_a_sem_indice) PARTITION BY RANGE (data_hora);
DO $$
DECLARE
    v_mes DATE;
BEGIN
    FOR v_mes IN
        SELECT DISTINCT date_trunc('month', data_hora AT TIME ZONE 'America/Sao_Paulo')::DATE
          FROM bench_a_sem_indice ORDER BY 1
    LOOP
        EXECUTE format('CREATE TABLE %I PARTITION OF bench_c_particionada FOR VALUES FROM (%L) TO (%L)',
                       'bench_c_' || to_char(v_mes, 'YYYYMM'),
                       v_mes::TIMESTAMP AT TIME ZONE 'America/Sao_Paulo',
                       (v_mes + INTERVAL '1 month')::TIMESTAMP AT TIME ZONE 'America/Sao_Paulo');
    END LOOP;
END $$;
INSERT INTO bench_c_particionada SELECT * FROM bench_a_sem_indice;
CREATE INDEX ON bench_c_particionada (id_dispositivo, data_hora);

-- D) view materializada por hora (sobre a particionada)
CREATE MATERIALIZED VIEW bench_d_mv_horaria AS
SELECT id_dispositivo,
       date_trunc('hour', data_hora) AS hora,
       AVG(temperatura_ar)           AS temp_media,
       MIN(temperatura_ar)           AS temp_min,
       MAX(temperatura_ar)           AS temp_max,
       MAX(velocidade_vento)         AS vento_max
  FROM bench_c_particionada
 GROUP BY 1, 2;
CREATE INDEX ON bench_d_mv_horaria (hora);

VACUUM ANALYZE bench_a_sem_indice;
VACUUM ANALYZE bench_b_indice;
VACUUM ANALYZE bench_c_particionada;
VACUUM ANALYZE bench_d_mv_horaria;

-- Tamanho de cada cenário (tabela + índices)
SELECT 'A sem índice' AS cenario, pg_size_pretty(pg_total_relation_size('bench_a_sem_indice')) AS tamanho
UNION ALL SELECT 'B índice', pg_size_pretty(pg_total_relation_size('bench_b_indice'))
UNION ALL SELECT 'D view materializada', pg_size_pretty(pg_total_relation_size('bench_d_mv_horaria'));

-- Períodos de teste: último dia completo, últimos 7 e 30 dias completos
SELECT date_trunc('day', MAX(data_hora))                         AS fim,
       date_trunc('day', MAX(data_hora)) - INTERVAL '1 day'      AS ini1,
       date_trunc('day', MAX(data_hora)) - INTERVAL '7 days'     AS ini7,
       date_trunc('day', MAX(data_hora)) - INTERVAL '30 days'    AS ini30,
       COUNT(*)                                                  AS total_linhas
  FROM bench_a_sem_indice \gset

\echo 'Massa de teste:' :total_linhas 'linhas | período 7 dias:' :ini7 'a' :fim

-- ---------------------------------------------------------------------
-- 3. EXPLAIN ANALYZE (para as figuras do relatório)
-- ---------------------------------------------------------------------
\echo '===== Q1 - Estação Centro, 1 dia, vento máximo ====='
\echo '--- A) sem índice'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT MAX(velocidade_vento) FROM bench_a_sem_indice
 WHERE id_dispositivo = 1 AND data_hora >= :'ini1' AND data_hora < :'fim';
\echo '--- B) índice composto'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT MAX(velocidade_vento) FROM bench_b_indice
 WHERE id_dispositivo = 1 AND data_hora >= :'ini1' AND data_hora < :'fim';

\echo '===== Q2 - Temperatura média de 7 dias por estação ====='
\echo '--- A) sem índice'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id_dispositivo, AVG(temperatura_ar) FROM bench_a_sem_indice
 WHERE data_hora >= :'ini7' AND data_hora < :'fim' GROUP BY id_dispositivo;
\echo '--- B) índice composto (não ajuda: a consulta não filtra a estação)'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id_dispositivo, AVG(temperatura_ar) FROM bench_b_indice
 WHERE data_hora >= :'ini7' AND data_hora < :'fim' GROUP BY id_dispositivo;
\echo '--- C) particionada (lê só as partições do período)'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id_dispositivo, AVG(temperatura_ar) FROM bench_c_particionada
 WHERE data_hora >= :'ini7' AND data_hora < :'fim' GROUP BY id_dispositivo;
\echo '--- D) view materializada'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id_dispositivo, AVG(temp_media) FROM bench_d_mv_horaria
 WHERE hora >= :'ini7' AND hora < :'fim' GROUP BY id_dispositivo;

-- ---------------------------------------------------------------------
-- 4. CONSULTAS REPETIDAS (:reps vezes cada)
-- ---------------------------------------------------------------------

-- Q1: vento máximo de 1 dia numa estação
CALL sp_bench_consulta('Q1_ESTACAO_1DIA_VENTO_MAX', 'A sem índice', format($q$
    SELECT MAX(velocidade_vento) FROM bench_a_sem_indice
     WHERE id_dispositivo = 1 AND data_hora >= %L AND data_hora < %L $q$, :'ini1', :'fim'), :reps);
CALL sp_bench_consulta('Q1_ESTACAO_1DIA_VENTO_MAX', 'B índice', format($q$
    SELECT MAX(velocidade_vento) FROM bench_b_indice
     WHERE id_dispositivo = 1 AND data_hora >= %L AND data_hora < %L $q$, :'ini1', :'fim'), :reps);
CALL sp_bench_consulta('Q1_ESTACAO_1DIA_VENTO_MAX', 'C particionada', format($q$
    SELECT MAX(velocidade_vento) FROM bench_c_particionada
     WHERE id_dispositivo = 1 AND data_hora >= %L AND data_hora < %L $q$, :'ini1', :'fim'), :reps);

-- Q2: temperatura média de 7 dias por estação
CALL sp_bench_consulta('Q2_TEMP_MEDIA_7D_POR_ESTACAO', 'A sem índice', format($q$
    SELECT id_dispositivo, AVG(temperatura_ar) FROM bench_a_sem_indice
     WHERE data_hora >= %L AND data_hora < %L GROUP BY id_dispositivo $q$, :'ini7', :'fim'), :reps);
CALL sp_bench_consulta('Q2_TEMP_MEDIA_7D_POR_ESTACAO', 'B índice', format($q$
    SELECT id_dispositivo, AVG(temperatura_ar) FROM bench_b_indice
     WHERE data_hora >= %L AND data_hora < %L GROUP BY id_dispositivo $q$, :'ini7', :'fim'), :reps);
CALL sp_bench_consulta('Q2_TEMP_MEDIA_7D_POR_ESTACAO', 'C particionada', format($q$
    SELECT id_dispositivo, AVG(temperatura_ar) FROM bench_c_particionada
     WHERE data_hora >= %L AND data_hora < %L GROUP BY id_dispositivo $q$, :'ini7', :'fim'), :reps);
CALL sp_bench_consulta('Q2_TEMP_MEDIA_7D_POR_ESTACAO', 'D view materializada', format($q$
    SELECT id_dispositivo, AVG(temp_media) FROM bench_d_mv_horaria
     WHERE hora >= %L AND hora < %L GROUP BY id_dispositivo $q$, :'ini7', :'fim'), :reps);

-- Q3: mínimos e máximos de 7 dias por estação
CALL sp_bench_consulta('Q3_MIN_MAX_7D_POR_ESTACAO', 'A sem índice', format($q$
    SELECT id_dispositivo, MIN(temperatura_ar), MAX(temperatura_ar), MAX(velocidade_vento)
      FROM bench_a_sem_indice
     WHERE data_hora >= %L AND data_hora < %L GROUP BY id_dispositivo $q$, :'ini7', :'fim'), :reps);
CALL sp_bench_consulta('Q3_MIN_MAX_7D_POR_ESTACAO', 'B índice', format($q$
    SELECT id_dispositivo, MIN(temperatura_ar), MAX(temperatura_ar), MAX(velocidade_vento)
      FROM bench_b_indice
     WHERE data_hora >= %L AND data_hora < %L GROUP BY id_dispositivo $q$, :'ini7', :'fim'), :reps);
CALL sp_bench_consulta('Q3_MIN_MAX_7D_POR_ESTACAO', 'C particionada', format($q$
    SELECT id_dispositivo, MIN(temperatura_ar), MAX(temperatura_ar), MAX(velocidade_vento)
      FROM bench_c_particionada
     WHERE data_hora >= %L AND data_hora < %L GROUP BY id_dispositivo $q$, :'ini7', :'fim'), :reps);
CALL sp_bench_consulta('Q3_MIN_MAX_7D_POR_ESTACAO', 'D view materializada', format($q$
    SELECT id_dispositivo, MIN(temp_min), MAX(temp_max), MAX(vento_max)
      FROM bench_d_mv_horaria
     WHERE hora >= %L AND hora < %L GROUP BY id_dispositivo $q$, :'ini7', :'fim'), :reps);

-- Q4: minutos com vento acima de 5 m/s por dia, numa estação, em 30 dias
CALL sp_bench_consulta('Q4_VENTO_ACIMA_5_POR_DIA_30D', 'A sem índice', format($q$
    SELECT date_trunc('day', data_hora), COUNT(*) FROM bench_a_sem_indice
     WHERE id_dispositivo = 1 AND velocidade_vento > 5
       AND data_hora >= %L AND data_hora < %L GROUP BY 1 $q$, :'ini30', :'fim'), :reps);
CALL sp_bench_consulta('Q4_VENTO_ACIMA_5_POR_DIA_30D', 'B índice', format($q$
    SELECT date_trunc('day', data_hora), COUNT(*) FROM bench_b_indice
     WHERE id_dispositivo = 1 AND velocidade_vento > 5
       AND data_hora >= %L AND data_hora < %L GROUP BY 1 $q$, :'ini30', :'fim'), :reps);
CALL sp_bench_consulta('Q4_VENTO_ACIMA_5_POR_DIA_30D', 'C particionada', format($q$
    SELECT date_trunc('day', data_hora), COUNT(*) FROM bench_c_particionada
     WHERE id_dispositivo = 1 AND velocidade_vento > 5
       AND data_hora >= %L AND data_hora < %L GROUP BY 1 $q$, :'ini30', :'fim'), :reps);

-- Q5: chuva do dia - somando os minutos x lendo a coluna chuva_acumulada
CALL sp_bench_consulta('Q5_CHUVA_DO_DIA', 'somando minutos', format($q$
    SELECT SUM(chuva) FROM bench_c_particionada
     WHERE id_dispositivo = 1 AND data_hora >= %L AND data_hora < %L $q$, :'ini1', :'fim'), :reps);
CALL sp_bench_consulta('Q5_CHUVA_DO_DIA', 'coluna acumulada', format($q$
    SELECT chuva_acumulada FROM bench_c_particionada
     WHERE id_dispositivo = 1 AND data_hora >= %L AND data_hora < %L
     ORDER BY data_hora DESC LIMIT 1 $q$, :'ini1', :'fim'), :reps);

-- ---------------------------------------------------------------------
-- 5. RESULTADOS
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_bench_resumo AS
SELECT experimento,
       cenario,
       COUNT(*)                                        AS execucoes,
       ROUND(AVG(duracao_ms), 3)                       AS media_ms,
       ROUND(STDDEV(duracao_ms), 3)                    AS desvio_ms,
       ROUND(MIN(duracao_ms), 3)                       AS min_ms,
       ROUND(MAX(duracao_ms), 3)                       AS max_ms,
       ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duracao_ms)::NUMERIC, 3) AS p95_ms,
       ROUND(AVG(registros / NULLIF(duracao_ms, 0) * 1000), 0) AS registros_por_s
  FROM bench_resultado
 GROUP BY experimento, cenario
 ORDER BY experimento, cenario;

SELECT * FROM vw_bench_resumo;

-- Ganho de cada cenário em relação ao "A sem índice" (quantas vezes mais rápido)
SELECT r.experimento, r.cenario, r.media_ms,
       ROUND(a.media_ms / NULLIF(r.media_ms, 0), 1) AS vezes_mais_rapido
  FROM vw_bench_resumo r
  JOIN vw_bench_resumo a ON a.experimento = r.experimento AND a.cenario = 'A sem índice'
 ORDER BY r.experimento, r.cenario;
