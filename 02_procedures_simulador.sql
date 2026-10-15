-- =====================================================================
-- APS Independente (LPBD) — Banco de Dados de Telemetria IoT
-- Etapa 2: Geração de Dados (Simulador de Fluxo)
--
-- Os valores seguem o comportamento real de uma estação meteorológica:
--   - ciclo do dia: mais frio de madrugada, mais quente ~15h;
--     umidade do ar sobe quando a temperatura cai; radiação solar só
--     de dia; vento mais forte à tarde; pressão com a "maré" de 12 h
--   - "clima do dia": cada dia sorteia se é seco, quente, ventoso ou
--     chuvoso. O sorteio é fixo por data, então a carga histórica e a
--     transmissão ao vivo concordam entre si
--   - falha de sensor: com probabilidade p_prob_anomalia a leitura sai
--     fora da faixa física do aparelho (testa a trigger de FALHA)
-- =====================================================================

-- ---------------------------------------------------------------------
-- FUNCTION AUXILIAR 1: número "aleatório" fixo por dia
-- Mesmo dia + mesma semente = sempre o mesmo número entre 0 e 1.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sorteio_dia(p_data DATE, p_semente INTEGER)
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT (('x' || substr(md5(p_data::TEXT || '-' || p_semente), 1, 8))::BIT(32)::BIGINT
            & 2147483647)::NUMERIC / 2147483647;
$$;

-- ---------------------------------------------------------------------
-- FUNCTION AUXILIAR 2: gera o valor de um sensor num instante
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_gerar_valor_sensor(VARCHAR, NUMERIC, NUMERIC, NUMERIC);

CREATE OR REPLACE FUNCTION fn_gerar_valor_sensor(
    p_tipo_sensor   VARCHAR,
    p_limite_min    NUMERIC,
    p_limite_max    NUMERIC,
    p_data_hora     TIMESTAMP,
    p_prob_anomalia NUMERIC DEFAULT 0.0005
) RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_dia      DATE    := p_data_hora::DATE;
    v_h        NUMERIC := EXTRACT(HOUR FROM p_data_hora) + EXTRACT(MINUTE FROM p_data_hora) / 60.0;
    -- clima do dia (sorteios fixos por data)
    v_chuvoso  BOOLEAN := fn_sorteio_dia(v_dia, 1) < 0.25;     -- ~1 em cada 4 dias chove
    v_calor    NUMERIC := fn_sorteio_dia(v_dia, 2);            -- 0 = dia ameno, 1 = dia muito quente
    v_secura   NUMERIC := fn_sorteio_dia(v_dia, 3);            -- 0 = úmido, 1 = muito seco
    v_vento    NUMERIC := fn_sorteio_dia(v_dia, 4);            -- 0 = calmo, 1 = muito ventoso
    v_dir_dia  NUMERIC := fn_sorteio_dia(v_dia, 5) * 360;      -- direção predominante
    v_press    NUMERIC := fn_sorteio_dia(v_dia, 6);
    -- variáveis de trabalho
    v_tmin     NUMERIC;
    v_tmax     NUMERIC;
    v_temp     NUMERIC;
    v_frac     NUMERIC;   -- 0 = hora mais fria, 1 = hora mais quente
    v_urmin    NUMERIC;
    v_vel      NUMERIC;
    v_valor    NUMERIC;
