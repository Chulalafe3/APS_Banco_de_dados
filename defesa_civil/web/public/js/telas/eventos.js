// Eventos: log filtrável; operador/admin reconhece em lote. Quem e quando
// reconheceu vêm do banco (relógio do servidor + usuário da sessão).
import { h, encher, limpar, segmentado, fmt, nome, selo, avisar, tabela } from '../ui.js';
import { get, post } from '../api.js';

const TIPOS = ['ALARME', 'FALHA_SENSOR', 'FALHA_TRANSMISSAO', 'LEITURA_REJEITADA', 'TRANSMISSAO_OK'];

export async function render(alvo, ctx) {
  const filtro = { tipos: new Set(TIPOS.slice(0, 4)), estacao: '', periodo: '7d', pendentes: false };
  const selecao = new Set();
  const podeAgir = ctx.pode('ADMIN', 'OPERADOR');
  const cfg = await get('/api/config');

  const contagem = h('div', { class: 'hoje' });
  const corpo = h('div', {});
  const btReconhecer = h('button', { class: 'botao primario', type: 'button', disabled: true, onclick: reconhecer }, 'Reconhecer selecionados');
  const infoSel = h('span', { class: 'mudo pequeno' });

  const pilulas = h('div', { class: 'pilulas', role: 'group', 'aria-label': 'Tipos de evento' },
    TIPOS.map((t) => h('button', {
      class: 'pilula', type: 'button', 'aria-pressed': String(filtro.tipos.has(t)),
      onclick: (ev) => {
        if (filtro.tipos.has(t) && filtro.tipos.size > 1) filtro.tipos.delete(t); else filtro.tipos.add(t);
        ev.currentTarget.setAttribute('aria-pressed', String(filtro.tipos.has(t)));
        carregar();
      },
    }, nome(t))));
  const selEstacao = h('select', { class: 'entrada', onchange: (ev) => { filtro.estacao = ev.target.value; carregar(); } },
    h('option', { value: '' }, 'Todas'), cfg.estacoes.map((e) => h('option', { value: e.id }, e.nome)));
  const chkPend = h('input', { type: 'checkbox', onchange: (ev) => { filtro.pendentes = ev.target.checked; carregar(); } });

  alvo.append(
    h('section', { class: 'bloco' },
      h('div', { class: 'filtros' },
        h('div', { class: 'campo' }, h('span', {}, 'Tipos'), pilulas),
        h('label', { class: 'campo' }, h('span', {}, 'Estação'), selEstacao),
        h('div', { class: 'campo' }, h('span', {}, 'Período'),
          segmentado([['24h', '24 horas'], ['7d', '7 dias'], ['30d', '30 dias'], ['tudo', 'Tudo']], filtro.periodo, (v) => { filtro.periodo = v; carregar(); }, 'Período')),
        h('label', { class: 'check', style: { paddingBottom: '.5rem' } }, chkPend, 'Só pendentes'))),
    contagem,
    h('section', { class: 'bloco' },
      podeAgir ? h('div', { class: 'linha-acoes', style: { marginBottom: '1rem' } }, btReconhecer, infoSel) : null,
      corpo));

  let lista = [];
  function atualizarSel() {
    btReconhecer.disabled = !selecao.size;
    infoSel.textContent = selecao.size ? `${selecao.size} selecionado(s)` : 'Selecione eventos pendentes para marcar como vistos.';
  }

  async function carregar() {
    const qs = new URLSearchParams({ tipos: [...filtro.tipos].join(','), estacoes: filtro.estacao, periodo: filtro.periodo, pendentes: filtro.pendentes ? '1' : '0' });
    const r = await get(`/api/eventos?${qs}`);
    lista = r.lista;
    selecao.clear(); atualizarSel();

    limpar(contagem);
    for (const t of TIPOS.filter((x) => filtro.tipos.has(x))) {
      const c = r.contagem.find((x) => x.tipo === t) || { total: 0, pendentes: 0 };
      contagem.append(h('div', {}, h('div', { class: 'v' }, fmt.int(c.total)),
        h('div', { class: 'r' }, `${nome(t).toLowerCase()}${t !== 'TRANSMISSAO_OK' ? `, ${fmt.int(c.pendentes)} pendente(s)` : ''}`)));
    }

    const pendentesVisiveis = lista.filter((e) => !e.reconhecido && e.tipo !== 'TRANSMISSAO_OK');
    const marcarTodos = h('input', {
      type: 'checkbox', 'aria-label': 'Selecionar todos os pendentes da lista',
      onchange: (ev) => {
        pendentesVisiveis.forEach((e) => (ev.target.checked ? selecao.add(e.id_evento) : selecao.delete(e.id_evento)));
        corpo.querySelectorAll('input[data-id]').forEach((c) => { c.checked = ev.target.checked; c.closest('tr').classList.toggle('selecionada', c.checked); });
        atualizarSel();
      },
    });

    const colunas = [];
    if (podeAgir) {
      colunas.push({
        titulo: marcarTodos,
        valor: (e, tr) => (e.reconhecido || e.tipo === 'TRANSMISSAO_OK' ? '' : h('input', {
          type: 'checkbox', 'aria-label': 'Selecionar evento', dados: { id: e.id_evento },
          onchange: (ev) => { (ev.target.checked ? selecao.add(e.id_evento) : selecao.delete(e.id_evento)); tr.classList.toggle('selecionada', ev.target.checked); atualizarSel(); },
        })),
      });
    }
    colunas.push(
      { titulo: 'Quando', valor: (e) => h('span', {}, fmt.data(e.data_hora), ' ', h('strong', {}, fmt.hora(e.data_hora))) },
      { titulo: 'Estação', valor: (e) => e.estacao },
      { titulo: 'Tipo', valor: (e) => selo(e.tipo, `tipo-${e.tipo}`) },
      { titulo: 'Mensagem', classe: 'msg', valor: (e) => e.mensagem },
      { titulo: 'Situação', valor: (e) => (e.tipo === 'TRANSMISSAO_OK' ? h('span', { class: 'mudo' }, 'informativo')
        : e.reconhecido ? h('span', { class: 'pequeno' }, `Visto por ${e.reconhecido_por || 'sistema'}`, h('br'), h('span', { class: 'mudo' }, fmt.dataHora(e.reconhecido_em)))
          : h('strong', { style: { color: 'var(--alerta)' } }, 'Pendente')) },
    );
    encher(corpo, 
      tabela(colunas, lista, {
        vazio: 'Nenhum evento com esses filtros.', altura: '65vh',
        classeLinha: (e) => (!e.reconhecido && e.tipo !== 'TRANSMISSAO_OK' ? 'pendente' : null),
      }),
      lista.length >= r.limite ? h('p', { class: 'mudo pequeno', style: { marginTop: '.6rem' } }, `Mostrando os ${r.limite} mais recentes. Use os filtros para refinar.`) : null);
  }

  async function reconhecer() {
    btReconhecer.disabled = true;
    try {
      const r = await post('/api/eventos/reconhecer', { ids: [...selecao] });
      avisar(`${r.reconhecidos} evento(s) reconhecido(s). Ficou registrado na auditoria.`);
      ctx.atualizarContador();
      await carregar();
    } catch (e) { avisar(e.message, 'erro'); atualizarSel(); }
  }

  ctx.ouvir('evento', () => { if (!selecao.size) carregar(); });
  await carregar();
}
