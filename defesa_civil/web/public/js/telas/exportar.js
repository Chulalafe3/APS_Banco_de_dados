// Exportar: leituras no formato de planilha (CSV para Excel em português).
import { h, segmentado, bloco, campo } from '../ui.js';
import { get } from '../api.js';

export async function render(alvo) {
  const cfg = await get('/api/config');
  let periodo = '24h';
  const sel = h('select', {}, h('option', { value: '' }, 'Todas as estações'),
    cfg.estacoes.map((e) => h('option', { value: e.id }, e.nome)));
  const estimativa = h('p', { class: 'mudo pequeno' });
  const linhas = { '24h': 1440, '7d': 10080, '30d': 43200 };
  const atualizar = () => {
    const n = linhas[periodo] * (sel.value ? 1 : cfg.estacoes.length);
    estimativa.textContent = `Cerca de ${n.toLocaleString('pt-BR')} linhas (uma por estação por minuto).`;
  };
  sel.addEventListener('change', atualizar);

  const baixar = h('a', {
    class: 'botao primario', href: '#',
    onclick: (ev) => {
      ev.preventDefault();
      const qs = new URLSearchParams({ periodo, estacoes: sel.value });
      window.location.href = `/api/exportar.csv?${qs}`;
    },
  }, 'Baixar planilha (CSV)');

  alvo.append(bloco('Exportar leituras', 'Arquivo CSV separado por ponto e vírgula, com vírgula decimal: abre direto no Excel em português.', null,
    h('div', { class: 'formulario', style: { maxWidth: '560px' } },
      campo('Estação', sel),
      h('div', { class: 'campo' }, h('span', {}, 'Período (até agora)'),
        segmentado([['24h', 'Últimas 24 horas'], ['7d', '7 dias'], ['30d', '30 dias']], periodo, (v) => { periodo = v; atualizar(); }, 'Período')),
      estimativa,
      h('div', { class: 'linha-acoes' }, baixar),
      h('p', { class: 'mudo pequeno' }, 'Cada exportação fica registrada na auditoria, com o usuário, o período e a quantidade de leituras.'))));
  atualizar();
}
