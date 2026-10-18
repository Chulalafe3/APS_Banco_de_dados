-- =====================================================================
-- APS - 03_simulador.sql
-- O "dispositivo": gera uma leitura por minuto e transmite em lotes de
-- 10 minutos chamando fn_receber_lote (o mesmo caminho de um dado real).
--
-- O que ele simula:
--   * dia e noite (radiação, temperatura, umidade, vento)
--   * estação do ano (inverno mais frio e seco)
--   * dias de chuva à tarde
--   * um DIA DE TEMPORAL (chuva forte e vento) para disparar alarmes
--   * FALHA DE TRANSMISSÃO: lote não enviado; os dados ficam guardados
--     e seguem junto com o lote seguinte (como um datalogger real)
--   * FALHA DE SENSOR: código de erro -9999 em um parâmetro
-- =====================================================================

CREATE OR REPLACE PROCEDURE sp_simular_dispositivo(
    p_id_dispositivo         INTEGER,
    p_inicio                 TIMESTAMPTZ,
    p_fim                    TIMESTAMPTZ,
    p_dia_temporal           DATE    DEFAULT NULL,
    p_prob_falha_transmissao NUMERIC DEFAULT 0.02,    -- 2% dos lotes
    p_prob_falha_sensor      NUMERIC DEFAULT 0.005,   -- 0,5% das leituras
    p_ajuste_temperatura     NUMERIC DEFAULT 0)       -- diferença entre estações
LANGUAGE plpgsql AS $$
DECLARE
    v_t             TIMESTAMPTZ := date_trunc('minute', p_inicio);
    v_local         TIMESTAMP;
    v_dia           DATE := NULL;
    v_hora          NUMERIC;
    v_doy           INTEGER;
    v_mes           INTEGER;
    v_sol           NUMERIC;
    v_temporal      BOOLEAN;
    v_dia_chuvoso   BOOLEAN;
    v_inicio_chuva  NUMERIC;
    v_dir_dia       NUMERIC;
    v_secura        NUMERIC;
    v_temp_base     NUMERIC;
    v_chovendo      BOOLEAN;
    v_chuva         NUMERIC;
    v_temp          NUMERIC;
    v_umid          NUMERIC;
    v_vento         NUMERIC;
    v_dir           NUMERIC;
    v_rad           NUMERIC;
    v_leitura       JSONB;
    v_falha         TEXT;
    v_lote          JSONB := '[]'::JSONB;
    v_intervalo     INTEGER;
