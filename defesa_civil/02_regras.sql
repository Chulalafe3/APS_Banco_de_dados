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
    -- defesa em profundidade: mesmo um INSERT direto (fora do
    -- fn_receber_lote) não grava leitura com data no futuro
    IF NEW.data_hora > now() + make_interval(mins => fn_config('tolerancia_futuro')::INT) THEN
        RAISE EXCEPTION 'Leitura com data no futuro (%) recusada; relógio do servidor: %',
                        NEW.data_hora, now();
    END IF;

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
-- 2b. EVENTO IMUTÁVEL + RECONHECIMENTO + AVISO EM TEMPO REAL
--    - Um evento registrado não pode ser alterado nem "desreconhecido";
--      só pode passar de não reconhecido para reconhecido.
--    - Quem e quando reconheceu são preenchidos pelo banco (relógio do
--      servidor e usuário da sessão), nunca digitados.
--    - Alarmes e falhas novos avisam o painel (NOTIFY aps_tempo_real).
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_evento_antes_alterar()
RETURNS TRIGGER AS $$
BEGIN
    IF (NEW.id_dispositivo, NEW.data_hora, NEW.tipo, NEW.parametro, NEW.valor,
        NEW.id_regra, NEW.mensagem)
       IS DISTINCT FROM
       (OLD.id_dispositivo, OLD.data_hora, OLD.tipo, OLD.parametro, OLD.valor,
        OLD.id_regra, OLD.mensagem) THEN
        RAISE EXCEPTION 'Evento % é imutável: só o reconhecimento pode ser registrado', OLD.id_evento;
    END IF;

    IF OLD.reconhecido AND NOT NEW.reconhecido THEN
        RAISE EXCEPTION 'Evento % já foi reconhecido e não pode voltar a pendente', OLD.id_evento;
    END IF;

    IF NEW.reconhecido AND NOT OLD.reconhecido THEN
        NEW.reconhecido_em  := now();
        NEW.reconhecido_por := NULLIF(current_setting('app.usuario_id', TRUE), '')::INTEGER;
    ELSE
        NEW.reconhecido_em  := OLD.reconhecido_em;     -- não aceita data digitada
        NEW.reconhecido_por := OLD.reconhecido_por;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_evento_antes_alterar
BEFORE UPDATE ON evento
FOR EACH ROW EXECUTE FUNCTION fn_evento_antes_alterar();

CREATE OR REPLACE FUNCTION fn_evento_antes_inserir()
RETURNS TRIGGER AS $$
BEGIN
    NEW.reconhecido     := FALSE;      -- nasce pendente
    NEW.reconhecido_em  := NULL;
    NEW.reconhecido_por := NULL;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_evento_antes_inserir
BEFORE INSERT ON evento
FOR EACH ROW EXECUTE FUNCTION fn_evento_antes_inserir();

CREATE OR REPLACE FUNCTION fn_evento_avisar()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.tipo <> 'TRANSMISSAO_OK' AND NEW.data_hora > now() - INTERVAL '30 minutes' THEN
        PERFORM pg_notify('aps_tempo_real', json_build_object(
                    'tipo', 'evento', 'id_evento', NEW.id_evento,
                    'id_dispositivo', NEW.id_dispositivo, 'evento', NEW.tipo,
                    'mensagem', NEW.mensagem)::TEXT);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_evento_avisar
AFTER INSERT ON evento
FOR EACH ROW EXECUTE FUNCTION fn_evento_avisar();

-- Reconhece eventos (marca como vistos). Retorna quantos mudaram.
CREATE OR REPLACE FUNCTION fn_reconhecer_eventos(p_ids BIGINT[])
RETURNS INTEGER AS $$
DECLARE
    v_qtd INTEGER;
BEGIN
    UPDATE evento SET reconhecido = TRUE
     WHERE id_evento = ANY (p_ids) AND NOT reconhecido AND tipo <> 'TRANSMISSAO_OK';
    GET DIAGNOSTICS v_qtd = ROW_COUNT;
    RETURN v_qtd;
END;
$$ LANGUAGE plpgsql;

