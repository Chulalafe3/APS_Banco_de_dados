-- =====================================================================
-- APS - 02_regras.sql
-- Triggers, recepção de lotes, verificação de comunicação,
-- partições e ciclo de vida dos dados (Data Lifecycle)
-- =====================================================================

-- =====================================================================
-- 1. TRIGGER ANTES DE GRAVAR A LEITURA
--    a) FALHA DE SENSOR: valor fora da faixa física do sensor é anulado
--       (vira NULL) e o valor original fica registrado no evento.
--    b) CHUVA ACUMULADA: soma a chuva do minuto ao acumulado do dia
--       (zera à meia-noite, horário de Brasília).
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_leitura_antes_inserir()
RETURNS TRIGGER AS $$
DECLARE
    v_linha       JSONB   := to_jsonb(NEW);
    v_alterou     BOOLEAN := FALSE;
    s             RECORD;
    v_valor       NUMERIC;
    v_inicio_dia  TIMESTAMPTZ;
    v_acum_ant    NUMERIC;
BEGIN
    -- a) falha de sensor
    FOR s IN
        SELECT parametro, unidade, limite_min, limite_max
          FROM sensor
         WHERE id_dispositivo = NEW.id_dispositivo AND ativo
    LOOP
        v_valor := (v_linha ->> s.parametro)::NUMERIC;

        IF v_valor IS NOT NULL AND (v_valor < s.limite_min OR v_valor > s.limite_max) THEN
            INSERT INTO evento (id_dispositivo, data_hora, tipo, parametro, valor, mensagem)
            VALUES (NEW.id_dispositivo, NEW.data_hora, 'FALHA_SENSOR', s.parametro, v_valor,
                    format('Falha de sensor: %s = %s fora da faixa válida [%s ; %s] %s. Valor descartado.',
                           s.parametro, v_valor, s.limite_min, s.limite_max, s.unidade));

            v_linha   := jsonb_set(v_linha, ARRAY[s.parametro], 'null'::JSONB);
            v_alterou := TRUE;
        END IF;
    END LOOP;

    IF v_alterou THEN
        NEW := jsonb_populate_record(NEW, v_linha);
    END IF;

    -- b) chuva acumulada do dia: pega só a leitura anterior (usa o índice)
    v_inicio_dia := date_trunc('day', NEW.data_hora AT TIME ZONE 'America/Sao_Paulo')
                    AT TIME ZONE 'America/Sao_Paulo';

    SELECT l.chuva_acumulada
      INTO v_acum_ant
      FROM leitura l
     WHERE l.id_dispositivo = NEW.id_dispositivo
       AND l.data_hora >= v_inicio_dia
       AND l.data_hora <  NEW.data_hora
     ORDER BY l.data_hora DESC
     LIMIT 1;

    NEW.chuva_acumulada := COALESCE(v_acum_ant, 0) + COALESCE(NEW.chuva, 0);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_leitura_antes_inserir
BEFORE INSERT ON leitura
FOR EACH ROW EXECUTE FUNCTION fn_leitura_antes_inserir();

-- =====================================================================
-- 2. TRIGGER DEPOIS DE GRAVAR A LEITURA (trigger de segurança)
--    a) ALARME: compara com as regras do cliente. Só dispara quando o
--       valor CRUZA o limite (antes estava normal, agora não está) e
--       não houve alarme da mesma regra na última hora.
--    b) STATUS: atualiza o status do dispositivo
--       FALHA (falha de sensor nesta leitura) > ALERTA (regra violada)
--       > OPERACIONAL.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_leitura_depois_inserir()
RETURNS TRIGGER AS $$
DECLARE
    v_atual      JSONB := to_jsonb(NEW);
    v_anterior   JSONB;
    r            RECORD;
    v_valor      NUMERIC;
    v_valor_ant  NUMERIC;
    v_viola      BOOLEAN;
    v_violava    BOOLEAN;
    v_em_alerta  BOOLEAN := FALSE;
    v_em_falha   BOOLEAN;
    v_status     VARCHAR(12);
