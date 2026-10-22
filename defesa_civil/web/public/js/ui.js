// Utilitários de interface.
// h() monta elementos com textContent: dados vindos do banco nunca viram
// HTML (proteção contra XSS).

export function h(tag, attrs = {}, ...filhos) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'style' && typeof v === 'object') {
      for (const [sk, sv] of Object.entries(v)) {
        if (sk.startsWith('--')) el.style.setProperty(sk, sv); else el.style[sk] = sv;
      }
    }
    else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
    else if (k === 'dados') Object.entries(v).forEach(([dk, dv]) => { el.dataset[dk] = dv; });
    else if (v === true) el.setAttribute(k, '');
    else el.setAttribute(k, v);
  }
  anexar(el, filhos);
  return el;
}

function anexar(el, filhos) {
  for (const f of filhos.flat(Infinity)) {
    if (f === null || f === undefined || f === false) continue;
    el.append(f instanceof Node ? f : document.createTextNode(String(f)));
  }
}

const NS = 'http://www.w3.org/2000/svg';
export function s(tag, attrs = {}, ...filhos) {
  const el = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined) continue;
    if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v);
  }
  for (const f of filhos.flat(Infinity)) {
    if (f === null || f === undefined || f === false) continue;
    el.append(f instanceof Node ? f : document.createTextNode(String(f)));
  }
  return el;
}

export function limpar(el) { while (el.firstChild) el.firstChild.remove(); return el; }
// limpa e preenche (ignora null/false e achata listas, ao contrário do append nativo)
export function encher(el, ...filhos) { limpar(el); anexar(el, filhos); return el; }

