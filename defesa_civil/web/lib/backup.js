// Backup lógico com pg_dump (formato custom, comprimido), feito com o
// papel aps_backup (só leitura). Para cada cópia:
//   - SHA-256 do arquivo (detecta corrupção ou adulteração)
//   - manifesto.json na própria pasta (sobrevive mesmo se o banco se perder)
//   - registro em log_backup + auditoria (quando o banco está no ar)
//   - retenção: apaga cópias com mais de N dias, mantendo sempre as últimas
// Verificação: confere o SHA-256 e lê o índice do arquivo com pg_restore.
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawn } = require('child_process');
const config = require('./config');
const banco = require('./banco');

const PASTA = config.backup.pasta;
const MANIFESTO = path.join(PASTA, 'manifesto.json');
let emAndamento = false;

// Acha o pg_dump/pg_restore: config.backup.pg_bin, instalação padrão do
// Windows (maior versão) ou o PATH
function binario(nome) {
  const exe = process.platform === 'win32' ? nome + '.exe' : nome;
  if (config.backup.pg_bin) return path.join(config.backup.pg_bin, exe);
  if (process.platform === 'win32') {
    const base = 'C:\\Program Files\\PostgreSQL';
    if (fs.existsSync(base)) {
      const versoes = fs.readdirSync(base).filter((v) => /^\d+/.test(v))
        .sort((a, b) => parseFloat(b) - parseFloat(a));
      for (const v of versoes) {
        const p = path.join(base, v, 'bin', exe);
        if (fs.existsSync(p)) return p;
      }
    }
  }
  return nome;
}

function rodar(cmd, args) {
  return new Promise((resolve) => {
    const p = config.papeis.backup;
    const proc = spawn(cmd, args, { env: { ...process.env, PGPASSWORD: p.senha }, windowsHide: true });
    let saida = '', erro = '';
    proc.stdout.on('data', (d) => { saida += d; });
    proc.stderr.on('data', (d) => { erro += d; });
    proc.on('error', (e) => resolve({ codigo: -1, saida, erro: e.message }));
    proc.on('close', (codigo) => resolve({ codigo, saida, erro }));
  });
}

function sha256(arq) {
  return new Promise((resolve, reject) => {
    const h = crypto.createHash('sha256');
    fs.createReadStream(arq).on('data', (d) => h.update(d)).on('end', () => resolve(h.digest('hex'))).on('error', reject);
  });
}

function lerManifesto() {
  try { return JSON.parse(fs.readFileSync(MANIFESTO, 'utf8')); } catch { return []; }
}
function gravarManifesto(lista) {
  const tmp = MANIFESTO + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(lista, null, 2));
  fs.renameSync(tmp, MANIFESTO);
}

