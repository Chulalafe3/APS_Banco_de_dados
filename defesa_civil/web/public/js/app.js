// Núcleo do painel: login, estrutura, rotas, relógio do servidor e tempo real.
import { h, s, icone, limpar, fmt, nome, avisar, campo } from './ui.js';
import { get, post, estado, agoraServidor, ajustarRelogio, conectarTempoReal, desconectarTempoReal, ouvir } from './api.js';

// telas: módulo, título, ícone e perfis que veem a tela no menu
const TELAS = {
  painel:     { titulo: 'Painel',         icone: 'painel',    grupo: 'Monitoramento' },
  graficos:   { titulo: 'Gráficos',       icone: 'graficos',  grupo: 'Monitoramento' },
  chuva:      { titulo: 'Chuva',          icone: 'chuva',     grupo: 'Monitoramento' },
  eventos:    { titulo: 'Eventos',        icone: 'eventos',   grupo: 'Monitoramento' },
  historico:  { titulo: 'Histórico',      icone: 'historico', grupo: 'Monitoramento' },
  exportar:   { titulo: 'Exportar dados', icone: 'exportar',  grupo: 'Monitoramento' },
  config:     { titulo: 'Configuração',   icone: 'config',    grupo: 'Administração', perfis: ['ADMIN', 'OPERADOR'] },
  usuarios:   { titulo: 'Usuários',       icone: 'usuarios',  grupo: 'Administração', perfis: ['ADMIN'] },
  auditoria:  { titulo: 'Auditoria',      icone: 'auditoria', grupo: 'Administração', perfis: ['ADMIN'] },
  backups:    { titulo: 'Backups',        icone: 'backups',   grupo: 'Administração', perfis: ['ADMIN'] },
  conta:      { titulo: 'Minha conta',    icone: 'conta',     oculta: true },
};

const app = document.getElementById('app');
let limpezas = [];
let refs = {};
let relogioId = null;

// --- tema -------------------------------------------------------------
function temaSalvo() {
  try { return localStorage.getItem('aps-tema'); } catch { return null; }
}
function aplicarTema(t) {
  const tema = t || temaSalvo() || (matchMedia('(prefers-color-scheme: dark)').matches ? 'escuro' : 'claro');
  document.documentElement.dataset.tema = tema;
  return tema;
}
function alternarTema() {
  const novo = document.documentElement.dataset.tema === 'escuro' ? 'claro' : 'escuro';
  try { localStorage.setItem('aps-tema', novo); } catch { /* sem armazenamento */ }
  aplicarTema(novo);
  irPara(rotaAtual(), true);   // redesenha (gráficos usam as cores do tema)
}

// --- início -----------------------------------------------------------
async function iniciar() {
  aplicarTema();
  window.addEventListener('sessao-expirada', (ev) => {
    if (!estado.usuario) return;
    estado.usuario = null;
    desconectarTempoReal();
    telaLogin(ev.detail);
  });
  try {
    const { usuario } = await get('/api/eu');
    estado.usuario = usuario;
    if (usuario.trocar_senha) telaTrocaSenha();
    else montarEstrutura();
  } catch (e) {
    if (e.status === 0) {
      limpar(app).append(h('div', { class: 'carregando' }, 'Não foi possível falar com o servidor do painel. Ele está rodando?'));
    } else {
      telaLogin();
    }
  }
}

// --- login ------------------------------------------------------------
function arteLogin() {
  // régua de pluviômetro decorativa
  const regua = s('svg', { class: 'regua', viewBox: '0 0 64 600', preserveAspectRatio: 'none', 'aria-hidden': 'true' });
  for (let i = 0; i <= 60; i++) {
    regua.append(s('line', { x1: i % 5 === 0 ? 20 : 34, x2: 64, y1: i * 10, y2: i * 10, stroke: '#7FB2DA', 'stroke-width': i % 5 === 0 ? 2 : 1, opacity: 0.55 }));
  }
  regua.append(s('rect', { x: 46, y: 380, width: 18, height: 220, fill: '#58A8E8', opacity: 0.55 }));
  return h('div', { class: 'arte' },
    regua,
    h('div', {},
      h('h1', {}, 'Chuva, vento e temperatura de São José dos Campos, minuto a minuto'),
      h('p', {}, 'Monitoramento das estações meteorológicas da Defesa Civil: leituras em tempo real, alarmes de chuva forte e vento, histórico e auditoria de tudo o que acontece no sistema.')),
    h('p', { class: 'rodape-arte' }, 'APS de Banco de Dados – PostgreSQL com dados críticos'));
}

