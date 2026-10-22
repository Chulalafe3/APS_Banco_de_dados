-- =====================================================================
-- APS - 07_seguranca.sql
-- Segurança de dados críticos: usuários, sessões, papéis de mínimo
-- privilégio, isolamento por cliente (RLS), auditoria à prova de
-- adulteração e registro de backups.
--
-- Rodar DEPOIS do 01 a 05 (o rodar_tudo.sql já inclui). Precisa ser
-- executado por um superusuário (postgres): cria papéis e extensões.
--
-- Princípio: o banco NÃO confia em quem a aplicação diz ser. A aplicação
-- só repassa o TOKEN da sessão (set_config('app.sessao', token, true));
-- o próprio banco valida o token e descobre usuário, perfil e cliente.
-- Um invasor que tome o servidor web não consegue se passar por outro
-- usuário nem ver dados de outro cliente sem um token válido.
-- =====================================================================
SET client_min_messages TO WARNING;
-- durante a própria instalação, os comandos de estrutura não são
-- auditados um a um (fica um único registro SEGURANCA_INSTALADA no fim)
SET app.instalando = 'on';
CREATE EXTENSION IF NOT EXISTS pgcrypto;          -- crypt/bcrypt, digest, gen_random_bytes

-- =====================================================================
-- 1. TABELAS
-- =====================================================================

-- USUARIO: pessoas que usam o painel
--   ADMIN        tudo, inclusive usuários, auditoria, backups e configuração
--   OPERADOR     reconhece eventos e ajusta regras de alarme e sensores
--   VISUALIZADOR só consulta
-- id_cliente NULL = enxerga todos os clientes (só para ADMIN)
CREATE TABLE IF NOT EXISTS usuario (
    id_usuario         SERIAL        PRIMARY KEY,
    nome               VARCHAR(100)  NOT NULL,
    login              VARCHAR(40)   NOT NULL,
    senha_hash         TEXT          NOT NULL,          -- bcrypt (nunca a senha)
    perfil             VARCHAR(12)   NOT NULL CHECK (perfil IN ('ADMIN', 'OPERADOR', 'VISUALIZADOR')),
    id_cliente         INTEGER       REFERENCES cliente(id_cliente),
    ativo              BOOLEAN       NOT NULL DEFAULT TRUE,
    trocar_senha       BOOLEAN       NOT NULL DEFAULT TRUE,  -- obriga troca no 1º acesso
    tentativas_falhas  SMALLINT      NOT NULL DEFAULT 0,
    bloqueado_ate      TIMESTAMPTZ,
    criado_em          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    senha_alterada_em  TIMESTAMPTZ   NOT NULL DEFAULT now(),
    ultimo_login       TIMESTAMPTZ,
    CONSTRAINT ck_usuario_cliente CHECK (perfil = 'ADMIN' OR id_cliente IS NOT NULL),
    CONSTRAINT ck_usuario_login   CHECK (login ~ '^[a-z0-9._-]{3,40}$')
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_usuario_login ON usuario (lower(login));

-- SESSAO: só o hash SHA-256 do token fica no banco
CREATE TABLE IF NOT EXISTS sessao (
    id_sessao     BIGSERIAL     PRIMARY KEY,
    token_hash    BYTEA         NOT NULL UNIQUE,
    id_usuario    INTEGER       NOT NULL REFERENCES usuario(id_usuario),
    criada_em     TIMESTAMPTZ   NOT NULL DEFAULT now(),
    ultimo_uso    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    expira_em     TIMESTAMPTZ   NOT NULL,
    encerrada_em  TIMESTAMPTZ,
    ip            VARCHAR(45),
    agente        VARCHAR(200)
);

-- AUDITORIA: append-only, encadeada por hash (cada linha guarda o hash
-- da anterior). Alterar ou apagar uma linha quebra a corrente, e
-- fn_verificar_auditoria() aponta onde.
CREATE TABLE IF NOT EXISTS auditoria (
    id_auditoria   BIGINT        PRIMARY KEY,
    data_hora      TIMESTAMPTZ   NOT NULL,
    id_usuario     INTEGER,
    login          VARCHAR(40),
    ip             VARCHAR(45),
    acao           VARCHAR(30)   NOT NULL,     -- INSERT, UPDATE, DELETE, LOGIN, ...
    tabela         VARCHAR(40),
    registro       VARCHAR(60),
    antes          JSONB,
    depois         JSONB,
    detalhe        VARCHAR(300),
    hash_anterior  BYTEA,
    hash           BYTEA         NOT NULL
);
CREATE SEQUENCE IF NOT EXISTS auditoria_id_seq;
CREATE INDEX IF NOT EXISTS idx_auditoria_data ON auditoria (data_hora);
CREATE INDEX IF NOT EXISTS idx_auditoria_tabela ON auditoria (tabela, registro);

-- LOG_BACKUP: cada cópia de segurança feita pelo servidor
CREATE TABLE IF NOT EXISTS log_backup (
    id_backup      SERIAL        PRIMARY KEY,
    registrado_em  TIMESTAMPTZ   NOT NULL DEFAULT now(),
    origem         VARCHAR(12)   NOT NULL CHECK (origem IN ('AUTOMATICO', 'MANUAL')),
    status         VARCHAR(8)    NOT NULL CHECK (status IN ('OK', 'FALHA')),
    arquivo        VARCHAR(200),
    tamanho_bytes  BIGINT,
    sha256         CHAR(64),
    duracao_ms     INTEGER,
    mensagem       VARCHAR(300),
    id_usuario     INTEGER       REFERENCES usuario(id_usuario)
);

-- Dispositivos autenticam o envio com uma chave própria (só o hash fica)
ALTER TABLE dispositivo ADD COLUMN IF NOT EXISTS chave_api_hash BYTEA UNIQUE;

-- quem reconheceu o evento
DO $$ BEGIN
    ALTER TABLE evento ADD CONSTRAINT fk_evento_reconhecido_por
        FOREIGN KEY (reconhecido_por) REFERENCES usuario(id_usuario);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- =====================================================================
-- 2. SESSÃO ATUAL (quem está usando o banco nesta transação)
--    A aplicação faz set_config('app.sessao', <token>, true) no início de
--    cada transação. Estas funções validam o token na tabela sessao.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_sessao_atual(
    OUT id_usuario INTEGER, OUT login VARCHAR, OUT perfil VARCHAR, OUT id_cliente INTEGER)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT u.id_usuario, u.login, u.perfil, u.id_cliente
      FROM sessao s
      JOIN usuario u USING (id_usuario)
     WHERE s.token_hash = digest(NULLIF(current_setting('app.sessao', TRUE), ''), 'sha256')
       AND s.encerrada_em IS NULL
       AND s.expira_em > now()
       AND u.ativo
$$;

CREATE OR REPLACE FUNCTION fn_sessao_perfil()
RETURNS VARCHAR LANGUAGE sql STABLE AS $$ SELECT (fn_sessao_atual()).perfil $$;

-- dispositivos que a sessão atual pode ver (ADMIN sem cliente = todos)
CREATE OR REPLACE FUNCTION fn_dispositivos_visiveis()
RETURNS SETOF INTEGER
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT d.id_dispositivo
      FROM dispositivo d, fn_sessao_atual() s
     WHERE s.id_usuario IS NOT NULL
       AND (d.id_cliente = s.id_cliente OR (s.perfil = 'ADMIN' AND s.id_cliente IS NULL))
$$;

-- exige um perfil mínimo; gera erro (e o erro fica no log do servidor)
CREATE OR REPLACE FUNCTION fn_exigir_perfil(p_perfis VARCHAR[])
RETURNS INTEGER
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    s RECORD;
BEGIN
    SELECT * INTO s FROM fn_sessao_atual();
    IF s.id_usuario IS NULL THEN
        RAISE EXCEPTION 'Sessão inválida ou expirada' USING ERRCODE = '28000';
    END IF;
    IF NOT s.perfil = ANY (p_perfis) THEN
        RAISE EXCEPTION 'Acesso negado: perfil % não pode executar esta ação', s.perfil
              USING ERRCODE = '42501';
    END IF;
    RETURN s.id_usuario;
END;
$$;

-- =====================================================================
-- 3. AUDITORIA
-- =====================================================================

-- texto canônico de uma linha de auditoria (base do hash)
CREATE OR REPLACE FUNCTION fn_auditoria_texto(a auditoria)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT concat_ws('|', a.id_auditoria, EXTRACT(EPOCH FROM a.data_hora)::TEXT,
                     a.id_usuario, a.login, a.ip, a.acao, a.tabela, a.registro,
                     a.antes::TEXT, a.depois::TEXT, a.detalhe)
$$;

-- antes de gravar: data do servidor, usuário da sessão, número em ordem
-- e hash encadeado. Um lock serializa a corrente (sem buracos de ordem).
CREATE OR REPLACE FUNCTION fn_auditoria_antes_inserir()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    s RECORD;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('aps_auditoria'));

    SELECT * INTO s FROM fn_sessao_atual();
    NEW.id_auditoria := nextval('auditoria_id_seq');
    NEW.data_hora    := clock_timestamp();             -- nunca informada
    NEW.id_usuario   := s.id_usuario;
    NEW.login        := COALESCE(s.login, NEW.login, 'sistema:' || session_user);
    NEW.ip           := COALESCE(NULLIF(current_setting('app.ip', TRUE), ''), NEW.ip);

    SELECT hash INTO NEW.hash_anterior
      FROM auditoria ORDER BY id_auditoria DESC LIMIT 1;

    NEW.hash := digest(COALESCE(encode(NEW.hash_anterior, 'hex'), 'inicio')
                       || '|' || fn_auditoria_texto(NEW), 'sha256');
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_auditoria_antes_inserir
BEFORE INSERT ON auditoria
FOR EACH ROW EXECUTE FUNCTION fn_auditoria_antes_inserir();

