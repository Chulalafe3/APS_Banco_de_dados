// Conexões com o PostgreSQL, uma por papel (mínimo privilégio):
//   app          -> telas do painel (aps_app)
//   dispositivo  -> recepção de leituras e simulador (aps_dispositivo)
// Toda consulta de usuário roda numa transação com o TOKEN da sessão em
// app.sessao: é o banco que descobre quem é o usuário (07_seguranca.sql).
'use strict';
const { Pool, types } = require('pg');
const config = require('./config');

// NUMERIC e BIGINT chegam como texto por padrão; aqui viram número
types.setTypeParser(1700, (v) => (v === null ? null : parseFloat(v)));
types.setTypeParser(20, (v) => (v === null ? null : parseInt(v, 10)));
types.setTypeParser(1082, (v) => v);   // DATE fica 'AAAA-MM-DD' (sem fuso)

function novoPool(papel, max) {
  const p = config.papeis[papel];
  const pool = new Pool({
    host: config.banco.host,
    port: config.banco.porta,
    database: config.banco.nome,
    user: p.usuario,
    password: p.senha,
    max,
    connectionTimeoutMillis: 5000,
    idleTimeoutMillis: 30000,
    application_name: `aps-painel-${papel}`,
    options: '-c timezone=America/Sao_Paulo -c statement_timeout=30000',
  });
  pool.on('error', (e) => console.error(`[banco:${papel}] conexão perdida:`, e.message));
  return pool;
}

const pools = {
  app: novoPool('app', 15),
  dispositivo: novoPool('dispositivo', 4),
};

// Executa fn(cliente) numa transação ligada à sessão do usuário
async function comSessao(token, ip, fn, papel = 'app') {
  const c = await pools[papel].connect();
  try {
    await c.query('BEGIN');
    await c.query("SELECT set_config('app.sessao', $1, true), set_config('app.ip', $2, true)",
      [token || '', ip || '']);
    const r = await fn(c);
    await c.query('COMMIT');
    return r;
  } catch (e) {
    await c.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    c.release();
  }
}

// Consulta simples sem usuário (tarefas do sistema)
async function sistema(sql, params = [], papel = 'app') {
  return pools[papel].query(sql, params);
}

// Erros de conexão (banco fora do ar) x erros de regra
function ehFalhaDeConexao(e) {
  return ['ECONNREFUSED', 'ECONNRESET', 'ETIMEDOUT', 'ENOTFOUND', 'EPIPE', '57P01', '57P02', '57P03', '08006', '08001', '08004']
    .includes(e.code) || /timeout exceeded when trying to connect|Connection terminated/i.test(e.message || '');
}

module.exports = { pools, comSessao, sistema, ehFalhaDeConexao };