// ícones (traço simples, 18px)
const ICONES = {
  painel: 'M3 13h7V3H3zM14 21h7V11h-7zM3 21h7v-5H3zM14 3v5h7V3z',
  graficos: 'M3 3v18h18M7 15l4-5 4 3 5-7',
  chuva: 'M7 15a5 5 0 1 1 1-9.9A6 6 0 0 1 19 9a4 4 0 0 1-1 7.9M8 19l-1 2M12 18l-1 3M16 19l-1 2',
  eventos: 'M12 3l9 16H3zM12 10v4M12 17v.5',
  historico: 'M3 12a9 9 0 1 0 3-6.7M3 4v5h5M12 7v5l3 2',
  exportar: 'M12 3v12M7 10l5 5 5-5M5 21h14',
  config: 'M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0M14 4v4M8 10v4M16 16v4',
  usuarios: 'M16 20v-1a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v1M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8M22 20v-1a4 4 0 0 0-3-3.9M16 3.1a4 4 0 0 1 0 7.8',
  auditoria: 'M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6zM9 12l2 2 4-4',
  backups: 'M4 7c0-1.7 3.6-3 8-3s8 1.3 8 3-3.6 3-8 3-8-1.3-8-3M4 7v10c0 1.7 3.6 3 8 3s8-1.3 8-3V7M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3',
  sair: 'M15 4h4a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1h-4M10 17l5-5-5-5M15 12H3',
  tema: 'M21 13A9 9 0 1 1 11 3a7 7 0 0 0 10 10',
  conta: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8M4 21a8 8 0 0 1 16 0',
  ok: 'M5 12l5 5L20 7',
  alerta: 'M12 3l9 16H3zM12 10v4M12 17v.5',
  escudo: 'M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z',
  baixar: 'M12 3v12M7 10l5 5 5-5M5 21h14',
  atualizar: 'M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7',
};
export function icone(nome, tam = 18) {
  return s('svg', { width: tam, height: tam, viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor',
    'stroke-width': 1.8, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true' },
  s('path', { d: ICONES[nome] || '' }));
}

// seta de direção do vento (aponta para onde o vento vai)
export function setaVento(graus, tam = 18) {
  return s('svg', { width: tam, height: tam, viewBox: '0 0 24 24', 'aria-hidden': 'true' },
    s('path', { d: 'M12 3l5 9h-3.5v9h-3v-9H7z', fill: 'currentColor',
      transform: `rotate(${(graus + 180) % 360} 12 12)` }));
}

// --- formatação (sempre no fuso de Brasília) ---------------------------
const FUSO = 'America/Sao_Paulo';
const fData = new Intl.DateTimeFormat('pt-BR', { timeZone: FUSO, day: '2-digit', month: '2-digit', year: '2-digit' });
const fHora = new Intl.DateTimeFormat('pt-BR', { timeZone: FUSO, hour: '2-digit', minute: '2-digit' });
const fHoraS = new Intl.DateTimeFormat('pt-BR', { timeZone: FUSO, hour: '2-digit', minute: '2-digit', second: '2-digit' });
const fDiaMes = new Intl.DateTimeFormat('pt-BR', { timeZone: FUSO, day: '2-digit', month: '2-digit' });
const fLonga = new Intl.DateTimeFormat('pt-BR', { timeZone: FUSO, weekday: 'long', day: 'numeric', month: 'long' });

export const fmt = {
  data: (v) => (v ? fData.format(new Date(v)) : '—'),
  hora: (v) => (v ? fHora.format(new Date(v)) : '—'),
  horaS: (v) => (v ? fHoraS.format(new Date(v)) : '—'),
  diaMes: (v) => (v ? fDiaMes.format(new Date(v)) : '—'),
  dataHora: (v) => (v ? `${fData.format(new Date(v))} ${fHora.format(new Date(v))}` : '—'),
  longa: (v) => fLonga.format(new Date(v)),
  num: (v, casas = 1) => (v === null || v === undefined || Number.isNaN(v) ? '—'
    : Number(v).toLocaleString('pt-BR', { minimumFractionDigits: casas, maximumFractionDigits: casas })),
  int: (v) => (v === null || v === undefined ? '—' : Number(v).toLocaleString('pt-BR')),
  bytes: (b) => {
    if (b === null || b === undefined) return '—';
    const u = ['B', 'KB', 'MB', 'GB']; let i = 0; let n = b;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return `${n.toLocaleString('pt-BR', { maximumFractionDigits: i ? 1 : 0 })} ${u[i]}`;
  },
  // "há 3 min", "há 2 h", relativo ao relógio do SERVIDOR
  ha: (v, agora) => {
    if (!v) return 'sem dados';
    const min = Math.round((agora - new Date(v)) / 60000);
    if (min < 1) return 'agora há pouco';
    if (min < 60) return `há ${min} min`;
    const hs = Math.floor(min / 60);
    if (hs < 48) return `há ${hs} h`;
    return `há ${Math.floor(hs / 24)} dias`;
  },
};

export const NOMES = {
  temperatura_ar: 'Temperatura do ar', umidade_ar: 'Umidade do ar', chuva: 'Chuva no minuto',
  chuva_acumulada: 'Chuva acumulada no dia', direcao_vento: 'Direção do vento',
  velocidade_vento: 'Velocidade do vento', radiacao_solar: 'Radiação solar',
  ALARME: 'Alarme', FALHA_SENSOR: 'Falha de sensor', FALHA_TRANSMISSAO: 'Falha de transmissão',
  LEITURA_REJEITADA: 'Leitura rejeitada', TRANSMISSAO_OK: 'Transmissão OK',
  OPERACIONAL: 'Operacional', ALERTA: 'Em alerta', FALHA: 'Com falha',
  ATENCAO: 'Atenção', CRITICO: 'Crítico',
  ADMIN: 'Administrador', OPERADOR: 'Operador', VISUALIZADOR: 'Visualizador',
  ACIMA: 'acima de', ABAIXO: 'abaixo de',
};
export const UNIDADES = {
  temperatura_ar: '°C', umidade_ar: '%', chuva: 'mm', chuva_acumulada: 'mm',
  direcao_vento: '°', velocidade_vento: 'm/s', radiacao_solar: 'W/m²',
};
export const nome = (k) => NOMES[k] || k;

export function selo(valor, classe = valor, texto = nome(valor)) {
  return h('span', { class: `selo ${classe}` }, texto);
}

// cor de cada estação nos gráficos (a mesma em todas as telas)
export function corEstacao(id) {
  const v = getComputedStyle(document.documentElement).getPropertyValue(`--estacao-${((id - 1) % 4) + 1}`);
  return v.trim() || '#1F6FB2';
}

// --- avisos (toasts) ---------------------------------------------------
export function avisar(texto, tipo = 'ok', titulo = null, duracao = 5000) {
  const el = h('div', { class: `aviso ${tipo}` }, titulo ? h('strong', {}, titulo) : null, texto);
  document.getElementById('avisos').append(el);
  setTimeout(() => el.remove(), duracao);
}

// --- diálogo modal (usa <dialog> nativo: foco e Esc já funcionam) -------
export function dialogo({ titulo, descricao, conteudo, confirmar = 'Salvar', cancelar = 'Cancelar', perigo = false, aoConfirmar }) {
  return new Promise((resolve) => {
    const erro = h('p', { class: 'erro-form', role: 'alert' });
    const btOk = h('button', { class: `botao ${perigo ? 'perigo' : 'primario'}`, type: 'submit' }, confirmar);
    const form = h('form', { method: 'dialog' },
      h('div', { class: 'cab' }, h('h2', {}, titulo), descricao ? h('p', { class: 'mudo pequeno' }, descricao) : null),
      h('div', { class: 'corpo' }, conteudo, erro),
      h('div', { class: 'pe' },
        cancelar ? h('button', { class: 'botao', type: 'button', onclick: () => fechar(null) }, cancelar) : null,
        btOk));
    const dlg = h('dialog', {}, form);
    function fechar(v) { dlg.close(); dlg.remove(); resolve(v); }
    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      erro.textContent = '';
      btOk.disabled = true;
      try {
        const r = aoConfirmar ? await aoConfirmar(new FormData(form)) : true;
        fechar(r === undefined ? true : r);
      } catch (e) {
        erro.textContent = e.message;
        btOk.disabled = false;
      }
    });
    dlg.addEventListener('cancel', (ev) => { ev.preventDefault(); fechar(null); });
    document.body.append(dlg);
    dlg.showModal();
  });
}