-- append-only: UPDATE, DELETE e TRUNCATE são proibidos
CREATE OR REPLACE FUNCTION fn_auditoria_imutavel()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'A auditoria é somente de inclusão: % não é permitido', TG_OP
          USING ERRCODE = '42501';
END;
$$;

CREATE OR REPLACE TRIGGER trg_auditoria_imutavel
BEFORE UPDATE OR DELETE ON auditoria
FOR EACH ROW EXECUTE FUNCTION fn_auditoria_imutavel();

CREATE OR REPLACE TRIGGER trg_auditoria_sem_truncate
BEFORE TRUNCATE ON auditoria
FOR EACH STATEMENT EXECUTE FUNCTION fn_auditoria_imutavel();

-- registra uma ação da aplicação (login, exportação, backup, ...)
CREATE OR REPLACE FUNCTION fn_auditar_acao(
    p_acao VARCHAR, p_detalhe VARCHAR DEFAULT NULL,
    p_tabela VARCHAR DEFAULT NULL, p_registro VARCHAR DEFAULT NULL,
    p_login VARCHAR DEFAULT NULL)
RETURNS VOID
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
    INSERT INTO auditoria (acao, detalhe, tabela, registro, login, data_hora, hash)
    VALUES (upper(left(p_acao, 30)), left(p_detalhe, 300), p_tabela, p_registro,
            p_login, now(), ''::BYTEA)
$$;

-- trigger genérica: grava antes/depois de cada alteração
-- TG_ARGV[0] = coluna da chave primária
CREATE OR REPLACE FUNCTION fn_auditar_alteracao()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_antes   JSONB := CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) END;
    v_depois  JSONB := CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) END;
    v_detalhe VARCHAR;
