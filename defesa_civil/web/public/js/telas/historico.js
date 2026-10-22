// Histórico: resumo mensal (meses arquivados + recentes) e o ciclo de
// vida dos dados (partições ativas, arquivadas e futuras).
import { h, fmt, bloco, tabela } from '../ui.js';
import { get } from '../api.js';

const MESES = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'];
const nomeMes = (aaaamm) => `${MESES[+aaaamm.slice(4, 6) - 1]}/${aaaamm.slice(2, 4)}`;

export async function render(alvo, ctx) {
  const r = await get('/api/historico');
  const agora = ctx.agora();
  const mesAtual = `${agora.getFullYear()}${String(agora.getMonth() + 1).padStart(2, '0')}`;

  // --- linha do tempo das partições
  const partes = h('div', { class: 'partes' });
  for (const p of r.particoes) {
    const m = p.nome.replace(/\D/g, '');
    const arquivo = p.tabela === 'leitura_arquivo';
    const futura = !arquivo && m > mesAtual;
    partes.append(h('div', { class: `p ${arquivo ? 'arquivo' : futura ? 'futura' : 'recente'}`,
      title: `${p.nome} (${p.tabela})` },
    h('strong', {}, nomeMes(m)), arquivo ? 'arquivada' : futura ? 'pronta' : 'ativa'));
  }

  const armazenamento = tabela([
    { titulo: 'Tabela', valor: (a) => h('strong', {}, a.tabela) },
    { titulo: 'Conteúdo', valor: (a) => a.descricao },
    { titulo: 'Partições', n: true, valor: (a) => (a.particoes === null ? '—' : a.particoes) },
    { titulo: 'Tamanho', n: true, valor: (a) => fmt.bytes(a.bytes) },
  ], r.armazenamento);

  alvo.append(bloco('Ciclo de vida dos dados',
    'A tabela de leituras é dividida por mês. O mês atual e o anterior ficam ativos; os mais antigos viram resumo diário e a partição inteira vai para o arquivo (sem apagar linha por linha). Partições futuras são criadas com antecedência.',
    null,
    partes,
    h('div', { class: 'legenda', style: { margin: '.8rem 0 1.2rem' } },
      h('span', {}, h('span', { class: 'tr', style: { background: 'var(--agua)' } }), 'ativa: recebe leituras'),
      h('span', {}, h('span', { class: 'tr', style: { background: 'var(--tinta-3)' } }), 'arquivada: índice BRIN, só consulta'),
      h('span', {}, h('span', { class: 'tr tracejado', style: { '--c': 'var(--tinta-3)' } }), 'pronta: criada antes de o mês começar')),
    armazenamento));

  // --- resumo mensal
  alvo.append(bloco('Resumo por mês', 'Meses arquivados vêm do resumo diário; meses ativos são calculados das leituras.', null,
    tabela([
      { titulo: 'Mês', valor: (m) => h('strong', {}, nomeMes(m.mes.replace('-', ''))) },
      { titulo: 'Estação', valor: (m) => m.estacao },
      { titulo: 'Temp. média', n: true, valor: (m) => `${fmt.num(m.temp_media, 1)} °C` },
      { titulo: 'Mín / máx', n: true, valor: (m) => `${fmt.num(m.temp_min, 1)} / ${fmt.num(m.temp_max, 1)}` },
      { titulo: 'Umidade mín.', n: true, valor: (m) => `${fmt.num(m.umidade_min, 0)} %` },
      { titulo: 'Chuva total', n: true, valor: (m) => `${fmt.num(m.chuva_total, 1)} mm` },
      { titulo: 'Vento máx.', n: true, valor: (m) => `${fmt.num(m.vento_max, 1)} m/s` },
      { titulo: 'Leituras', n: true, valor: (m) => fmt.int(m.leituras) },
      { titulo: 'Valores inválidos', n: true, valor: (m) => fmt.int(m.invalidos) },
      { titulo: 'Origem', valor: (m) => (m.origem === 'arquivo' ? 'arquivo' : h('span', { style: { color: 'var(--agua)' } }, 'ativo')) },
    ], r.meses.slice().reverse(), { altura: '60vh' })));

  alvo.append(bloco('Arquivamentos realizados', 'Cada mês movido para o arquivo, com o tempo que levou.', null,
    tabela([
      { titulo: 'Partição', valor: (a) => a.particao },
      { titulo: 'Executado em', valor: (a) => fmt.dataHora(a.executado_em) },
      { titulo: 'Leituras movidas', n: true, valor: (a) => fmt.int(a.linhas_movidas) },
      { titulo: 'Dias resumidos', n: true, valor: (a) => fmt.int(a.dias_resumidos) },
      { titulo: 'Duração', n: true, valor: (a) => `${fmt.num(a.duracao_ms, 0)} ms` },
    ], r.arquivamento, { vazio: 'Nenhum mês arquivado ainda.' })));
}
