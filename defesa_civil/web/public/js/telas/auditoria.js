// Auditoria (ADMIN): quem fez o quê, quando e de onde, com antes/depois.
// A trilha é encadeada por hash: "Verificar integridade" recalcula a
// corrente e aponta o primeiro registro adulterado, se houver.
import { h, encher, limpar, fmt, selo, segmentado, bloco, icone, avisar, tabela } from '../ui.js';
import { get } from '../api.js';

const ACOES = {
  INSERT: 'Inclusão', UPDATE: 'Alteração', DELETE: 'Exclusão', LOGIN: 'Login', LOGOUT: 'Saída',
  LOGIN_FALHA: 'Login recusado', LOGIN_BLOQUEADO: 'Tentativa bloqueada', USUARIO_BLOQUEADO: 'Usuário bloqueado',
  USUARIO_DESBLOQUEADO: 'Usuário desbloqueado', DDL: 'Mudança de estrutura', EXPORTACAO: 'Exportação de dados',
  BACKUP_OK: 'Backup feito', BACKUP_FALHA: 'Backup falhou', BACKUP_VERIFICADO: 'Backup verificado',
  BACKUP_DOWNLOAD: 'Backup baixado', SIMULACAO_MANUAL: 'Transmissão sob demanda', INGEST_NEGADO: 'Envio recusado',
  CONTINGENCIA_REENVIO: 'Reenvio da contingência', SEGURANCA_INSTALADA: 'Segurança instalada',
};
const RISCO = ['LOGIN_FALHA', 'LOGIN_BLOQUEADO', 'USUARIO_BLOQUEADO', 'INGEST_NEGADO', 'DDL', 'DELETE', 'BACKUP_FALHA'];
const MUDANCA = ['UPDATE', 'INSERT', 'USUARIO_DESBLOQUEADO', 'EXPORTACAO', 'BACKUP_DOWNLOAD'];
const TABELAS = { regra_alarme: 'regra de alarme', sensor: 'sensor', usuario: 'usuário', configuracao: 'parâmetro', dispositivo: 'estação', evento: 'evento', cliente: 'cliente', log_backup: 'backup' };

function seloAcao(a) {
  return selo(a, RISCO.includes(a) ? 'critico' : MUDANCA.includes(a) ? 'alerta' : 'ok', ACOES[a] || a);
}

function valorTexto(v) {
  if (v === null || v === undefined) return '—';
  if (typeof v === 'object') return JSON.stringify(v);
  if (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(v)) return fmt.dataHora(v);
  return String(v);
}

function diferenca(antes, depois) {
  const chaves = [...new Set([...Object.keys(antes || {}), ...Object.keys(depois || {})])];
  const grade = h('div', { class: 'diff' }, h('div', { class: 'cab' }, 'Campo'), h('div', { class: 'cab' }, 'Antes'), h('div', { class: 'cab' }, 'Depois'));
  for (const k of chaves) {
    const a = antes ? antes[k] : undefined; const d = depois ? depois[k] : undefined;
    const mudou = JSON.stringify(a) !== JSON.stringify(d);
    grade.append(h('div', { class: 'k' }, k),
      h('div', { class: mudou && antes ? 'mudou' : null }, antes ? valorTexto(a) : ''),
      h('div', { class: mudou && depois ? 'mudou' : null }, depois ? valorTexto(d) : ''));
  }
  return grade;
}