BEGIN
    SELECT intervalo_transmissao_min INTO v_intervalo
      FROM dispositivo WHERE id_dispositivo = p_id_dispositivo;

    WHILE v_t < p_fim LOOP
        v_local := v_t AT TIME ZONE 'America/Sao_Paulo';

        -- sorteios que valem para o dia inteiro
        IF v_dia IS DISTINCT FROM v_local::DATE THEN
            v_dia      := v_local::DATE;
            v_doy      := EXTRACT(DOY FROM v_local);
            v_mes      := EXTRACT(MONTH FROM v_local);
            v_temporal := (v_dia = p_dia_temporal);
            -- inverno (jun-ago) chove menos
            v_dia_chuvoso  := random() < CASE WHEN v_mes IN (6, 7, 8) THEN 0.10
                                              WHEN v_mes IN (5, 9)    THEN 0.20
                                              ELSE 0.30 END;
            v_inicio_chuva := 14 + random() * 3;            -- chuva começa entre 14h e 17h
            v_dir_dia      := 60 + random() * 120;          -- vento predominante do dia
            v_secura       := 15 + random() * 17;           -- tardes secas no inverno
            -- temperatura média: ~24 °C no verão, ~16 °C no inverno
            v_temp_base    := 20 + 4 * COS(2 * PI() * (v_doy - 15) / 365.0) + p_ajuste_temperatura;
        END IF;

        v_hora := EXTRACT(HOUR FROM v_local) + EXTRACT(MINUTE FROM v_local) / 60.0;
        v_sol  := GREATEST(0, SIN(PI() * (v_hora - 6) / 12));   -- 0 à noite, 1 ao meio-dia

        -- chuva
        IF v_temporal THEN
            v_chovendo := v_hora BETWEEN 14 AND 18;
            v_chuva    := CASE WHEN v_chovendo THEN 0.1 + random() * 0.5 ELSE 0 END;  -- ~80 mm em 4 h
        ELSE
            v_chovendo := v_dia_chuvoso AND v_hora BETWEEN v_inicio_chuva AND v_inicio_chuva + 1.5;
            v_chuva    := CASE WHEN v_chovendo AND random() < 0.6 THEN random() * 0.4 ELSE 0 END;
        END IF;

        v_temp := v_temp_base - 4 + 9 * v_sol + (random() - 0.5)
                  - CASE WHEN v_chovendo THEN 3 ELSE 0 END;
        v_umid := 95 - 45 * v_sol + random() * 4
                  - CASE WHEN v_mes IN (7, 8, 9) THEN v_secura * v_sol ELSE 0 END   -- inverno seco
                  + CASE WHEN v_chovendo THEN 25 ELSE 0 END;
        v_umid := LEAST(100, GREATEST(10, v_umid));
        v_rad  := 1000 * v_sol * (0.85 + random() * 0.15)
                  * CASE WHEN v_chovendo THEN 0.25 WHEN v_dia_chuvoso THEN 0.7 ELSE 1 END;
        v_vento := 1.5 + 3 * v_sol + random() * 1.5;
        v_dir   := v_dir_dia + (random() - 0.5) * 60;

        IF v_temporal AND v_hora BETWEEN 14.5 AND 16 THEN
            v_vento := 12 + random() * 12;                 -- rajadas de até ~24 m/s
            v_dir   := 200 + (random() - 0.5) * 40;        -- frente fria (sudoeste)
        END IF;

        v_leitura := jsonb_build_object(
            'data_hora',        v_t,
            'temperatura_ar',   ROUND(v_temp, 2),
            'umidade_ar',       ROUND(v_umid, 2),
            'chuva',            ROUND(v_chuva, 2),
            'direcao_vento',    ROUND(((v_dir + 360)::NUMERIC % 360), 1),
            'velocidade_vento', ROUND(v_vento, 2),
            'radiacao_solar',   ROUND(v_rad, 2));

        -- falha de sensor: código de erro em um parâmetro sorteado
        IF random() < p_prob_falha_sensor THEN
            v_falha := (ARRAY['temperatura_ar', 'umidade_ar', 'chuva',
                              'direcao_vento', 'velocidade_vento', 'radiacao_solar'])
                       [1 + floor(random() * 6)::INT];
            v_leitura := jsonb_set(v_leitura, ARRAY[v_falha], '-9999'::JSONB);
        END IF;

        v_lote := v_lote || v_leitura;

        -- fim da janela de 10 minutos: tenta transmitir
        IF EXTRACT(MINUTE FROM v_local)::INT % v_intervalo = v_intervalo - 1 THEN
            IF random() >= p_prob_falha_transmissao THEN
                PERFORM fn_receber_lote(p_id_dispositivo, v_lote,
                                        v_t + INTERVAL '1 minute' + random() * INTERVAL '40 seconds');
                v_lote := '[]'::JSONB;
                COMMIT;
            END IF;
            -- se falhou, o lote continua acumulando e vai junto no próximo envio
        END IF;

        v_t := v_t + INTERVAL '1 minute';
    END LOOP;

    -- envia o que sobrou
    IF jsonb_array_length(v_lote) > 0 THEN
        PERFORM fn_receber_lote(p_id_dispositivo, v_lote, p_fim);
    END IF;
    COMMIT;
END;
$$;
