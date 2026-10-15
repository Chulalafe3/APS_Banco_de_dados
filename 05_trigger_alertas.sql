-- =====================================================================
-- 05_trigger_alertas.sql
-- APS Independente - LPBD (UNIP)
-- Trigger de segurança: detecção de falhas e alertas em tempo real
--
-- Rode a carga histórica DEPOIS deste script (ver README):
--   CALL sp_gerar_historico(1, 3);
-- Assim cada leitura histórica passa pela trigger, como passaria
-- em produção, e o banco já nasce com um histórico de alertas real.
--
-- Cada linha da telemetria traz todos os sensores da estação naquele
-- minuto (uma coluna por sensor). A trigger percorre os sensores
-- ativos da estação, pega o valor da coluna de cada um
-- (coluna = tipo_sensor em minúsculas) e, para cada sensor:
--   1. FALHA DO SENSOR: valor fora da faixa física do aparelho
--      (sensores.limite_min / limite_max) -> alerta FALHA_SENSOR
--   2. EVENTO METEOROLÓGICO: valor viola alguma regra de
--      limites_alerta -> grava só a regra MAIS GRAVE violada
--   3. Não duplica: se já existe alerta PENDENTE da mesma regra,
--      não abre outro
--   4. Volta ao normal: alertas pendentes que não valem mais
--      viram RESOLVIDO
-- No fim, uma vez por linha:
--   5. Atualiza estacoes.status_operacional:
--      FALHA > ALERTA > OPERACIONAL (MANUTENCAO nunca é sobrescrito)
-- Coluna NULL (sensor não enviou leitura) é ignorada.
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
    v_linha         JSONB := to_jsonb(NEW);   -- a linha inteira, para ler a coluna de cada sensor
    v_sensor        sensores%ROWTYPE;
    v_valor         NUMERIC;
    v_limite        RECORD;
    v_achou_limite  BOOLEAN;
    v_status_novo   VARCHAR(20);
BEGIN
    FOR v_sensor IN
        SELECT * FROM sensores
        WHERE id_estacao = NEW.id_estacao
          AND ativo
        ORDER BY id_sensor
    LOOP
        -- valor deste sensor = coluna com o nome do tipo_sensor
        v_valor := (v_linha ->> lower(v_sensor.tipo_sensor))::NUMERIC;

        -- sensor sem leitura neste minuto: nada a verificar
        CONTINUE WHEN v_valor IS NULL;

        -- =============================================================
        -- PASSO 1: FALHA DO SENSOR (valor fisicamente impossível)
        -- =============================================================
        IF (v_sensor.limite_min IS NOT NULL AND v_valor < v_sensor.limite_min)
        OR (v_sensor.limite_max IS NOT NULL AND v_valor > v_sensor.limite_max) THEN

            -- Abre alerta só se não houver um FALHA_SENSOR pendente
            IF NOT EXISTS (
                SELECT 1 FROM logs_alertas
                WHERE id_sensor   = v_sensor.id_sensor
                  AND tipo_alerta = 'FALHA_SENSOR'
                  AND status      = 'PENDENTE'
            ) THEN
                INSERT INTO logs_alertas
                    (id_sensor, id_estacao, data_hora, valor_registrado,
                     tipo_alerta, status, id_limite, nivel)
                VALUES
                    (v_sensor.id_sensor, NEW.id_estacao, NEW.data_hora, v_valor,
                     'FALHA_SENSOR', 'PENDENTE', NULL, 'FALHA');
            END IF;

            -- Valor inválido: não faz sentido avaliar as regras de clima.
            -- Segue para o próximo sensor.
            CONTINUE;
        END IF;

        -- Leitura fisicamente válida: se havia falha pendente, resolve
        UPDATE logs_alertas
           SET status = 'RESOLVIDO', data_resolucao = NEW.data_hora
         WHERE id_sensor   = v_sensor.id_sensor
           AND tipo_alerta = 'FALHA_SENSOR'
           AND status      = 'PENDENTE';

        -- =============================================================
        -- PASSO 2: REGRA MAIS GRAVE VIOLADA (limites_alerta)
        -- =============================================================
        SELECT l.id_limite,
               l.nivel,
               CASE WHEN l.limite_max IS NOT NULL AND v_valor > l.limite_max
                    THEN 'LIMITE_EXCEDIDO_MAX'
                    ELSE 'LIMITE_EXCEDIDO_MIN'
               END AS tipo_alerta
          INTO v_limite
          FROM limites_alerta l
         WHERE l.id_sensor = v_sensor.id_sensor
           AND l.ativo
           AND (   (l.limite_max IS NOT NULL AND v_valor > l.limite_max)
                OR (l.limite_min IS NOT NULL AND v_valor < l.limite_min))
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
         WHERE id_sensor = v_sensor.id_sensor
           AND status    = 'PENDENTE'
           AND id_limite IS NOT NULL
           AND (NOT v_achou_limite OR id_limite <> v_limite.id_limite);

        -- =============================================================
        -- PASSO 4: ABRE ALERTA (SEM DUPLICAR)
        -- =============================================================
        IF v_achou_limite AND NOT EXISTS (
            SELECT 1 FROM logs_alertas
            WHERE id_sensor = v_sensor.id_sensor
              AND id_limite = v_limite.id_limite
              AND status    = 'PENDENTE'
        ) THEN
            INSERT INTO logs_alertas
                (id_sensor, id_estacao, data_hora, valor_registrado,
                 tipo_alerta, status, id_limite, nivel)
            VALUES
                (v_sensor.id_sensor, NEW.id_estacao, NEW.data_hora, v_valor,
                 v_limite.tipo_alerta, 'PENDENTE', v_limite.id_limite, v_limite.nivel);
        END IF;
    END LOOP;

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
     WHERE id_estacao = NEW.id_estacao
       AND status     = 'PENDENTE';

    -- Só grava se mudou, e nunca tira a estação de MANUTENCAO
    UPDATE estacoes
       SET status_operacional = v_status_novo
     WHERE id_estacao = NEW.id_estacao
       AND status_operacional IS DISTINCT FROM v_status_novo
       AND status_operacional IS DISTINCT FROM 'MANUTENCAO';

    RETURN NULL;  -- trigger AFTER: o retorno é ignorado