BEGIN
    -- -----------------------------------------------------------------
    -- Falha de sensor: valor fora da faixa física do aparelho
    -- (direção do vento é circular, não tem "fora da faixa")
    -- -----------------------------------------------------------------
    IF p_tipo_sensor <> 'DIRECAO_VENTO'
       AND (p_limite_min IS NOT NULL OR p_limite_max IS NOT NULL)
       AND random() < p_prob_anomalia THEN
        IF p_limite_max IS NOT NULL AND (p_limite_min IS NULL OR random() < 0.5) THEN
            RETURN round(p_limite_max + 1 + random()::NUMERIC * 20, 2);
        ELSE
            RETURN round(p_limite_min - 1 - random()::NUMERIC * 20, 2);
        END IF;
    END IF;

    -- -----------------------------------------------------------------
    -- Curva da temperatura do dia (base para vários sensores)
    -- mínima ~6h, máxima ~15h
    -- -----------------------------------------------------------------
    v_tmin := 14 + 4 * v_calor - CASE WHEN v_chuvoso THEN 1 ELSE 0 END;
    v_tmax := v_tmin + 8 + 10 * v_calor - CASE WHEN v_chuvoso THEN 6 ELSE 0 END;

    IF v_h >= 6 AND v_h < 15 THEN
        v_frac := 0.5 - 0.5 * cos(pi() * (v_h - 6) / 9);         -- subindo
    ELSIF v_h >= 15 THEN
        v_frac := 0.5 + 0.5 * cos(pi() * (v_h - 15) / 15);       -- descendo
    ELSE
        v_frac := 0.5 + 0.5 * cos(pi() * (v_h + 9) / 15);        -- madrugada
    END IF;

    v_temp := v_tmin + (v_tmax - v_tmin) * v_frac;

    CASE p_tipo_sensor
        WHEN 'TEMPERATURA_AR' THEN
            v_valor := v_temp + (random() - 0.5) * 0.4;

        WHEN 'UMIDADE_AR' THEN
            -- inversa da temperatura: ~95% de madrugada, mínima à tarde
            v_urmin := CASE WHEN v_chuvoso THEN 70 + 15 * random()
                            ELSE 55 - 35 * v_secura END;
            v_valor := 95 - (95 - v_urmin) * v_frac + (random() - 0.5) * 0.6;
            v_valor := LEAST(GREATEST(v_valor, 5), 100);

        WHEN 'VELOCIDADE_VENTO', 'RAJADA_VENTO' THEN
            -- vento médio do dia + reforço à tarde + turbulência
            v_vel := 1 + 4 * v_vento * v_vento
                     + 3 * v_vento * GREATEST(sin(pi() * (v_h - 9) / 12), 0)
                     + random() * 1.5;
            IF p_tipo_sensor = 'RAJADA_VENTO' THEN
                v_vel := v_vel * (1.4 + random() * 0.6) + random() * 2;
            END IF;
            v_valor := v_vel;

        WHEN 'DIRECAO_VENTO' THEN
            v_valor := v_dir_dia + (random() - 0.5) * 90;          -- ±45° em volta da predominante
            v_valor := mod(v_valor + 360, 360);

        WHEN 'PRESSAO_BAROMETRICA' THEN
            -- pressão reduzida ao nível do mar (como as estações informam)
            -- maré barométrica (2 picos/dia) + frente fria em dia de chuva
            v_valor := 1015 + 6 * (v_press - 0.5)
                       + 1.2 * cos(4 * pi() * (v_h - 10) / 24)
                       - CASE WHEN v_chuvoso THEN 3 ELSE 0 END
                       + (random() - 0.5) * 0.2;

        WHEN 'RADIACAO_SOLAR' THEN
            IF v_h <= 6 OR v_h >= 18 THEN
                v_valor := 0;
            ELSE
                v_valor := (CASE WHEN v_chuvoso THEN 250 ELSE 950 END)
                           * sin(pi() * (v_h - 6) / 12)
                           * (0.75 + random() * 0.25);              -- nuvens passando
            END IF;

        WHEN 'PLUVIOMETRO' THEN
            -- mm no minuto: só em dia chuvoso, mais à tarde/noite
            IF v_chuvoso AND v_h BETWEEN 13 AND 21 AND random() < 0.30 THEN
                v_valor := random() * 0.8;
            ELSE
                v_valor := 0;
            END IF;

        WHEN 'UMIDADE_SOLO' THEN
            -- muda devagar: depende do clima do dia e seca um pouco à tarde
            v_valor := CASE WHEN v_chuvoso THEN 40 + 10 * v_secura
                            ELSE 38 - 22 * v_secura END
                       - 1.5 * v_frac
                       + (random() - 0.5) * 0.1;

        ELSE
            v_valor := 50 + (random() - 0.5) * 10;
    END CASE;

    RETURN round(v_valor, 2);
END;
$$;

COMMENT ON FUNCTION fn_gerar_valor_sensor(VARCHAR, NUMERIC, NUMERIC, TIMESTAMP, NUMERIC) IS
    'Valor simulado e realista de um sensor num instante (ciclo do dia + clima do dia + falhas raras)';

