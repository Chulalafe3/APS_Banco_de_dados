// Backups e continuidade (ADMIN): cópias com SHA-256, verificação,
// retenção, proteção contra queda (WAL, fila de contingência) e o roteiro
// de recuperação.
import { h, limpar, fmt, selo, bloco, tabela, avisar, icone } from '../ui.js';
import { get, post } from '../api.js';

export async function render(alvo, ctx) {
  const caixa = h('div', { style: { display: 'contents' } });
  alvo.append(caixa);

  async function carregar() {
    const r = await get('/api/backups');
    const agora = ctx.agora();
    limpar(caixa);

    const oks = r.copias.filter((c) => c.status === 'OK' && c.existe);
    const ultima = oks[0];
    const horas = ultima ? (agora - new Date(ultima.iniciado_em)) / 3600e3 : Infinity;
    const cls = !ultima ? 'erro' : horas > 26 ? 'alerta' : 'ok';
    const btFazer = h('button', { class: 'botao primario', type: 'button', disabled: r.em_andamento, onclick: fazer }, r.em_andamento ? 'Backup em andamento…' : 'Fazer backup agora');

    caixa.append(h('div', { class: `faixa ${cls}` },
      h('span', { class: 'icone' }, icone(cls === 'ok' ? 'escudo' : 'alerta', 26)),
      h('div', { class: 'texto' },
        h('strong', {}, !ultima ? 'Nenhuma cópia de segurança disponível' : `Última cópia ${fmt.ha(ultima.iniciado_em, agora)} (${fmt.dataHora(ultima.iniciado_em)})`),
        h('span', { class: 'mudo' }, !ultima ? 'Faça a primeira cópia agora. As próximas acontecem todos os dias automaticamente.'
          : `${fmt.bytes(ultima.tamanho_bytes)}, ${oks.length} cópia(s) guardada(s). Próxima automática: ${fmt.dataHora(r.agenda.proximo)}.`)),
      btFazer));

    async function fazer() {
      btFazer.disabled = true; btFazer.textContent = 'Fazendo backup…';
      try {
        const b = await post('/api/backups');
        if (b.status === 'OK') avisar(`${b.arquivo} (${fmt.bytes(b.tamanho_bytes)}) em ${fmt.num(b.duracao_ms / 1000, 1)} s.`, 'ok', 'Backup concluído');
        else avisar(b.mensagem, 'erro', 'Backup falhou');
      } catch (e) { avisar(e.message, 'erro'); }
      await carregar();
    }

    // --- agenda / proteção
    const sv = r.servidor;
    const linhaParam = (rotulo, valor, bom, explicacao) => [
      h('dt', {}, rotulo),
      h('dd', {}, h('strong', { style: { color: bom ? 'var(--ok)' : 'var(--alerta)' } }, valor), ' ', h('span', { class: 'mudo pequeno' }, explicacao))];
    caixa.append(h('div', { class: 'grade-2' },
      bloco('Agenda e retenção', null, null,
        h('dl', { class: 'lista-def' },
          h('dt', {}, 'Backup automático'), h('dd', {}, `todo dia às ${r.agenda.hora_diaria}`),
          h('dt', {}, 'Próximo'), h('dd', {}, fmt.dataHora(r.agenda.proximo)),
          h('dt', {}, 'Retenção'), h('dd', {}, `${r.agenda.retencao_dias} dias, sempre mantendo as ${r.agenda.minimo_manter} últimas cópias boas`),
          h('dt', {}, 'Formato'), h('dd', {}, 'pg_dump custom (comprimido), feito pelo papel aps_backup, que só lê'),
          h('dt', {}, 'Pasta'), h('dd', { class: 'pequeno' }, r.pasta),
          h('dt', {}, 'Programa'), h('dd', { class: 'pequeno' }, r.pg_dump),
          h('dt', {}, 'Tamanho do banco'), h('dd', {}, fmt.bytes(sv.tamanho_banco)))),
      bloco('Proteção contra queda', `PostgreSQL ${sv.versao.split(' ')[0]}`, null,
        h('dl', { class: 'lista-def' },
          linhaParam('fsync', sv.fsync, sv.fsync === 'on', 'cada COMMIT é gravado no disco antes de confirmar'),
          linhaParam('synchronous_commit', sv.synchronous_commit, sv.synchronous_commit === 'on', 'transação confirmada não se perde numa queda de energia'),
          linhaParam('full_page_writes', sv.full_page_writes, sv.full_page_writes === 'on', 'protege contra páginas gravadas pela metade'),
          linhaParam('wal_level', sv.wal_level, sv.wal_level !== 'minimal', 'permite arquivar o WAL e ter réplicas'),
          linhaParam('archive_mode', sv.archive_mode, sv.archive_mode === 'on', sv.archive_mode === 'on' ? 'WAL arquivado: recuperação para qualquer instante (PITR)' : 'desligado: recuperação só até o último backup (veja o plano abaixo)'),
          linhaParam('Réplicas conectadas', String(sv.replicas), sv.replicas > 0, sv.replicas > 0 ? 'há cópia em tempo real em outro servidor' : 'nenhuma réplica em espera'),
          linhaParam('Fila de contingência', `${r.contingencia.pendentes} lote(s)`, r.contingencia.pendentes === 0,
            r.contingencia.pendentes ? 'lotes recebidos com o banco fora do ar, aguardando reenvio' : 'lotes recebidos com o banco fora do ar são guardados aqui e reenviados sozinhos')),
        r.contingencia.pendentes ? h('button', { class: 'botao', type: 'button', style: { marginTop: '1rem' }, onclick: async () => { const x = await post('/api/contingencia/reenviar'); avisar(`${x.reenviados} lote(s) reenviado(s).`); carregar(); } }, 'Reenviar agora') : null)));

    // --- cópias
    caixa.append(bloco('Cópias de segurança', 'O SHA-256 é calculado na hora da cópia. Verificar recalcula e confere se o pg_restore consegue ler o arquivo.', null,
      tabela([
        { titulo: 'Quando', valor: (c) => h('span', {}, fmt.data(c.iniciado_em), ' ', h('strong', {}, fmt.hora(c.iniciado_em))) },
        { titulo: 'Arquivo', valor: (c) => h('div', {}, c.arquivo, c.sha256 ? h('div', { class: 'hash' }, `sha256 ${c.sha256.slice(0, 20)}…`) : null) },
        { titulo: 'Origem', valor: (c) => (c.origem === 'MANUAL' ? 'manual' : 'automático') },
        { titulo: 'Tamanho', n: true, valor: (c) => fmt.bytes(c.tamanho_bytes) },
        { titulo: 'Duração', n: true, valor: (c) => `${fmt.num(c.duracao_ms / 1000, 1)} s` },
        { titulo: 'Situação', valor: (c) => (c.status !== 'OK' ? h('div', {}, selo('f', 'critico', 'Falhou'), h('div', { class: 'mudo pequeno' }, c.mensagem))
          : !c.existe ? selo('r', 'VISUALIZADOR', 'Removida pela retenção') : selo('o', 'ok', 'Disponível')) },
        { titulo: '', valor: (c) => (c.status === 'OK' && c.existe ? h('div', { class: 'linha-acoes' },
          h('button', { class: 'botao pequeno', type: 'button', onclick: (ev) => verificar(c, ev.currentTarget) }, 'Verificar'),
          h('a', { class: 'botao pequeno', href: `/api/backups/baixar?arquivo=${encodeURIComponent(c.arquivo)}` }, icone('baixar', 16), 'Baixar')) : '') },
      ], r.copias, { vazio: 'Nenhuma cópia feita ainda.' })));

    // --- plano de recuperação (é uma sequência: numerada)
    caixa.append(bloco('Plano de recuperação', 'O que fazer se o banco for perdido (disco, servidor ou erro humano).', null,
      h('div', { class: 'grade-2' },
        h('ol', { class: 'passos' },
          h('li', {}, 'Pare o servidor do painel. Os dispositivos continuam guardando as leituras (até o atraso máximo configurado).'),
          h('li', {}, 'Escolha a cópia mais recente com situação "Disponível" e clique em Verificar.'),
          h('li', {}, 'Rode ferramentas\\restaurar.bat (ou: createdb aps_defesa_civil_novo e pg_restore -d aps_defesa_civil_novo arquivo.dump).'),
          h('li', {}, 'Rode 07_seguranca.sql no banco restaurado: papéis e senhas do PostgreSQL ficam fora do pg_dump.'),
          h('li', {}, 'Aponte o config.json para o banco novo e suba o painel. A fila de contingência e os dataloggers reenviam o que faltou.'),
          h('li', {}, 'Na Auditoria, clique em Verificar integridade para confirmar que a trilha veio inteira.')),
        h('dl', { class: 'lista-def' },
          h('dt', {}, 'Perda máxima (RPO)'), h('dd', {}, sv.archive_mode === 'on' ? 'minutos (backup + WAL arquivado)' : 'até 24 h de dados no banco, recuperáveis dos dataloggers por até 7 dias'),
          h('dt', {}, 'Tempo para voltar (RTO)'), h('dd', {}, 'minutos: restaurar este banco leva menos de 1 min'),
          h('dt', {}, 'Queda do banco'), h('dd', {}, 'o servidor guarda os lotes em disco e reenvia quando o banco volta'),
          h('dt', {}, 'Para PITR'), h('dd', {}, 'archive_mode = on e archive_command copiando o WAL para outro disco')))));
  }

  async function verificar(c, bt) {
    bt.disabled = true; bt.textContent = 'Verificando…';
    try {
      const r = await post('/api/backups/verificar', { arquivo: c.arquivo });
      avisar(r.detalhe, r.ok ? 'ok' : 'erro', r.ok ? 'Cópia íntegra' : 'Problema na cópia', 9000);
    } catch (e) { avisar(e.message, 'erro'); }
    bt.disabled = false; bt.textContent = 'Verificar';
  }

  await carregar();
}
