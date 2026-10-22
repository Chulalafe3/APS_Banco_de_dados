// Gráficos: temperatura, umidade, vento e radiação por período, com as
// linhas dos limites de alarme.
import { h, encher, limpar, segmentado, corEstacao, bloco } from '../ui.js';
import { get } from '../api.js';
import { graficoLinhas } from '../graficos.js';

const SERIES = [
  { campo: 'temperatura', titulo: 'Temperatura do ar', unidade: '°C', regra: 'temperatura_ar', casas: 1 },
  { campo: 'umidade', titulo: 'Umidade do ar', unidade: '%', regra: 'umidade_ar', casas: 0 },
  { campo: 'vento', titulo: 'Velocidade do vento (máxima)', unidade: 'm/s', regra: 'velocidade_vento', casas: 1, minZero: true },
  { campo: 'radiacao', titulo: 'Radiação solar', unidade: 'W/m²', casas: 0, minZero: true },
];

export async function render(alvo, ctx) {
  let periodo = '24h';
  let estacoes = [];
  let selecionadas = new Set();
  const legenda = h('div', { class: 'legenda' });
  const grade = h('div', { class: 'grade-2' });
  const filtros = h('div', { class: 'filtros' });
  alvo.append(h('section', { class: 'bloco' }, filtros, h('div', { style: { marginTop: '1rem' } }, legenda)), grade);

  const cfg = await get('/api/config');
  estacoes = cfg.estacoes;
  selecionadas = new Set(estacoes.map((e) => e.id));

  const pilulas = h('div', { class: 'pilulas', role: 'group', 'aria-label': 'Estações' },
    estacoes.map((e) => h('button', {
      class: 'pilula', type: 'button', 'aria-pressed': 'true',
      onclick: (ev) => {
        const b = ev.currentTarget;
        if (selecionadas.has(e.id) && selecionadas.size > 1) selecionadas.delete(e.id); else selecionadas.add(e.id);
        b.setAttribute('aria-pressed', String(selecionadas.has(e.id)));
        carregar();
      },
    }, h('span', { class: 'pt', style: { background: corEstacao(e.id) } }), e.nome)));

  filtros.append(
    h('div', { class: 'campo' }, h('span', {}, 'Período'),
      segmentado([['24h', 'Últimas 24 horas'], ['7d', '7 dias'], ['30d', '30 dias']], periodo, (v) => { periodo = v; carregar(); }, 'Período')),
    h('div', { class: 'campo' }, h('span', {}, 'Estações'), pilulas));

  const desligar = [];
  ctx.aoSair(() => desligar.forEach((f) => f()));

  async function carregar() {
    const r = await get(`/api/series?periodo=${periodo}&estacoes=${[...selecionadas].join(',')}`);
    desligar.forEach((f) => f()); desligar.length = 0;
    limpar(grade);
    const raiz = getComputedStyle(document.documentElement);
    const corNivel = { ATENCAO: raiz.getPropertyValue('--atencao').trim(), ALERTA: raiz.getPropertyValue('--alerta').trim(), CRITICO: raiz.getPropertyValue('--critico').trim() };
    const intervalo = periodo === '24h' ? 5 * 60e3 : 3600e3;

    encher(legenda, 
      ...estacoes.filter((e) => selecionadas.has(e.id)).map((e) => h('span', {}, h('span', { class: 'tr', style: { background: corEstacao(e.id) } }), e.nome)),
      h('span', {}, h('span', { class: 'tr tracejado', style: { '--c': corNivel.ALERTA } }), 'limite de alarme'),
      h('span', { class: 'mudo' }, periodo === '24h' ? 'Médias de 5 em 5 minutos.' : 'Médias por hora (view materializada, atualizada a cada 10 min).'));

    for (const se of SERIES) {
      const caixa = h('div', {});
      // um limite por regra (se for igual nas estações, aparece uma vez)
      const vistos = new Map();
      for (const rg of r.regras.filter((x) => x.parametro === se.regra && selecionadas.has(x.id))) {
        const chave = `${rg.condicao}${rg.limite}`;
        if (!vistos.has(chave)) vistos.set(chave, { valor: rg.limite, cor: corNivel[rg.nivel], rotulo: `${rg.condicao === 'ACIMA' ? 'acima de' : 'abaixo de'} ${rg.limite} ${se.unidade}` });
      }
      grade.append(bloco(se.titulo, null, null, caixa));
      desligar.push(graficoLinhas(caixa, {
        unidade: se.unidade, casas: se.casas, minZero: se.minZero, limites: [...vistos.values()], rotulo: se.titulo,
        series: estacoes.filter((e) => selecionadas.has(e.id)).map((e) => ({
          id: e.id, nome: e.nome, cor: corEstacao(e.id), intervalo,
          pontos: r.pontos.filter((p) => p.id === e.id).map((p) => ({ t: Date.parse(p.t), v: p[se.campo] })),
        })),
      }));
    }
  }

  // em 24 h, acompanha o tempo real
  let t = null;
  ctx.ouvir('lote', () => { if (periodo === '24h') { clearTimeout(t); t = setTimeout(carregar, 800); } });
  ctx.aoSair(() => clearTimeout(t));
  await carregar();
}