BEGIN
    -- senha nunca vai para a auditoria (nem o hash); só o fato
    IF TG_TABLE_NAME = 'usuario' THEN
        IF TG_OP = 'UPDATE' AND v_antes ->> 'senha_hash' IS DISTINCT FROM v_depois ->> 'senha_hash' THEN
            v_detalhe := 'senha alterada';
        END IF;
        v_antes  := v_antes  - 'senha_hash';
        v_depois := v_depois - 'senha_hash';
    END IF;
    IF TG_TABLE_NAME = 'dispositivo' THEN
        IF TG_OP = 'UPDATE' AND v_antes ->> 'chave_api_hash' IS DISTINCT FROM v_depois ->> 'chave_api_hash' THEN
            v_detalhe := 'chave de API do dispositivo trocada';
        END IF;
        v_antes  := v_antes  - 'chave_api_hash';
        v_depois := v_depois - 'chave_api_hash';
        -- status e última comunicação mudam a cada lote: não são auditados
        IF TG_OP = 'UPDATE'
           AND (v_antes  - 'status' - 'ultima_comunicacao')
             = (v_depois - 'status' - 'ultima_comunicacao')
           AND v_detalhe IS NULL THEN
            RETURN NULL;
        END IF;
    END IF;
    IF TG_TABLE_NAME = 'usuario' AND TG_OP = 'UPDATE'
       AND (v_antes  - 'ultimo_login' - 'tentativas_falhas' - 'bloqueado_ate')
         = (v_depois - 'ultimo_login' - 'tentativas_falhas' - 'bloqueado_ate')
       AND v_detalhe IS NULL THEN
        RETURN NULL;                    -- login/tentativa já é auditado à parte
    END IF;
    IF TG_OP = 'UPDATE' AND v_antes = v_depois AND v_detalhe IS NULL THEN
        RETURN NULL;                    -- nada mudou
    END IF;

    INSERT INTO auditoria (acao, tabela, registro, antes, depois, detalhe, data_hora, hash)
    VALUES (TG_OP, TG_TABLE_NAME,
            COALESCE(v_depois, v_antes) ->> TG_ARGV[0],
            v_antes, v_depois, v_detalhe, now(), ''::BYTEA);
    RETURN NULL;
END;
$$;

DO $$
DECLARE
    t RECORD;
