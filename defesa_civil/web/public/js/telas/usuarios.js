// Usuários (ADMIN): cadastro, perfil, cliente, ativação, senha e bloqueio.
// Tudo passa por funções do banco que conferem o perfil de quem pede.
import { h, encher, limpar, fmt, nome, selo, bloco, tabela, avisar, dialogo, campo } from '../ui.js';
import { get, post, put } from '../api.js';

function senhaProvisoria() {
  const letras = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ';
  const nums = '23456789';
  const a = new Uint32Array(10);
  crypto.getRandomValues(a);
  let s = '';
  for (let i = 0; i < 7; i++) s += letras[a[i] % letras.length];
  for (let i = 7; i < 10; i++) s += nums[a[i] % nums.length];
  return s;
}

export async function render(alvo, ctx) {
  const caixa = h('div', {});
  alvo.append(bloco('Usuários do painel',
    'Administrador vê e altera tudo; operador reconhece eventos e ajusta alarmes do seu cliente; visualizador só consulta. Cinco senhas erradas seguidas bloqueiam o acesso por 15 minutos.',
    h('button', { class: 'botao primario', type: 'button', onclick: () => editar(null) }, 'Novo usuário'),
    caixa));

  let dados;
  async function carregar() {
    dados = await get('/api/usuarios');
    encher(caixa, tabela([
      { titulo: 'Nome', valor: (u) => h('div', {}, h('strong', {}, u.nome), h('div', { class: 'mudo pequeno' }, u.login)) },
      { titulo: 'Perfil', valor: (u) => selo(u.perfil) },
      { titulo: 'Cliente', valor: (u) => u.cliente || h('span', { class: 'mudo' }, 'todos') },
      { titulo: 'Situação', valor: (u) => h('div', { class: 'pilulas' },
        !u.ativo ? selo('inativo', 'FALHA', 'Desativado') : selo('ativo', 'ok', 'Ativo'),
        u.bloqueado ? selo('b', 'critico', 'Bloqueado') : null,
        u.trocar_senha ? selo('t', 'atencao', 'Troca de senha pendente') : null) },
      { titulo: 'Último acesso', valor: (u) => (u.ultimo_login ? fmt.dataHora(u.ultimo_login) : h('span', { class: 'mudo' }, 'nunca')) },
      { titulo: 'Sessões abertas', n: true, valor: (u) => u.sessoes_ativas },
      { titulo: '', valor: (u) => h('div', { class: 'linha-acoes' },
        h('button', { class: 'botao pequeno', type: 'button', onclick: () => editar(u) }, 'Editar'),
        h('button', { class: 'botao pequeno', type: 'button', onclick: () => redefinir(u) }, 'Redefinir senha'),
        u.bloqueado ? h('button', { class: 'botao pequeno', type: 'button', onclick: () => desbloquear(u) }, 'Desbloquear') : null) },
    ], dados.usuarios, { classeLinha: (u) => (u.ativo ? null : 'inativo') }));
  }

  async function editar(u) {
    const novo = !u;
    const nomeIn = h('input', { name: 'nome', required: true, maxlength: 100, value: u?.nome || '' });
    const loginIn = h('input', { name: 'login', required: true, pattern: '[a-z0-9._\\-]{3,40}', maxlength: 40, autocomplete: 'off' });
    const perfilIn = h('select', { name: 'perfil' }, ['VISUALIZADOR', 'OPERADOR', 'ADMIN'].map((p) => h('option', { value: p, selected: (u?.perfil || 'VISUALIZADOR') === p }, nome(p))));
    const clienteIn = h('select', { name: 'id_cliente' }, h('option', { value: '' }, 'Todos os clientes (só administrador)'),
      dados.clientes.map((c) => h('option', { value: c.id_cliente, selected: (u ? u.id_cliente : dados.clientes[0]?.id_cliente) === c.id_cliente }, c.nome)));
    const provisoria = senhaProvisoria();
    const senhaIn = h('input', { name: 'senha', required: true, value: provisoria, minlength: 8 });
    const ativoIn = h('input', { type: 'checkbox', name: 'ativo', checked: u ? u.ativo : true });

    const r = await dialogo({
      titulo: novo ? 'Novo usuário' : `Editar ${u.nome}`,
      descricao: novo ? 'A senha é provisória: a pessoa troca no primeiro acesso.' : null,
      conteudo: h('div', { class: 'formulario' },
        campo('Nome completo', nomeIn),
        novo ? campo('Login', loginIn, 'Letras minúsculas, números, ponto ou hífen.') : null,
        h('div', { class: 'duas' }, campo('Perfil', perfilIn), campo('Cliente', clienteIn)),
        novo ? campo('Senha provisória', senhaIn, 'Gerada aleatoriamente. Anote e entregue à pessoa.') : null,
        !novo ? h('label', { class: 'check' }, ativoIn, 'Usuário ativo (desativar encerra as sessões abertas)') : null),
      confirmar: novo ? 'Criar usuário' : 'Salvar alterações',
      aoConfirmar: async () => {
        const corpo = { nome: nomeIn.value, perfil: perfilIn.value, id_cliente: clienteIn.value, ativo: ativoIn.checked };
        if (novo) await post('/api/usuarios', { ...corpo, login: loginIn.value, senha: senhaIn.value });
        else await put(`/api/usuarios/${u.id_usuario}`, corpo);
        return true;
      },
    });
    if (r) { avisar(novo ? `Usuário ${loginIn.value} criado.` : 'Alterações salvas.'); await carregar(); }
  }

  async function redefinir(u) {
    const provisoria = senhaProvisoria();
    const senhaIn = h('input', { required: true, value: provisoria, minlength: 8 });
    const r = await dialogo({
      titulo: `Redefinir a senha de ${u.nome}`,
      descricao: 'As sessões abertas dessa pessoa são encerradas e ela precisa trocar a senha no próximo acesso.',
      conteudo: campo('Nova senha provisória', senhaIn),
      confirmar: 'Redefinir senha', perigo: true,
      aoConfirmar: () => post(`/api/usuarios/${u.id_usuario}/senha`, { nova: senhaIn.value }),
    });
    if (r) { avisar(`Senha de ${u.login} redefinida.`); await carregar(); }
  }

  async function desbloquear(u) {
    try { await post(`/api/usuarios/${u.id_usuario}/desbloquear`); avisar(`${u.login} desbloqueado.`); await carregar(); }
    catch (e) { avisar(e.message, 'erro'); }
  }

  await carregar();
}
