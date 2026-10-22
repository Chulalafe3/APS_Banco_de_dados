// Rotas da API. Cada consulta roda com o token da sessão (banco.comSessao),
// então o RLS e as funções do 07_seguranca.sql decidem o que cada perfil
// pode ver e fazer. A checagem de perfil aqui é só para a tela responder
// rápido; quem garante é o banco.
'use strict';
const fs = require('fs');
const path = require('path');
const { rota, json, ErroHttp, SEGURANCA } = require('./http');
const banco = require('./banco');
const tempoReal = require('./tempo-real');
const backup = require('./backup');
const contingencia = require('./contingencia');
const agendador = require('./agendador');
const config = require('./config');

const COOKIE = 'aps_sessao';
const PERIODOS = { '24h': '24 hours', '7d': '7 days', '30d': '30 days', '90d': '90 days', '180d': '180 days' };

// ---------------------------------------------------------------------
// Autenticação
// ---------------------------------------------------------------------
async function autenticar(ctx, permitirTrocaPendente = false) {
  const token = ctx.cookies[COOKIE];
  if (!token || !/^[0-9a-f]{64}$/.test(token)) throw new ErroHttp(401, 'Faça login para continuar');
  const r = await banco.sistema('SELECT * FROM fn_validar_sessao($1)', [token]);
  if (!r.rows.length) throw new ErroHttp(401, 'Sessão expirada. Faça login novamente');
  ctx.token = token;
  ctx.usuario = r.rows[0];
  if (ctx.usuario.trocar_senha && !permitirTrocaPendente) {
    throw new ErroHttp(403, 'Troque sua senha antes de continuar');
  }
}
const logado = (ctx) => autenticar(ctx);
const logadoMesmoComTroca = (ctx) => autenticar(ctx, true);
const perfil = (...perfis) => (ctx) => {
  if (!perfis.includes(ctx.usuario.perfil)) throw new ErroHttp(403, 'Seu perfil não tem acesso a esta função');
};

// consulta com a sessão do usuário
async function q(ctx, sql, params = []) {
  return (await banco.comSessao(ctx.token, ctx.ip, (c) => c.query(sql, params))).rows;
}
async function tx(ctx, fn) { return banco.comSessao(ctx.token, ctx.ip, fn); }

function periodo(valor, padrao = '24h') {
  return PERIODOS[valor] || PERIODOS[padrao];
}
function inteiro(v, nome) {
  const n = Number(v);
  if (!Number.isInteger(n)) throw new ErroHttp(400, `${nome} inválido`);
  return n;
}
function numero(v, nome) {
  const n = Number(v);
  if (v === '' || v === null || v === undefined || !Number.isFinite(n)) throw new ErroHttp(400, `${nome} precisa ser um número`);
  return n;
}
function listaIds(texto) {
  return String(texto || '').split(',').filter((t) => t.trim() !== '').map(Number)
    .filter((n) => Number.isInteger(n) && n > 0);
}

// limite simples de tentativas de login por IP (o banco também bloqueia
// o usuário após 5 erros)
const tentativasIp = new Map();
function limitarLogin(ip) {
  const agora = Date.now();
  const lista = (tentativasIp.get(ip) || []).filter((t) => agora - t < 5 * 60000);
  lista.push(agora);
  tentativasIp.set(ip, lista);
  if (lista.length > 15) throw new ErroHttp(429, 'Muitas tentativas deste computador. Aguarde alguns minutos');
}

// ---------------------------------------------------------------------
// Sessão
// ---------------------------------------------------------------------
rota('GET', '/api/saude', async () => ({
  banco: tempoReal.online(), hora_servidor: new Date().toISOString(),
  contingencia_pendentes: contingencia.pendentes().length,
}));

rota('POST', '/api/login', async (ctx) => {
  limitarLogin(ctx.ip);
  const { login, senha } = ctx.corpo;
  if (!login || !senha) throw new ErroHttp(400, 'Informe usuário e senha');
  const r = (await banco.sistema('SELECT * FROM fn_login($1,$2,$3,$4)',
    [String(login).slice(0, 40), String(senha).slice(0, 200), ctx.ip, String(ctx.req.headers['user-agent'] || '').slice(0, 200)])).rows[0];
  if (!r.ok) throw new ErroHttp(401, r.mensagem);
  const u = (await banco.sistema('SELECT * FROM fn_validar_sessao($1)', [r.token])).rows[0];
  json(ctx.res, 200, { usuario: u }, {
    'Set-Cookie': `${COOKIE}=${r.token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800`,
  });
});

