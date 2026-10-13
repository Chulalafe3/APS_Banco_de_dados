-- =====================================================================
-- APS Independente (LPBD) — Banco de Dados de Telemetria IoT
-- Etapa 1b: Dados iniciais — Estação e Sensores
-- =====================================================================

-- ---------------------------------------------------------------------
-- Estação de teste
-- ---------------------------------------------------------------------
-- (pode rodar mais de uma vez: se a estação já existe, não insere de novo)
INSERT INTO estacoes (nome, localizacao, latitude, longitude, status_operacional)
SELECT 'Estação Meteorológica 01', 'São José dos Campos - SP', -23.2237, -45.9009, 'OPERACIONAL'
WHERE NOT EXISTS (SELECT 1 FROM estacoes WHERE nome = 'Estação Meteorológica 01');

-- ---------------------------------------------------------------------
-- Sensores / variáveis medidas
-- numero_sensor_fisico = número de série do dispositivo físico que
-- agrupa variáveis vindas do mesmo sensor (ex: anemômetro 22103467
-- entrega velocidade + direção + rajada em um único aparelho)
-- ---------------------------------------------------------------------
-- (pode rodar mais de uma vez: só insere os sensores que ainda não existem)
INSERT INTO sensores (id_estacao, tipo_sensor, unidade_medida, limite_min, limite_max, numero_sensor_fisico)
SELECT v.id_estacao, v.tipo_sensor, v.unidade_medida, v.limite_min, v.limite_max, v.numero_sensor_fisico
FROM (VALUES
    (1, 'TEMPERATURA_AR',       '°C',   -5::NUMERIC, 45::NUMERIC, '1'),
    (1, 'UMIDADE_AR',           '%',     0,  100,  '1'),
    (1, 'VELOCIDADE_VENTO',     'm/s',   0,   30,  '22103467'),
    (1, 'DIRECAO_VENTO',        '°',  NULL, NULL,  '22103467'),
    (1, 'RAJADA_VENTO',         'm/s',   0,   45,  '22103467'),
    (1, 'PRESSAO_BAROMETRICA',  'hPa', 950, 1050,  '3'),
    (1, 'RADIACAO_SOLAR',       'W/m²',  0, 1200,  '4'),
    (1, 'PLUVIOMETRO',          'mm',    0,   50,  '5'),
    (1, 'UMIDADE_SOLO',         '%',     0,  100,  '6')
) AS v(id_estacao, tipo_sensor, unidade_medida, limite_min, limite_max, numero_sensor_fisico)
WHERE NOT EXISTS (
    SELECT 1 FROM sensores s
    WHERE s.id_estacao = v.id_estacao AND s.tipo_sensor = v.tipo_sensor
);