export function campo(rotulo, entrada, ajuda = null) {
  return h('label', { class: 'campo' }, h('span', {}, rotulo), entrada, ajuda ? h('small', { class: 'ajuda' }, ajuda) : null);
}

export function segmentado(opcoes, atual, aoMudar, rotulo) {
  const grupo = h('div', { class: 'segmentado', role: 'group', 'aria-label': rotulo });
  for (const [valor, texto] of opcoes) {
    grupo.append(h('button', { type: 'button', 'aria-pressed': String(valor === atual),
      onclick: () => {
        grupo.querySelectorAll('button').forEach((b) => b.setAttribute('aria-pressed', 'false'));
        grupo.querySelector(`[data-v="${valor}"]`).setAttribute('aria-pressed', 'true');
        aoMudar(valor);
      }, dados: { v: valor } }, texto));
  }
  return grupo;
}

export function bloco(titulo, descricao, acoes, ...conteudo) {
  return h('section', { class: 'bloco' },
    h('header', {}, h('h2', {}, titulo), descricao ? h('p', {}, descricao) : null,
      acoes ? h('div', { class: 'acoes' }, acoes) : null),
    conteudo);
}

export function tabela(colunas, linhas, opcoes = {}) {
  const thead = h('thead', {}, h('tr', {}, colunas.map((c) => h('th', { class: c.n ? 'n' : null, scope: 'col' }, c.titulo))));
  const tbody = h('tbody', {});
  if (!linhas.length) {
    tbody.append(h('tr', {}, h('td', { colspan: colunas.length, class: 'vazio' }, opcoes.vazio || 'Nada para mostrar.')));
  }
  for (const l of linhas) {
    const tr = h('tr', { class: opcoes.classeLinha ? opcoes.classeLinha(l) : null });
    for (const c of colunas) {
      const v = c.valor(l, tr);
      tr.append(h('td', { class: [c.n ? 'n' : '', c.classe || ''].join(' ').trim() || null }, v));
    }
    tbody.append(tr);
  }
  return h('div', { class: 'tabela-rolagem', style: opcoes.altura ? { maxHeight: opcoes.altura } : null },
    h('table', { class: 'tabela' }, thead, tbody));
}

export function vazio(texto) { return h('div', { class: 'vazio' }, texto); }