function telaLogin(mensagem = null) {
  limpezas.forEach((f) => f()); limpezas = [];
  const erro = h('p', { class: 'erro-form', role: 'alert' }, mensagem && mensagem !== 'Faça login para continuar' ? mensagem : '');
  const usuario = h('input', { name: 'login', autocomplete: 'username', required: true, autofocus: true, maxlength: 40 });
  const senha = h('input', { name: 'senha', type: 'password', autocomplete: 'current-password', required: true });
  const botao = h('button', { class: 'botao primario', type: 'submit' }, 'Entrar');
  const form = h('form', {
    onsubmit: async (ev) => {
      ev.preventDefault();
      erro.textContent = ''; botao.disabled = true;
      try {
        const r = await post('/api/login', { login: usuario.value, senha: senha.value });
        estado.usuario = r.usuario;
        if (r.usuario.trocar_senha) telaTrocaSenha(); else montarEstrutura();
      } catch (e) {
        erro.textContent = e.message; senha.value = ''; senha.focus(); botao.disabled = false;
      }
    },
  },
  h('h2', {}, 'Entrar no painel'),
  h('p', { class: 'mudo' }, 'Use o usuário e a senha fornecidos pelo administrador.'),
  campo('Usuário', usuario), campo('Senha', senha), erro, botao);
  limpar(app).append(h('main', { class: 'entrada-tela' }, arteLogin(), h('div', { class: 'form-lado' }, form)));
  usuario.focus();
}

function formularioSenha(aoConcluir, exigirAtual = true) {
  const atual = h('input', { type: 'password', autocomplete: 'current-password', required: true });
  const nova = h('input', { type: 'password', autocomplete: 'new-password', required: true, minlength: 8 });
  const conf = h('input', { type: 'password', autocomplete: 'new-password', required: true });
  const erro = h('p', { class: 'erro-form', role: 'alert' });
  const botao = h('button', { class: 'botao primario', type: 'submit' }, 'Trocar senha');
  const form = h('form', {
    class: 'formulario',
    onsubmit: async (ev) => {
      ev.preventDefault(); erro.textContent = '';
      if (nova.value !== conf.value) { erro.textContent = 'A confirmação não é igual à nova senha.'; return; }
      botao.disabled = true;
      try {
        await post('/api/eu/senha', { atual: atual.value, nova: nova.value });
        aoConcluir();
      } catch (e) { erro.textContent = e.message; botao.disabled = false; }
    },
  },
  exigirAtual ? campo('Senha atual', atual) : null,
  campo('Nova senha', nova, 'Pelo menos 8 caracteres, com letras e números.'),
  campo('Repita a nova senha', conf), erro, botao);
  return form;
}

function telaTrocaSenha() {
  const form = formularioSenha(async () => {
    const { usuario } = await get('/api/eu');
    estado.usuario = usuario;
    avisar('Senha trocada. Bem-vindo ao painel.');
    montarEstrutura();
  });
  const sair = h('button', { class: 'botao discreto', type: 'button', onclick: sairDoSistema }, 'Sair');
  limpar(app).append(h('main', { class: 'entrada-tela' }, arteLogin(),
    h('div', { class: 'form-lado' }, h('div', { style: { width: 'min(360px, 100%)', display: 'grid', gap: '1rem' } },
      h('h2', {}, `Olá, ${estado.usuario.nome.split(' ')[0]}`),
      h('p', { class: 'mudo' }, 'No primeiro acesso, ou depois que o administrador redefine a senha, é preciso criar uma senha só sua.'),
      form, sair))));
}

async function sairDoSistema() {
  await post('/api/logout').catch(() => {});
  estado.usuario = null;
  desconectarTempoReal();
  telaLogin();
}

// --- estrutura --------------------------------------------------------
function podeVer(chave) {
  const t = TELAS[chave];
  return t && (!t.perfis || t.perfis.includes(estado.usuario.perfil));
}

