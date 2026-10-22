// Minha conta: dados do usuário e troca de senha.
import { h, fmt, nome, bloco, avisar } from '../ui.js';

export async function render(alvo, ctx) {
  const u = ctx.usuario;
  alvo.append(h('div', { class: 'grade-2' },
    bloco('Seus dados', null, null,
      h('dl', { class: 'lista-def' },
        h('dt', {}, 'Nome'), h('dd', {}, u.nome),
        h('dt', {}, 'Login'), h('dd', {}, u.login),
        h('dt', {}, 'Perfil'), h('dd', {}, nome(u.perfil)),
        h('dt', {}, 'Cliente'), h('dd', {}, u.cliente || 'todos os clientes'),
        h('dt', {}, 'Sessão expira'), h('dd', {}, `${fmt.dataHora(u.expira_em)} (ou após 60 min sem uso)`))),
    bloco('Trocar senha', 'Pelo menos 8 caracteres, com letras e números.', null,
      ctx.formularioSenha(() => avisar('Senha trocada. Ficou registrado na auditoria.')))));
}