function carimbo(d = new Date()) {
  const z = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${z(d.getMonth() + 1)}${z(d.getDate())}_${z(d.getHours())}${z(d.getMinutes())}${z(d.getSeconds())}`;
}

// origem: 'AUTOMATICO' | 'MANUAL'; token/ip: sessão de quem pediu (manual)
async function executar(origem, token = null, ip = null) {
  if (emAndamento) throw Object.assign(new Error('Já existe um backup em andamento'), { code: 'P0001' });
  emAndamento = true;
  const inicio = Date.now();
  const nome = `${config.banco.nome}_${carimbo()}.dump`;
  const arq = path.join(PASTA, nome);
  const reg = { arquivo: nome, origem, iniciado_em: new Date().toISOString() };
  try {
    const r = await rodar(binario('pg_dump'), [
      '-h', config.banco.host, '-p', String(config.banco.porta), '-U', config.papeis.backup.usuario,
      '-d', config.banco.nome, '-Fc', '-Z', '6', '--no-owner', '-f', arq,
    ]);
    if (r.codigo !== 0) {
      try { fs.unlinkSync(arq); } catch { /* nada a apagar */ }
      throw new Error((r.erro || 'pg_dump falhou').trim().split('\n').slice(-2).join(' '));
    }
    reg.tamanho_bytes = fs.statSync(arq).size;
    reg.sha256 = await sha256(arq);
    fs.writeFileSync(arq + '.sha256', `${reg.sha256}  ${nome}\n`);
    reg.status = 'OK';
    reg.mensagem = 'Cópia concluída e conferida';
  } catch (e) {
    reg.status = 'FALHA';
    reg.mensagem = e.message.slice(0, 280);
  } finally {
    emAndamento = false;
  }
  reg.duracao_ms = Date.now() - inicio;

  const lista = lerManifesto();
  lista.push(reg);
  gravarManifesto(lista);

  try {
    await banco.comSessao(token, ip, (c) => c.query(
      'SELECT fn_registrar_backup($1,$2,$3,$4,$5,$6,$7)',
      [origem, reg.status, reg.arquivo, reg.tamanho_bytes || null, reg.sha256 || null, reg.duracao_ms, reg.mensagem]));
  } catch (e) {
    console.error('[backup] não foi possível registrar no banco:', e.message);
  }
  console.log(`[backup] ${origem} ${reg.status}: ${nome} ${reg.mensagem}`);
  if (reg.status === 'OK') aplicarRetencao();
  return reg;
}

// confere integridade (SHA-256) e se o pg_restore consegue ler o arquivo
async function verificar(nome) {
  const item = lerManifesto().find((m) => m.arquivo === nome);
  if (!item || !/^[\w.-]+\.dump$/.test(nome)) throw Object.assign(new Error('Backup não encontrado'), { code: 'P0001' });
  const arq = path.join(PASTA, nome);
  if (!fs.existsSync(arq)) return { arquivo: nome, ok: false, detalhe: 'Arquivo não existe mais na pasta de backups' };
  const atual = await sha256(arq);
  if (atual !== item.sha256) return { arquivo: nome, ok: false, detalhe: 'SHA-256 diferente do registrado: arquivo corrompido ou alterado' };
  const r = await rodar(binario('pg_restore'), ['--list', arq]);
  if (r.codigo !== 0) return { arquivo: nome, ok: false, detalhe: 'pg_restore não conseguiu ler: ' + r.erro.trim().slice(0, 200) };
  const objetos = r.saida.split('\n').filter((l) => /^\d+;/.test(l)).length;
  const tabelas = r.saida.split('\n').filter((l) => / TABLE DATA /.test(l)).length;
  return { arquivo: nome, ok: true, detalhe: `Íntegro: SHA-256 confere; ${objetos} objetos, ${tabelas} tabelas com dados prontos para restaurar` };
}

// apaga cópias antigas, mas sempre mantém as N mais recentes que deram certo
function aplicarRetencao() {
  const lista = lerManifesto();
  const limite = Date.now() - config.backup.retencao_dias * 86400000;
  const oks = lista.filter((m) => m.status === 'OK' && !m.removido_em)
    .sort((a, b) => b.iniciado_em.localeCompare(a.iniciado_em));
  const proteger = new Set(oks.slice(0, config.backup.minimo_manter).map((m) => m.arquivo));
  let removidos = 0;
  for (const m of oks) {
    if (proteger.has(m.arquivo) || Date.parse(m.iniciado_em) >= limite) continue;
    for (const f of [m.arquivo, m.arquivo + '.sha256']) {
      try { fs.unlinkSync(path.join(PASTA, f)); } catch { /* já não existe */ }
    }
    m.removido_em = new Date().toISOString();
    removidos++;
  }
  if (removidos) { gravarManifesto(lista); console.log(`[backup] retenção: ${removidos} cópia(s) antiga(s) removida(s)`); }
}

function listar() {
  return lerManifesto().map((m) => ({
    ...m, existe: !m.removido_em && fs.existsSync(path.join(PASTA, m.arquivo)),
  })).reverse();
}

module.exports = {
  executar, verificar, listar, PASTA,
  emAndamento: () => emAndamento,
  pgDump: () => binario('pg_dump'),
};
