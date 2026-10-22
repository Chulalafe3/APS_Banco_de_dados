// Configuração: regras de alarme e faixas dos sensores (OPERADOR/ADMIN),
// parâmetros do banco e chaves das estações (ADMIN). Toda alteração é
// conferida pelo banco (RLS) e vai para a auditoria com antes/depois.
import { h, limpar, fmt, nome, bloco, tabela, avisar, dialogo, campo } from '../ui.js';
import { get, put, post } from '../api.js';

const NIVEIS = { ATENCAO: 'Atenção', ALERTA: 'Alerta', CRITICO: 'Crítico' };

export async function render(alvo, ctx) {
  const admin = ctx.pode('ADMIN');
  const caixa = h('div', { style: { display: 'contents' } });
  alvo.append(caixa);

  async function carregar() {
    const c = await get('/api/config');
    limpar(caixa);

    // linha editável: os campos mudam e o botão Salvar acende
    function editavel(valores, campos, salvar) {
      const btn = h('button', { class: 'botao pequeno', type: 'button', disabled: true }, 'Salvar');
      const entradas = {};
      const marcar = () => { btn.disabled = false; btn.classList.add('primario'); };
      for (const [k, tipo, extra] of campos) {
        let el;
        if (tipo === 'check') el = h('input', { type: 'checkbox', checked: !!valores[k], onchange: marcar, 'aria-label': k });
        else if (tipo === 'select') el = h('select', { class: 'entrada', onchange: marcar, 'aria-label': k }, extra.map((o) => h('option', { value: o, selected: o === valores[k] }, NIVEIS[o] || nome(o))));
        else el = h('input', { class: `entrada ${tipo === 'texto' ? 'largo' : ''}`, type: tipo === 'texto' ? 'text' : 'number', step: 'any', value: valores[k] ?? '', oninput: marcar, 'aria-label': k });
        entradas[k] = el;
      }
      btn.addEventListener('click', async () => {
        const dados = Object.fromEntries(Object.entries(entradas).map(([k, el]) => [k, el.type === 'checkbox' ? el.checked : el.value]));
        btn.disabled = true;
        try { await salvar(dados); avisar('Alteração salva e registrada na auditoria.'); btn.classList.remove('primario'); }
        catch (e) { avisar(e.message, 'erro'); btn.disabled = false; }
      });
      return { entradas, btn };
    }

    // --- regras de alarme
    caixa.append(bloco('Regras de alarme', 'Quando o valor cruza o limite, o banco gera um alarme (no máximo um por hora por regra).', null,
      tabela([
        { titulo: 'Estação', valor: (r) => r.estacao },
        { titulo: 'Parâmetro', valor: (r) => nome(r.parametro) },
        { titulo: 'Condição', valor: (r) => nome(r.condicao) },
        { titulo: 'Limite', valor: (r) => h('span', {}, r._e.entradas.limite, ' ', h('span', { class: 'mudo' }, r.parametro.includes('chuva') ? 'mm' : r.parametro === 'velocidade_vento' ? 'm/s' : r.parametro === 'temperatura_ar' ? '°C' : '%')) },
        { titulo: 'Nível', valor: (r) => r._e.entradas.nivel },
        { titulo: 'Nota', valor: (r) => r._e.entradas.nota },
        { titulo: 'Ativa', valor: (r) => r._e.entradas.ativo },
        { titulo: '', valor: (r) => r._e.btn },
      ], c.regras.map((r) => ({ ...r, _e: editavel(r, [['limite', 'num'], ['nivel', 'select', ['ATENCAO', 'ALERTA', 'CRITICO']], ['nota', 'texto'], ['ativo', 'check']],
        (d) => put(`/api/regras/${r.id_regra}`, d)) })))));

    // --- sensores
    caixa.append(bloco('Faixa válida dos sensores', 'Valor fora desta faixa é tratado como falha do sensor: é descartado e vira evento.', null,
      tabela([
        { titulo: 'Estação', valor: (s) => s.estacao },
        { titulo: 'Parâmetro', valor: (s) => nome(s.parametro) },
        { titulo: 'Mínimo', valor: (s) => s._e.entradas.limite_min },
        { titulo: 'Máximo', valor: (s) => s._e.entradas.limite_max },
        { titulo: 'Unidade', valor: (s) => s.unidade },
        { titulo: 'Ativo', valor: (s) => s._e.entradas.ativo },
        { titulo: '', valor: (s) => s._e.btn },
      ], c.sensores.map((s) => ({ ...s, _e: editavel(s, [['limite_min', 'num'], ['limite_max', 'num'], ['ativo', 'check']],
        (d) => put(`/api/sensores/${s.id_sensor}`, d)) })), { altura: '50vh' })));

    // --- parâmetros do banco
    caixa.append(bloco('Regras de datas e retenção', admin ? 'Usadas pelo banco para validar leituras e manter as partições.' : 'Somente o administrador altera estes valores.', null,
      tabela([
        { titulo: 'Parâmetro', valor: (p) => h('div', {}, h('strong', {}, p.descricao), h('div', { class: 'mudo pequeno' }, p.chave)) },
        { titulo: 'Valor', valor: (p) => (admin ? h('span', {}, p._e.entradas.valor, ' ', p.unidade) : `${p.valor} ${p.unidade}`) },
        { titulo: 'Alterado em', valor: (p) => fmt.dataHora(p.alterado_em) },
        { titulo: '', valor: (p) => (admin ? p._e.btn : '') },
      ], c.parametros.map((p) => ({ ...p, _e: editavel(p, [['valor', 'num']], (d) => put(`/api/parametros/${p.chave}`, d)) })))));

    // --- estações
    caixa.append(bloco('Estações', 'Dispositivos reais enviam leituras para /api/ingest com a chave da estação no cabeçalho.', null,
      tabela([
        { titulo: 'Estação', valor: (e) => h('strong', {}, e.nome) },
        { titulo: 'Leitura / transmissão', valor: (e) => `a cada ${e.intervalo_leitura_min} min / ${e.intervalo_transmissao_min} min` },
        { titulo: 'Localização', valor: (e) => `${fmt.num(e.latitude, 4)}, ${fmt.num(e.longitude, 4)}` },
        { titulo: 'Origem dos dados', valor: (e) => (e.simulado ? 'simulador em tempo real' : 'dispositivo') },
        { titulo: '', valor: (e) => (admin ? h('button', { class: 'botao pequeno', type: 'button', onclick: () => gerarChave(e) }, 'Gerar chave de API') : '') },
      ], c.estacoes)));
  }

  async function gerarChave(e) {
    const ok = await dialogo({
      titulo: `Nova chave para ${e.nome}`,
      descricao: 'A chave atual deixa de funcionar na hora. A nova aparece uma única vez: o banco guarda só o hash dela.',
      conteudo: h('p', {}, 'Gerar uma nova chave?'), confirmar: 'Gerar chave', perigo: true,
    });
    if (!ok) return;
    try {
      const r = await post(`/api/dispositivos/${e.id}/chave`);
      const exemplo = `curl -X POST http://${location.host}/api/ingest -H "X-Chave-Dispositivo: ${r.chave}" -H "Content-Type: application/json" -d "[{\\"data_hora\\":\\"AAAA-MM-DDTHH:MM:00-03:00\\",\\"temperatura_ar\\":24.1}]"`;
      await dialogo({
        titulo: 'Chave gerada', descricao: 'Copie agora e configure no dispositivo. Ela não será mostrada de novo.',
        conteudo: h('div', { class: 'formulario' }, campo('Chave', h('div', { class: 'codigo' }, r.chave)),
          campo('Exemplo de envio', h('div', { class: 'codigo' }, exemplo))),
        confirmar: 'Fechar', cancelar: null,
      });
    } catch (err) { avisar(err.message, 'erro'); }
  }

  await carregar();
}