rota('POST', '/api/logout', async (ctx) => {
  const token = ctx.cookies[COOKIE];
  if (token) await banco.sistema('SELECT fn_logout($1)', [token]).catch(() => {});
  json(ctx.res, 200, { ok: true }, { 'Set-Cookie': `${COOKIE}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0` });
});

rota('GET', '/api/eu', logadoMesmoComTroca, async (ctx) => ({ usuario: ctx.usuario }));

rota('POST', '/api/eu/senha', logadoMesmoComTroca, async (ctx) => {
  await q(ctx, 'SELECT fn_alterar_minha_senha($1, $2)', [ctx.corpo.atual || '', ctx.corpo.nova || '']);
  return { ok: true };
});

// ---------------------------------------------------------------------
// Painel
// ---------------------------------------------------------------------
rota('GET', '/api/painel', logado, async (ctx) => tx(ctx, async (c) => {
  const estacoes = (await c.query(`
    SELECT d.id_dispositivo AS id, d.nome, d.status, d.ultima_comunicacao, d.intervalo_transmissao_min,
           d.latitude, d.longitude, d.simulado, cl.nome AS cliente,
           ROUND(EXTRACT(EPOCH FROM now() - d.ultima_comunicacao) / 60) AS minutos_sem_comunicacao,
           u.data_hora AS ultima_leitura, u.temperatura_ar, u.umidade_ar, u.chuva_acumulada,
           u.velocidade_vento, u.direcao_vento, u.radiacao_solar,
           (SELECT COUNT(*) FROM evento e
             WHERE e.id_dispositivo = d.id_dispositivo AND NOT e.reconhecido
               AND e.tipo <> 'TRANSMISSAO_OK') AS pendentes
      FROM dispositivo d
      JOIN cliente cl USING (id_cliente)
      LEFT JOIN LATERAL (SELECT * FROM leitura l WHERE l.id_dispositivo = d.id_dispositivo
                          ORDER BY l.data_hora DESC LIMIT 1) u ON TRUE
     WHERE d.ativo
     ORDER BY d.nome`)).rows;

  // últimas 6 h, de 10 em 10 min, para as minicurvas dos cartões
  const tendencia = (await c.query(`
    SELECT id_dispositivo AS id,
           date_bin('10 minutes', data_hora, TIMESTAMPTZ '2000-01-01') AS t,
           ROUND(AVG(temperatura_ar), 2) AS temperatura, ROUND(AVG(umidade_ar), 1) AS umidade,
           MAX(velocidade_vento) AS vento, MAX(chuva_acumulada) AS chuva
      FROM leitura
     WHERE data_hora >= now() - INTERVAL '6 hours'
     GROUP BY 1, 2 ORDER BY 2`)).rows;

  const eventos = (await c.query(`
    SELECT e.id_evento, e.data_hora, d.nome AS estacao, e.tipo, e.mensagem, e.reconhecido
      FROM evento e JOIN dispositivo d USING (id_dispositivo)
     WHERE e.tipo <> 'TRANSMISSAO_OK'
     ORDER BY e.data_hora DESC, e.id_evento DESC LIMIT 8`)).rows;

  const hoje = (await c.query(`
    SELECT COUNT(*) FILTER (WHERE tipo = 'ALARME')            AS alarmes,
           COUNT(*) FILTER (WHERE tipo = 'FALHA_SENSOR')      AS falhas_sensor,
           COUNT(*) FILTER (WHERE tipo = 'FALHA_TRANSMISSAO') AS falhas_transmissao,
           COUNT(*) FILTER (WHERE tipo = 'LEITURA_REJEITADA') AS lotes_com_rejeicao,
           COUNT(*) FILTER (WHERE tipo = 'TRANSMISSAO_OK')    AS transmissoes,
           COALESCE(SUM(valor) FILTER (WHERE tipo = 'TRANSMISSAO_OK'), 0) AS leituras
      FROM evento
     WHERE data_hora >= date_trunc('day', now())`)).rows[0];

  const regras = (await c.query(`
    SELECT id_dispositivo AS id, parametro, condicao, limite, nivel
      FROM regra_alarme WHERE ativo`)).rows;

  return { estacoes, tendencia, eventos, hoje, regras, hora_servidor: new Date().toISOString() };
}));

