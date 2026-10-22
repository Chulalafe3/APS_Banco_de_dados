// Camada HTTP mínima (sem framework): rotas, JSON, cookies, arquivos
// estáticos, cabeçalhos de segurança e tradução de erros do banco.
'use strict';
const fs = require('fs');
const path = require('path');

const PUBLICO = path.join(__dirname, '..', 'public');
const TIPOS = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.svg': 'image/svg+xml',
  '.png': 'image/png', '.ico': 'image/x-icon', '.json': 'application/json',
  '.woff2': 'font/woff2',
};

const SEGURANCA = {
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'no-referrer',
  'Content-Security-Policy':
    "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
};

class ErroHttp extends Error {
  constructor(status, mensagem) { super(mensagem); this.status = status; }
}

// --- rotas ------------------------------------------------------------
const rotas = [];
function rota(metodo, padrao, ...handlers) {
  const nomes = [];
  const re = new RegExp('^' + padrao.replace(/:(\w+)/g, (_, n) => { nomes.push(n); return '([^/]+)'; }) + '$');
  rotas.push({ metodo, re, nomes, handlers });
}

function encontrar(metodo, caminho) {
  for (const r of rotas) {
    if (r.metodo !== metodo) continue;
    const m = r.re.exec(caminho);
    if (m) {
      const params = {};
      r.nomes.forEach((n, i) => { params[n] = decodeURIComponent(m[i + 1]); });
      return { rota: r, params };
    }
  }
  return null;
}

// --- utilidades de requisição/resposta ---------------------------------
function cookies(req) {
  const out = {};
  (req.headers.cookie || '').split(';').forEach((p) => {
    const i = p.indexOf('=');
    if (i > 0) out[p.slice(0, i).trim()] = decodeURIComponent(p.slice(i + 1).trim());
  });
  return out;
}

function ipDe(req) {
  return (req.socket.remoteAddress || '').replace(/^::ffff:/, '');
}

function lerCorpo(req, limite = 2 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let tam = 0;
    const partes = [];
    req.on('data', (c) => {
      tam += c.length;
      if (tam > limite) { reject(new ErroHttp(413, 'Requisição grande demais')); req.destroy(); return; }
      partes.push(c);
    });
    req.on('end', () => {
      if (!partes.length) return resolve({});
      try { resolve(JSON.parse(Buffer.concat(partes).toString('utf8'))); }
      catch { reject(new ErroHttp(400, 'JSON inválido')); }
    });
    req.on('error', reject);
  });
}

function json(res, status, dados, extras = {}) {
  const corpo = JSON.stringify(dados);
  res.writeHead(status, {
    ...SEGURANCA, 'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store', ...extras,
  });
  res.end(corpo);
}

function estatico(req, res, caminho) {
  let rel = caminho === '/' ? '/index.html' : caminho;
  const arq = path.normalize(path.join(PUBLICO, rel));
  if (!arq.startsWith(PUBLICO)) { res.writeHead(403); return res.end(); }
  fs.stat(arq, (err, st) => {
    if (err || !st.isFile()) {
      // SPA: rotas desconhecidas sem extensão caem no index.html
      if (!path.extname(rel)) return estatico(req, res, '/index.html');
      res.writeHead(404, SEGURANCA); return res.end('Não encontrado');
    }
    res.writeHead(200, {
      ...SEGURANCA,
      'Content-Type': TIPOS[path.extname(arq)] || 'application/octet-stream',
      'Cache-Control': 'no-cache',
    });
    fs.createReadStream(arq).pipe(res);
  });
}

// Erros do PostgreSQL -> HTTP (mensagens de regra vão para a tela;
// erros internos só vão para o log)
function traduzirErro(e) {
  if (e instanceof ErroHttp) return { status: e.status, mensagem: e.message };
  const porCodigo = {
    '28000': 401, '28P01': 400, '42501': 403, '22023': 400, '23505': 409,
    '23514': 400, '22P02': 400, 'P0001': 400, '23503': 400,
  };
  if (porCodigo[e.code]) {
    let m = e.message;
    if (e.code === '42501' && /permission denied/.test(m)) m = 'Acesso negado';
    if (e.code === '23514') m = 'Valor fora do permitido (' + (e.constraint || 'restrição') + ')';
    return { status: porCodigo[e.code], mensagem: m };
  }
  return { status: 500, mensagem: 'Erro interno no servidor' };
}

async function tratar(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const achou = encontrar(req.method, url.pathname);

  if (!achou) {
    if (url.pathname.startsWith('/api/')) return json(res, 404, { erro: 'Rota não encontrada' });
    if (req.method !== 'GET') { res.writeHead(405); return res.end(); }
    return estatico(req, res, url.pathname);
  }

  const ctx = {
    req, res, url, params: achou.params, query: Object.fromEntries(url.searchParams),
    cookies: cookies(req), ip: ipDe(req), corpo: {},
  };
  try {
    if (['POST', 'PUT', 'DELETE'].includes(req.method)) {
      // proteção CSRF: só o próprio painel envia este cabeçalho
      // (um site de terceiros não consegue sem permissão de CORS)
      if (!ctx.url.pathname.startsWith('/api/ingest') && req.headers['x-requested-with'] !== 'aps-painel') {
        throw new ErroHttp(403, 'Requisição sem o cabeçalho do painel');
      }
      ctx.corpo = await lerCorpo(req);
    }
    for (const h of achou.rota.handlers) {
      const r = await h(ctx);
      if (res.writableEnded || res.headersSent) return;
      if (r !== undefined) return json(res, 200, r);
    }
  } catch (e) {
    const t = traduzirErro(e);
    if (t.status >= 500) console.error(`[http] ${req.method} ${url.pathname}:`, e);
    if (!res.headersSent) json(res, t.status, { erro: t.mensagem });
    else res.end();
  }
}

module.exports = { rota, tratar, json, ErroHttp, SEGURANCA };