-- =====================================================================
-- 3. RECEPÇÃO DE LOTE
--    Ponto de entrada dos dados: o dispositivo envia um lote (JSON, como
--    faria por uma API) com as leituras acumuladas desde o último envio.
--
--    DATA SOMENTE EM TEMPO REAL: quem chama fn_receber_lote NÃO informa a
--    data de recebimento; o banco usa o próprio relógio (now()). A versão
--    com data informada (fn_receber_lote_interno) existe só para a carga
--    histórica do simulador e não é liberada para a aplicação (07).
--
--    Cada leitura é validada antes de gravar. Uma leitura ruim NÃO derruba
--    o lote: ela é descartada e registrada como LEITURA_REJEITADA.
--      - data ausente ou em formato inválido
--      - data no futuro (além da tolerância, em relação ao recebimento)
--      - data antiga demais (além do atraso máximo configurado)
--      - mês sem partição ativa (ex.: mês já arquivado)
--    Leituras repetidas (reenvio) são ignoradas antes das triggers, para
--    não gerar eventos de falha de sensor "fantasmas".
--
--    Exemplo de lote:
--    [{"data_hora":"2026-10-18T15:01:00-03:00","temperatura_ar":24.3,
--      "umidade_ar":68.0,"chuva":0.4,"direcao_vento":135,
--      "velocidade_vento":3.2,"radiacao_solar":512}, ...]
-- =====================================================================

-- versão antiga (data de recebimento informada pelo chamador)
DROP FUNCTION IF EXISTS fn_receber_lote(INTEGER, JSONB, TIMESTAMPTZ);

-- parâmetro numérico da tabela configuracao
CREATE OR REPLACE FUNCTION fn_config(p_chave VARCHAR)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT valor FROM configuracao WHERE chave = p_chave
$$;

-- texto -> timestamptz sem derrubar o lote se o formato for inválido
CREATE OR REPLACE FUNCTION fn_texto_para_data(p_texto TEXT)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_texto IS NULL OR p_texto !~ '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}' THEN
        RETURN NULL;
    END IF;
    RETURN p_texto::TIMESTAMPTZ;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