// ---------------------------------------------------------------------
// Gráficos
// ---------------------------------------------------------------------
rota('GET', '/api/series', logado, async (ctx) => {
  const per = ['24h', '7d', '30d'].includes(ctx.query.periodo) ? ctx.query.periodo : '24h';
  const ids = listaIds(ctx.query.estacoes);
  return tx(ctx, async (c) => {
    let pontos;
    if (per === '24h') {
      pontos = (await c.query(`
        SELECT id_dispositivo AS id, date_bin('5 minutes', data_hora, TIMESTAMPTZ '2000-01-01') AS t,
               ROUND(AVG(temperatura_ar), 2) AS temperatura, ROUND(AVG(umidade_ar), 2) AS umidade,
               MAX(velocidade_vento) AS vento, ROUND(AVG(radiacao_solar), 1) AS radiacao,
               MAX(chuva_acumulada) AS chuva_acumulada, SUM(chuva) AS chuva
          FROM leitura
         WHERE data_hora >= now() - INTERVAL '24 hours'
           AND (cardinality($1::int[]) = 0 OR id_dispositivo = ANY ($1))
         GROUP BY 1, 2 ORDER BY 2`, [ids])).rows;
    } else {
      pontos = (await c.query(`
        SELECT id_dispositivo AS id, hora AS t, temp_media AS temperatura, umidade_media AS umidade,
               vento_max AS vento, radiacao_media AS radiacao, chuva_acumulada_dia AS chuva_acumulada,
               chuva_hora AS chuva
          FROM vw_resumo_horario
         WHERE hora >= now() - $2::interval
           AND (cardinality($1::int[]) = 0 OR id_dispositivo = ANY ($1))
         ORDER BY hora`, [ids, periodo(per)])).rows;
    }
    const regras = (await c.query(
      'SELECT id_dispositivo AS id, parametro, condicao, limite, nivel FROM regra_alarme WHERE ativo')).rows;
    return { periodo: per, pontos, regras };
  });
});

rota('GET', '/api/chuva', logado, async (ctx) => {
  const dias = { '30': 30, '90': 90, '180': 180 }[ctx.query.dias] || 30;
  return tx(ctx, async (c) => {
    const dados = (await c.query(`
      SELECT id, dia, chuva FROM (
        SELECT id_dispositivo AS id, (data_hora AT TIME ZONE 'America/Sao_Paulo')::DATE AS dia,
               MAX(chuva_acumulada) AS chuva
          FROM leitura
         WHERE data_hora >= (CURRENT_DATE - $1::INT)::TIMESTAMP AT TIME ZONE 'America/Sao_Paulo'
         GROUP BY 1, 2
        UNION ALL
        SELECT id_dispositivo, dia, chuva_total FROM leitura_diaria WHERE dia >= CURRENT_DATE - $1::INT
      ) q ORDER BY dia, id`, [dias])).rows;
    const limite = (await c.query(`
      SELECT MIN(limite) AS limite FROM regra_alarme WHERE parametro = 'chuva_acumulada' AND ativo`)).rows[0].limite;
    return { dias, dados, limite };
  });
});

// ---------------------------------------------------------------------
// Eventos
// ---------------------------------------------------------------------
const TIPOS_EVENTO = ['ALARME', 'FALHA_SENSOR', 'FALHA_TRANSMISSAO', 'LEITURA_REJEITADA', 'TRANSMISSAO_OK'];

