// Tempo real: o banco avisa (NOTIFY aps_tempo_real) quando chega um lote
// ou um alarme/falha; o servidor repassa aos navegadores por
// Server-Sent Events (/api/stream). Cada navegador só recebe avisos das
// estações que o usuário dele pode ver.
'use strict';
const { Client } = require('pg');
const config = require('./config');

const clientes = new Set();   // { res, dispositivos:Set, perfil }
let ouvinte = null;
let bancoOnline = null;
const ouvintesSaude = [];

function enviar(c, evento, dados) {
  try { c.res.write(`event: ${evento}\ndata: ${JSON.stringify(dados)}\n\n`); } catch { /* conexão caiu */ }
}

function transmitir(evento, dados, idDispositivo = null) {
  for (const c of clientes) {
    if (idDispositivo !== null && !c.dispositivos.has(idDispositivo)) continue;
    enviar(c, evento, dados);
  }
}

function registrar(res, dispositivos, perfil) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-store',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  res.write('retry: 5000\n\n');
  const c = { res, dispositivos: new Set(dispositivos), perfil };
  clientes.add(c);
  enviar(c, 'saude', { banco: bancoOnline, hora: new Date().toISOString() });
  res.on('close', () => clientes.delete(c));
}

// batimento: mantém a conexão aberta e leva a hora do servidor
setInterval(() => transmitir('saude', { banco: bancoOnline, hora: new Date().toISOString() }), 25000).unref();

function definirSaude(online, motivo) {
  if (online === bancoOnline) return;
  bancoOnline = online;
  console.log(`[tempo-real] banco ${online ? 'ONLINE' : 'FORA DO AR'}${motivo ? ': ' + motivo : ''}`);
  transmitir('saude', { banco: online, hora: new Date().toISOString() });
  ouvintesSaude.forEach((f) => f(online));
}

async function conectarOuvinte() {
  const p = config.papeis.app;
  const c = new Client({
    host: config.banco.host, port: config.banco.porta, database: config.banco.nome,
    user: p.usuario, password: p.senha, application_name: 'aps-painel-listen',
  });
  c.on('notification', (msg) => {
    let d;
    try { d = JSON.parse(msg.payload); } catch { return; }
    transmitir(d.tipo, d, d.id_dispositivo ?? null);
  });
  const reconectar = (e) => {
    if (ouvinte !== c) return;
    ouvinte = null;
    definirSaude(false, e && e.message);
    c.end().catch(() => {});
    setTimeout(iniciar, 5000);
  };
  c.on('error', reconectar);
  c.on('end', () => reconectar());
  await c.connect();
  await c.query('LISTEN aps_tempo_real');
  ouvinte = c;
  definirSaude(true);
}

async function iniciar() {
  try { await conectarOuvinte(); }
  catch (e) { definirSaude(false, e.message); setTimeout(iniciar, 5000); }
}

module.exports = {
  iniciar, registrar, transmitir, definirSaude,
  online: () => bancoOnline,
  aoMudarSaude: (f) => ouvintesSaude.push(f),
  conectados: () => clientes.size,
};
