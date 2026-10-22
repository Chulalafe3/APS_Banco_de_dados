// Painel: situação agora, uma estação por cartão (com pluviômetro),
// números de hoje e os últimos alarmes/falhas. Atualiza sozinho quando
// chega um lote (tempo real).
import { h, encher, icone, limpar, fmt, nome, selo, setaVento, corEstacao, avisar, bloco } from '../ui.js';
import { get, post } from '../api.js';
import { pluviometro, minicurva } from '../graficos.js';

export async function render(alvo, ctx) {
  const situacao = h('div', { class: 'situacao' });
  const estacoes = h('div', { class: 'estacoes' });
  const hoje = h('div', { class: 'hoje' });
  const feed = h('div', { class: 'feed' });
  const podeAgir = ctx.pode('ADMIN', 'OPERADOR');

  alvo.append(
    situacao,
    estacoes,
    hoje,
    bloco('Últimos alarmes e falhas', 'Os mais recentes primeiro. Reconhecer marca que alguém já viu.',
      h('a', { class: 'botao pequeno', href: '#/eventos' }, 'Ver todos os eventos'), feed));

  let dados = null;
  async function carregar() {
    try {
      dados = await get('/api/painel');
      desenhar();
    } catch (e) {
      if (!dados) encher(estacoes, h('div', { class: 'faixa erro' }, icone('alerta', 22), h('div', { class: 'texto' }, h('strong', {}, 'Não foi possível carregar o painel'), e.message)));
    }
  }

  function limiteDe(id, parametro) {
    return dados.regras.find((r) => r.id === id && r.parametro === parametro);
  }
  function viola(id, parametro, valor) {
    const r = limiteDe(id, parametro);
    if (!r || valor === null || valor === undefined) return false;
    return r.condicao === 'ACIMA' ? valor > r.limite : valor < r.limite;
  }

  function desenhar() {
    const agora = ctx.agora();

    // --- frase de situação
    const criticas = dados.estacoes.filter((e) => e.chuva_acumulada > (limiteDe(e.id, 'chuva_acumulada')?.limite ?? Infinity));
    const falhas = dados.estacoes.filter((e) => e.status === 'FALHA');
    const alertas = dados.estacoes.filter((e) => e.status === 'ALERTA');
    const atrasadas = dados.estacoes.filter((e) => e.minutos_sem_comunicacao > e.intervalo_transmissao_min + 5);
    let frase; let cls;
    if (criticas.length) { frase = `Chuva acima do limite crítico em ${criticas.map((e) => e.nome).join(' e ')}`; cls = 'erro'; }
    else if (falhas.length) { frase = `Falha em ${falhas.map((e) => e.nome).join(' e ')}`; cls = 'erro'; }
    else if (atrasadas.length) { frase = `Sem comunicação com ${atrasadas.map((e) => e.nome).join(' e ')}`; cls = 'erro'; }
    else if (alertas.length) { frase = `${alertas.map((e) => e.nome).join(' e ')} em alerta`; cls = 'alerta'; }
    else { frase = dados.estacoes.length === 1 ? 'A estação está operando normalmente' : `As ${dados.estacoes.length} estações estão operando normalmente`; cls = 'ok'; }
    const ultima = dados.estacoes.map((e) => e.ultima_comunicacao).filter(Boolean).sort().pop();

    encher(situacao, 
      h('div', { class: `faixa ${cls}`, style: { flex: '1' } },
        h('span', { class: 'icone' }, icone(cls === 'ok' ? 'ok' : 'alerta', 26)),
        h('div', { class: 'texto' },
          h('div', { class: 'frase' }, frase,
            h('small', {}, ultima ? `Último lote recebido ${fmt.ha(ultima, agora)}, às ${fmt.hora(ultima)}. As estações transmitem a cada 10 minutos.` : 'Nenhum lote recebido ainda.'))),
        podeAgir ? h('button', {
          class: 'botao', type: 'button', title: 'Pede às estações simuladas que transmitam agora, sem esperar os 10 minutos',
          onclick: async (ev) => {
            const bt = ev.currentTarget;
            bt.disabled = true;
            try { const r = await post('/api/simulador/transmitir'); avisar(`${r.leituras} leitura(s) nova(s) recebida(s).`); await carregar(); }
            catch (e) { avisar(e.message, 'erro'); bt.disabled = false; }
          },
        }, icone('atualizar'), 'Transmitir agora') : null));

    // --- cartões das estações
    limpar(estacoes);
    for (const e of dados.estacoes) estacoes.append(cartao(e, agora));
    if (!dados.estacoes.length) estacoes.append(h('div', { class: 'vazio bloco' }, 'Nenhuma estação ativa para o seu usuário.'));

    // --- hoje
    const hj = dados.hoje;
    encher(hoje, 
      item(fmt.int(hj.leituras), 'leituras gravadas hoje'),
      item(fmt.int(hj.transmissoes), 'lotes recebidos'),
      item(fmt.int(hj.alarmes), 'alarmes'),
      item(fmt.int(hj.falhas_sensor), 'falhas de sensor'),
      item(fmt.int(hj.falhas_transmissao), 'falhas de transmissão'),
      item(fmt.int(hj.lotes_com_rejeicao), 'lotes com leitura rejeitada'));

    // --- feed
    limpar(feed);
    if (!dados.eventos.length) feed.append(h('p', { class: 'vazio' }, 'Nenhum alarme ou falha registrado.'));
    for (const ev of dados.eventos) {
      feed.append(h('div', { class: `item${ev.reconhecido ? ' visto' : ''}` },
        h('time', { datetime: ev.data_hora }, fmt.hora(ev.data_hora), h('small', {}, fmt.data(ev.data_hora))),
        h('div', { class: 'm' },
          h('div', { class: 'topo-item' }, selo(ev.tipo, `tipo-${ev.tipo}`), h('strong', {}, ev.estacao),
            ev.reconhecido ? h('span', { class: 'mudo pequeno' }, 'reconhecido')
              : podeAgir ? h('button', { class: 'botao discreto pequeno', type: 'button', onclick: () => reconhecer(ev.id_evento) }, 'Reconhecer') : null),
          ev.mensagem)));
    }
  }

  function item(v, r) { return h('div', {}, h('div', { class: 'v' }, v), h('div', { class: 'r' }, r)); }

  function cartao(e, agora) {
    const limChuva = limiteDe(e.id, 'chuva_acumulada')?.limite ?? 50;
    const tend = dados.tendencia.filter((t) => t.id === e.id);
    const temAlarme = (p, v) => (viola(e.id, p, v) ? { style: { color: 'var(--alerta)' } } : {});
    const medida = (rotulo, valor, unidade, extra = null, parametro = null) => h('div', { class: 'medida' },
      h('div', { class: 'r' }, rotulo),
      h('div', { class: 'v', ...(parametro ? temAlarme(parametro, valor) : {}) }, extra, valor, unidade ? h('small', {}, unidade) : null));
    const atrasada = e.minutos_sem_comunicacao > e.intervalo_transmissao_min + 5;

    return h('article', { class: 'estacao', dados: { status: e.status }, 'aria-label': e.nome },
      h('div', { class: 'tubo-lado' },
        h('div', { class: 'rotulo' }, 'Chuva hoje'),
        pluviometro(e.chuva_acumulada || 0, limChuva),
        h('div', { class: 'valor' }, fmt.num(e.chuva_acumulada, 1), h('small', {}, ' mm')),
        h('div', { class: 'rotulo' }, `limite ${fmt.num(limChuva, 0)} mm`)),
      h('div', { class: 'dados' },
        h('div', { class: 'cab-est' },
          h('h2', {}, e.nome), selo(e.status),
          h('div', { class: 'quando' }, e.ultima_leitura
            ? `Leitura das ${fmt.hora(e.ultima_leitura)}, recebida ${fmt.ha(e.ultima_comunicacao, agora)}`
            : 'Ainda sem leituras')),
        h('div', { class: 'temperatura' },
          h('div', { class: 'grande', ...temAlarme('temperatura_ar', e.temperatura_ar) }, fmt.num(e.temperatura_ar, 1), h('small', {}, '°C')),
          minicurva(tend.map((t) => t.temperatura), corEstacao(e.id), { rotulo: 'Temperatura nas últimas 6 horas' })),
        h('div', { class: 'medidas' },
          medida('Umidade', fmt.num(e.umidade_ar, 0), '%', null, 'umidade_ar'),
          medida('Vento', fmt.num(e.velocidade_vento, 1), 'm/s', null, 'velocidade_vento'),
          medida('Direção', `${fmt.num(e.direcao_vento, 0)}°`, null, e.direcao_vento !== null ? setaVento(e.direcao_vento) : null),
          medida('Radiação', fmt.num(e.radiacao_solar, 0), 'W/m²'),
          medida('Vento em km/h', fmt.num(e.velocidade_vento * 3.6, 0), 'km/h'),
          medida('Pendências', fmt.int(e.pendentes), null)),
        h('div', { class: 'rodape-est' },
          atrasada ? h('strong', { style: { color: 'var(--critico)' } }, `Sem comunicação há ${e.minutos_sem_comunicacao} min`) : h('span', {}, `Transmite a cada ${e.intervalo_transmissao_min} min`),
          h('a', { href: '#/graficos' }, 'Ver gráficos'))));
  }

  async function reconhecer(id) {
    try { await post('/api/eventos/reconhecer', { ids: [id] }); ctx.atualizarContador(); await carregar(); }
    catch (e) { avisar(e.message, 'erro'); }
  }

  // tempo real: recarrega quando chega lote ou evento (com pequena espera
  // para juntar avisos de várias estações)
  let t = null;
  const agendar = () => { clearTimeout(t); t = setTimeout(carregar, 600); };
  ctx.ouvir('lote', agendar);
  ctx.ouvir('evento', agendar);
  const relogio = setInterval(() => dados && desenhar(), 30000);   // "há X min"
  ctx.aoSair(() => { clearInterval(relogio); clearTimeout(t); });

  await carregar();
}