rota('GET', '/api/eventos', logado, async (ctx) => {
  const tipos = String(ctx.query.tipos || 'ALARME,FALHA_SENSOR,FALHA_TRANSMISSAO,LEITURA_REJEITADA')
    .split(',').filter((t) => TIPOS_EVENTO.includes(t));
  const ids = listaIds(ctx.query.estacoes);
  const per = ctx.query.periodo === 'tudo' ? null : periodo(ctx.query.periodo, '7d');
  const pend = ctx.query.pendentes === '1';
  const where = `e.tipo = ANY ($1) AND (cardinality($2::int[]) = 0 OR e.id_dispositivo = ANY ($2))
                 AND ($3::interval IS NULL OR e.data_hora >= now() - $3::interval)
                 AND (NOT $4 OR NOT e.reconhecido)`;
  return tx(ctx, async (c) => {
    const lista = (await c.query(`
      SELECT e.id_evento, e.data_hora, e.id_dispositivo, d.nome AS estacao, e.tipo, e.parametro, e.valor,
             e.mensagem, e.reconhecido, e.reconhecido_em, u.nome AS reconhecido_por
        FROM evento e
        JOIN dispositivo d USING (id_dispositivo)
        LEFT JOIN usuario u ON u.id_usuario = e.reconhecido_por
       WHERE ${where}
       ORDER BY e.data_hora DESC, e.id_evento DESC
       LIMIT 400`, [tipos, ids, per, pend])).rows;
    const contagem = (await c.query(`
      SELECT e.tipo, COUNT(*) AS total, COUNT(*) FILTER (WHERE NOT e.reconhecido) AS pendentes
        FROM evento e WHERE ${where} GROUP BY e.tipo`, [tipos, ids, per, pend])).rows;
    return { lista, contagem, limite: 400 };
  });
});

rota('POST', '/api/eventos/reconhecer', logado, perfil('ADMIN', 'OPERADOR'), async (ctx) => {
  const ids = (Array.isArray(ctx.corpo.ids) ? ctx.corpo.ids : []).map(Number).filter(Number.isInteger).slice(0, 5000);
  if (!ids.length) throw new ErroHttp(400, 'Nenhum evento selecionado');
  const n = (await q(ctx, 'SELECT fn_reconhecer_eventos($1::bigint[]) AS n', [ids]))[0].n;
  return { reconhecidos: n };
});

// ---------------------------------------------------------------------
// Histórico e ciclo de vida dos dados
// ---------------------------------------------------------------------
rota('GET', '/api/historico', logado, async (ctx) => tx(ctx, async (c) => {
  const meses = (await c.query(`
    SELECT d.nome AS estacao, q.id, q.mes, q.origem, q.temp_media, q.temp_min, q.temp_max,
           q.umidade_min, q.chuva_total, q.vento_max, q.leituras, q.invalidos
      FROM (
        SELECT id_dispositivo AS id, to_char(dia, 'YYYY-MM') AS mes, 'arquivo' AS origem,
               ROUND(AVG(temp_media), 1) AS temp_media, MIN(temp_min) AS temp_min, MAX(temp_max) AS temp_max,
               MIN(umidade_min) AS umidade_min, ROUND(SUM(chuva_total), 1) AS chuva_total,
               MAX(vento_max) AS vento_max, SUM(qtd_leituras) AS leituras, SUM(qtd_valores_invalidos) AS invalidos
          FROM leitura_diaria GROUP BY 1, 2
        UNION ALL
        SELECT id_dispositivo, to_char(data_hora AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM'), 'recente',
               ROUND(AVG(temperatura_ar), 1), MIN(temperatura_ar), MAX(temperatura_ar),
               MIN(umidade_ar), ROUND(SUM(chuva), 1), MAX(velocidade_vento), COUNT(*),
               SUM((temperatura_ar IS NULL)::INT + (umidade_ar IS NULL)::INT + (chuva IS NULL)::INT
                   + (direcao_vento IS NULL)::INT + (velocidade_vento IS NULL)::INT + (radiacao_solar IS NULL)::INT)
          FROM leitura GROUP BY 1, 2
      ) q JOIN dispositivo d ON d.id_dispositivo = q.id
     ORDER BY q.mes, d.nome`)).rows;
  const arquivamento = (await c.query(
    'SELECT particao, executado_em, linhas_movidas, dias_resumidos, duracao_ms FROM log_arquivamento ORDER BY particao')).rows;
  const armazenamento = (await c.query(`
    SELECT 'leitura' AS tabela, 'Dados recentes (particionada por mês)' AS descricao,
           (SELECT COUNT(*) FROM pg_inherits WHERE inhparent = 'leitura'::regclass) AS particoes,
           (SELECT COALESCE(SUM(pg_total_relation_size(inhrelid)), 0) FROM pg_inherits WHERE inhparent = 'leitura'::regclass) AS bytes
    UNION ALL
    SELECT 'leitura_arquivo', 'Histórico arquivado (índice BRIN)',
           (SELECT COUNT(*) FROM pg_inherits WHERE inhparent = 'leitura_arquivo'::regclass),
           (SELECT COALESCE(SUM(pg_total_relation_size(inhrelid)), 0) FROM pg_inherits WHERE inhparent = 'leitura_arquivo'::regclass)
    UNION ALL
    SELECT 'leitura_diaria', 'Resumo diário dos meses arquivados', NULL, pg_total_relation_size('leitura_diaria')
    UNION ALL
    SELECT 'evento', 'Log de eventos', NULL, pg_total_relation_size('evento')`)).rows;
  const particoes = (await c.query(`
    SELECT c.relname AS nome, p.relname AS tabela
      FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_class p ON p.oid = i.inhparent
     WHERE p.relname IN ('leitura', 'leitura_arquivo') ORDER BY c.relname`)).rows;
  return { meses, arquivamento, armazenamento, particoes };
}));