BEGIN
    -- leitura anterior do mesmo dispositivo (para saber se o limite foi cruzado agora)
    SELECT to_jsonb(l)
      INTO v_anterior
      FROM leitura l
     WHERE l.id_dispositivo = NEW.id_dispositivo
       AND l.data_hora < NEW.data_hora
     ORDER BY l.data_hora DESC
     LIMIT 1;

    -- a) alarmes
    FOR r IN
        SELECT * FROM regra_alarme
         WHERE id_dispositivo = NEW.id_dispositivo AND ativo
    LOOP
        v_valor := (v_atual ->> r.parametro)::NUMERIC;
        CONTINUE WHEN v_valor IS NULL;

        v_viola := CASE r.condicao WHEN 'ACIMA' THEN v_valor > r.limite
                                   ELSE v_valor < r.limite END;
        CONTINUE WHEN NOT v_viola;

        v_em_alerta := TRUE;

        v_valor_ant := (v_anterior ->> r.parametro)::NUMERIC;
        v_violava := COALESCE(CASE r.condicao WHEN 'ACIMA' THEN v_valor_ant > r.limite
                                              ELSE v_valor_ant < r.limite END, FALSE);

        -- dispara só na virada (antes normal, agora não) e no máximo 1 vez
        -- por hora para a mesma regra, evitando repetição quando o valor
        -- oscila em torno do limite (ex.: rajadas de vento)
        IF NOT v_violava AND NOT EXISTS (
               SELECT 1 FROM evento e
                WHERE e.id_dispositivo = NEW.id_dispositivo
                  AND e.tipo = 'ALARME'
                  AND e.id_regra = r.id_regra
                  AND e.data_hora > NEW.data_hora - INTERVAL '1 hour'
                  AND e.data_hora <= NEW.data_hora) THEN
            INSERT INTO evento (id_dispositivo, data_hora, tipo, parametro, valor, id_regra, mensagem)
            VALUES (NEW.id_dispositivo, NEW.data_hora, 'ALARME', r.parametro, v_valor, r.id_regra,
                    format('[%s] %s %s do limite %s (valor: %s). Nota: %s',
                           r.nivel, r.parametro, lower(r.condicao), r.limite, v_valor,
                           COALESCE(r.nota, '-')));
        END IF;
    END LOOP;

    -- b) status do dispositivo
    v_em_falha := EXISTS (
        SELECT 1 FROM evento e
         WHERE e.id_dispositivo = NEW.id_dispositivo
           AND e.data_hora = NEW.data_hora
           AND e.tipo = 'FALHA_SENSOR');

    v_status := CASE WHEN v_em_falha  THEN 'FALHA'
                     WHEN v_em_alerta THEN 'ALERTA'
                     ELSE 'OPERACIONAL' END;

    UPDATE dispositivo
       SET status = v_status
     WHERE id_dispositivo = NEW.id_dispositivo
       AND status IS DISTINCT FROM v_status;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_leitura_depois_inserir
AFTER INSERT ON leitura
FOR EACH ROW EXECUTE FUNCTION fn_leitura_depois_inserir();

-- =====================================================================
-- 3. RECEPÇÃO DE LOTE
--    Ponto de entrada dos dados: o dispositivo envia um lote (JSON, como
--    faria por uma API) com as leituras acumuladas desde o último envio.
--    - registra TRANSMISSAO_OK
--    - detecta FALHA_TRANSMISSAO quando o lote chega atrasado
--      (mais que o intervalo de transmissão + 5 min de tolerância)
--
--    Exemplo de lote:
--    [{"data_hora":"2026-10-18T15:01:00-03:00","temperatura_ar":24.3,
--      "umidade_ar":68.0,"chuva":0.4,"direcao_vento":135,
--      "velocidade_vento":3.2,"radiacao_solar":512}, ...]
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_receber_lote(
    p_id_dispositivo  INTEGER,
    p_leituras        JSONB,
    p_recebido_em     TIMESTAMPTZ DEFAULT now())
RETURNS INTEGER AS $$
DECLARE
    v_ultima      TIMESTAMPTZ;
    v_intervalo   SMALLINT;
    v_minutos     NUMERIC;
    v_qtd         INTEGER;