BEGIN
    FOR t IN SELECT * FROM (VALUES
            ('cliente', 'id_cliente'), ('dispositivo', 'id_dispositivo'),
            ('sensor', 'id_sensor'), ('regra_alarme', 'id_regra'),
            ('configuracao', 'chave'), ('usuario', 'id_usuario')) AS x(tabela, pk)
    LOOP
        EXECUTE format('CREATE OR REPLACE TRIGGER trg_auditar_%1$s
                        AFTER INSERT OR UPDATE OR DELETE ON %1$I
                        FOR EACH ROW EXECUTE FUNCTION fn_auditar_alteracao(%2$L)', t.tabela, t.pk);
    END LOOP;
END $$;

-- no evento, só o reconhecimento é auditado (eventos são imutáveis)
CREATE OR REPLACE TRIGGER trg_auditar_evento
AFTER UPDATE OF reconhecido ON evento
FOR EACH ROW WHEN (NOT OLD.reconhecido AND NEW.reconhecido)
EXECUTE FUNCTION fn_auditar_alteracao('id_evento');

-- configuração: a data da alteração é sempre a do servidor
CREATE OR REPLACE FUNCTION fn_configuracao_antes_alterar()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.alterado_em := now();
    RETURN NEW;
END;
$$;
CREATE OR REPLACE TRIGGER trg_configuracao_antes_alterar
BEFORE INSERT OR UPDATE ON configuracao
FOR EACH ROW EXECUTE FUNCTION fn_configuracao_antes_alterar();

-- confere a corrente de hashes inteira
CREATE OR REPLACE FUNCTION fn_verificar_auditoria(
    OUT registros BIGINT, OUT integra BOOLEAN, OUT primeiro_problema BIGINT, OUT detalhe TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    a           auditoria;
    v_anterior  BYTEA := NULL;
    v_esperado  BYTEA;
BEGIN
    PERFORM fn_exigir_perfil(ARRAY['ADMIN']::VARCHAR[]);
    registros := 0; integra := TRUE;
    FOR a IN SELECT * FROM auditoria ORDER BY id_auditoria LOOP
        registros := registros + 1;
        v_esperado := digest(COALESCE(encode(v_anterior, 'hex'), 'inicio')
                             || '|' || fn_auditoria_texto(a), 'sha256');
        IF a.hash_anterior IS DISTINCT FROM v_anterior OR a.hash <> v_esperado THEN
            integra := FALSE;
            primeiro_problema := a.id_auditoria;
            detalhe := CASE WHEN a.hash_anterior IS DISTINCT FROM v_anterior
                            THEN 'corrente quebrada: registro anterior removido ou alterado'
                            ELSE 'conteúdo do registro alterado depois de gravado' END;
            RETURN;
        END IF;
        v_anterior := a.hash;
    END LOOP;
    detalhe := format('%s registros conferidos, corrente íntegra', registros);
END;
$$;

-- =====================================================================
-- 4. LOGIN, SESSÕES E USUÁRIOS (tudo por funções; a aplicação não
--    lê nem grava a tabela usuario diretamente)
-- =====================================================================

-- política de senha: 8+ caracteres, com letra e número
CREATE OR REPLACE FUNCTION fn_validar_senha(p_senha TEXT)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_senha IS NULL OR length(p_senha) < 8 OR p_senha !~ '[A-Za-z]' OR p_senha !~ '[0-9]' THEN
        RAISE EXCEPTION 'A senha precisa ter pelo menos 8 caracteres, com letras e números'
              USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Login: 5 erros seguidos bloqueiam o usuário por 15 minutos.
-- Não usa RAISE para falhas (o RAISE desfaria a contagem de tentativas).
CREATE OR REPLACE FUNCTION fn_login(
    p_login TEXT, p_senha TEXT, p_ip TEXT DEFAULT NULL, p_agente TEXT DEFAULT NULL,
    OUT ok BOOLEAN, OUT mensagem TEXT, OUT token TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    u        usuario;
    v_token  TEXT;
BEGIN
    PERFORM set_config('app.ip', COALESCE(p_ip, ''), TRUE);
    ok := FALSE;
    SELECT * INTO u FROM usuario WHERE lower(login) = lower(trim(p_login));

    IF NOT FOUND THEN
        PERFORM crypt(COALESCE(p_senha, ''), gen_salt('bf', 10));   -- mesmo tempo de resposta
        PERFORM fn_auditar_acao('LOGIN_FALHA', 'usuário inexistente', 'usuario', NULL, left(p_login, 40));
        mensagem := 'Usuário ou senha inválidos';
        RETURN;
    END IF;

    IF NOT u.ativo THEN
        PERFORM fn_auditar_acao('LOGIN_FALHA', 'usuário desativado', 'usuario', u.id_usuario::TEXT, u.login);
        mensagem := 'Usuário ou senha inválidos';
        RETURN;
    END IF;

    IF u.bloqueado_ate > now() THEN
        PERFORM fn_auditar_acao('LOGIN_BLOQUEADO', 'tentativa durante bloqueio', 'usuario', u.id_usuario::TEXT, u.login);
        mensagem := format('Usuário bloqueado por excesso de tentativas. Tente após %s.',
                           to_char(u.bloqueado_ate AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'));
        RETURN;
    END IF;

    IF crypt(COALESCE(p_senha, ''), u.senha_hash) <> u.senha_hash THEN
        UPDATE usuario
           SET tentativas_falhas = tentativas_falhas + 1,
               bloqueado_ate = CASE WHEN tentativas_falhas + 1 >= 5
                                    THEN now() + INTERVAL '15 minutes' END
         WHERE id_usuario = u.id_usuario;
        PERFORM fn_auditar_acao(CASE WHEN u.tentativas_falhas + 1 >= 5 THEN 'USUARIO_BLOQUEADO' ELSE 'LOGIN_FALHA' END,
                                format('senha incorreta (%s/5)', u.tentativas_falhas + 1),
                                'usuario', u.id_usuario::TEXT, u.login);
        mensagem := CASE WHEN u.tentativas_falhas + 1 >= 5
                         THEN 'Usuário bloqueado por 15 minutos após 5 tentativas'
                         ELSE 'Usuário ou senha inválidos' END;
        RETURN;
    END IF;

    v_token := encode(gen_random_bytes(32), 'hex');
    INSERT INTO sessao (token_hash, id_usuario, expira_em, ip, agente)
    VALUES (digest(v_token, 'sha256'), u.id_usuario, now() + INTERVAL '8 hours', p_ip, left(p_agente, 200));

    UPDATE usuario SET tentativas_falhas = 0, bloqueado_ate = NULL, ultimo_login = now()
     WHERE id_usuario = u.id_usuario;

    PERFORM set_config('app.sessao', v_token, TRUE);
    PERFORM fn_auditar_acao('LOGIN', 'login realizado', 'usuario', u.id_usuario::TEXT);

    ok := TRUE; token := v_token; mensagem := 'OK';
END;
$$;

-- Valida a sessão e renova: expira após 60 min sem uso (máximo 8 h)
CREATE OR REPLACE FUNCTION fn_validar_sessao(p_token TEXT)
RETURNS TABLE (id_usuario INTEGER, nome VARCHAR, login VARCHAR, perfil VARCHAR,
               id_cliente INTEGER, cliente VARCHAR, trocar_senha BOOLEAN, expira_em TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_sessao sessao;
BEGIN
    SELECT * INTO v_sessao FROM sessao s
     WHERE s.token_hash = digest(p_token, 'sha256')
       AND s.encerrada_em IS NULL AND s.expira_em > now();
    IF NOT FOUND THEN RETURN; END IF;

    IF v_sessao.ultimo_uso < now() - INTERVAL '60 minutes' THEN
        UPDATE sessao SET encerrada_em = now() WHERE id_sessao = v_sessao.id_sessao;
        RETURN;
    END IF;
    IF v_sessao.ultimo_uso < now() - INTERVAL '30 seconds' THEN
        UPDATE sessao SET ultimo_uso = now() WHERE id_sessao = v_sessao.id_sessao;
    END IF;

    RETURN QUERY
    SELECT u.id_usuario, u.nome, u.login, u.perfil, u.id_cliente, c.nome,
           u.trocar_senha, v_sessao.expira_em
      FROM usuario u LEFT JOIN cliente c USING (id_cliente)
     WHERE u.id_usuario = v_sessao.id_usuario AND u.ativo;
END;
$$;

CREATE OR REPLACE FUNCTION fn_logout(p_token TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM set_config('app.sessao', p_token, TRUE);
    IF (fn_sessao_atual()).id_usuario IS NOT NULL THEN
        PERFORM fn_auditar_acao('LOGOUT', 'sessão encerrada pelo usuário', 'usuario',
                                (fn_sessao_atual()).id_usuario::TEXT);
    END IF;
    UPDATE sessao SET encerrada_em = now()
     WHERE token_hash = digest(p_token, 'sha256') AND encerrada_em IS NULL;
END;
$$;

CREATE OR REPLACE FUNCTION fn_alterar_minha_senha(p_atual TEXT, p_nova TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_id    INTEGER := fn_exigir_perfil(ARRAY['ADMIN', 'OPERADOR', 'VISUALIZADOR']::VARCHAR[]);
    v_hash  TEXT;
BEGIN
    SELECT senha_hash INTO v_hash FROM usuario WHERE id_usuario = v_id;
    IF crypt(COALESCE(p_atual, ''), v_hash) <> v_hash THEN
        RAISE EXCEPTION 'Senha atual incorreta' USING ERRCODE = '28P01';
    END IF;
    IF p_nova = p_atual THEN
        RAISE EXCEPTION 'A nova senha precisa ser diferente da atual' USING ERRCODE = '22023';
    END IF;
    PERFORM fn_validar_senha(p_nova);
    UPDATE usuario SET senha_hash = crypt(p_nova, gen_salt('bf', 10)),
                       senha_alterada_em = now(), trocar_senha = FALSE
     WHERE id_usuario = v_id;
END;
$$;

-- lista de usuários para a tela de administração (sem hash de senha)
CREATE OR REPLACE FUNCTION fn_listar_usuarios()
RETURNS TABLE (id_usuario INTEGER, nome VARCHAR, login VARCHAR, perfil VARCHAR,
               id_cliente INTEGER, cliente VARCHAR, ativo BOOLEAN, trocar_senha BOOLEAN,
               bloqueado BOOLEAN, tentativas_falhas SMALLINT, criado_em TIMESTAMPTZ,
               ultimo_login TIMESTAMPTZ, sessoes_ativas BIGINT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM fn_exigir_perfil(ARRAY['ADMIN']::VARCHAR[]);
    RETURN QUERY
    SELECT u.id_usuario, u.nome, u.login, u.perfil, u.id_cliente, c.nome, u.ativo,
           u.trocar_senha, COALESCE(u.bloqueado_ate > now(), FALSE), u.tentativas_falhas,
           u.criado_em, u.ultimo_login,
           (SELECT COUNT(*) FROM sessao s WHERE s.id_usuario = u.id_usuario
               AND s.encerrada_em IS NULL AND s.expira_em > now()
               AND s.ultimo_uso > now() - INTERVAL '60 minutes')
      FROM usuario u LEFT JOIN cliente c USING (id_cliente)
     ORDER BY u.ativo DESC, u.nome;
END;
$$;

CREATE OR REPLACE FUNCTION fn_criar_usuario(
    p_nome TEXT, p_login TEXT, p_senha TEXT, p_perfil TEXT, p_id_cliente INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_id INTEGER;
BEGIN
    PERFORM fn_exigir_perfil(ARRAY['ADMIN']::VARCHAR[]);
    PERFORM fn_validar_senha(p_senha);
    INSERT INTO usuario (nome, login, senha_hash, perfil, id_cliente, trocar_senha)
    VALUES (trim(p_nome), lower(trim(p_login)), crypt(p_senha, gen_salt('bf', 10)),
            upper(p_perfil), p_id_cliente, TRUE)
    RETURNING id_usuario INTO v_id;
    RETURN v_id;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Já existe um usuário com o login %', lower(trim(p_login)) USING ERRCODE = '23505';
END;
$$;

-- alteração de cadastro; não deixa o sistema ficar sem ADMIN ativo
CREATE OR REPLACE FUNCTION fn_atualizar_usuario(
    p_id INTEGER, p_nome TEXT, p_perfil TEXT, p_id_cliente INTEGER, p_ativo BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_eu INTEGER := fn_exigir_perfil(ARRAY['ADMIN']::VARCHAR[]);
BEGIN
    IF p_id = v_eu AND (upper(p_perfil) <> 'ADMIN' OR NOT p_ativo) THEN
        RAISE EXCEPTION 'Você não pode remover o seu próprio acesso de administrador' USING ERRCODE = '42501';
    END IF;
    UPDATE usuario
       SET nome = trim(p_nome), perfil = upper(p_perfil), id_cliente = p_id_cliente, ativo = p_ativo
     WHERE id_usuario = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Usuário % não encontrado', p_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM usuario WHERE perfil = 'ADMIN' AND ativo) THEN
        RAISE EXCEPTION 'O sistema precisa de pelo menos um administrador ativo' USING ERRCODE = '42501';
    END IF;
    IF NOT p_ativo THEN                      -- desativado: derruba as sessões
        UPDATE sessao SET encerrada_em = now() WHERE id_usuario = p_id AND encerrada_em IS NULL;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_redefinir_senha(p_id INTEGER, p_nova TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM fn_exigir_perfil(ARRAY['ADMIN']::VARCHAR[]);
    PERFORM fn_validar_senha(p_nova);
    UPDATE usuario SET senha_hash = crypt(p_nova, gen_salt('bf', 10)), senha_alterada_em = now(),
                       trocar_senha = TRUE, tentativas_falhas = 0, bloqueado_ate = NULL
     WHERE id_usuario = p_id;
    UPDATE sessao SET encerrada_em = now() WHERE id_usuario = p_id AND encerrada_em IS NULL;
END;
$$;

CREATE OR REPLACE FUNCTION fn_desbloquear_usuario(p_id INTEGER)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM fn_exigir_perfil(ARRAY['ADMIN']::VARCHAR[]);
    UPDATE usuario SET tentativas_falhas = 0, bloqueado_ate = NULL WHERE id_usuario = p_id;
    PERFORM fn_auditar_acao('USUARIO_DESBLOQUEADO', 'bloqueio removido pelo administrador',
                            'usuario', p_id::TEXT);
END;
$$;

-- =====================================================================
-- 5. OPERAÇÕES PROTEGIDAS (perfil conferido no banco)
-- =====================================================================
DROP FUNCTION IF EXISTS fn_reconhecer_eventos(BIGINT[]);
CREATE OR REPLACE FUNCTION fn_reconhecer_eventos(p_ids BIGINT[])
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_qtd INTEGER;
BEGIN
    PERFORM fn_exigir_perfil(ARRAY['ADMIN', 'OPERADOR']::VARCHAR[]);
    UPDATE evento SET reconhecido = TRUE
     WHERE id_evento = ANY (p_ids) AND NOT reconhecido AND tipo <> 'TRANSMISSAO_OK'
       AND id_dispositivo IN (SELECT fn_dispositivos_visiveis());
    GET DIAGNOSTICS v_qtd = ROW_COUNT;
    RETURN v_qtd;
END;
$$;

-- gera uma nova chave de API para o dispositivo (mostrada uma única vez)
CREATE OR REPLACE FUNCTION fn_gerar_chave_dispositivo(p_id INTEGER)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_chave TEXT := 'aps_' || encode(gen_random_bytes(24), 'hex');
BEGIN
    PERFORM fn_exigir_perfil(ARRAY['ADMIN']::VARCHAR[]);
    UPDATE dispositivo SET chave_api_hash = digest(v_chave, 'sha256') WHERE id_dispositivo = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Dispositivo % não encontrado', p_id; END IF;
    RETURN v_chave;
END;
$$;

-- recepção autenticada pela chave do dispositivo (endpoint /api/ingest)
CREATE OR REPLACE FUNCTION fn_receber_lote_com_chave(p_chave TEXT, p_leituras JSONB)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_id INTEGER;
BEGIN
    SELECT id_dispositivo INTO v_id FROM dispositivo
     WHERE chave_api_hash = digest(p_chave, 'sha256') AND ativo;
    IF v_id IS NULL THEN
        PERFORM fn_auditar_acao('INGEST_NEGADO', 'chave de dispositivo inválida', 'dispositivo');
        RETURN -1;
    END IF;
    RETURN fn_receber_lote(v_id, p_leituras);
END;
$$;

-- reenvio da fila de contingência do servidor web: a fila guarda só o
-- hash da chave (a chave em texto nunca vai para o disco)
CREATE OR REPLACE FUNCTION fn_receber_lote_contingencia(p_chave_hash TEXT, p_leituras JSONB)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_id INTEGER;
BEGIN
    SELECT id_dispositivo INTO v_id FROM dispositivo
     WHERE chave_api_hash = decode(p_chave_hash, 'hex') AND ativo;
    IF v_id IS NULL THEN
        PERFORM fn_auditar_acao('INGEST_NEGADO', 'contingência: chave de dispositivo inválida', 'dispositivo');
        RETURN -1;
    END IF;
    PERFORM fn_auditar_acao('CONTINGENCIA_REENVIO', format('lote da fila de contingência reenviado (%s leituras)',
                            jsonb_array_length(p_leituras)), 'dispositivo', v_id::TEXT);
    RETURN fn_receber_lote(v_id, p_leituras);
END;
$$;

CREATE OR REPLACE FUNCTION fn_registrar_backup(
    p_origem TEXT, p_status TEXT, p_arquivo TEXT, p_tamanho BIGINT,
    p_sha256 TEXT, p_duracao_ms INTEGER, p_mensagem TEXT)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_id INTEGER;
BEGIN
    INSERT INTO log_backup (origem, status, arquivo, tamanho_bytes, sha256, duracao_ms, mensagem, id_usuario)
    VALUES (upper(p_origem), upper(p_status), p_arquivo, p_tamanho, p_sha256, p_duracao_ms,
            left(p_mensagem, 300), (fn_sessao_atual()).id_usuario)
    RETURNING id_backup INTO v_id;
    PERFORM fn_auditar_acao('BACKUP_' || upper(p_status),
                            format('%s: %s (%s bytes)', lower(p_origem), p_arquivo, p_tamanho),
                            'log_backup', v_id::TEXT);
    RETURN v_id;
END;
$$;

-- tarefas de manutenção chamadas pelo agendador do servidor
CREATE OR REPLACE FUNCTION fn_manutencao_verificar_comunicacao()
RETURNS INTEGER LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT fn_verificar_comunicacao()
$$;
CREATE OR REPLACE FUNCTION fn_manutencao_resumo_horario()
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN CALL sp_atualizar_resumo_horario(); END;
$$;
CREATE OR REPLACE FUNCTION fn_manutencao_diaria()
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_antes BIGINT := (SELECT COUNT(*) FROM log_arquivamento);
BEGIN
    CALL sp_arquivar_dados();          -- também cria as partições futuras
    -- sessões encerradas/expiradas há mais de 30 dias saem da tabela
    DELETE FROM sessao WHERE COALESCE(encerrada_em, expira_em) < now() - INTERVAL '30 days';
    RETURN format('%s partição(ões) arquivada(s)', (SELECT COUNT(*) FROM log_arquivamento) - v_antes);
END;
$$;

-- simulador em tempo real rodando com os privilégios do dono
ALTER FUNCTION fn_simular_tempo_real(BOOLEAN, NUMERIC) SECURITY DEFINER;
ALTER FUNCTION fn_simular_tempo_real(BOOLEAN, NUMERIC) SET search_path = public, pg_temp;
ALTER FUNCTION fn_receber_lote(INTEGER, JSONB) SECURITY DEFINER;
ALTER FUNCTION fn_receber_lote(INTEGER, JSONB) SET search_path = public, pg_temp;

-- =====================================================================
-- 6. ISOLAMENTO POR CLIENTE (Row Level Security)
--    Para os papéis da aplicação, cada linha só aparece se o dispositivo
--    pertence ao cliente do usuário da sessão. O dono das tabelas
--    (postgres) e as funções SECURITY DEFINER não são afetados.
-- =====================================================================
DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['dispositivo', 'sensor', 'regra_alarme', 'leitura',
                             'leitura_arquivo', 'leitura_diaria', 'evento']
    LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS pol_cliente ON %I', t);
        EXECUTE format('CREATE POLICY pol_cliente ON %I FOR SELECT
                        USING (id_dispositivo IN (SELECT fn_dispositivos_visiveis()))', t);
    END LOOP;
END $$;

ALTER TABLE cliente ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pol_cliente ON cliente;
CREATE POLICY pol_cliente ON cliente FOR SELECT
    USING (id_cliente IN (SELECT d.id_cliente FROM dispositivo d)
           OR ((fn_sessao_atual()).perfil = 'ADMIN' AND (fn_sessao_atual()).id_cliente IS NULL));

-- alterações: regras e sensores (OPERADOR/ADMIN); configuração (ADMIN)
DROP POLICY IF EXISTS pol_alterar ON regra_alarme;
CREATE POLICY pol_alterar ON regra_alarme FOR UPDATE
    USING  (id_dispositivo IN (SELECT fn_dispositivos_visiveis())
            AND (SELECT fn_sessao_perfil()) IN ('ADMIN', 'OPERADOR'))
    WITH CHECK (id_dispositivo IN (SELECT fn_dispositivos_visiveis()));
DROP POLICY IF EXISTS pol_alterar ON sensor;
CREATE POLICY pol_alterar ON sensor FOR UPDATE
    USING  (id_dispositivo IN (SELECT fn_dispositivos_visiveis())
            AND (SELECT fn_sessao_perfil()) IN ('ADMIN', 'OPERADOR'))
    WITH CHECK (id_dispositivo IN (SELECT fn_dispositivos_visiveis()));

ALTER TABLE configuracao ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pol_ler ON configuracao;
CREATE POLICY pol_ler ON configuracao FOR SELECT USING (TRUE);
DROP POLICY IF EXISTS pol_alterar ON configuracao;
CREATE POLICY pol_alterar ON configuracao FOR UPDATE
    USING ((SELECT fn_sessao_perfil()) = 'ADMIN');

-- auditoria e backups: só ADMIN lê
ALTER TABLE auditoria ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pol_admin ON auditoria;
CREATE POLICY pol_admin ON auditoria FOR SELECT USING ((SELECT fn_sessao_perfil()) = 'ADMIN');
ALTER TABLE log_backup ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pol_admin ON log_backup;
CREATE POLICY pol_admin ON log_backup FOR SELECT USING ((SELECT fn_sessao_perfil()) = 'ADMIN');
ALTER TABLE log_arquivamento ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pol_ler ON log_arquivamento;
CREATE POLICY pol_ler ON log_arquivamento FOR SELECT USING ((SELECT fn_sessao_perfil()) IS NOT NULL);

-- views comuns respeitam o RLS de quem consulta (PostgreSQL 15+)
DO $$
DECLARE
    v TEXT;
BEGIN
    IF current_setting('server_version_num')::INT >= 150000 THEN
        FOREACH v IN ARRAY ARRAY['vw_leitura_completa', 'vw_status_estacoes', 'vw_log_eventos', 'vw_exportacao']
        LOOP
            EXECUTE format('ALTER VIEW %I SET (security_invoker = true)', v);
        END LOOP;
    ELSE
        RAISE WARNING 'PostgreSQL < 15: views sem security_invoker; use 15 ou mais novo';
    END IF;
END $$;

-- view materializada não tem RLS: a aplicação lê por esta view filtrada
CREATE OR REPLACE VIEW vw_resumo_horario WITH (security_barrier = true) AS
SELECT m.*
  FROM mv_resumo_horario m
 WHERE m.id_dispositivo IN (SELECT fn_dispositivos_visiveis());

-- =====================================================================
-- 7. PAPÉIS DO POSTGRESQL (mínimo privilégio)
--    aps_app          servidor web: lê dados e chama funções protegidas
--    aps_dispositivo  só envia leituras (fn_receber_lote / com chave)
--    aps_backup       só faz cópia de segurança (pg_dump)
--    aps_leitura      grupo somente leitura (relatórios, BI)
--    TROQUE AS SENHAS em produção: ALTER ROLE aps_app PASSWORD '...';
-- =====================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aps_app') THEN
        CREATE ROLE aps_app LOGIN PASSWORD 'aps_app_2026' CONNECTION LIMIT 30;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aps_dispositivo') THEN
        CREATE ROLE aps_dispositivo LOGIN PASSWORD 'aps_disp_2026' CONNECTION LIMIT 10;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aps_backup') THEN
        -- BYPASSRLS: o pg_dump precisa ler todas as linhas
        CREATE ROLE aps_backup LOGIN PASSWORD 'aps_backup_2026' BYPASSRLS CONNECTION LIMIT 3;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aps_leitura') THEN
        CREATE ROLE aps_leitura NOLOGIN;
    END IF;
END $$;

DO $$
BEGIN
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO aps_app, aps_dispositivo, aps_backup, aps_leitura',
                   current_database());
END $$;

REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO aps_app, aps_dispositivo, aps_backup, aps_leitura;

-- nada é liberado por padrão; cada permissão abaixo é explícita
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM PUBLIC, aps_app, aps_dispositivo, aps_leitura;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, aps_app, aps_dispositivo, aps_leitura;
REVOKE EXECUTE ON ALL FUNCTIONS  IN SCHEMA public FROM PUBLIC;
REVOKE EXECUTE ON ALL PROCEDURES IN SCHEMA public FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- aps_app: leitura dos dados (filtrada pelo RLS)
GRANT SELECT ON cliente, dispositivo, sensor, regra_alarme, configuracao,
                leitura, leitura_arquivo, leitura_diaria, evento,
                log_arquivamento, log_backup, auditoria,
                vw_leitura_completa, vw_status_estacoes, vw_log_eventos, vw_exportacao,
                vw_resumo_horario
   TO aps_app;
-- (dispositivo sem a coluna da chave)
REVOKE SELECT ON dispositivo FROM aps_app;
GRANT SELECT (id_dispositivo, id_cliente, nome, intervalo_leitura_min, intervalo_transmissao_min,
              latitude, longitude, ativo, status, ultima_comunicacao, simulado)
   ON dispositivo TO aps_app;
-- nomes dos usuários (para "reconhecido por"), sem senha nem dados de acesso
GRANT SELECT (id_usuario, nome, login) ON usuario TO aps_app;
-- ler parâmetros do servidor (wal_level, archive_mode) na tela de backups
GRANT pg_read_all_settings TO aps_app;
-- alterações permitidas (conferidas pelo RLS e auditadas)
GRANT UPDATE (limite, nivel, nota, ativo) ON regra_alarme TO aps_app;
GRANT UPDATE (limite_min, limite_max, ativo) ON sensor TO aps_app;
GRANT UPDATE (valor) ON configuracao TO aps_app;

GRANT EXECUTE ON FUNCTION
    fn_login(TEXT, TEXT, TEXT, TEXT), fn_validar_sessao(TEXT), fn_logout(TEXT),
    fn_alterar_minha_senha(TEXT, TEXT), fn_listar_usuarios(),
    fn_criar_usuario(TEXT, TEXT, TEXT, TEXT, INTEGER),
    fn_atualizar_usuario(INTEGER, TEXT, TEXT, INTEGER, BOOLEAN),
    fn_redefinir_senha(INTEGER, TEXT), fn_desbloquear_usuario(INTEGER),
    fn_reconhecer_eventos(BIGINT[]), fn_gerar_chave_dispositivo(INTEGER),
    fn_verificar_auditoria(), fn_auditar_acao(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR),
    fn_registrar_backup(TEXT, TEXT, TEXT, BIGINT, TEXT, INTEGER, TEXT),
    fn_manutencao_verificar_comunicacao(), fn_manutencao_resumo_horario(), fn_manutencao_diaria(),
    fn_sessao_atual(), fn_sessao_perfil(), fn_dispositivos_visiveis(), fn_exigir_perfil(VARCHAR[]),
    fn_config(VARCHAR)
   TO aps_app;

-- aps_dispositivo: só enviar leituras
GRANT EXECUTE ON FUNCTION fn_receber_lote(INTEGER, JSONB), fn_receber_lote_com_chave(TEXT, JSONB),
                          fn_receber_lote_contingencia(TEXT, JSONB),
                          fn_simular_tempo_real(BOOLEAN, NUMERIC)
   TO aps_dispositivo;
-- funções usadas internamente pelas SECURITY DEFINER rodam como dono;
-- as funções auxiliares das policies precisam ser executáveis por quem consulta
GRANT EXECUTE ON FUNCTION fn_auditar_acao(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR),
                          fn_sessao_atual(), fn_dispositivos_visiveis()
   TO aps_dispositivo;

-- aps_backup: leitura de tudo para o pg_dump (PostgreSQL 14+)
DO $$
BEGIN
    IF current_setting('server_version_num')::INT >= 140000 THEN
        GRANT pg_read_all_data TO aps_backup;
    ELSE
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO aps_backup;
        GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO aps_backup;
    END IF;
END $$;

-- aps_leitura: relatórios (vê todos os clientes; dados sem informação pessoal)
GRANT SELECT ON vw_exportacao, vw_leitura_completa, leitura, leitura_arquivo, leitura_diaria,
                dispositivo, cliente
   TO aps_leitura;
DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['dispositivo', 'leitura', 'leitura_arquivo', 'leitura_diaria', 'cliente']
    LOOP
        EXECUTE format('DROP POLICY IF EXISTS pol_relatorio ON %I', t);
        EXECUTE format('CREATE POLICY pol_relatorio ON %I FOR SELECT TO aps_leitura USING (TRUE)', t);
    END LOOP;
END $$;
REVOKE SELECT ON dispositivo FROM aps_leitura;
GRANT SELECT (id_dispositivo, id_cliente, nome, latitude, longitude, ativo) ON dispositivo TO aps_leitura;

-- =====================================================================
-- 8. USUÁRIOS INICIAIS (todos precisam trocar a senha no 1º acesso)
--    admin     / Admin@2026      ADMIN (todos os clientes)
--    operador  / Operador@2026   OPERADOR da Defesa Civil de SJC
--    consulta  / Consulta@2026   VISUALIZADOR da Defesa Civil de SJC
-- =====================================================================
INSERT INTO usuario (nome, login, senha_hash, perfil, id_cliente)
SELECT v.nome, v.login, crypt(v.senha, gen_salt('bf', 10)), v.perfil,
       CASE WHEN v.perfil = 'ADMIN' THEN NULL
            ELSE (SELECT id_cliente FROM cliente WHERE nome = 'Defesa Civil de São José dos Campos') END
  FROM (VALUES ('Administrador do sistema',     'admin',    'Admin@2026',    'ADMIN'),
               ('Operador da Defesa Civil',     'operador', 'Operador@2026', 'OPERADOR'),
               ('Consulta da Defesa Civil',     'consulta', 'Consulta@2026', 'VISUALIZADOR')
       ) AS v(nome, login, senha, perfil)
 WHERE NOT EXISTS (SELECT 1 FROM usuario u WHERE u.login = v.login)
 ORDER BY CASE v.perfil WHEN 'ADMIN' THEN 1 WHEN 'OPERADOR' THEN 2 ELSE 3 END;

-- =====================================================================
-- 9. AUDITORIA DE ESTRUTURA (DDL)
--    Qualquer ALTER/CREATE/DROP/GRANT fica registrado, inclusive quem
--    desligar uma trigger de proteção (ALTER TABLE ... DISABLE TRIGGER).
--    Ignora só a atualização periódica da view materializada.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_auditar_ddl()
RETURNS EVENT_TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    c RECORD;
BEGIN
    IF current_setting('app.instalando', TRUE) = 'on' THEN RETURN; END IF;
    FOR c IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
        CONTINUE WHEN c.command_tag IN ('REFRESH MATERIALIZED VIEW');
        CONTINUE WHEN c.schema_name = 'pg_temp' OR c.schema_name LIKE 'pg_temp%';
        INSERT INTO auditoria (acao, tabela, registro, detalhe, data_hora, hash)
        VALUES ('DDL', left(c.object_type, 40), NULL,
                left(c.command_tag || ': ' || COALESCE(c.object_identity, '?')
                     || ' | ' || regexp_replace(current_query(), '\s+', ' ', 'g'), 300),
                now(), ''::BYTEA);
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION fn_auditar_drop()
RETURNS EVENT_TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    c RECORD;
BEGIN
    IF current_setting('app.instalando', TRUE) = 'on' THEN RETURN; END IF;
    FOR c IN SELECT * FROM pg_event_trigger_dropped_objects() WHERE original LOOP
        CONTINUE WHEN c.schema_name LIKE 'pg_temp%';
        INSERT INTO auditoria (acao, tabela, detalhe, data_hora, hash)
        VALUES ('DDL', left(c.object_type, 40),
                left('DROP: ' || COALESCE(c.object_identity, '?'), 300), now(), ''::BYTEA);
    END LOOP;
END;
$$;

DROP EVENT TRIGGER IF EXISTS evt_auditar_ddl;
CREATE EVENT TRIGGER evt_auditar_ddl ON ddl_command_end EXECUTE FUNCTION fn_auditar_ddl();
DROP EVENT TRIGGER IF EXISTS evt_auditar_drop;
CREATE EVENT TRIGGER evt_auditar_drop ON sql_drop EXECUTE FUNCTION fn_auditar_drop();

RESET app.instalando;
SELECT fn_auditar_acao('SEGURANCA_INSTALADA', '07_seguranca.sql executado: papéis, RLS e auditoria');

SELECT login, perfil, 'trocar no 1º acesso' AS senha FROM usuario ORDER BY id_usuario;
