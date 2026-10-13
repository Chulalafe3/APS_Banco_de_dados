-- =====================================================================
-- 06_arquivamento.sql
-- APS Independente - LPBD (UNIP)
-- Manutenção e Limpeza (Data Lifecycle)
--
-- 1. sp_arquivar_telemetria : move leituras com mais de 30 dias de
--                             telemetria -> telemetria_historico
-- 2. log_arquivamento       : registra cada execução (quantas linhas,
--                             quanto tempo) — evidência para o relatório
-- 3. sp_criar_particoes     : cria as partições mensais futuras da
--                             telemetria (sem elas, inserts falham)
-- 4. vw_telemetria_completa : consulta única sobre dados atuais + arquivo
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. LOG DAS EXECUÇÕES DO ARQUIVAMENTO
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS log_arquivamento (
    id_execucao     SERIAL PRIMARY KEY,
    data_execucao   TIMESTAMP NOT NULL DEFAULT NOW(),
    data_corte      TIMESTAMP NOT NULL,
        -- leituras ANTES desta data foram arquivadas
    linhas_movidas  BIGINT NOT NULL,
    duracao_ms      NUMERIC(12,2) NOT NULL
);

COMMENT ON TABLE log_arquivamento IS
    'Histórico de execuções da procedure de arquivamento (Data Lifecycle)';

-- Índice no histórico: consultas antigas também filtram por sensor + período
CREATE INDEX IF NOT EXISTS idx_historico_sensor_data
    ON telemetria_historico (id_sensor, data_hora);

-- ---------------------------------------------------------------------
-- 2. PROCEDURE DE ARQUIVAMENTO
--    Move (apaga da telemetria + insere no histórico) num único
--    comando. Se algo falhar no meio, nada é perdido: ou move tudo,
--    ou não move nada.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_arquivar_telemetria(p_dias INTEGER DEFAULT 30)
LANGUAGE plpgsql
AS $$
DECLARE
    v_corte   TIMESTAMP := date_trunc('minute', NOW()) - make_interval(days => p_dias);
    v_inicio  TIMESTAMP := clock_timestamp();
    v_linhas  BIGINT;
    v_ms      NUMERIC(12,2);
BEGIN
    WITH movidas AS (
        DELETE FROM telemetria
        WHERE data_hora < v_corte
        RETURNING id_leitura, id_sensor, data_hora, valor
    )
    INSERT INTO telemetria_historico (id_leitura, id_sensor, data_hora, valor)
    SELECT id_leitura, id_sensor, data_hora, valor
    FROM movidas
    ON CONFLICT (id_leitura, data_hora) DO NOTHING;

    GET DIAGNOSTICS v_linhas = ROW_COUNT;

    v_ms := EXTRACT(EPOCH FROM (clock_timestamp() - v_inicio)) * 1000;

    INSERT INTO log_arquivamento (data_corte, linhas_movidas, duracao_ms)
    VALUES (v_corte, v_linhas, v_ms);

    RAISE NOTICE 'Arquivamento concluído: % leituras anteriores a % movidas em % ms',
                 v_linhas, v_corte, v_ms;
END;
$$;

COMMENT ON PROCEDURE sp_arquivar_telemetria(INTEGER) IS
    'Move leituras com mais de p_dias (padrão 30) de telemetria para telemetria_historico e registra em log_arquivamento';

-- ---------------------------------------------------------------------
-- 3. CRIAÇÃO AUTOMÁTICA DAS PARTIÇÕES MENSAIS
--    A telemetria só aceita leituras de meses que têm partição.
--    Esta procedure cria o mês atual + os próximos p_meses.
--    Partições novas herdam o índice e a trigger automaticamente.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_criar_particoes(p_meses INTEGER DEFAULT 3)
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio  DATE;
    v_fim     DATE;
    v_nome    TEXT;
BEGIN
    FOR i IN 0..p_meses LOOP
        v_inicio := (date_trunc('month', NOW()) + make_interval(months => i))::DATE;
        v_fim    := (v_inicio + INTERVAL '1 month')::DATE;
        v_nome   := 'telemetria_' || to_char(v_inicio, 'YYYY_MM');

        IF to_regclass(v_nome) IS NULL THEN
            EXECUTE format(
                'CREATE TABLE %I PARTITION OF telemetria FOR VALUES FROM (%L) TO (%L)',
                v_nome, v_inicio, v_fim);
            RAISE NOTICE 'Partição criada: %', v_nome;
        END IF;
    END LOOP;
END;
$$;

COMMENT ON PROCEDURE sp_criar_particoes(INTEGER) IS
    'Cria as partições mensais da telemetria para o mês atual e os próximos p_meses (padrão 3)';

-- Já garante as partições até janeiro de 2027
CALL sp_criar_particoes(3);

-- ---------------------------------------------------------------------
-- 4. VIEW: TODOS OS DADOS (ATUAIS + ARQUIVADOS)
--    Para relatórios de longo prazo, sem precisar lembrar em qual
--    tabela cada leitura está.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_telemetria_completa AS
    SELECT id_leitura, id_sensor, data_hora, valor, 'ATUAL'     AS origem
    FROM telemetria
    UNION ALL
    SELECT id_leitura, id_sensor, data_hora, valor, 'ARQUIVADO' AS origem
    FROM telemetria_historico;

COMMENT ON VIEW vw_telemetria_completa IS
    'Leituras da tabela operacional e do histórico juntas, com a coluna origem';


-- =====================================================================
-- 5. TESTE (selecione e rode bloco por bloco)
-- =====================================================================
/*
-- 5.1 Antes: quantas leituras em cada tabela
SELECT
    (SELECT COUNT(*) FROM telemetria)           AS atuais,
    (SELECT COUNT(*) FROM telemetria_historico) AS arquivadas;

-- 5.2 Se a carga massiva cobriu exatamente 30 dias, ainda não há
--     nada velho o suficiente. Para testar agora, arquive o que tem
--     mais de 20 dias (cerca de 1/3 da carga):
CALL sp_arquivar_telemetria(20);

-- 5.3 Depois: os números devem ter mudado, e o total continua igual
SELECT
    (SELECT COUNT(*) FROM telemetria)           AS atuais,
    (SELECT COUNT(*) FROM telemetria_historico) AS arquivadas,
    (SELECT COUNT(*) FROM vw_telemetria_completa) AS total;

-- 5.4 Registro da execução (linhas movidas e tempo)
SELECT * FROM log_arquivamento ORDER BY id_execucao DESC;

-- 5.5 Uso normal (regra da APS): mais de 30 dias
CALL sp_arquivar_telemetria();

-- 5.6 Partições existentes
SELECT inhrelid::regclass AS particao
FROM pg_inherits
WHERE inhparent = 'telemetria'::regclass
ORDER BY 1;
*/