BEGIN
    SELECT ultima_comunicacao, intervalo_transmissao_min
      INTO v_ultima, v_intervalo
      FROM dispositivo
     WHERE id_dispositivo = p_id_dispositivo AND ativo
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Dispositivo % não existe ou está inativo', p_id_dispositivo;
    END IF;

    -- falha de transmissão: lote atrasado
    IF v_ultima IS NOT NULL
       AND p_recebido_em - v_ultima > make_interval(mins => v_intervalo + 5)
       -- não duplica se a verificação ao vivo já registrou a falha
       AND NOT EXISTS (SELECT 1 FROM evento e
                        WHERE e.id_dispositivo = p_id_dispositivo
                          AND e.tipo = 'FALHA_TRANSMISSAO'
                          AND e.data_hora > v_ultima) THEN
        v_minutos := ROUND(EXTRACT(EPOCH FROM p_recebido_em - v_ultima) / 60);
        INSERT INTO evento (id_dispositivo, data_hora, tipo, valor, mensagem)
        VALUES (p_id_dispositivo, p_recebido_em, 'FALHA_TRANSMISSAO', v_minutos,
                format('Falha de transmissão: %s min sem comunicação (esperado a cada %s min). '
                       'Dados recuperados no lote seguinte.', v_minutos, v_intervalo));
    END IF;

    -- grava as leituras em ordem de tempo (as triggers rodam em cada linha)
    INSERT INTO leitura (id_dispositivo, data_hora, temperatura_ar, umidade_ar, chuva,
                         direcao_vento, velocidade_vento, radiacao_solar, recebido_em)
    SELECT p_id_dispositivo, x.data_hora, x.temperatura_ar, x.umidade_ar, x.chuva,
           x.direcao_vento, x.velocidade_vento, x.radiacao_solar, p_recebido_em
      FROM jsonb_to_recordset(p_leituras) AS x(
               data_hora TIMESTAMPTZ, temperatura_ar NUMERIC, umidade_ar NUMERIC,
               chuva NUMERIC, direcao_vento NUMERIC, velocidade_vento NUMERIC,
               radiacao_solar NUMERIC)
     ORDER BY x.data_hora
    ON CONFLICT (id_dispositivo, data_hora) DO NOTHING;   -- reenvio não duplica

    GET DIAGNOSTICS v_qtd = ROW_COUNT;

    INSERT INTO evento (id_dispositivo, data_hora, tipo, valor, mensagem)
    VALUES (p_id_dispositivo, p_recebido_em, 'TRANSMISSAO_OK', v_qtd,
            format('Lote recebido com %s leituras.', v_qtd));

    UPDATE dispositivo
       SET ultima_comunicacao = p_recebido_em
     WHERE id_dispositivo = p_id_dispositivo;

    RETURN v_qtd;
END;
$$ LANGUAGE plpgsql;

-- =====================================================================
-- 4. VERIFICAÇÃO DE COMUNICAÇÃO "AO VIVO"
--    Em produção roda a cada poucos minutos (agendador). Marca FALHA nos
--    dispositivos que passaram do prazo sem enviar lote.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_verificar_comunicacao(p_agora TIMESTAMPTZ DEFAULT now())
RETURNS INTEGER AS $$
DECLARE
    d       RECORD;
    v_qtd   INTEGER := 0;
    v_min   NUMERIC;
BEGIN
    FOR d IN
        SELECT * FROM dispositivo
         WHERE ativo
           AND ultima_comunicacao IS NOT NULL
           AND p_agora - ultima_comunicacao > make_interval(mins => intervalo_transmissao_min + 5)
    LOOP
        CONTINUE WHEN EXISTS (SELECT 1 FROM evento e
                               WHERE e.id_dispositivo = d.id_dispositivo
                                 AND e.tipo = 'FALHA_TRANSMISSAO'
                                 AND e.data_hora > d.ultima_comunicacao);

        v_min := ROUND(EXTRACT(EPOCH FROM p_agora - d.ultima_comunicacao) / 60);
        INSERT INTO evento (id_dispositivo, data_hora, tipo, valor, mensagem)
        VALUES (d.id_dispositivo, p_agora, 'FALHA_TRANSMISSAO', v_min,
                format('Falha de transmissão: dispositivo atrasado %s min (esperado a cada %s min).',
                       v_min, d.intervalo_transmissao_min));

        UPDATE dispositivo SET status = 'FALHA' WHERE id_dispositivo = d.id_dispositivo;
        v_qtd := v_qtd + 1;
    END LOOP;
    RETURN v_qtd;
END;
$$ LANGUAGE plpgsql;

-- =====================================================================
-- 5. PARTIÇÕES MENSAIS
--    Cria as partições leitura_AAAAMM a partir de p_inicio (se não existirem).
-- =====================================================================
CREATE OR REPLACE PROCEDURE sp_criar_particoes(p_inicio DATE, p_meses INTEGER DEFAULT 3)
LANGUAGE plpgsql AS $$
DECLARE
    v_mes   DATE := date_trunc('month', p_inicio)::DATE;
    v_nome  TEXT;
    i       INTEGER;
BEGIN
    FOR i IN 1..p_meses LOOP
        v_nome := 'leitura_' || to_char(v_mes, 'YYYYMM');
        IF to_regclass(v_nome) IS NULL THEN
            EXECUTE format(
                'CREATE TABLE %I PARTITION OF leitura FOR VALUES FROM (%L) TO (%L)',
                v_nome,
                (v_mes::TIMESTAMP AT TIME ZONE 'America/Sao_Paulo'),
                ((v_mes + INTERVAL '1 month')::TIMESTAMP AT TIME ZONE 'America/Sao_Paulo'));
        END IF;
        v_mes := (v_mes + INTERVAL '1 month')::DATE;
    END LOOP;
END;
$$;