// ---------------------------------------------------------------------
// Exportação (CSV no padrão do Excel brasileiro: ; e vírgula decimal)
// ---------------------------------------------------------------------
rota('GET', '/api/exportar.csv', logado, async (ctx) => {
  const per = ['24h', '7d', '30d'].includes(ctx.query.periodo) ? ctx.query.periodo : '24h';
  const ids = listaIds(ctx.query.estacoes);
  const linhas = await tx(ctx, async (c) => {
    const r = (await c.query(`
      SELECT "Estação", "Data", "Hora", "Temperatura do ar (°C)", "Umidade do ar (%)", "Chuva (mm)",
             "Chuva acumulada no dia (mm)", "Direção do vento (°)", "Velocidade do vento (m/s)",
             "Radiação solar (W/m²)"
        FROM vw_exportacao
       WHERE data_hora >= now() - $1::interval
         AND (cardinality($2::int[]) = 0 OR id_dispositivo = ANY ($2))
       ORDER BY "Estação", data_hora`, [periodo(per), ids]));
    await c.query('SELECT fn_auditar_acao($1, $2)',
      ['EXPORTACAO', `CSV de ${per}: ${r.rowCount} leituras (estações: ${ids.join(',') || 'todas'})`]);
    return r;
  });
  const cols = linhas.fields.map((f) => f.name);
  const fmt = (v) => (v === null ? '' : typeof v === 'number' ? String(v).replace('.', ',') : `"${String(v).replace(/"/g, '""')}"`);
  const corpo = '﻿' + cols.map(fmt).join(';') + '\r\n'
    + linhas.rows.map((r) => cols.map((k) => fmt(r[k])).join(';')).join('\r\n');
  ctx.res.writeHead(200, {
    ...SEGURANCA, 'Content-Type': 'text/csv; charset=utf-8', 'Cache-Control': 'no-store',
    'Content-Disposition': `attachment; filename="leituras_${per}.csv"`,
  });
  ctx.res.end(corpo);
});

// ---------------------------------------------------------------------
// Configuração (regras de alarme, sensores, parâmetros do banco)
// ---------------------------------------------------------------------
rota('GET', '/api/config', logado, async (ctx) => tx(ctx, async (c) => ({
  estacoes: (await c.query(`SELECT id_dispositivo AS id, nome, status, simulado, intervalo_leitura_min,
                                   intervalo_transmissao_min, latitude, longitude
                              FROM dispositivo WHERE ativo ORDER BY nome`)).rows,
  regras: (await c.query(`SELECT r.id_regra, r.id_dispositivo AS id, d.nome AS estacao, r.parametro, r.condicao,
                                 r.limite, r.nivel, r.nota, r.ativo
                            FROM regra_alarme r JOIN dispositivo d USING (id_dispositivo)
                           ORDER BY d.nome, r.parametro`)).rows,
  sensores: (await c.query(`SELECT s.id_sensor, s.id_dispositivo AS id, d.nome AS estacao, s.parametro, s.unidade,
                                   s.limite_min, s.limite_max, s.ativo
                              FROM sensor s JOIN dispositivo d USING (id_dispositivo)
                             ORDER BY d.nome, s.id_sensor`)).rows,
  parametros: (await c.query('SELECT * FROM configuracao ORDER BY chave')).rows,
})));

