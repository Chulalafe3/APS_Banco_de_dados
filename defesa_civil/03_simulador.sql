-- =====================================================================
-- APS - 03_simulador.sql
-- O "dispositivo": gera uma leitura por minuto e transmite em lotes de
-- 10 minutos pelo mesmo caminho de um dado real (fn_receber_lote).
--
-- O que ele simula:
--   * dia e noite (radiação, temperatura, umidade, vento)
--   * estação do ano (inverno mais frio e seco)
--   * dias de chuva à tarde
--   * um DIA DE TEMPORAL (chuva forte e vento) para disparar alarmes
--   * FALHA DE TRANSMISSÃO: lote não enviado; os dados ficam guardados
--     e seguem junto com o lote seguinte (como um datalogger real)
--   * FALHA DE SENSOR: código de erro -9999 em um parâmetro
--
-- Partes:
--   fn_simular_leituras        modelo do tempo: devolve as leituras (JSON)
--                              de um intervalo, sem gravar nada
--   sp_simular_dispositivo     carga HISTÓRICA (usa fn_receber_lote_interno,
--                              com a data de recebimento do passado)
--   fn_simular_tempo_real      "datalogger ao vivo": chamado pelo servidor
--                              a cada 10 min, transmite pelo fn_receber_lote
--                              público (data = relógio do servidor)
-- =====================================================================

-- ---------------------------------------------------------------------
-- Sorteio determinístico em [0, 1): o mesmo dia dá sempre o mesmo valor.
-- Assim o tempo de um dia é coerente mesmo gerado em pedaços de 10 min
-- (tempo real), e as duas estações (3 km de distância) compartilham o
-- clima da cidade: chovem nos mesmos dias, com o mesmo vento predominante.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sorteio_dia(p_dia DATE, p_chave TEXT)
RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$
    SELECT ('x' || substr(md5(p_dia::TEXT || '|' || p_chave), 1, 8))::BIT(32)::BIGINT
           / 4294967296.0
$$;

-- ---------------------------------------------------------------------
-- MODELO DO TEMPO: leituras de 1 em 1 minuto em [p_inicio, p_fim)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_simular_leituras(
    p_inicio              TIMESTAMPTZ,
    p_fim                 TIMESTAMPTZ,
    p_dia_temporal        DATE    DEFAULT NULL,
    p_prob_falha_sensor   NUMERIC DEFAULT 0.005,   -- 0,5% das leituras
    p_ajuste_temperatura  NUMERIC DEFAULT 0)       -- diferença entre estações
RETURNS JSONB
LANGUAGE plpgsql VOLATILE AS $$
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
BEGIN
    WHILE v_t < p_fim LOOP
        v_local := v_t AT TIME ZONE 'America/Sao_Paulo';

        -- sorteios que valem para o dia inteiro (clima da cidade)
        IF v_dia IS DISTINCT FROM v_local::DATE THEN
            v_dia      := v_local::DATE;
            v_doy      := EXTRACT(DOY FROM v_local);
            v_mes      := EXTRACT(MONTH FROM v_local);
            v_temporal := (v_dia = p_dia_temporal);
            -- inverno (jun-ago) chove menos
            v_dia_chuvoso  := fn_sorteio_dia(v_dia, 'chuva')
                              < CASE WHEN v_mes IN (6, 7, 8) THEN 0.10
                                     WHEN v_mes IN (5, 9)    THEN 0.20
                                     ELSE 0.30 END;
            v_inicio_chuva := 14 + fn_sorteio_dia(v_dia, 'inicio') * 3;   -- entre 14h e 17h
            v_dir_dia      := 60 + fn_sorteio_dia(v_dia, 'direcao') * 120; -- vento predominante
            v_secura       := 15 + fn_sorteio_dia(v_dia, 'secura') * 17;   -- tardes secas no inverno
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
        v_t := v_t + INTERVAL '1 minute';
    END LOOP;

    RETURN v_lote;
END;
$$;

-- ---------------------------------------------------------------------
-- CARGA HISTÓRICA: simula o período [p_inicio, p_fim) janela a janela.
-- Usa fn_receber_lote_interno (data de recebimento no passado), que só
-- o administrador do banco pode executar (07_seguranca.sql).
-- Faz COMMIT a cada lote: rode pelo PSQL Tool, não pela Query Tool.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_simular_dispositivo(
    p_id_dispositivo         INTEGER,
    p_inicio                 TIMESTAMPTZ,
    p_fim                    TIMESTAMPTZ,
    p_dia_temporal           DATE    DEFAULT NULL,
    p_prob_falha_transmissao NUMERIC DEFAULT 0.02,    -- 2% dos lotes
    p_prob_falha_sensor      NUMERIC DEFAULT 0.005,   -- 0,5% das leituras
    p_ajuste_temperatura     NUMERIC DEFAULT NULL)    -- NULL = o do dispositivo