-- =====================================================================
-- 6. ATUALIZAÇÃO DA VIEW MATERIALIZADA
-- =====================================================================
CREATE OR REPLACE PROCEDURE sp_atualizar_resumo_horario()
LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT ispopulated FROM pg_matviews WHERE matviewname = 'mv_resumo_horario') THEN
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_resumo_horario;
    ELSE
        REFRESH MATERIALIZED VIEW mv_resumo_horario;
    END IF;
END;
$$;

-- =====================================================================
-- 7. CICLO DE VIDA DOS DADOS (Data Lifecycle)
--    Mantém na tabela leitura o mês atual e o anterior (>= 30 dias).
--    Para cada mês mais antigo:
--      1) gera o resumo diário em leitura_diaria
--      2) DETACH da tabela leitura
--      3) ATTACH na tabela leitura_arquivo
--    O mês inteiro muda de tabela de uma vez, sem DELETE linha a linha.
-- =====================================================================
CREATE OR REPLACE PROCEDURE sp_arquivar_dados(
    p_referencia    DATE    DEFAULT CURRENT_DATE,
    p_meses_manter  INTEGER DEFAULT 2)
LANGUAGE plpgsql AS $$
DECLARE
    v_corte   DATE := (date_trunc('month', p_referencia)
                       - make_interval(months => p_meses_manter - 1))::DATE;
    p         RECORD;
    v_mes     DATE;
    v_ini     TIMESTAMPTZ;
    v_linhas  BIGINT;
    v_dias    INTEGER;
BEGIN
    FOR p IN
        SELECT c.relname
          FROM pg_inherits i
          JOIN pg_class c ON c.oid = i.inhrelid
         WHERE i.inhparent = 'leitura'::REGCLASS
           AND c.relname ~ '^leitura_[0-9]{6}$'
         ORDER BY c.relname
    LOOP
        v_mes := to_date(substr(p.relname, 9), 'YYYYMM');
        CONTINUE WHEN (v_mes + INTERVAL '1 month')::DATE > v_corte;

        v_ini := clock_timestamp();

        -- 1) resumo diário
        EXECUTE format($sql$
            INSERT INTO leitura_diaria
            SELECT id_dispositivo,
                   (data_hora AT TIME ZONE 'America/Sao_Paulo')::DATE,
                   MIN(temperatura_ar), MAX(temperatura_ar), ROUND(AVG(temperatura_ar), 2),
                   MIN(umidade_ar),     MAX(umidade_ar),     ROUND(AVG(umidade_ar), 2),
                   SUM(chuva),
                   ROUND(AVG(velocidade_vento), 2), MAX(velocidade_vento),
                   -- média vetorial da direção (a média simples de 350° e 10° daria 180°)
                   ROUND(MOD((DEGREES(ATAN2(AVG(SIN(RADIANS(direcao_vento))),
                                            AVG(COS(RADIANS(direcao_vento))))) + 360)::NUMERIC, 360), 1),
                   ROUND(AVG(radiacao_solar), 2), MAX(radiacao_solar),
                   COUNT(*),
                   SUM((temperatura_ar IS NULL)::INT + (umidade_ar IS NULL)::INT
                     + (chuva IS NULL)::INT + (direcao_vento IS NULL)::INT
                     + (velocidade_vento IS NULL)::INT + (radiacao_solar IS NULL)::INT)
              FROM %I
             GROUP BY id_dispositivo, (data_hora AT TIME ZONE 'America/Sao_Paulo')::DATE
            ON CONFLICT (id_dispositivo, dia) DO NOTHING
        $sql$, p.relname);
        GET DIAGNOSTICS v_dias = ROW_COUNT;

        EXECUTE format('SELECT COUNT(*) FROM %I', p.relname) INTO v_linhas;

        -- 2) e 3) move a partição inteira para o arquivo
        EXECUTE format('ALTER TABLE leitura DETACH PARTITION %I', p.relname);
        EXECUTE format('ALTER TABLE leitura_arquivo ATTACH PARTITION %I FOR VALUES FROM (%L) TO (%L)',
                       p.relname,
                       (v_mes::TIMESTAMP AT TIME ZONE 'America/Sao_Paulo'),
                       ((v_mes + INTERVAL '1 month')::TIMESTAMP AT TIME ZONE 'America/Sao_Paulo'));

        INSERT INTO log_arquivamento (particao, linhas_movidas, dias_resumidos, duracao_ms)
        VALUES (p.relname, v_linhas, v_dias,
                EXTRACT(EPOCH FROM clock_timestamp() - v_ini) * 1000);

        RAISE NOTICE 'Arquivado %: % leituras, % dias resumidos.', p.relname, v_linhas, v_dias;
    END LOOP;

    CALL sp_atualizar_resumo_horario();
END;
$$;
