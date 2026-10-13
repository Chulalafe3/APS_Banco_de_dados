-- =====================================================================
-- 05_trigger_alertas.sql
-- APS Independente - LPBD (UNIP)
-- Trigger de segurança: detecção de falhas e alertas em tempo real
--
-- IMPORTANTE: rode a carga massiva ANTES deste script.
--   CALL sp_gerar_carga_massiva(1, NOW() - INTERVAL '30 days', NOW(), 0.02);
-- Se a trigger já existir durante a carga, ela vai verificar as
-- ~389 mil leituras e gerar milhares de alertas de uma vez.
--
-- O que a trigger faz a cada leitura inserida em telemetria:
--   1. FALHA DO SENSOR: valor fora da faixa física do aparelho
--      (sensores.limite_min / limite_max) -> alerta FALHA_SENSOR
--   2. EVENTO METEOROLÓGICO: valor viola alguma regra de
--      limites_alerta -> grava só a regra MAIS GRAVE violada
--   3. Não duplica: se já existe alerta PENDENTE da mesma regra,
--      não abre outro
--   4. Volta ao normal: alertas pendentes que não valem mais
--      viram RESOLVIDO
--   5. Atualiza estacoes.status_operacional:
--      FALHA > ALERTA > OPERACIONAL (MANUTENCAO nunca é sobrescrito)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. AJUSTES NA TABELA DE ALERTAS
-- ---------------------------------------------------------------------
ALTER TABLE logs_alertas
    ADD COLUMN IF NOT EXISTS data_resolucao TIMESTAMP;

COMMENT ON COLUMN logs_alertas.data_hora IS
    'Momento da leitura que abriu o alerta';
COMMENT ON COLUMN logs_alertas.data_resolucao IS
    'Momento da leitura que voltou ao normal (alerta RESOLVIDO)';
COMMENT ON COLUMN logs_alertas.tipo_alerta IS
    'LIMITE_EXCEDIDO_MAX, LIMITE_EXCEDIDO_MIN ou FALHA_SENSOR';
COMMENT ON COLUMN logs_alertas.nivel IS
    'INFO, ATENCAO, CRITICO (regras de limites_alerta) ou FALHA (sensor com defeito)';

-- Índice parcial: a trigger só consulta alertas PENDENTES,
-- então indexamos só eles (índice pequeno e rápido)
CREATE INDEX IF NOT EXISTS idx_alertas_pendentes
    ON logs_alertas (id_estacao, id_sensor)
    WHERE status = 'PENDENTE';

-- ---------------------------------------------------------------------
-- 2. FUNÇÃO DA TRIGGER
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_verificar_leitura()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_sensor        sensores%ROWTYPE;
    v_limite        RECORD;
    v_achou_limite  BOOLEAN := FALSE;
    v_status_novo   VARCHAR(20);