-- valor JSON -> numeric (número ou texto numérico; o resto vira NULL)
CREATE OR REPLACE FUNCTION fn_json_numero(p_valor JSONB)
RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE jsonb_typeof(p_valor)
                WHEN 'number' THEN (p_valor #>> '{}')::NUMERIC
                WHEN 'string' THEN CASE WHEN (p_valor #>> '{}') ~ '^\s*-?\d+(\.\d+)?\s*$'
                                        THEN (p_valor #>> '{}')::NUMERIC END
           END
$$;

-- a partição do mês está ligada à tabela leitura (e não arquivada)?
CREATE OR REPLACE FUNCTION fn_particao_ativa(p_data TIMESTAMPTZ)
RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
          FROM pg_inherits i
          JOIN pg_class c ON c.oid = i.inhrelid
         WHERE i.inhparent = 'leitura'::REGCLASS
           AND c.relname = 'leitura_' || to_char(p_data AT TIME ZONE 'America/Sao_Paulo', 'YYYYMM'))
$$;

CREATE OR REPLACE FUNCTION fn_receber_lote_interno(
    p_id_dispositivo  INTEGER,
    p_leituras        JSONB,
    p_recebido_em     TIMESTAMPTZ)
RETURNS INTEGER AS $$
DECLARE
    v_ultima       TIMESTAMPTZ;
    v_intervalo    SMALLINT;
    v_minutos      NUMERIC;
    v_tol_futuro   INTERVAL := make_interval(mins => fn_config('tolerancia_futuro')::INT);
    v_atraso_max   INTERVAL := make_interval(days => fn_config('atraso_maximo')::INT);
    v_tol_transm   INTEGER  := fn_config('tolerancia_transmissao')::INT;
    v_qtd          INTEGER  := 0;
    v_total        INTEGER;
    v_repetidas    INTEGER;
    v_rejeitadas   INTEGER;
BEGIN
    IF jsonb_typeof(p_leituras) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'Lote inválido: esperado um array JSON de leituras';
    END IF;

    SELECT ultima_comunicacao, intervalo_transmissao_min
      INTO v_ultima, v_intervalo
      FROM dispositivo
     WHERE id_dispositivo = p_id_dispositivo AND ativo
       FOR UPDATE;                         -- um lote por vez por dispositivo

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Dispositivo % não existe ou está inativo', p_id_dispositivo;
    END IF;

    -- falha de transmissão: lote atrasado
    IF v_ultima IS NOT NULL
       AND p_recebido_em - v_ultima > make_interval(mins => v_intervalo + v_tol_transm)
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

    -- Uma única instrução (CTEs):
    --   lote   -> lê o JSON (formato inválido vira NULL, não derruba o lote)
    --   meses  -> partição ativa? (consulta 1 vez por mês, não por leitura)
    --   class  -> motivo de rejeição de cada leitura (NULL = válida)
    --   rej    -> um evento LEITURA_REJEITADA por motivo, com quantidade
    --   ins    -> grava as válidas e NOVAS, em ordem de tempo. Repetidas
    --             (já no banco ou duplicadas no lote) ficam de fora ANTES
    --             das triggers: o reenvio não gera evento nenhum.
    WITH lote AS MATERIALIZED (
        SELECT fn_texto_para_data(x ->> 'data_hora')    AS data_hora,
               x ->> 'data_hora'                        AS texto_data,
               fn_json_numero(x -> 'temperatura_ar')    AS temperatura_ar,
               fn_json_numero(x -> 'umidade_ar')        AS umidade_ar,
               fn_json_numero(x -> 'chuva')             AS chuva,
               fn_json_numero(x -> 'direcao_vento')     AS direcao_vento,
               fn_json_numero(x -> 'velocidade_vento')  AS velocidade_vento,
               fn_json_numero(x -> 'radiacao_solar')    AS radiacao_solar
          FROM jsonb_array_elements(p_leituras) AS x
    ),
    meses AS MATERIALIZED (
        SELECT m.mes, fn_particao_ativa(m.mes) AS ativa
          FROM (SELECT DISTINCT date_trunc('month', data_hora AT TIME ZONE 'America/Sao_Paulo')
                                    AT TIME ZONE 'America/Sao_Paulo' AS mes
                  FROM lote WHERE data_hora IS NOT NULL) m
    ),
    class AS MATERIALIZED (
        SELECT l.*,
               CASE WHEN l.data_hora IS NULL                        THEN 'data ausente ou inválida'
                    WHEN l.data_hora > p_recebido_em + v_tol_futuro THEN 'data no futuro'
                    WHEN l.data_hora < p_recebido_em - v_atraso_max THEN 'data antiga demais'
                    WHEN NOT m.ativa                                THEN 'mês sem partição ativa'
               END AS motivo
          FROM lote l
          LEFT JOIN meses m
            ON m.mes = date_trunc('month', l.data_hora AT TIME ZONE 'America/Sao_Paulo')
                           AT TIME ZONE 'America/Sao_Paulo'
    ),
    rej AS (
        INSERT INTO evento (id_dispositivo, data_hora, tipo, valor, mensagem)
        SELECT p_id_dispositivo, p_recebido_em, 'LEITURA_REJEITADA', COUNT(*),
               left(format('%s leitura(s) rejeitada(s): %s (ex.: %s). O restante do lote foi gravado.',
                           COUNT(*), motivo, MIN(COALESCE(texto_data, '(sem data)'))), 250)
          FROM class
         WHERE motivo IS NOT NULL
         GROUP BY motivo
        RETURNING valor
    ),
    ins AS (
        INSERT INTO leitura (id_dispositivo, data_hora, temperatura_ar, umidade_ar, chuva,
                             direcao_vento, velocidade_vento, radiacao_solar, recebido_em)
        SELECT p_id_dispositivo, t.data_hora, t.temperatura_ar, t.umidade_ar, t.chuva,
               t.direcao_vento, t.velocidade_vento, t.radiacao_solar, p_recebido_em
          FROM (SELECT DISTINCT ON (data_hora) *
                  FROM class WHERE motivo IS NULL
                 ORDER BY data_hora) t
         WHERE NOT EXISTS (SELECT 1 FROM leitura l
                            WHERE l.id_dispositivo = p_id_dispositivo
                              AND l.data_hora = t.data_hora)
         ORDER BY t.data_hora
        ON CONFLICT (id_dispositivo, data_hora) DO NOTHING
        RETURNING 1
    )
    SELECT (SELECT COUNT(*) FROM lote),
           COALESCE((SELECT SUM(valor) FROM rej), 0),
           (SELECT COUNT(*) FROM ins)
      INTO v_total, v_rejeitadas, v_qtd;

    v_repetidas := v_total - v_rejeitadas - v_qtd;

    INSERT INTO evento (id_dispositivo, data_hora, tipo, valor, mensagem)
    VALUES (p_id_dispositivo, p_recebido_em, 'TRANSMISSAO_OK', v_qtd,
            format('Lote recebido com %s leituras (%s gravadas, %s repetidas, %s rejeitadas).',
                   v_total, v_qtd, v_repetidas, v_rejeitadas));

    UPDATE dispositivo
       SET ultima_comunicacao = p_recebido_em
     WHERE id_dispositivo = p_id_dispositivo;

    -- aviso em tempo real para o painel (LISTEN aps_tempo_real), só para
    -- dados "ao vivo" (a carga histórica não gera aviso)
    IF p_recebido_em > now() - INTERVAL '5 minutes' THEN
        PERFORM pg_notify('aps_tempo_real', json_build_object(
                    'tipo', 'lote', 'id_dispositivo', p_id_dispositivo,
                    'gravadas', v_qtd, 'rejeitadas', v_rejeitadas)::TEXT);
    END IF;

    RETURN v_qtd;
END;
$$ LANGUAGE plpgsql;

-- Versão pública: a data de recebimento é SEMPRE o relógio do servidor
CREATE OR REPLACE FUNCTION fn_receber_lote(
    p_id_dispositivo  INTEGER,
    p_leituras        JSONB)
RETURNS INTEGER
LANGUAGE sql AS $$
    SELECT fn_receber_lote_interno(p_id_dispositivo, p_leituras, now())
$$;

-- =====================================================================
-- 4. VERIFICAÇÃO DE COMUNICAÇÃO "AO VIVO"
--    Em produção roda a cada poucos minutos (agendador). Marca FALHA nos
--    dispositivos que passaram do prazo sem enviar lote.
-- =====================================================================
DROP FUNCTION IF EXISTS fn_verificar_comunicacao(TIMESTAMPTZ);
CREATE OR REPLACE FUNCTION fn_verificar_comunicacao()
RETURNS INTEGER AS $$
DECLARE
    p_agora TIMESTAMPTZ := now();          -- relógio do servidor, nunca informado
    d       RECORD;
    v_qtd   INTEGER := 0;
    v_min   NUMERIC;
BEGIN
    FOR d IN
        SELECT * FROM dispositivo
         WHERE ativo
           AND ultima_comunicacao IS NOT NULL
           AND p_agora - ultima_comunicacao > make_interval(mins => intervalo_transmissao_min
                                                         + fn_config('tolerancia_transmissao')::INT)
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

-- Manutenção: garante o mês atual e os N meses seguintes (configuração
-- meses_particoes_futuras). Roda no agendador do servidor e no
-- arquivamento, para que a virada do mês nunca encontre a tabela sem
-- partição (antes: em jan/2027 toda transmissão falharia).
CREATE OR REPLACE PROCEDURE sp_manter_particoes()
LANGUAGE plpgsql AS $$
BEGIN
    CALL sp_criar_particoes(CURRENT_DATE, 1 + fn_config('meses_particoes_futuras')::INT);
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
DROP PROCEDURE IF EXISTS sp_arquivar_dados(DATE, INTEGER);
CREATE OR REPLACE PROCEDURE sp_arquivar_dados()
LANGUAGE plpgsql AS $$
DECLARE
    -- referência = hoje no relógio do servidor (não é informada)
    v_corte   DATE := (date_trunc('month', CURRENT_DATE)
                       - make_interval(months => fn_config('meses_dados_recentes')::INT - 1))::DATE;
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

    CALL sp_manter_particoes();
    CALL sp_atualizar_resumo_horario();
END;
$$;