rota('PUT', '/api/regras/:id', logado, perfil('ADMIN', 'OPERADOR'), async (ctx) => {
  const b = ctx.corpo;
  if (!['ATENCAO', 'ALERTA', 'CRITICO'].includes(b.nivel)) throw new ErroHttp(400, 'Nível inválido');
  const r = await q(ctx, `UPDATE regra_alarme SET limite = $2, nivel = $3, nota = $4, ativo = $5
                           WHERE id_regra = $1 RETURNING id_regra`,
    [inteiro(ctx.params.id, 'Regra'), numero(b.limite, 'Limite'), b.nivel, String(b.nota || '').slice(0, 150) || null, !!b.ativo]);
  if (!r.length) throw new ErroHttp(403, 'Regra não encontrada ou sem permissão');
  return { ok: true };
});

rota('PUT', '/api/sensores/:id', logado, perfil('ADMIN', 'OPERADOR'), async (ctx) => {
  const b = ctx.corpo;
  const min = numero(b.limite_min, 'Mínimo'); const max = numero(b.limite_max, 'Máximo');
  if (min >= max) throw new ErroHttp(400, 'O mínimo precisa ser menor que o máximo');
  const r = await q(ctx, `UPDATE sensor SET limite_min = $2, limite_max = $3, ativo = $4
                           WHERE id_sensor = $1 RETURNING id_sensor`,
    [inteiro(ctx.params.id, 'Sensor'), min, max, !!b.ativo]);
  if (!r.length) throw new ErroHttp(403, 'Sensor não encontrado ou sem permissão');
  return { ok: true };
});

rota('PUT', '/api/parametros/:chave', logado, perfil('ADMIN'), async (ctx) => {
  const r = await q(ctx, 'UPDATE configuracao SET valor = $2 WHERE chave = $1 RETURNING chave',
    [String(ctx.params.chave), numero(ctx.corpo.valor, 'Valor')]);
  if (!r.length) throw new ErroHttp(403, 'Parâmetro não encontrado ou sem permissão');
  return { ok: true };
});

rota('POST', '/api/dispositivos/:id/chave', logado, perfil('ADMIN'), async (ctx) => {
  const r = await q(ctx, 'SELECT fn_gerar_chave_dispositivo($1) AS chave', [inteiro(ctx.params.id, 'Estação')]);
  return { chave: r[0].chave };
});

rota('POST', '/api/simulador/transmitir', logado, perfil('ADMIN', 'OPERADOR'), async (ctx) => {
  const n = await agendador.simular(true);
  await q(ctx, 'SELECT fn_auditar_acao($1, $2)', ['SIMULACAO_MANUAL', `transmissão simulada sob demanda: ${n} leitura(s)`]);
  return { leituras: n };
});

// ---------------------------------------------------------------------
// Usuários (ADMIN)
// ---------------------------------------------------------------------
rota('GET', '/api/usuarios', logado, perfil('ADMIN'), async (ctx) => tx(ctx, async (c) => ({
  usuarios: (await c.query('SELECT * FROM fn_listar_usuarios()')).rows,
  clientes: (await c.query('SELECT id_cliente, nome FROM cliente ORDER BY nome')).rows,
})));

function dadosUsuario(b) {
  if (!['ADMIN', 'OPERADOR', 'VISUALIZADOR'].includes(b.perfil)) throw new ErroHttp(400, 'Perfil inválido');
  if (!String(b.nome || '').trim()) throw new ErroHttp(400, 'Informe o nome');
  const cliente = b.id_cliente === '' || b.id_cliente === null || b.id_cliente === undefined ? null : inteiro(b.id_cliente, 'Cliente');
  if (b.perfil !== 'ADMIN' && cliente === null) throw new ErroHttp(400, 'Operador e visualizador precisam de um cliente');
  return { nome: String(b.nome).trim().slice(0, 100), perfil: b.perfil, cliente };
}

