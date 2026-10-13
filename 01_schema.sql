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
    status_operacional  VARCHAR(20) NOT NULL DEFAULT 'OPERACIONAL',
        -- valores esperados: OPERACIONAL, ALERTA, FALHA, MANUTENCAO
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
-- ---------------------------------------------------------------------
CREATE TABLE telemetria (
    id_leitura          BIGSERIAL,
    id_sensor           INTEGER NOT NULL REFERENCES sensores(id_sensor),
    data_hora           TIMESTAMP NOT NULL,
    valor               NUMERIC(12,4) NOT NULL,
    PRIMARY KEY (id_leitura, data_hora)
) PARTITION BY RANGE (data_hora);

COMMENT ON TABLE telemetria IS 'Leituras brutas dos sensores (1 por minuto). Particionada por mês para otimizar consultas e o expurgo de dados antigos.';

-- Partições iniciais (uma por mês) — criar novas conforme o tempo avança
CREATE TABLE telemetria_2026_09 PARTITION OF telemetria
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');

CREATE TABLE telemetria_2026_10 PARTITION OF telemetria
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');

CREATE TABLE telemetria_2026_11 PARTITION OF telemetria
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');

-- Índice composto: consultas típicas filtram por sensor + período
CREATE INDEX idx_telemetria_sensor_data
    ON telemetria (id_sensor, data_hora);

-- ---------------------------------------------------------------------
-- 3b. TABELA HISTÓRICA (destino do arquivamento após 30 dias — Etapa 5)
-- ---------------------------------------------------------------------
CREATE TABLE telemetria_historico (
    id_leitura          BIGINT NOT NULL,
    id_sensor           INTEGER NOT NULL REFERENCES sensores(id_sensor),
    data_hora           TIMESTAMP NOT NULL,
    valor               NUMERIC(12,4) NOT NULL,
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
    tipo_alerta         VARCHAR(30) NOT NULL,
        -- ex: LIMITE_EXCEDIDO_MAX, LIMITE_EXCEDIDO_MIN, SENSOR_OFFLINE
    status              VARCHAR(20) NOT NULL DEFAULT 'PENDENTE'
        -- valores esperados: PENDENTE, RESOLVIDO
);

COMMENT ON TABLE logs_alertas IS 'Ocorrências graves detectadas pela trigger de segurança sobre a tabela de telemetria';

CREATE INDEX idx_alertas_estacao_data
    ON logs_alertas (id_estacao, data_hora);