LANGUAGE plpgsql AS $$
DECLARE
    v_intervalo   INTEGER;
    v_ajuste      NUMERIC;
    v_ini_janela  TIMESTAMPTZ := date_trunc('minute', p_inicio);
    v_fim_janela  TIMESTAMPTZ;
    v_lote        JSONB := '[]'::JSONB;
BEGIN
    SELECT intervalo_transmissao_min,
           COALESCE(p_ajuste_temperatura, ajuste_temperatura_sim)
      INTO v_intervalo, v_ajuste
      FROM dispositivo WHERE id_dispositivo = p_id_dispositivo;

    WHILE v_ini_janela < p_fim LOOP
        -- janelas alinhadas ao relógio: hh:00-hh:09, hh:10-hh:19, ...
        v_fim_janela := LEAST(p_fim,
            date_trunc('hour', v_ini_janela)
            + make_interval(mins => (EXTRACT(MINUTE FROM v_ini_janela)::INT / v_intervalo + 1) * v_intervalo));

        v_lote := v_lote || fn_simular_leituras(v_ini_janela, v_fim_janela, p_dia_temporal,
                                                p_prob_falha_sensor, v_ajuste);

        -- fim da janela: tenta transmitir (se falhar, acumula para o próximo)
        IF v_fim_janela < p_fim AND random() >= p_prob_falha_transmissao THEN
            PERFORM fn_receber_lote_interno(p_id_dispositivo, v_lote,
                                            v_fim_janela + random() * INTERVAL '40 seconds');
            v_lote := '[]'::JSONB;
            COMMIT;
        END IF;

        v_ini_janela := v_fim_janela;
    END LOOP;

    -- envia o que sobrou
    IF jsonb_array_length(v_lote) > 0 THEN
        PERFORM fn_receber_lote_interno(p_id_dispositivo, v_lote, p_fim);
    END IF;
    COMMIT;
END;
$$;

-- ---------------------------------------------------------------------
-- TEMPO REAL: para cada estação ativa, gera as leituras desde a última
-- recebida até o minuto atual e transmite pelo fn_receber_lote público
-- (data de recebimento = relógio do servidor). O servidor web chama a
-- cada 10 min; p_forcar = TRUE ignora a falha de transmissão sorteada.
-- Se o servidor ficou desligado, recupera no máximo o atraso permitido
-- (configuracao.atraso_maximo); o buraco anterior fica sem dados, como
-- num datalogger que perdeu a memória.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_simular_tempo_real(
    p_forcar                 BOOLEAN DEFAULT FALSE,
    p_prob_falha_transmissao NUMERIC DEFAULT 0.02)
RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    d         RECORD;
    v_desde   TIMESTAMPTZ;
    v_ate     TIMESTAMPTZ := date_trunc('minute', now());
    v_limite  TIMESTAMPTZ := date_trunc('minute', now())
                             - make_interval(days => fn_config('atraso_maximo')::INT)
                             + INTERVAL '10 minutes';
    v_total   INTEGER := 0;
BEGIN
    FOR d IN
        SELECT id_dispositivo, ajuste_temperatura_sim,
               (SELECT MAX(l.data_hora) FROM leitura l
                 WHERE l.id_dispositivo = dp.id_dispositivo) AS ultima
          FROM dispositivo dp
         WHERE ativo AND simulado
         ORDER BY id_dispositivo
    LOOP
        v_desde := GREATEST(COALESCE(d.ultima + INTERVAL '1 minute', v_ate - INTERVAL '10 minutes'),
                            v_limite);
        CONTINUE WHEN v_desde >= v_ate;
        CONTINUE WHEN NOT p_forcar AND random() < p_prob_falha_transmissao;  -- falhou: vai no próximo

        v_total := v_total + fn_receber_lote(
                       d.id_dispositivo,
                       fn_simular_leituras(v_desde, v_ate, NULL, 0.005, d.ajuste_temperatura_sim));
    END LOOP;
    RETURN v_total;
END;
$$;
