// =====================================================================
// Dispositivo de teste: faz o papel de um datalogger real enviando
// leituras para a API do painel (POST /api/ingest) com a chave da estação.
// Serve para demonstrar a recepção autenticada e a fila de contingência
// (desligue o PostgreSQL com o teste rodando e ligue de novo).
//
//   node dispositivo_teste.js <chave> [segundos entre envios] [url]
//   ex.: node dispositivo_teste.js aps_1f2e... 30
//
// A chave é gerada no painel: Configuração > Estações > Gerar chave de API.
// Como um datalogger, mede a cada minuto e guarda o que não conseguiu
// enviar para o próximo envio.
// =====================================================================
'use strict';
const [chave, intervaloSeg = '60', url = 'http://127.0.0.1:8080'] = process.argv.slice(2);
if (!chave) {
  console.log('Uso: node dispositivo_teste.js <chave> [segundos entre envios] [url]');
  process.exit(1);
}

const pendentes = [];
let ultimoMinuto = null;

function medir() {
  // uma leitura por minuto, com a hora do próprio dispositivo
  const agora = new Date();
  agora.setSeconds(0, 0);
  if (ultimoMinuto && agora.getTime() <= ultimoMinuto) return;
  ultimoMinuto = agora.getTime();
  const h = agora.getHours() + agora.getMinutes() / 60;
  const sol = Math.max(0, Math.sin(Math.PI * (h - 6) / 12));
  pendentes.push({
    data_hora: agora.toISOString(),
    temperatura_ar: +(15 + 9 * sol + Math.random()).toFixed(2),
    umidade_ar: +(92 - 40 * sol + Math.random() * 4).toFixed(1),
    chuva: 0,
    direcao_vento: +(90 + Math.random() * 60).toFixed(0),
    velocidade_vento: +(1.5 + 3 * sol + Math.random()).toFixed(2),
    radiacao_solar: +(950 * sol).toFixed(1),
  });
}

async function enviar() {
  medir();
  if (!pendentes.length) return;
  const lote = pendentes.slice();
  const hora = new Date().toLocaleTimeString('pt-BR');
  try {
    const r = await fetch(`${url}/api/ingest`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Chave-Dispositivo': chave },
      body: JSON.stringify(lote),
    });
    const d = await r.json();
    if (r.status === 200) {
      pendentes.splice(0, lote.length);
      console.log(`[${hora}] lote com ${lote.length} leitura(s): ${d.gravadas} gravada(s) no banco`);
    } else if (r.status === 202) {
      pendentes.splice(0, lote.length);
      console.log(`[${hora}] BANCO FORA DO AR: ${lote.length} leitura(s) guardadas na fila de contingência do servidor`);
    } else {
      console.log(`[${hora}] recusado (${r.status}): ${d.erro}`);
      if (r.status === 401) process.exit(1);
    }
  } catch (e) {
    console.log(`[${hora}] servidor do painel inacessível; ${pendentes.length} leitura(s) seguem guardadas no dispositivo`);
  }
}

console.log(`Dispositivo de teste enviando para ${url} a cada ${intervaloSeg} s (Ctrl+C para parar)`);
setInterval(medir, 15000);
enviar();
setInterval(enviar, Number(intervaloSeg) * 1000);