-- ---------------------------------------------------------------------
-- PROCEDURE 1: CARGA DE UM PERÍODO (1 linha por minuto)
-- Insere tudo de uma vez (set-based, com generate_series).
-- Para cada minuto, gera o valor de cada sensor ativo da estação e
-- coloca cada um na sua coluna (temperatura_ar, umidade_ar, ...).
-- Sensor inativo fica NULL.
-- Para períodos longos use sp_gerar_historico, que chama esta
-- procedure mês a mês.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_gerar_carga_massiva(
    p_id_estacao    INTEGER,
    p_data_inicio   TIMESTAMP,
    p_data_fim      TIMESTAMP,
    p_prob_anomalia NUMERIC DEFAULT 0.0005
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_qtd_inserida BIGINT;
BEGIN
    INSERT INTO telemetria (id_estacao, data_hora,
        temperatura_ar, umidade_ar, velocidade_vento, direcao_vento, rajada_vento,
        pressao_barometrica, radiacao_solar, pluviometro, umidade_solo)
    SELECT
        p_id_estacao,
        gs AS data_hora,
        max(v.valor) FILTER (WHERE v.tipo_sensor = 'TEMPERATURA_AR'),
        max(v.valor) FILTER (WHERE v.tipo_sensor = 'UMIDADE_AR'),
        max(v.valor) FILTER (WHERE v.tipo_sensor = 'VELOCIDADE_VENTO'),
        max(v.valor) FILTER (WHERE v.tipo_sensor = 'DIRECAO_VENTO'),
        max(v.valor) FILTER (WHERE v.tipo_sensor = 'RAJADA_VENTO'),
        max(v.valor) FILTER (WHERE v.tipo_sensor = 'PRESSAO_BAROMETRICA'),
        max(v.valor) FILTER (WHERE v.tipo_sensor = 'RADIACAO_SOLAR'),
        max(v.valor) FILTER (WHERE v.tipo_sensor = 'PLUVIOMETRO'),
        max(v.valor) FILTER (WHERE v.tipo_sensor = 'UMIDADE_SOLO')
    FROM generate_series(date_trunc('minute', p_data_inicio),
                         date_trunc('minute', p_data_fim),
                         INTERVAL '1 minute') AS gs
    CROSS JOIN LATERAL (
        SELECT s.tipo_sensor,
               fn_gerar_valor_sensor(s.tipo_sensor, s.limite_min, s.limite_max,
                                     gs, p_prob_anomalia) AS valor
        FROM sensores s
        WHERE s.id_estacao = p_id_estacao
          AND s.ativo = TRUE
    ) AS v
    GROUP BY gs
    ORDER BY gs                       -- em ordem de tempo, como chegaria da estação
    ON CONFLICT DO NOTHING;           -- minutos que já existem são ignorados

    GET DIAGNOSTICS v_qtd_inserida = ROW_COUNT;
    RAISE NOTICE 'Carga concluída: % minutos inseridos (estação %, % a %)',
        v_qtd_inserida, p_id_estacao, p_data_inicio, p_data_fim;
END;
$$;

-- ---------------------------------------------------------------------
-- PROCEDURE 2: HISTÓRICO DE VÁRIOS MESES, MÊS A MÊS
-- - cria as partições que faltarem
-- - gera um mês por vez e faz COMMIT ao fim de cada um
--   (se der erro no mês 3, os meses 1 e 2 já ficaram salvos)
-- - mostra quanto tempo cada mês levou (dado para a Etapa 6)
-- Precisa ser chamada com CALL fora de BEGIN/COMMIT
-- (no pgAdmin, com Auto commit ligado, que é o padrão).
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_gerar_historico(
    p_id_estacao    INTEGER,
    p_meses         INTEGER DEFAULT 3,
    p_prob_anomalia NUMERIC DEFAULT 0.0005
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fim_total  TIMESTAMP := date_trunc('minute', LOCALTIMESTAMP);
    v_inicio     TIMESTAMP := v_fim_total - make_interval(months => p_meses);
    v_fim_lote   TIMESTAMP;
    v_relogio    TIMESTAMP;
BEGIN
    CALL sp_criar_particoes_periodo(v_inicio, v_fim_total);
    COMMIT;

    WHILE v_inicio < v_fim_total LOOP
        -- lote vai até o início do próximo mês (ou até agora)
        v_fim_lote := LEAST(date_trunc('month', v_inicio) + INTERVAL '1 month',
                            v_fim_total + INTERVAL '1 minute');
        v_relogio  := clock_timestamp();

        CALL sp_gerar_carga_massiva(p_id_estacao, v_inicio,
                                    v_fim_lote - INTERVAL '1 minute', p_prob_anomalia);
        COMMIT;

        RAISE NOTICE '  -> mês % gravado em % s', to_char(v_inicio, 'YYYY-MM'),
            round(EXTRACT(EPOCH FROM clock_timestamp() - v_relogio)::NUMERIC, 1);

        v_inicio := v_fim_lote;
    END LOOP;
END;
$$;

COMMENT ON PROCEDURE sp_gerar_historico(INTEGER, INTEGER, NUMERIC) IS
    'Gera p_meses de histórico até agora, um mês por transação';

-- ---------------------------------------------------------------------
-- PROCEDURE 3: TRANSMISSÃO PERIÓDICA (comportamento real da estação)
-- A estação mede 1x por minuto e envia o lote dos últimos 10 minutos.
-- Pensada para ser chamada a cada 10 minutos na demonstração ao vivo.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_transmitir_leituras(
    p_id_estacao    INTEGER,
    p_prob_anomalia NUMERIC DEFAULT 0.0005
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fim    TIMESTAMP := date_trunc('minute', LOCALTIMESTAMP);
    v_inicio TIMESTAMP := v_fim - INTERVAL '9 minutes';
BEGIN
    CALL sp_gerar_carga_massiva(p_id_estacao, v_inicio, v_fim, p_prob_anomalia);
END;
$$;

-- ---------------------------------------------------------------------
-- EXEMPLOS DE USO
-- ---------------------------------------------------------------------
-- Histórico de 3 meses, mês a mês (rodar depois do 05, ver README):
-- CALL sp_gerar_historico(1, 3);

-- Um período específico:
-- CALL sp_gerar_carga_massiva(1, '2026-10-01', '2026-10-01 23:59');

-- Transmissão simulada de um ciclo (10 min) para a estação 1:
-- CALL sp_transmitir_leituras(1);
