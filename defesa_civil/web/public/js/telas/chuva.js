// Chuva: total por dia de cada estação, com o limite crítico, e a lista
// dos dias que passaram do limite.
import { h, encher, limpar, segmentado, corEstacao, bloco, fmt, tabela } from '../ui.js';
import { get } from '../api.js';
import { graficoBarras } from '../graficos.js';

export async function render(alvo, ctx) {
  let dias = '30';
  const resumo = h('div', { class: 'hoje' });
  const caixa = h('div', {});
  const lista = h('div', {});
  alvo.append(
    h('section', { class: 'bloco' },
      h('header', {}, h('h2', {}, 'Chuva por dia'),
        h('p', {}, 'Dias recentes vêm das leituras; meses arquivados, do resumo diário.'),
        h('div', { class: 'acoes' }, segmentado([['30', '30 dias'], ['90', '90 dias'], ['180', '180 dias']], dias, (v) => { dias = v; carregar(); }, 'Período'))),
      caixa),
    resumo,
    bloco('Dias acima do limite crítico', 'Chuva acumulada no dia maior que o limite da regra de alarme.', null, lista));

  const [cfg] = await Promise.all([get('/api/config')]);
  let desligar = () => {};
  ctx.aoSair(() => desligar());

  async function carregar() {
    const r = await get(`/api/chuva?dias=${dias}`);
    const todosDias = [...new Set(r.dados.map((d) => d.dia))].sort();
    const series = cfg.estacoes.map((e) => ({
      id: e.id, nome: e.nome, cor: corEstacao(e.id),
      valores: Object.fromEntries(r.dados.filter((d) => d.id === e.id).map((d) => [d.dia, d.chuva || 0])),
    }));
    desligar();
    desligar = graficoBarras(caixa, { dias: todosDias, series, limite: r.limite, rotulo: 'Chuva por dia' });

    limpar(resumo);
    for (const se of series) {
      const v = Object.values(se.valores);
      const total = v.reduce((a, b) => a + b, 0);
      const chuvosos = v.filter((x) => x >= 1).length;
      resumo.append(
        h('div', {}, h('div', { class: 'v', style: { color: se.cor } }, `${fmt.num(total, 0)} mm`), h('div', { class: 'r' }, `total na ${se.nome}`)),
        h('div', {}, h('div', { class: 'v' }, chuvosos), h('div', { class: 'r' }, `dias com chuva (≥ 1 mm) na ${se.nome}`)));
    }

    const acima = r.dados.filter((d) => r.limite !== null && d.chuva > r.limite).sort((a, b) => b.dia.localeCompare(a.dia));
    const nomeEst = Object.fromEntries(cfg.estacoes.map((e) => [e.id, e.nome]));
    encher(lista, tabela([
      { titulo: 'Dia', valor: (d) => `${d.dia.slice(8, 10)}/${d.dia.slice(5, 7)}/${d.dia.slice(0, 4)}` },
      { titulo: 'Estação', valor: (d) => nomeEst[d.id] },
      { titulo: 'Chuva no dia', n: true, valor: (d) => `${fmt.num(d.chuva, 1)} mm` },
      { titulo: 'Acima do limite', n: true, valor: (d) => `+${fmt.num(d.chuva - r.limite, 1)} mm` },
    ], acima, { vazio: `Nenhum dia passou de ${fmt.num(r.limite, 0)} mm neste período.` }));
  }
  await carregar();
}