rota('POST', '/api/usuarios', logado, perfil('ADMIN'), async (ctx) => {
  const d = dadosUsuario(ctx.corpo);
  const login = String(ctx.corpo.login || '').trim().toLowerCase();
  if (!/^[a-z0-9._-]{3,40}$/.test(login)) throw new ErroHttp(400, 'Login: 3 a 40 caracteres (letras minúsculas, números, ponto, hífen)');
  const r = await q(ctx, 'SELECT fn_criar_usuario($1,$2,$3,$4,$5) AS id', [d.nome, login, ctx.corpo.senha || '', d.perfil, d.cliente]);
  return { id: r[0].id };
});

rota('PUT', '/api/usuarios/:id', logado, perfil('ADMIN'), async (ctx) => {
  const d = dadosUsuario(ctx.corpo);
  await q(ctx, 'SELECT fn_atualizar_usuario($1,$2,$3,$4,$5)',
    [inteiro(ctx.params.id, 'Usuário'), d.nome, d.perfil, d.cliente, ctx.corpo.ativo !== false]);
  return { ok: true };
});

rota('POST', '/api/usuarios/:id/senha', logado, perfil('ADMIN'), async (ctx) => {
  await q(ctx, 'SELECT fn_redefinir_senha($1,$2)', [inteiro(ctx.params.id, 'Usuário'), ctx.corpo.nova || '']);
  return { ok: true };
});

rota('POST', '/api/usuarios/:id/desbloquear', logado, perfil('ADMIN'), async (ctx) => {
  await q(ctx, 'SELECT fn_desbloquear_usuario($1)', [inteiro(ctx.params.id, 'Usuário')]);
  return { ok: true };
});

// ---------------------------------------------------------------------
// Auditoria (ADMIN)
// ---------------------------------------------------------------------
rota('GET', '/api/auditoria', logado, perfil('ADMIN'), async (ctx) => {
  const per = ctx.query.periodo === 'tudo' ? null : periodo(ctx.query.periodo, '7d');
  const pagina = Math.max(0, parseInt(ctx.query.pagina || '0', 10) || 0);
  const f = [ctx.query.acao || null, ctx.query.tabela || null, ctx.query.login || null, per];
  const where = `($1::text IS NULL OR acao = $1) AND ($2::text IS NULL OR tabela = $2)
                 AND ($3::text IS NULL OR login = $3)
                 AND ($4::interval IS NULL OR data_hora >= now() - $4::interval)`;
  return tx(ctx, async (c) => ({
    lista: (await c.query(`
      SELECT id_auditoria, data_hora, login, ip, acao, tabela, registro, antes, depois, detalhe,
             encode(hash, 'hex') AS hash
        FROM auditoria WHERE ${where}
       ORDER BY id_auditoria DESC LIMIT 50 OFFSET $5`, [...f, pagina * 50])).rows,
    total: (await c.query(`SELECT COUNT(*) AS n FROM auditoria WHERE ${where}`, f)).rows[0].n,
    filtros: (await c.query(`
      SELECT (SELECT array_agg(DISTINCT acao ORDER BY acao) FROM auditoria) AS acoes,
             (SELECT array_agg(DISTINCT tabela ORDER BY tabela) FROM auditoria WHERE tabela IS NOT NULL) AS tabelas,
             (SELECT array_agg(DISTINCT login ORDER BY login) FROM auditoria WHERE login IS NOT NULL) AS logins`)).rows[0],
    pagina,
  }));
});

rota('GET', '/api/auditoria/verificar', logado, perfil('ADMIN'), async (ctx) =>
  (await q(ctx, 'SELECT * FROM fn_verificar_auditoria()'))[0]);

// ---------------------------------------------------------------------
// Backups e continuidade (ADMIN)
// ---------------------------------------------------------------------
rota('GET', '/api/backups', logado, perfil('ADMIN'), async (ctx) => {
  const servidor = await tx(ctx, async (c) => (await c.query(`
    SELECT current_setting('wal_level') AS wal_level, current_setting('archive_mode') AS archive_mode,
           current_setting('archive_command') AS archive_command, current_setting('fsync') AS fsync,
           current_setting('synchronous_commit') AS synchronous_commit,
           current_setting('full_page_writes') AS full_page_writes,
           current_setting('server_version') AS versao,
           pg_database_size(current_database()) AS tamanho_banco,
           (SELECT COUNT(*) FROM pg_stat_replication) AS replicas`)).rows[0]);
  return {
    copias: backup.listar(),
    servidor,
    agenda: { hora_diaria: config.backup.hora_diaria, proximo: agendador.proximoBackup(),
      retencao_dias: config.backup.retencao_dias, minimo_manter: config.backup.minimo_manter },
    pasta: backup.PASTA, pg_dump: backup.pgDump(), em_andamento: backup.emAndamento(),
    contingencia: { pasta: contingencia.PASTA, pendentes: contingencia.pendentes().length },
    agendador: agendador.estado,
  };
});