BEGIN
    -- Dados do sensor que gerou a leitura
    SELECT * INTO v_sensor
    FROM sensores
    WHERE id_sensor = NEW.id_sensor;

    -- =================================================================
    -- PASSO 1: FALHA DO SENSOR (valor fisicamente impossível)
    -- =================================================================
    IF (v_sensor.limite_min IS NOT NULL AND NEW.valor < v_sensor.limite_min)
    OR (v_sensor.limite_max IS NOT NULL AND NEW.valor > v_sensor.limite_max) THEN

        -- Abre alerta só se não houver um FALHA_SENSOR pendente
        IF NOT EXISTS (
            SELECT 1 FROM logs_alertas
            WHERE id_sensor   = NEW.id_sensor
              AND tipo_alerta = 'FALHA_SENSOR'
              AND status      = 'PENDENTE'
        ) THEN
            INSERT INTO logs_alertas
                (id_sensor, id_estacao, data_hora, valor_registrado,
                 tipo_alerta, status, id_limite, nivel)
            VALUES
                (NEW.id_sensor, v_sensor.id_estacao, NEW.data_hora, NEW.valor,
                 'FALHA_SENSOR', 'PENDENTE', NULL, 'FALHA');
        END IF;

        -- Valor inválido: não faz sentido avaliar as regras de clima.
        -- Pula direto para a atualização do status.

    ELSE
        -- Leitura fisicamente válida: se havia falha pendente, resolve
        UPDATE logs_alertas
           SET status = 'RESOLVIDO', data_resolucao = NEW.data_hora
         WHERE id_sensor   = NEW.id_sensor
           AND tipo_alerta = 'FALHA_SENSOR'
           AND status      = 'PENDENTE';

        -- =============================================================
        -- PASSO 2: REGRA MAIS GRAVE VIOLADA (limites_alerta)
        -- =============================================================
        SELECT l.id_limite,
               l.nivel,
               CASE WHEN l.limite_max IS NOT NULL AND NEW.valor > l.limite_max
                    THEN 'LIMITE_EXCEDIDO_MAX'
                    ELSE 'LIMITE_EXCEDIDO_MIN'
               END AS tipo_alerta
          INTO v_limite
          FROM limites_alerta l
         WHERE l.id_sensor = NEW.id_sensor
           AND l.ativo
           AND (   (l.limite_max IS NOT NULL AND NEW.valor > l.limite_max)
                OR (l.limite_min IS NOT NULL AND NEW.valor < l.limite_min))
         ORDER BY CASE l.nivel
                      WHEN 'CRITICO' THEN 3
                      WHEN 'ATENCAO' THEN 2
                      ELSE 1
                  END DESC
         LIMIT 1;

        v_achou_limite := FOUND;

        -- =============================================================
        -- PASSO 3: RESOLVE O QUE NÃO VALE MAIS
        -- Alertas de regra pendentes deste sensor que não são a regra
        -- violada agora viram RESOLVIDO (ex: temperatura voltou ao
        -- normal, ou passou de "Calor extremo" para só "Calor")
        -- =============================================================
        UPDATE logs_alertas
           SET status = 'RESOLVIDO', data_resolucao = NEW.data_hora
         WHERE id_sensor = NEW.id_sensor
           AND status    = 'PENDENTE'
           AND id_limite IS NOT NULL
           AND (NOT v_achou_limite OR id_limite <> v_limite.id_limite);

        -- =============================================================
        -- PASSO 4: ABRE ALERTA (SEM DUPLICAR)
        -- =============================================================
        IF v_achou_limite AND NOT EXISTS (
            SELECT 1 FROM logs_alertas
            WHERE id_sensor = NEW.id_sensor
              AND id_limite = v_limite.id_limite
              AND status    = 'PENDENTE'
        ) THEN
            INSERT INTO logs_alertas
                (id_sensor, id_estacao, data_hora, valor_registrado,
                 tipo_alerta, status, id_limite, nivel)
            VALUES
                (NEW.id_sensor, v_sensor.id_estacao, NEW.data_hora, NEW.valor,
                 v_limite.tipo_alerta, 'PENDENTE', v_limite.id_limite, v_limite.nivel);
        END IF;
    END IF;

    -- =================================================================
    -- PASSO 5: STATUS DA ESTAÇÃO (pelo alerta pendente mais grave)
    --   FALHA       -> algum sensor com defeito
    --   ALERTA      -> algum alerta ATENCAO ou CRITICO pendente
    --   OPERACIONAL -> nada pendente (ou só INFO)
    -- =================================================================
    SELECT CASE
               WHEN bool_or(nivel = 'FALHA')                    THEN 'FALHA'
               WHEN bool_or(nivel IN ('CRITICO', 'ATENCAO'))    THEN 'ALERTA'
               ELSE 'OPERACIONAL'
           END
      INTO v_status_novo
      FROM logs_alertas
     WHERE id_estacao = v_sensor.id_estacao
       AND status     = 'PENDENTE';

    -- Só grava se mudou, e nunca tira a estação de MANUTENCAO
    UPDATE estacoes
       SET status_operacional = v_status_novo
     WHERE id_estacao = v_sensor.id_estacao
       AND status_operacional IS DISTINCT FROM v_status_novo
       AND status_operacional IS DISTINCT FROM 'MANUTENCAO';

    RETURN NULL;  -- trigger AFTER: o retorno é ignorado
