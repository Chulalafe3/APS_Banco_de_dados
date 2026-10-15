-- =====================================================================
-- 07_migrar_formato_colunas.sql
-- APS Independente - LPBD (UNIP)
-- Migração: telemetria de "1 linha por sensor" para
--           "1 linha por minuto, 1 coluna por sensor"
--
-- SÓ PARA BANCOS CRIADOS COM A VERSÃO ANTIGA DOS SCRIPTS
-- (telemetria com as colunas id_sensor / valor).
-- Banco novo: não precisa deste arquivo, os scripts 01 a 06 já criam
-- tudo no formato novo.
--
-- O que faz (tudo numa transação: se der erro, nada muda):
--   1. Cria telemetria_nova (particionada, mesmas partições mensais)
--   2. Copia os dados atuais e os arquivados, um sensor em cada coluna
--   3. Apaga as tabelas antigas (e as views que dependiam delas)
--   4. Renomeia as novas para os nomes oficiais
-- logs_alertas, limites_alerta, sensores e estacoes não mudam.
--
-- DEPOIS DESTE ARQUIVO, rode de novo (F5 em cada um, nesta ordem):
--   02_procedures_simulador.sql   (simulador no formato novo)
--   05_trigger_alertas.sql        (trigger no formato novo)
--   06_arquivamento.sql           (arquivamento e view no formato novo)
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 0. CONFERÊNCIA: só roda se o banco ainda estiver no formato antigo
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name   = 'telemetria'
          AND column_name  = 'id_sensor'
    ) THEN
        RAISE EXCEPTION 'A telemetria já está no formato novo (não tem a coluna id_sensor). Nada a migrar.';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- 1. NOVA TELEMETRIA (mesma estrutura do 01_schema.sql)
-- ---------------------------------------------------------------------
CREATE TABLE telemetria_nova (
    id_leitura          BIGSERIAL,
    id_estacao          INTEGER NOT NULL
                        CONSTRAINT telemetria_id_estacao_fkey REFERENCES estacoes(id_estacao),
    data_hora           TIMESTAMP NOT NULL,
    temperatura_ar      NUMERIC(10,2),
    umidade_ar          NUMERIC(10,2),
    velocidade_vento    NUMERIC(10,2),
    direcao_vento       NUMERIC(10,2),
    rajada_vento        NUMERIC(10,2),
    pressao_barometrica NUMERIC(10,2),
    radiacao_solar      NUMERIC(10,2),
    pluviometro         NUMERIC(10,2),
    umidade_solo        NUMERIC(10,2),
    PRIMARY KEY (id_leitura, data_hora)
) PARTITION BY RANGE (data_hora);

CREATE UNIQUE INDEX idx_telemetria_nova_estacao_data
    ON telemetria_nova (id_estacao, data_hora);

-- Uma partição nova para cada partição mensal que já existe
DO $$
DECLARE
    v_part  RECORD;
    v_mes   DATE;
BEGIN
    FOR v_part IN
        SELECT c.relname
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = 'telemetria'::regclass
          AND c.relname ~ '^telemetria_\d{4}_\d{2}$'
        ORDER BY c.relname
    LOOP
        v_mes := to_date(substr(v_part.relname, 12), 'YYYY_MM');
        EXECUTE format(
            'CREATE TABLE %I PARTITION OF telemetria_nova FOR VALUES FROM (%L) TO (%L)',
            'telemetria_nova_' || to_char(v_mes, 'YYYY_MM'),
            v_mes, (v_mes + INTERVAL '1 month')::DATE);
    END LOOP;
END;
$$;

-- Histórico no formato novo
CREATE TABLE telemetria_nova_historico (
    id_leitura          BIGINT NOT NULL,
    id_estacao          INTEGER NOT NULL
                        CONSTRAINT telemetria_historico_id_estacao_fkey REFERENCES estacoes(id_estacao),
    data_hora           TIMESTAMP NOT NULL,
    temperatura_ar      NUMERIC(10,2),
    umidade_ar          NUMERIC(10,2),
    velocidade_vento    NUMERIC(10,2),
    direcao_vento       NUMERIC(10,2),
    rajada_vento        NUMERIC(10,2),
    pressao_barometrica NUMERIC(10,2),
    radiacao_solar      NUMERIC(10,2),
    pluviometro         NUMERIC(10,2),
    umidade_solo        NUMERIC(10,2),
    data_arquivamento   TIMESTAMP NOT NULL DEFAULT NOW(),
    PRIMARY KEY (id_leitura, data_hora)
);

-- ---------------------------------------------------------------------
-- 2. CÓPIA DOS DADOS: cada sensor vai para a coluna do seu tipo
--    (sem trigger na tabela nova: os alertas antigos já existem)
-- ---------------------------------------------------------------------
INSERT INTO telemetria_nova (id_estacao, data_hora,
    temperatura_ar, umidade_ar, velocidade_vento, direcao_vento, rajada_vento,
    pressao_barometrica, radiacao_solar, pluviometro, umidade_solo)
SELECT
    s.id_estacao,
    t.data_hora,
    max(t.valor) FILTER (WHERE s.tipo_sensor = 'TEMPERATURA_AR'),
    max(t.valor) FILTER (WHERE s.tipo_sensor = 'UMIDADE_AR'),
    max(t.valor) FILTER (WHERE s.tipo_sensor = 'VELOCIDADE_VENTO'),
    max(t.valor) FILTER (WHERE s.tipo_sensor = 'DIRECAO_VENTO'),
    max(t.valor) FILTER (WHERE s.tipo_sensor = 'RAJADA_VENTO'),
    max(t.valor) FILTER (WHERE s.tipo_sensor = 'PRESSAO_BAROMETRICA'),
    max(t.valor) FILTER (WHERE s.tipo_sensor = 'RADIACAO_SOLAR'),
    max(t.valor) FILTER (WHERE s.tipo_sensor = 'PLUVIOMETRO'),
    max(t.valor) FILTER (WHERE s.tipo_sensor = 'UMIDADE_SOLO')
