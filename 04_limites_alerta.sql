-- =====================================================================
-- 04_limites_alerta.sql
-- APS Independente - LPBD (UNIP)
-- Tabela de limites de alerta configuráveis
--
-- Cada sensor pode ter QUANTOS limites quiser (atenção, crítico,
-- frio, calor, etc.), cada um com nome, nível e descrição livre.
-- A trigger de segurança (próxima etapa) vai ler esta tabela.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. TABELA DE LIMITES
-- ---------------------------------------------------------------------
CREATE TABLE limites_alerta (
    id_limite       SERIAL PRIMARY KEY,
    id_sensor       INTEGER NOT NULL REFERENCES sensores(id_sensor),
    nome            VARCHAR(60) NOT NULL,
        -- nome curto do alerta, ex: 'Calor extremo'
    nivel           VARCHAR(10) NOT NULL DEFAULT 'ATENCAO'
                    CHECK (nivel IN ('INFO', 'ATENCAO', 'CRITICO')),
    limite_min      NUMERIC(10,2),
        -- dispara se valor < limite_min (NULL = não verifica mínimo)
    limite_max      NUMERIC(10,2),
        -- dispara se valor > limite_max (NULL = não verifica máximo)
    descricao       TEXT,
        -- texto livre: o que o alerta significa / o que fazer
    ativo           BOOLEAN NOT NULL DEFAULT TRUE,
    data_cadastro   TIMESTAMP NOT NULL DEFAULT NOW(),

    -- pelo menos um dos limites precisa estar preenchido
    CONSTRAINT ck_limite_preenchido
        CHECK (limite_min IS NOT NULL OR limite_max IS NOT NULL),

    -- se os dois estiverem preenchidos, o mínimo tem que ser menor
    CONSTRAINT ck_limite_ordem
        CHECK (limite_min IS NULL OR limite_max IS NULL OR limite_min < limite_max)
);

COMMENT ON TABLE limites_alerta IS
    'Regras de alerta por sensor. Um sensor pode ter vários limites (níveis diferentes). Lida pela trigger de detecção de falhas.';
COMMENT ON COLUMN limites_alerta.nivel IS
    'Gravidade: INFO, ATENCAO ou CRITICO. Define o status que a estação recebe.';
COMMENT ON COLUMN limites_alerta.descricao IS
    'Descrição livre do alerta (significado, ação recomendada).';

-- Índice: a trigger vai buscar os limites ativos de um sensor a cada leitura
CREATE INDEX idx_limites_sensor_ativo
    ON limites_alerta (id_sensor)
    WHERE ativo = TRUE;

-- ---------------------------------------------------------------------
-- 2. LIGAR OS ALERTAS AO LIMITE QUE OS DISPAROU
-- ---------------------------------------------------------------------
ALTER TABLE logs_alertas
    ADD COLUMN id_limite INTEGER REFERENCES limites_alerta(id_limite),
    ADD COLUMN nivel     VARCHAR(10);

COMMENT ON COLUMN logs_alertas.id_limite IS 'Qual regra de limites_alerta disparou este alerta';
COMMENT ON COLUMN logs_alertas.nivel     IS 'Nível do alerta no momento em que foi gerado';

-- ---------------------------------------------------------------------
-- 3. NOVO SIGNIFICADO DOS LIMITES NA TABELA SENSORES
--    limite_min/limite_max de sensores passam a ser a FAIXA FÍSICA
--    de medição do aparelho (o que ele consegue medir).
--    Os alertas agora ficam em limites_alerta.
-- ---------------------------------------------------------------------
COMMENT ON COLUMN sensores.limite_min IS 'Faixa física de medição do sensor (mínimo). Alertas ficam em limites_alerta.';
COMMENT ON COLUMN sensores.limite_max IS 'Faixa física de medição do sensor (máximo). Alertas ficam em limites_alerta.';

-- ---------------------------------------------------------------------
-- 4. LIMITES INICIAIS (EXEMPLOS - AJUSTE À VONTADE)
--    Usa o tipo do sensor para achar o id, sem depender de números fixos.
-- ---------------------------------------------------------------------
INSERT INTO limites_alerta (id_sensor, nome, nivel, limite_min, limite_max, descricao)
SELECT s.id_sensor, v.nome, v.nivel, v.limite_min, v.limite_max, v.descricao
FROM (VALUES
    -- Temperatura do ar (°C)
    ('TEMPERATURA_AR', 'Calor',          'ATENCAO', NULL::NUMERIC, 32::NUMERIC, 'Temperatura acima de 32 °C.'),
    ('TEMPERATURA_AR', 'Calor extremo',  'CRITICO', NULL,          38,          'Temperatura acima de 38 °C. Risco à saúde e a equipamentos.'),
    ('TEMPERATURA_AR', 'Frio',           'ATENCAO', 5,             NULL,        'Temperatura abaixo de 5 °C.'),
    ('TEMPERATURA_AR', 'Risco de geada', 'CRITICO', 0,             NULL,        'Temperatura abaixo de 0 °C. Possível geada.'),

    -- Umidade relativa do ar (%)
    ('UMIDADE_AR', 'Ar seco',          'ATENCAO', 30, NULL, 'Umidade abaixo de 30 %.'),
    ('UMIDADE_AR', 'Ar muito seco',    'CRITICO', 20, NULL, 'Umidade abaixo de 20 %. Risco à saúde e de incêndio.'),

    -- Vento médio (m/s)
    ('VELOCIDADE_VENTO', 'Vento forte',      'ATENCAO', NULL, 10, 'Vento médio acima de 10 m/s (36 km/h).'),
    ('VELOCIDADE_VENTO', 'Vento muito forte','CRITICO', NULL, 17, 'Vento médio acima de 17 m/s (61 km/h).'),

    -- Rajada (m/s)
    ('RAJADA_VENTO', 'Rajada forte',   'ATENCAO', NULL, 15, 'Rajada acima de 15 m/s (54 km/h).'),
    ('RAJADA_VENTO', 'Rajada severa',  'CRITICO', NULL, 25, 'Rajada acima de 25 m/s (90 km/h). Risco de danos.'),

    -- Umidade do solo (%)
    ('UMIDADE_SOLO', 'Solo seco',      'ATENCAO', 20, NULL, 'Umidade do solo abaixo de 20 %.')
) AS v(tipo_sensor, nome, nivel, limite_min, limite_max, descricao)
JOIN sensores s
  ON s.tipo_sensor = v.tipo_sensor
 AND s.id_estacao  = 1;

-- Conferência
SELECT s.tipo_sensor, l.nome, l.nivel, l.limite_min, l.limite_max, l.descricao
FROM limites_alerta l
JOIN sensores s ON s.id_sensor = l.id_sensor
ORDER BY s.tipo_sensor, l.nivel;
