// Comunicação com o servidor + estado compartilhado entre as telas.

export const estado = {
  usuario: null,
  // diferença entre o relógio do servidor e o do navegador: a hora mostrada
  // na tela é SEMPRE a do servidor (o relógio do computador pode estar errado)
  desvioRelogio: 0,
  bancoOnline: true,
  ouvintes: {},          // evento SSE -> [funções]
};

export const agoraServidor = () => new Date(Date.now() + estado.desvioRelogio);

export function ajustarRelogio(isoServidor) {
  const d = Date.parse(isoServidor);
  if (!Number.isNaN(d)) estado.desvioRelogio = d - Date.now();
}

export class ErroApi extends Error {
  constructor(status, mensagem) { super(mensagem); this.status = status; }
}

export async function api(caminho, { metodo = 'GET', corpo } = {}) {
  const opcoes = { method: metodo, headers: {}, credentials: 'same-origin' };
  if (metodo !== 'GET') {
    opcoes.headers['X-Requested-With'] = 'aps-painel';        // proteção CSRF
    opcoes.headers['Content-Type'] = 'application/json';
    opcoes.body = JSON.stringify(corpo || {});
  }
  let r;
  try {
    r = await fetch(caminho, opcoes);
  } catch {
    throw new ErroApi(0, 'Sem conexão com o servidor do painel');
  }
  const tipo = r.headers.get('content-type') || '';
  const dados = tipo.includes('application/json') ? await r.json() : null;
  if (!r.ok) {
    const erro = new ErroApi(r.status, (dados && dados.erro) || `Erro ${r.status}`);
    if (r.status === 401 && !caminho.startsWith('/api/login')) {
      window.dispatchEvent(new CustomEvent('sessao-expirada', { detail: erro.message }));
    }
    throw erro;
  }
  return dados;
}

export const get = (c) => api(c);
export const post = (c, corpo) => api(c, { metodo: 'POST', corpo });
export const put = (c, corpo) => api(c, { metodo: 'PUT', corpo });

// --- tempo real (Server-Sent Events) ----------------------------------
let fonte = null;
export function conectarTempoReal() {
  desconectarTempoReal();
  fonte = new EventSource('/api/stream');
  for (const tipo of ['saude', 'lote', 'evento']) {
    fonte.addEventListener(tipo, (ev) => {
      let d; try { d = JSON.parse(ev.data); } catch { return; }
      (estado.ouvintes[tipo] || []).forEach((f) => f(d));
    });
  }
  fonte.onerror = () => (estado.ouvintes.desconectado || []).forEach((f) => f());
}
export function desconectarTempoReal() { if (fonte) { fonte.close(); fonte = null; } }

export function ouvir(tipo, f) {
  (estado.ouvintes[tipo] ||= []).push(f);
  return () => { estado.ouvintes[tipo] = estado.ouvintes[tipo].filter((x) => x !== f); };
}
