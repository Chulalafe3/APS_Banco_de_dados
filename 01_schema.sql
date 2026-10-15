-- =====================================================================
-- APS Independente (LPBD) — Banco de Dados de Telemetria IoT
-- Etapa 1: Esquema do Banco de Dados
-- Adaptado para Estação Meteorológica
-- SGBD: PostgreSQL
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. TABELA DE CONTROLE DE EQUIPAMENTOS (estações)
-- ---------------------------------------------------------------------
CREATE TABLE estacoes (
    id_estacao          SERIAL PRIMARY KEY,
    nome                VARCHAR(100) NOT NULL,
    localizacao         VARCHAR(150),
    latitude            NUMERIC(9,6),
    longitude           NUMERIC(9,6),
    status_operacional  VARCHAR(20) NOT NULL DEFAULT 'OPERACIONAL'
                        CHECK (status_operacional IN ('OPERACIONAL', 'ALERTA', 'FALHA', 'MANUTENCAO')),
    data_instalacao     DATE NOT NULL DEFAULT CURRENT_DATE,
    ativo               BOOLEAN NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE estacoes IS 'Controle das estações meteorológicas (equipamentos monitorados)';

-- ---------------------------------------------------------------------
-- 2. SENSORES CADASTRADOS
-- ---------------------------------------------------------------------
CREATE TABLE sensores (
    id_sensor           SERIAL PRIMARY KEY,
    id_estacao          INTEGER NOT NULL REFERENCES estacoes(id_estacao),
    tipo_sensor         VARCHAR(30) NOT NULL,
        -- ex: TEMPERATURA, UMIDADE, VENTO_VELOCIDADE, VENTO_DIRECAO, PRESSAO, CHUVA
    unidade_medida      VARCHAR(10) NOT NULL,
        -- ex: °C, %, m/s, hPa, mm
    limite_min          NUMERIC(10,2),
    limite_max          NUMERIC(10,2),
    numero_sensor_fisico VARCHAR(30),
        -- número de série do dispositivo físico (ex: '22103467' do anemômetro),
        -- agrupando variáveis que vêm do mesmo sensor
    ativo               BOOLEAN NOT NULL DEFAULT TRUE,
    data_cadastro       TIMESTAMP NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE sensores IS 'Sensores cadastrados por estação, com limites de segurança configuráveis (usados pela trigger de alerta)';
COMMENT ON COLUMN sensores.limite_min IS 'Limite inferior aceitável — usado pela trigger de detecção de falha';
COMMENT ON COLUMN sensores.limite_max IS 'Limite superior aceitável — usado pela trigger de detecção de falha';
COMMENT ON COLUMN sensores.numero_sensor_fisico IS 'Número de série do dispositivo físico de origem (ex: 22103467 = anemômetro, que gera 3 variáveis: velocidade, direção, rajada)';

-- ---------------------------------------------------------------------
-- 3. HISTÓRICO DE TELEMETRIA — PARTICIONADA POR DATA (mês)
--    Uma linha por estação por minuto, com uma coluna por sensor.
--    O nome de cada coluna é o tipo_sensor da tabela sensores em
--    minúsculas (TEMPERATURA_AR -> temperatura_ar). A trigger de alertas
--    usa essa regra para saber qual coluna é de qual sensor.
--    Sensor novo na estação = ALTER TABLE telemetria ADD COLUMN <tipo>
--    + cadastrar o sensor com o mesmo tipo_sensor.
--    NULL = o sensor não enviou leitura naquele minuto.
-- ---------------------------------------------------------------------
CREATE TABLE telemetria (
    id_leitura          BIGSERIAL,
    id_estacao          INTEGER NOT NULL REFERENCES estacoes(id_estacao),
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

-- Índice composto ÚNICO: consultas típicas filtram por estação + período,
-- e uma estação não pode ter duas linhas no mesmo minuto
-- (evita duplicar dados se a transmissão for chamada duas vezes)
CREATE UNIQUE INDEX idx_telemetria_estacao_data
    ON telemetria (id_estacao, data_hora);

-- ---------------------------------------------------------------------
-- 3a. CRIAÇÃO DAS PARTIÇÕES MENSAIS
--     A telemetria só aceita leituras de meses que têm partição.
--     sp_criar_particoes_periodo cria todos os meses entre duas datas
--     (passado ou futuro). Partições novas herdam índices e triggers.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_criar_particoes_periodo(
    p_inicio TIMESTAMP,
    p_fim    TIMESTAMP
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_mes   DATE := date_trunc('month', p_inicio)::DATE;
    v_nome  TEXT;
BEGIN
    WHILE v_mes <= p_fim LOOP
        v_nome := 'telemetria_' || to_char(v_mes, 'YYYY_MM');

        IF to_regclass(v_nome) IS NULL THEN
            EXECUTE format(
                'CREATE TABLE %I PARTITION OF telemetria FOR VALUES FROM (%L) TO (%L)',
                v_nome, v_mes, (v_mes + INTERVAL '1 month')::DATE);
            RAISE NOTICE 'Partição criada: %', v_nome;
        END IF;

        v_mes := (v_mes + INTERVAL '1 month')::DATE;
    END LOOP;
END;
$$;

COMMENT ON PROCEDURE sp_criar_particoes_periodo(TIMESTAMP, TIMESTAMP) IS
    'Cria as partições mensais da telemetria que faltam entre p_inicio e p_fim';

-- Partições iniciais: 3 meses para trás (carga histórica) e 3 para frente
CALL sp_criar_particoes_periodo(
    (NOW() - INTERVAL '3 months')::TIMESTAMP,
    (NOW() + INTERVAL '3 months')::TIMESTAMP);

-- ---------------------------------------------------------------------
-- 3b. TABELA HISTÓRICA (destino do arquivamento após 30 dias — Etapa 5)
-- ---------------------------------------------------------------------
-- Mesmas colunas da telemetria + data_arquivamento
CREATE TABLE telemetria_historico (
    id_leitura          BIGINT NOT NULL,
    id_estacao          INTEGER NOT NULL REFERENCES estacoes(id_estacao),
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

COMMENT ON TABLE telemetria_historico IS 'Destino da procedure de Data Lifecycle: leituras com mais de 30 dias saem da tabela operacional e vêm para cá';

-- ---------------------------------------------------------------------
-- 4. LOGS DE ALERTAS
-- ---------------------------------------------------------------------
CREATE TABLE logs_alertas (
    id_alerta           BIGSERIAL PRIMARY KEY,
    id_sensor           INTEGER NOT NULL REFERENCES sensores(id_sensor),
    id_estacao          INTEGER NOT NULL REFERENCES estacoes(id_estacao),
    data_hora           TIMESTAMP NOT NULL DEFAULT NOW(),
    valor_registrado    NUMERIC(12,4) NOT NULL,
    tipo_alerta         VARCHAR(30) NOT NULL
                        CHECK (tipo_alerta IN ('LIMITE_EXCEDIDO_MAX', 'LIMITE_EXCEDIDO_MIN',
                                               'FALHA_SENSOR', 'SENSOR_OFFLINE')),
    status              VARCHAR(20) NOT NULL DEFAULT 'PENDENTE'
                        CHECK (status IN ('PENDENTE', 'RESOLVIDO'))
);

COMMENT ON TABLE logs_alertas IS 'Ocorrências graves detectadas pela trigger de segurança sobre a tabela de telemetria';

CREATE INDEX idx_alertas_estacao_data
    ON logs_alertas (id_estacao, data_hora);