rota('POST', '/api/backups', logado, perfil('ADMIN'), async (ctx) => backup.executar('MANUAL', ctx.token, ctx.ip));

rota('POST', '/api/backups/verificar', logado, perfil('ADMIN'), async (ctx) => {
  const r = await backup.verificar(String(ctx.corpo.arquivo || ''));
  await q(ctx, 'SELECT fn_auditar_acao($1, $2, $3)', ['BACKUP_VERIFICADO', `${r.arquivo}: ${r.ok ? 'íntegro' : 'PROBLEMA'} - ${r.detalhe}`, 'log_backup']);
  return r;
});

rota('GET', '/api/backups/baixar', logado, perfil('ADMIN'), async (ctx) => {
  const nome = String(ctx.query.arquivo || '');
  if (!/^[\w.-]+\.dump$/.test(nome)) throw new ErroHttp(400, 'Arquivo inválido');
  const arq = path.join(backup.PASTA, nome);
  if (!fs.existsSync(arq)) throw new ErroHttp(404, 'Arquivo não encontrado');
  await q(ctx, 'SELECT fn_auditar_acao($1, $2, $3)', ['BACKUP_DOWNLOAD', `cópia baixada: ${nome}`, 'log_backup']);
  ctx.res.writeHead(200, {
    ...SEGURANCA, 'Content-Type': 'application/octet-stream', 'Cache-Control': 'no-store',
    'Content-Disposition': `attachment; filename="${nome}"`, 'Content-Length': fs.statSync(arq).size,
  });
  fs.createReadStream(arq).pipe(ctx.res);
});

rota('POST', '/api/contingencia/reenviar', logado, perfil('ADMIN'), async () => contingencia.reenviar());

// ---------------------------------------------------------------------
// Tempo real (Server-Sent Events)
// ---------------------------------------------------------------------
rota('GET', '/api/stream', logado, async (ctx) => {
  const ids = (await q(ctx, 'SELECT array_agg(id) AS ids FROM fn_dispositivos_visiveis() AS id'))[0].ids || [];
  tempoReal.registrar(ctx.res, ids, ctx.usuario.perfil);
});

// ---------------------------------------------------------------------
// Recepção de dispositivos reais (chave de API no cabeçalho)
// Se o banco estiver fora do ar, o lote vai para a fila de contingência.
// ---------------------------------------------------------------------
rota('POST', '/api/ingest', async (ctx) => {
  const chave = String(ctx.req.headers['x-chave-dispositivo'] || '');
  if (!/^aps_[0-9a-f]{48}$/.test(chave)) throw new ErroHttp(401, 'Chave de dispositivo ausente ou inválida');
  const leituras = Array.isArray(ctx.corpo) ? ctx.corpo : ctx.corpo.leituras;
  if (!Array.isArray(leituras) || !leituras.length || leituras.length > 20000) {
    throw new ErroHttp(400, 'Envie um array JSON com 1 a 20000 leituras');
  }
  try {
    const n = (await banco.sistema('SELECT fn_receber_lote_com_chave($1, $2::jsonb) AS n',
      [chave, JSON.stringify(leituras)], 'dispositivo')).rows[0].n;
    if (n < 0) throw new ErroHttp(401, 'Chave de dispositivo inválida');
    return { status: 'gravado', recebidas: leituras.length, gravadas: n };
  } catch (e) {
    if (!banco.ehFalhaDeConexao(e)) throw e;
    const arq = contingencia.guardar(chave, leituras);
    tempoReal.definirSaude(false, e.message);
    json(ctx.res, 202, { status: 'em_contingencia', recebidas: leituras.length,
      mensagem: 'Banco indisponível: lote guardado no servidor e será gravado quando o banco voltar', arquivo: arq });
  }
});

module.exports = {};