export async function render(alvo) {
  const filtro = { acao: '', tabela: '', login: '', periodo: '7d', pagina: 0 };
  const integridade = h('div', {});
  const filtros = h('div', { class: 'filtros' });
  const corpo = h('div', {});
  const paginas = h('div', { class: 'linha-acoes', style: { marginTop: '1rem' } });
  alvo.append(integridade,
    h('section', { class: 'bloco' }, filtros),
    h('section', { class: 'bloco' }, corpo, paginas));

  async function verificar() {
    encher(integridade, h('div', { class: 'faixa' }, h('div', { class: 'texto' }, 'Conferindo a corrente de hashes…')));
    try {
      const r = await get('/api/auditoria/verificar');
      encher(integridade, h('div', { class: `faixa ${r.integra ? 'ok' : 'erro'}` },
        h('span', { class: 'icone' }, icone(r.integra ? 'escudo' : 'alerta', 26)),
        h('div', { class: 'texto' },
          h('strong', {}, r.integra ? 'Trilha de auditoria íntegra' : `Adulteração detectada no registro nº ${r.primeiro_problema}`),
          h('span', { class: 'mudo' }, r.integra
            ? `${fmt.int(r.registros)} registros conferidos. Cada registro guarda o hash do anterior; alterar ou apagar qualquer um quebraria a corrente.`
            : `${r.detalhe}. ${fmt.int(r.registros)} registros conferidos até o problema.`)),
        h('button', { class: 'botao', type: 'button', onclick: verificar }, 'Verificar de novo')));
    } catch (e) { avisar(e.message, 'erro'); }
  }

  let primeira = true;
  async function carregar() {
    const qs = new URLSearchParams({ ...filtro });
    const r = await get(`/api/auditoria?${qs}`);
    if (primeira) {
      primeira = false;
      const sel = (chave, rotulo, opcoes, nomes = (x) => x) => h('label', { class: 'campo' }, h('span', {}, rotulo),
        h('select', { class: 'entrada', onchange: (ev) => { filtro[chave] = ev.target.value; filtro.pagina = 0; carregar(); } },
          h('option', { value: '' }, 'Todos'), (opcoes || []).map((o) => h('option', { value: o }, nomes(o)))));
      filtros.append(
        sel('acao', 'Ação', r.filtros.acoes, (a) => ACOES[a] || a),
        sel('tabela', 'Objeto', r.filtros.tabelas, (t) => TABELAS[t] || t),
        sel('login', 'Usuário', r.filtros.logins),
        h('div', { class: 'campo' }, h('span', {}, 'Período'),
          segmentado([['24h', '24 horas'], ['7d', '7 dias'], ['30d', '30 dias'], ['tudo', 'Tudo']], filtro.periodo, (v) => { filtro.periodo = v; filtro.pagina = 0; carregar(); }, 'Período')));
    }

    encher(corpo, tabela([
      { titulo: 'Nº', n: true, valor: (a) => a.id_auditoria },
      { titulo: 'Quando', valor: (a) => h('span', {}, fmt.data(a.data_hora), ' ', h('strong', {}, fmt.horaS(a.data_hora))) },
      { titulo: 'Quem', valor: (a) => h('div', {}, h('strong', {}, a.login || '—'), a.ip ? h('div', { class: 'mudo pequeno' }, a.ip) : null) },
      { titulo: 'Ação', valor: (a) => seloAcao(a.acao) },
      { titulo: 'Objeto', valor: (a) => (a.tabela ? `${TABELAS[a.tabela] || a.tabela}${a.registro ? ` nº ${a.registro}` : ''}` : '—') },
      { titulo: 'Detalhe', classe: 'msg', valor: (a) => {
        const det = h('div', {}, a.detalhe || '');
        if (a.antes || a.depois) {
          const alvoDiff = h('div', { hidden: true }, diferenca(a.antes, a.depois));
          const resumo = a.antes && a.depois
            ? Object.keys(a.depois).filter((k) => JSON.stringify(a.antes[k]) !== JSON.stringify(a.depois[k]))
              .map((k) => `${k}: ${valorTexto(a.antes[k])} → ${valorTexto(a.depois[k])}`).join('; ')
            : (a.depois ? 'registro criado' : 'registro removido');
          det.append(h('div', {}, resumo),
            h('button', { class: 'botao discreto pequeno', type: 'button', onclick: (ev) => { alvoDiff.hidden = !alvoDiff.hidden; ev.currentTarget.textContent = alvoDiff.hidden ? 'Ver antes e depois' : 'Ocultar'; } }, 'Ver antes e depois'),
            alvoDiff);
        }
        det.append(h('div', { class: 'hash', title: 'SHA-256 deste registro' }, `hash ${a.hash.slice(0, 16)}…`));
        return det;
      } },
    ], r.lista, { vazio: 'Nenhum registro com esses filtros.' }));

    const total = r.total; const ultima = Math.max(0, Math.ceil(total / 50) - 1);
    encher(paginas, 
      h('button', { class: 'botao pequeno', type: 'button', disabled: filtro.pagina === 0, onclick: () => { filtro.pagina--; carregar(); } }, 'Mais recentes'),
      h('span', { class: 'mudo pequeno' }, `${fmt.int(total)} registros; página ${filtro.pagina + 1} de ${ultima + 1}`),
      h('button', { class: 'botao pequeno', type: 'button', disabled: filtro.pagina >= ultima, onclick: () => { filtro.pagina++; carregar(); } }, 'Mais antigos'));
  }

  await Promise.all([verificar(), carregar()]);
}
