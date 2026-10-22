// Fila de contingência: se o banco estiver fora do ar quando um
// dispositivo enviar um lote (/api/ingest), o lote é gravado em disco
// (um arquivo por lote, gravação atômica) e reenviado quando o banco
// voltar. Assim uma queda do banco não perde dados.
// A fila guarda o HASH da chave do dispositivo, nunca a chave.
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const config = require('./config');
const banco = require('./banco');

const PASTA = config.contingencia.pasta;
let reenviando = false;

function guardar(chave, leituras) {
  const nome = `${Date.now()}_${crypto.randomBytes(4).toString('hex')}.json`;
  const conteudo = JSON.stringify({
    guardado_em: new Date().toISOString(),
    chave_hash: crypto.createHash('sha256').update(chave).digest('hex'),
    leituras,
  });
  const tmp = path.join(PASTA, nome + '.tmp');
  fs.writeFileSync(tmp, conteudo, { mode: 0o600 });
  fs.renameSync(tmp, path.join(PASTA, nome));        // atômico: nunca fica meio arquivo
  return nome;
}

function pendentes() {
  return fs.readdirSync(PASTA).filter((f) => f.endsWith('.json')).sort();
}

// Reenvia em ordem de chegada; para no primeiro erro de conexão
async function reenviar() {
  if (reenviando) return { reenviados: 0 };
  reenviando = true;
  let n = 0;
  try {
    for (const f of pendentes()) {
      const arq = path.join(PASTA, f);
      const d = JSON.parse(fs.readFileSync(arq, 'utf8'));
      try {
        await banco.sistema('SELECT fn_receber_lote_contingencia($1, $2::jsonb) AS n',
          [d.chave_hash, JSON.stringify(d.leituras)], 'dispositivo');
        fs.unlinkSync(arq);
        n++;
      } catch (e) {
        if (banco.ehFalhaDeConexao(e)) break;          // banco ainda fora: tenta depois
        // lote inválido: separa para análise em vez de travar a fila
        fs.renameSync(arq, arq.replace(/\.json$/, '.erro'));
        console.error(`[contingencia] lote ${f} recusado pelo banco:`, e.message);
      }
    }
  } finally { reenviando = false; }
  if (n) console.log(`[contingencia] ${n} lote(s) reenviado(s) ao banco`);
  return { reenviados: n };
}

module.exports = { guardar, pendentes, reenviar, PASTA };