FROM telemetria t
JOIN sensores s ON s.id_sensor = t.id_sensor
GROUP BY s.id_estacao, t.data_hora
ORDER BY t.data_hora, s.id_estacao;

-- Dados já arquivados (se houver). Ganham id_leitura novo, depois dos atuais.
INSERT INTO telemetria_nova_historico (id_leitura, id_estacao, data_hora,
    temperatura_ar, umidade_ar, velocidade_vento, direcao_vento, rajada_vento,
    pressao_barometrica, radiacao_solar, pluviometro, umidade_solo,
    data_arquivamento)
SELECT
    nextval(pg_get_serial_sequence('telemetria_nova', 'id_leitura')),
    x.*
FROM (
    SELECT
        s.id_estacao,
        h.data_hora,
        max(h.valor) FILTER (WHERE s.tipo_sensor = 'TEMPERATURA_AR'),
        max(h.valor) FILTER (WHERE s.tipo_sensor = 'UMIDADE_AR'),
        max(h.valor) FILTER (WHERE s.tipo_sensor = 'VELOCIDADE_VENTO'),
        max(h.valor) FILTER (WHERE s.tipo_sensor = 'DIRECAO_VENTO'),
        max(h.valor) FILTER (WHERE s.tipo_sensor = 'RAJADA_VENTO'),
        max(h.valor) FILTER (WHERE s.tipo_sensor = 'PRESSAO_BAROMETRICA'),
        max(h.valor) FILTER (WHERE s.tipo_sensor = 'RADIACAO_SOLAR'),
        max(h.valor) FILTER (WHERE s.tipo_sensor = 'PLUVIOMETRO'),
        max(h.valor) FILTER (WHERE s.tipo_sensor = 'UMIDADE_SOLO'),
        min(h.data_arquivamento)
    FROM telemetria_historico h
    JOIN sensores s ON s.id_sensor = h.id_sensor
    GROUP BY s.id_estacao, h.data_hora
    ORDER BY h.data_hora, s.id_estacao
) AS x;

-- ---------------------------------------------------------------------
-- 3. APAGA AS TABELAS ANTIGAS
--    CASCADE também apaga as views que usavam o formato antigo
--    (vw_telemetria_completa é recriada pelo 06; outras views de
--    consulta deixam de ser necessárias)
-- ---------------------------------------------------------------------
DROP TABLE telemetria_historico CASCADE;
DROP TABLE telemetria CASCADE;

-- ---------------------------------------------------------------------
-- 4. RENOMEIA AS NOVAS PARA OS NOMES OFICIAIS
--    (tabela, partições, índices e sequência:
--     "telemetria_nova..." -> "telemetria...")
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_obj RECORD;
BEGIN
    FOR v_obj IN
        SELECT c.relname, c.relkind
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname LIKE '%telemetria\_nova%'
        ORDER BY c.relkind, c.relname
    LOOP
        EXECUTE format('ALTER %s %I RENAME TO %I',
            CASE
                WHEN v_obj.relkind IN ('i', 'I') THEN 'INDEX'
                WHEN v_obj.relkind = 'S'         THEN 'SEQUENCE'
                ELSE 'TABLE'
            END,
            v_obj.relname,
            replace(v_obj.relname, 'telemetria_nova', 'telemetria'));
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------
-- 5. DESCRIÇÕES DAS COLUNAS (aparecem no pgAdmin)
-- ---------------------------------------------------------------------
COMMENT ON TABLE telemetria IS 'Leituras da estação (1 linha por minuto, 1 coluna por sensor). Particionada por mês para otimizar consultas e o expurgo de dados antigos.';
COMMENT ON COLUMN telemetria.temperatura_ar      IS 'Temperatura do ar (°C)';
COMMENT ON COLUMN telemetria.umidade_ar          IS 'Umidade relativa do ar (%)';
COMMENT ON COLUMN telemetria.velocidade_vento    IS 'Velocidade média do vento (m/s)';
COMMENT ON COLUMN telemetria.direcao_vento       IS 'Direção do vento (graus, 0 = norte)';
COMMENT ON COLUMN telemetria.rajada_vento        IS 'Rajada de vento (m/s)';
COMMENT ON COLUMN telemetria.pressao_barometrica IS 'Pressão barométrica ao nível do mar (hPa)';
COMMENT ON COLUMN telemetria.radiacao_solar      IS 'Radiação solar global (W/m²)';
COMMENT ON COLUMN telemetria.pluviometro         IS 'Chuva acumulada no minuto (mm)';
COMMENT ON COLUMN telemetria.umidade_solo        IS 'Umidade do solo (%)';
COMMENT ON TABLE telemetria_historico IS 'Destino da procedure de Data Lifecycle: leituras com mais de 30 dias saem da tabela operacional e vêm para cá';

COMMIT;

-- ---------------------------------------------------------------------
-- 6. CONFERÊNCIA
-- ---------------------------------------------------------------------
SELECT
    (SELECT count(*) FROM telemetria)           AS minutos_atuais,
    (SELECT count(*) FROM telemetria_historico) AS minutos_arquivados;

-- Próximo passo: rode 02, 05 e 06 de novo (ver o topo deste arquivo).
