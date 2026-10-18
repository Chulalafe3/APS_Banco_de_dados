-- =====================================================================
-- APS - Banco de Dados de Telemetria IoT
-- Monitoramento meteorológico para a Defesa Civil de São José dos Campos
--
-- 01_estrutura.sql - tabelas, chaves, índices e view materializada
-- PostgreSQL 14+ (testado no 16) - rodar num banco novo, ex.: aps_defesa_civil
-- =====================================================================

-- Para recriar do zero, descomente:
-- DROP SCHEMA public CASCADE; CREATE SCHEMA public;

SET client_min_messages TO WARNING;

-- ---------------------------------------------------------------------
-- CLIENTE
-- Cada cliente da plataforma. O acesso (login e senha) é citado no
-- documento, mas não é implementado no banco.
-- ---------------------------------------------------------------------
CREATE TABLE cliente (
    id_cliente     SERIAL       PRIMARY KEY,
    nome           VARCHAR(100) NOT NULL,
    cidade         VARCHAR(80),
    uf             CHAR(2),
    data_cadastro  DATE         NOT NULL DEFAULT CURRENT_DATE
);

-- ---------------------------------------------------------------------
-- DISPOSITIVO
-- Equipamento que coleta e transmite os dados (na prática, um datalogger
-- ou CLP). Tipo, meio de transmissão e formato de envio ficam no documento.
-- ---------------------------------------------------------------------
CREATE TABLE dispositivo (
    id_dispositivo            SERIAL       PRIMARY KEY,
    id_cliente                INTEGER      NOT NULL REFERENCES cliente(id_cliente),
    nome                      VARCHAR(100) NOT NULL,
    intervalo_leitura_min     SMALLINT     NOT NULL DEFAULT 1,
    intervalo_transmissao_min SMALLINT     NOT NULL DEFAULT 10,
    latitude                  NUMERIC(9,6),
    longitude                 NUMERIC(9,6),
    ativo                     BOOLEAN      NOT NULL DEFAULT TRUE,
    status                    VARCHAR(12)  NOT NULL DEFAULT 'OPERACIONAL'
                              CHECK (status IN ('OPERACIONAL', 'ALERTA', 'FALHA')),
    ultima_comunicacao        TIMESTAMPTZ
);

-- ---------------------------------------------------------------------
-- SENSOR
-- Cada parâmetro medido por um dispositivo, com a faixa física válida
-- (limites de segurança). Valor fora da faixa = falha de sensor.
-- O parâmetro corresponde a uma coluna da tabela leitura.
-- ---------------------------------------------------------------------
CREATE TABLE sensor (
    id_sensor       SERIAL       PRIMARY KEY,
    id_dispositivo  INTEGER      NOT NULL REFERENCES dispositivo(id_dispositivo),
    parametro       VARCHAR(30)  NOT NULL CHECK (parametro IN (
                        'temperatura_ar', 'umidade_ar', 'chuva',
                        'direcao_vento', 'velocidade_vento', 'radiacao_solar')),
    unidade         VARCHAR(10)  NOT NULL,
    limite_min      NUMERIC      NOT NULL,
    limite_max      NUMERIC      NOT NULL,
    ativo           BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_sensor_dispositivo_parametro UNIQUE (id_dispositivo, parametro),
    CONSTRAINT ck_sensor_faixa CHECK (limite_min < limite_max)
);

-- ---------------------------------------------------------------------
-- LEITURA (dados recentes)
-- Uma linha por dispositivo por minuto; uma coluna por parâmetro.
-- Particionada por mês (as partições são criadas por sp_criar_particoes).
-- A chave primária (dispositivo, data_hora) é também o índice composto
-- usado pelas consultas por estação e período.
-- ---------------------------------------------------------------------
CREATE TABLE leitura (
    id_dispositivo    INTEGER      NOT NULL REFERENCES dispositivo(id_dispositivo),
    data_hora         TIMESTAMPTZ  NOT NULL,          -- instante da medição
    -- NUMERIC(8,2) em todos: comporta códigos de erro do equipamento
    -- (ex.: -9999), que a trigger detecta e anula antes de gravar
    temperatura_ar    NUMERIC(8,2),                   -- °C
    umidade_ar        NUMERIC(8,2),                   -- % UR
    chuva             NUMERIC(8,2),                   -- mm no minuto
    chuva_acumulada   NUMERIC(8,2),                   -- mm no dia (calculado)
    direcao_vento     NUMERIC(8,2),                   -- graus (0 = Norte)
    velocidade_vento  NUMERIC(8,2),                   -- m/s
    radiacao_solar    NUMERIC(8,2),                   -- W/m²
    recebido_em       TIMESTAMPTZ  NOT NULL DEFAULT now(), -- chegada no banco
    PRIMARY KEY (id_dispositivo, data_hora)
) PARTITION BY RANGE (data_hora);

-- ---------------------------------------------------------------------
-- LEITURA_ARQUIVO (histórico)
-- Mesma estrutura. Recebe as partições mensais antigas inteiras
-- (DETACH/ATTACH), sem copiar linha por linha.
-- Índice BRIN: muito pequeno, ideal para dados gravados em ordem de tempo.
-- ---------------------------------------------------------------------
CREATE TABLE leitura_arquivo (
    LIKE leitura INCLUDING DEFAULTS,
    PRIMARY KEY (id_dispositivo, data_hora)
) PARTITION BY RANGE (data_hora);

CREATE INDEX idx_arquivo_data_hora_brin ON leitura_arquivo USING BRIN (data_hora);

