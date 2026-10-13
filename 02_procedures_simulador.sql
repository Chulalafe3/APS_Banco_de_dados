-- =====================================================================
-- APS Independente (LPBD) — Banco de Dados de Telemetria IoT
-- Etapa 2: Geração de Dados (Simulador de Fluxo)
-- =====================================================================

-- ---------------------------------------------------------------------
-- FUNCTION AUXILIAR: gera um valor plausível por tipo de sensor
-- Com probabilidade p_prob_anomalia, gera de propósito um valor
-- fora do limite configurado (para testar a trigger de alerta).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_gerar_valor_sensor(
    p_tipo_sensor   VARCHAR,
    p_limite_min    NUMERIC,
    p_limite_max    NUMERIC,
    p_prob_anomalia NUMERIC DEFAULT 0.02
) RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_base      NUMERIC;
    v_variacao  NUMERIC;
BEGIN
    -- valor base e variação "normal" esperada por tipo de sensor
    CASE p_tipo_sensor
        WHEN 'TEMPERATURA_AR'      THEN v_base := 24;   v_variacao := 6;
        WHEN 'UMIDADE_AR'          THEN v_base := 60;   v_variacao := 20;
        WHEN 'VELOCIDADE_VENTO'    THEN v_base := 8;    v_variacao := 5;
        WHEN 'RAJADA_VENTO'        THEN v_base := 12;   v_variacao := 8;
        WHEN 'DIRECAO_VENTO'       THEN v_base := 180;  v_variacao := 180; -- 0–360°, sem anomalia
        WHEN 'PRESSAO_BAROMETRICA' THEN v_base := 1013; v_variacao := 8;
        WHEN 'RADIACAO_SOLAR'      THEN v_base := 500;  v_variacao := 400;
        WHEN 'PLUVIOMETRO'         THEN v_base := 0;    v_variacao := 3;
        WHEN 'UMIDADE_SOLO'        THEN v_base := 35;   v_variacao := 15;
        ELSE                            v_base := 50;   v_variacao := 10;
    END CASE;

    -- direção do vento é circular (0–360°): qualquer valor é válido,
    -- não faz sentido gerar "anomalia" por limite aqui
    IF p_tipo_sensor = 'DIRECAO_VENTO' THEN
        RETURN v_base + (random() - 0.5) * 2 * v_variacao; -- uniforme em 0–360
    END IF;

    IF random() < p_prob_anomalia THEN
        -- gera valor fora do limite de propósito
        IF random() < 0.5 THEN
            RETURN COALESCE(p_limite_max, v_base + v_variacao) + (random() * v_variacao);
        ELSE
            RETURN GREATEST(COALESCE(p_limite_min, v_base - v_variacao) - (random() * v_variacao), 0);
        END IF;
    ELSE
        -- valor normal, dentro da faixa esperada
        RETURN GREATEST(v_base + (random() - 0.5) * 2 * v_variacao, 0);
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- PROCEDURE 1: CARGA EM MASSA (teste de estresse de escrita)
-- Gera leituras de 1 em 1 minuto, para todos os sensores ativos
-- de uma estação, entre duas datas. Uso: popular meses de histórico
-- de uma vez para os testes de volume/performance da Etapa 6.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_gerar_carga_massiva(
    p_id_estacao    INTEGER,
    p_data_inicio   TIMESTAMP,
    p_data_fim      TIMESTAMP,
    p_prob_anomalia NUMERIC DEFAULT 0.02
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_qtd_inserida BIGINT;
BEGIN
    INSERT INTO telemetria (id_sensor, data_hora, valor)
    SELECT
        s.id_sensor,
        gs AS data_hora,
        fn_gerar_valor_sensor(s.tipo_sensor, s.limite_min, s.limite_max, p_prob_anomalia)
    FROM sensores s
    CROSS JOIN generate_series(p_data_inicio, p_data_fim, INTERVAL '1 minute') AS gs
    WHERE s.id_estacao = p_id_estacao
      AND s.ativo = TRUE;

    GET DIAGNOSTICS v_qtd_inserida = ROW_COUNT;
    RAISE NOTICE 'Carga em massa concluída: % leituras inseridas (estação %, % a %)',
        v_qtd_inserida, p_id_estacao, p_data_inicio, p_data_fim;
END;
$$;

-- ---------------------------------------------------------------------
-- PROCEDURE 2: TRANSMISSÃO PERIÓDICA (comportamento real da estação)
-- Simula a estação "enviando" o lote acumulado dos últimos 10 minutos
-- (1 leitura/minuto). Pensada para ser chamada a cada 10 minutos
-- durante a demonstração ao vivo.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_transmitir_leituras(
    p_id_estacao INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fim    TIMESTAMP := date_trunc('minute', NOW());
    v_inicio TIMESTAMP := v_fim - INTERVAL '9 minutes';
BEGIN
    INSERT INTO telemetria (id_sensor, data_hora, valor)
    SELECT
        s.id_sensor,
        gs AS data_hora,
        fn_gerar_valor_sensor(s.tipo_sensor, s.limite_min, s.limite_max, 0.05)
    FROM sensores s
    CROSS JOIN generate_series(v_inicio, v_fim, INTERVAL '1 minute') AS gs
    WHERE s.id_estacao = p_id_estacao
      AND s.ativo = TRUE;

    RAISE NOTICE 'Transmissão concluída: leituras de % até % (estação %)',
        v_inicio, v_fim, p_id_estacao;
END;
$$;

-- ---------------------------------------------------------------------
-- EXEMPLOS DE USO
-- ---------------------------------------------------------------------
-- Carga em massa: 30 dias de histórico para a estação 1
-- CALL sp_gerar_carga_massiva(1, NOW() - INTERVAL '30 days', NOW(), 0.02);

-- Transmissão simulada de um ciclo (10 min) para a estação 1
-- CALL sp_transmitir_leituras(1);