END;
$$;

COMMENT ON FUNCTION fn_verificar_leitura() IS
    'Verifica cada linha nova da telemetria, sensor por sensor: falha de sensor, regras de limites_alerta, abre/resolve alertas e atualiza o status da estação';

-- ---------------------------------------------------------------------
-- 3. A TRIGGER
--    AFTER INSERT: a leitura é sempre gravada; a trigger só reage.
--    FOR EACH ROW: cada minuto da estação é verificado individualmente.
--    Criada na tabela particionada, vale para todas as partições.
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_verificar_leitura ON telemetria;

CREATE TRIGGER trg_verificar_leitura
AFTER INSERT ON telemetria
FOR EACH ROW
EXECUTE FUNCTION fn_verificar_leitura();


-- =====================================================================
-- 4. TESTE (selecione e rode bloco por bloco)
--    Usa só a coluna de temperatura (as outras ficam NULL e são
--    ignoradas). Horários no futuro próximo para não misturar com a
--    carga massiva.
-- =====================================================================
/*
-- 4.1 Leitura normal (25 °C) -> nenhum alerta
INSERT INTO telemetria (id_estacao, data_hora, temperatura_ar)
VALUES (1, date_trunc('minute', NOW()) + INTERVAL '1 min', 25);

-- 4.2 Calor (33 °C) -> abre "Calor" (ATENCAO), estação vira ALERTA
INSERT INTO telemetria (id_estacao, data_hora, temperatura_ar)
VALUES (1, date_trunc('minute', NOW()) + INTERVAL '2 min', 33);

-- 4.3 Continua em 33 °C -> NÃO abre outro (já existe pendente)
INSERT INTO telemetria (id_estacao, data_hora, temperatura_ar)
VALUES (1, date_trunc('minute', NOW()) + INTERVAL '3 min', 33.5);

-- 4.4 Sobe para 39 °C -> resolve "Calor", abre só "Calor extremo" (CRITICO)
INSERT INTO telemetria (id_estacao, data_hora, temperatura_ar)
VALUES (1, date_trunc('minute', NOW()) + INTERVAL '4 min', 39);

-- 4.5 Sensor com defeito (120 °C, fora da faixa física) -> FALHA_SENSOR, estação FALHA
INSERT INTO telemetria (id_estacao, data_hora, temperatura_ar)
VALUES (1, date_trunc('minute', NOW()) + INTERVAL '5 min', 120);

-- 4.6 Volta ao normal (24 °C) -> resolve tudo, estação OPERACIONAL
INSERT INTO telemetria (id_estacao, data_hora, temperatura_ar)
VALUES (1, date_trunc('minute', NOW()) + INTERVAL '6 min', 24);

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