function montarEstrutura() {
  const u = estado.usuario;
  const nav = h('nav', { class: 'navegacao', 'aria-label': 'Telas' });
  let grupo = null;
  for (const [chave, t] of Object.entries(TELAS)) {
    if (t.oculta || !podeVer(chave)) continue;
    if (t.grupo !== grupo) { grupo = t.grupo; nav.append(h('div', { class: 'grupo' }, grupo)); }
    nav.append(h('a', { href: `#/${chave}`, dados: { tela: chave } }, icone(t.icone), t.titulo,
      chave === 'eventos' ? h('span', { class: 'contador', hidden: true, 'aria-label': 'eventos pendentes' }) : null));
  }

  const lateral = h('aside', { class: 'lateral' },
    h('div', { class: 'marca' },
      s('svg', { width: 30, height: 30, viewBox: '0 0 32 32', 'aria-hidden': 'true' },
        s('rect', { x: 11, y: 2, width: 10, height: 28, rx: 5, fill: 'var(--agua-clara)', stroke: 'var(--agua)', 'stroke-width': 2 }),
        s('rect', { x: 13, y: 15, width: 6, height: 13, rx: 3, fill: 'var(--agua)' })),
      h('div', {}, h('strong', {}, 'Defesa Civil SJC'), h('span', {}, 'Monitoramento meteorológico'))),
    nav,
    h('div', { class: 'rodape' },
      h('div', {}, h('div', { class: 'quem' }, u.nome),
        h('div', { class: 'papel' }, `${nome(u.perfil)}${u.cliente ? ` – ${u.cliente}` : ' – todos os clientes'}`)),
      h('div', { class: 'acoes' },
        h('a', { class: 'botao discreto', href: '#/conta', title: 'Minha conta' }, icone('conta'), h('span', { class: 'oculto-visual' }, 'Minha conta')),
        h('button', { class: 'botao discreto', type: 'button', title: 'Alternar tema claro/escuro', onclick: alternarTema }, icone('tema'), h('span', { class: 'oculto-visual' }, 'Alternar tema')),
        h('button', { class: 'botao discreto', type: 'button', onclick: sairDoSistema }, icone('sair'), 'Sair'))));

  const titulo = h('h1', {});
  const conexao = h('span', { class: 'conexao', dados: { estado: 'conectando' } }, 'Conectando…');
  const hora = h('div', { class: 'hora' }); const data = h('div', { class: 'data' });
  const faixaBanco = h('div', { class: 'faixa-banco', role: 'alert', hidden: true },
    'O banco de dados está fora do ar. As telas mostram os últimos dados carregados; leituras de dispositivos ficam guardadas no servidor e serão gravadas quando o banco voltar.');
  const conteudo = h('main', { class: 'conteudo', id: 'conteudo', tabindex: '-1' });
  const principal = h('div', { class: 'principal' },
    h('header', { class: 'topo' }, titulo, h('div', { class: 'espaco' }), conexao,
      h('div', { class: 'relogio', title: 'Hora do servidor (Brasília)' }, hora, data)),
    faixaBanco, conteudo);
  limpar(app).append(h('div', { class: 'estrutura' }, lateral, principal));
  refs = { nav, titulo, conexao, hora, data, faixaBanco, conteudo };

  // relógio: hora do servidor
  const tique = () => { const a = agoraServidor(); hora.textContent = fmt.horaS(a); data.textContent = fmt.longa(a); };
  tique();
  clearInterval(relogioId);
  relogioId = setInterval(tique, 1000);

  // tempo real
  estado.ouvintes = {};
  ouvir('saude', (d) => {
    ajustarRelogio(d.hora);
    estado.bancoOnline = d.banco !== false;
    conexao.dataset.estado = estado.bancoOnline ? 'ao-vivo' : 'fora';
    conexao.textContent = estado.bancoOnline ? 'Ao vivo' : 'Banco fora do ar';
    faixaBanco.hidden = estado.bancoOnline;
  });
  ouvir('desconectado', () => { conexao.dataset.estado = 'conectando'; conexao.textContent = 'Reconectando…'; });
  ouvir('evento', (d) => {
    if (d.evento === 'ALARME') avisar(d.mensagem, 'alarme', 'Alarme', 12000);
    else if (d.evento === 'FALHA_SENSOR' || d.evento === 'FALHA_TRANSMISSAO') avisar(d.mensagem, 'erro', nome(d.evento), 8000);
    atualizarContador();
  });
  conectarTempoReal();
  atualizarContador();

  window.onhashchange = () => irPara(rotaAtual());
  irPara(rotaAtual());
}

let tContador = null;
function atualizarContador() {
  clearTimeout(tContador);
  tContador = setTimeout(async () => {
    try {
      const r = await get('/api/eventos?pendentes=1&periodo=tudo&tipos=ALARME,FALHA_SENSOR,FALHA_TRANSMISSAO,LEITURA_REJEITADA');
      const total = r.contagem.reduce((a, c) => a + c.pendentes, 0);
      const el = refs.nav && refs.nav.querySelector('.contador');
      if (el) { el.hidden = !total; el.textContent = total > 999 ? '999+' : String(total); }
    } catch { /* sem contador */ }
  }, 400);
}

function rotaAtual() {
  const c = (location.hash.replace(/^#\/?/, '') || 'painel').split('?')[0];
  return TELAS[c] && podeVer(c) ? c : 'painel';
}

async function irPara(chave, redesenho = false) {
  limpezas.forEach((f) => { try { f(); } catch { /* ok */ } });
  limpezas = [];
  const t = TELAS[chave];
  refs.titulo.textContent = t.titulo;
  document.title = `${t.titulo} – Defesa Civil SJC`;
  refs.nav.querySelectorAll('a').forEach((a) => {
    if (a.dataset.tela === chave) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
  });
  limpar(refs.conteudo).append(h('p', { class: 'carregando' }, 'Carregando…'));
  const ctx = {
    usuario: estado.usuario,
    agora: agoraServidor,
    pode: (...perfis) => perfis.includes(estado.usuario.perfil),
    aoSair: (f) => limpezas.push(f),
    ouvir: (tipo, f) => limpezas.push(ouvir(tipo, f)),
    atualizarContador,
    formularioSenha,
  };
  try {
    const modulo = await import(`./telas/${chave}.js`);
    limpar(refs.conteudo);
    await modulo.render(refs.conteudo, ctx);
    if (!redesenho) refs.conteudo.focus({ preventScroll: true });
  } catch (e) {
    console.error(e);
    limpar(refs.conteudo).append(h('div', { class: 'faixa erro' }, icone('alerta', 22),
      h('div', { class: 'texto' }, h('strong', {}, 'Não foi possível abrir esta tela'), e.message)));
  }
}

iniciar();