-- ---------------------------------------------------------------------
-- LEITURA_DIARIA (resumo por dia, gerado no arquivamento)
-- ---------------------------------------------------------------------
CREATE TABLE leitura_diaria (
    id_dispositivo          INTEGER      NOT NULL REFERENCES dispositivo(id_dispositivo),
    dia                     DATE         NOT NULL,
    temp_min                NUMERIC(5,2),
    temp_max                NUMERIC(5,2),
    temp_media              NUMERIC(5,2),
    umidade_min             NUMERIC(5,2),
    umidade_max             NUMERIC(5,2),
    umidade_media           NUMERIC(5,2),
    chuva_total             NUMERIC(7,2),
    vento_media             NUMERIC(5,2),
    vento_max               NUMERIC(5,2),
    vento_dir_predominante  NUMERIC(5,1),
    radiacao_media          NUMERIC(7,2),
    radiacao_max            NUMERIC(7,2),
    qtd_leituras            INTEGER,      -- 1440 = dia completo
    qtd_valores_invalidos   INTEGER,      -- valores anulados por falha de sensor
    PRIMARY KEY (id_dispositivo, dia)
);

-- ---------------------------------------------------------------------
-- REGRA_ALARME
-- Limites definidos pelo cliente para eventos climáticos.
-- ---------------------------------------------------------------------
CREATE TABLE regra_alarme (
    id_regra        SERIAL       PRIMARY KEY,
    id_dispositivo  INTEGER      NOT NULL REFERENCES dispositivo(id_dispositivo),
    parametro       VARCHAR(30)  NOT NULL CHECK (parametro IN (
                        'temperatura_ar', 'umidade_ar', 'chuva', 'chuva_acumulada',
                        'direcao_vento', 'velocidade_vento', 'radiacao_solar')),
    condicao        VARCHAR(6)   NOT NULL CHECK (condicao IN ('ACIMA', 'ABAIXO')),
    limite          NUMERIC      NOT NULL,
    nivel           VARCHAR(10)  NOT NULL DEFAULT 'ALERTA'
                    CHECK (nivel IN ('ATENCAO', 'ALERTA', 'CRITICO')),
    nota            VARCHAR(150),
    ativo           BOOLEAN      NOT NULL DEFAULT TRUE
);

-- ---------------------------------------------------------------------
-- EVENTO (log do dispositivo)
-- TRANSMISSAO_OK | FALHA_TRANSMISSAO | FALHA_SENSOR | ALARME
-- ---------------------------------------------------------------------
CREATE TABLE evento (
    id_evento       BIGSERIAL    PRIMARY KEY,
    id_dispositivo  INTEGER      NOT NULL REFERENCES dispositivo(id_dispositivo),
    data_hora       TIMESTAMPTZ  NOT NULL,
    tipo            VARCHAR(20)  NOT NULL CHECK (tipo IN (
                        'TRANSMISSAO_OK', 'FALHA_TRANSMISSAO', 'FALHA_SENSOR', 'ALARME')),
    parametro       VARCHAR(30),
    valor           NUMERIC,
    id_regra        INTEGER      REFERENCES regra_alarme(id_regra),
    mensagem        VARCHAR(250),
    reconhecido     BOOLEAN      NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_evento_dispositivo_hora ON evento (id_dispositivo, data_hora);

-- Índice parcial: só os eventos que exigem atenção e ainda não foram vistos.
-- Fica pequeno mesmo com milhares de TRANSMISSAO_OK na tabela.
CREATE INDEX idx_evento_pendentes ON evento (id_dispositivo, data_hora)
    WHERE NOT reconhecido AND tipo <> 'TRANSMISSAO_OK';

-- ---------------------------------------------------------------------
-- LOG_ARQUIVAMENTO (auditoria do ciclo de vida dos dados)
-- ---------------------------------------------------------------------
CREATE TABLE log_arquivamento (
    id_log          SERIAL       PRIMARY KEY,
    executado_em    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    particao        VARCHAR(40)  NOT NULL,
    linhas_movidas  BIGINT       NOT NULL,
    dias_resumidos  INTEGER      NOT NULL,
    duracao_ms      NUMERIC(12,3)
);

-- ---------------------------------------------------------------------
-- VIEW MATERIALIZADA: resumo por hora dos dados recentes
-- Fica gravada pronta; é atualizada com REFRESH (a cada lote, em produção).
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW mv_resumo_horario AS
SELECT id_dispositivo,
       date_trunc('hour', data_hora)       AS hora,
       ROUND(AVG(temperatura_ar), 2)       AS temp_media,
       MIN(temperatura_ar)                 AS temp_min,
       MAX(temperatura_ar)                 AS temp_max,
       ROUND(AVG(umidade_ar), 2)           AS umidade_media,
       SUM(chuva)                          AS chuva_hora,
       MAX(chuva_acumulada)                AS chuva_acumulada_dia,
       ROUND(AVG(velocidade_vento), 2)     AS vento_medio,
       MAX(velocidade_vento)               AS vento_max,
       ROUND(AVG(radiacao_solar), 2)       AS radiacao_media,
       COUNT(*)                            AS qtd_leituras
  FROM leitura
 GROUP BY id_dispositivo, date_trunc('hour', data_hora)
WITH NO DATA;

-- índice único: permite REFRESH ... CONCURRENTLY (sem bloquear a leitura)
CREATE UNIQUE INDEX idx_mv_resumo_horario ON mv_resumo_horario (id_dispositivo, hora);