END;
$$;

COMMENT ON FUNCTION fn_verificar_leitura() IS
    'Verifica cada leitura nova: falha de sensor, regras de limites_alerta, abre/resolve alertas e atualiza o status da estação';

-- ---------------------------------------------------------------------
-- 3. A TRIGGER
--    AFTER INSERT: a leitura é sempre gravada; a trigger só reage.
--    FOR EACH ROW: cada leitura é verificada individualmente.
--    Criada na tabela particionada, vale para todas as partições.
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_verificar_leitura ON telemetria;

CREATE TRIGGER trg_verificar_leitura
AFTER INSERT ON telemetria
FOR EACH ROW
EXECUTE FUNCTION fn_verificar_leitura();


-- =====================================================================
-- 4. TESTE (selecione e rode bloco por bloco)
--    Usa o sensor de temperatura. Horários no futuro próximo para
--    não misturar com a carga massiva.
-- =====================================================================
/*
-- 4.1 Leitura normal (25 °C) -> nenhum alerta
INSERT INTO telemetria (id_sensor, data_hora, valor)
SELECT id_sensor, NOW() + INTERVAL '1 min', 25
FROM sensores WHERE tipo_sensor = 'TEMPERATURA_AR' AND id_estacao = 1;

-- 4.2 Calor (33 °C) -> abre "Calor" (ATENCAO), estação vira ALERTA
INSERT INTO telemetria (id_sensor, data_hora, valor)
SELECT id_sensor, NOW() + INTERVAL '2 min', 33
FROM sensores WHERE tipo_sensor = 'TEMPERATURA_AR' AND id_estacao = 1;

-- 4.3 Continua em 33 °C -> NÃO abre outro (já existe pendente)
INSERT INTO telemetria (id_sensor, data_hora, valor)
SELECT id_sensor, NOW() + INTERVAL '3 min', 33.5
FROM sensores WHERE tipo_sensor = 'TEMPERATURA_AR' AND id_estacao = 1;

-- 4.4 Sobe para 39 °C -> resolve "Calor", abre só "Calor extremo" (CRITICO)
INSERT INTO telemetria (id_sensor, data_hora, valor)
SELECT id_sensor, NOW() + INTERVAL '4 min', 39
FROM sensores WHERE tipo_sensor = 'TEMPERATURA_AR' AND id_estacao = 1;

-- 4.5 Sensor com defeito (120 °C, fora da faixa física) -> FALHA_SENSOR, estação FALHA
INSERT INTO telemetria (id_sensor, data_hora, valor)
SELECT id_sensor, NOW() + INTERVAL '5 min', 120
FROM sensores WHERE tipo_sensor = 'TEMPERATURA_AR' AND id_estacao = 1;

-- 4.6 Volta ao normal (24 °C) -> resolve tudo, estação OPERACIONAL
INSERT INTO telemetria (id_sensor, data_hora, valor)
SELECT id_sensor, NOW() + INTERVAL '6 min', 24
FROM sensores WHERE tipo_sensor = 'TEMPERATURA_AR' AND id_estacao = 1;

-- Conferir os alertas
SELECT a.id_alerta, s.tipo_sensor, l.nome AS regra, a.nivel, a.tipo_alerta,
       a.valor_registrado, a.status, a.data_hora, a.data_resolucao
FROM logs_alertas a
JOIN sensores s            ON s.id_sensor = a.id_sensor
LEFT JOIN limites_alerta l ON l.id_limite = a.id_limite
ORDER BY a.id_alerta DESC
LIMIT 20;

-- Conferir o status da estação
SELECT id_estacao, nome, status_operacional FROM estacoes;
*/
