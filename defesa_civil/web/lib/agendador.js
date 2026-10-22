// Agendador do servidor (o PostgreSQL não tem agendador nativo; em
// produção poderia ser o pg_cron). Tudo usa o relógio do servidor.
//   a cada minuto     verificação de comunicação; contingência
//   a cada 10 min     simulador "ao vivo" + resumo horário
//   todo dia 00:15    manutenção (arquivamento, partições futuras, sessões)
//   todo dia (config) backup automático + retenção
'use strict';
const config = require('./config');
const banco = require('./banco');
const backup = require('./backup');
const contingencia = require('./contingencia');
const tempoReal = require('./tempo-real');

const estado = {
  ultima_simulacao: null, ultima_verificacao: null,
  ultima_manutencao: null, ultimo_backup_auto: null, erros: [],
};

function anotarErro(tarefa, e) {
  if (banco.ehFalhaDeConexao(e)) tempoReal.definirSaude(false, e.message);
  estado.erros.unshift({ tarefa, quando: new Date().toISOString(), erro: e.message });
  estado.erros.length = Math.min(estado.erros.length, 20);
  console.error(`[agendador] ${tarefa}:`, e.message);
}

async function simular(forcar = false) {
  const r = await banco.sistema('SELECT fn_simular_tempo_real($1) AS n', [forcar], 'dispositivo');
  await banco.sistema('SELECT fn_manutencao_resumo_horario()');
  estado.ultima_simulacao = new Date().toISOString();
  return r.rows[0].n;
}

async function manutencaoDiaria() {
  const r = await banco.sistema('SELECT fn_manutencao_diaria() AS r');
  estado.ultima_manutencao = new Date().toISOString();
  console.log('[agendador] manutenção diária:', r.rows[0].r);
}

async function porMinuto() {
  const agora = new Date();
  const min = agora.getMinutes();
  const hhmm = `${String(agora.getHours()).padStart(2, '0')}:${String(min).padStart(2, '0')}`;

  try {
    await banco.sistema('SELECT fn_manutencao_verificar_comunicacao()');
    estado.ultima_verificacao = agora.toISOString();
    tempoReal.definirSaude(true);
  } catch (e) { anotarErro('verificar comunicação', e); }

  if (contingencia.pendentes().length) {
    try { await contingencia.reenviar(); } catch (e) { anotarErro('contingência', e); }
  }

  if (config.simulador.ativo && min % config.simulador.intervalo_min === 0) {
    try { await simular(); } catch (e) { anotarErro('simulador', e); }
  }

  if (hhmm === '00:15') {
    try { await manutencaoDiaria(); } catch (e) { anotarErro('manutenção diária', e); }
  }

  if (hhmm === config.backup.hora_diaria) {
    try { estado.ultimo_backup_auto = (await backup.executar('AUTOMATICO')).status; }
    catch (e) { anotarErro('backup automático', e); }
  }
}

function proximoBackup() {
  const [h, m] = config.backup.hora_diaria.split(':').map(Number);
  const d = new Date();
  d.setHours(h, m, 0, 0);
  if (d <= new Date()) d.setDate(d.getDate() + 1);
  return d.toISOString();
}

function iniciar() {
  // ao subir: garante partições/arquivamento e recupera o atraso do simulador
  setTimeout(async () => {
    try { await manutencaoDiaria(); } catch (e) { anotarErro('manutenção inicial', e); }
    if (config.simulador.ativo) {
      try { console.log(`[agendador] simulador: ${await simular()} leitura(s) recuperada(s) até agora`); }
      catch (e) { anotarErro('simulador inicial', e); }
    }
  }, 1500);

  // alinha ao início de cada minuto (+3 s)
  const espera = 60000 - (Date.now() % 60000) + 3000;
  setTimeout(() => { porMinuto(); setInterval(porMinuto, 60000); }, espera);

  // banco voltou: esvazia a fila de contingência na hora
  tempoReal.aoMudarSaude((online) => { if (online) contingencia.reenviar().catch(() => {}); });
}

module.exports = { iniciar, simular, estado, proximoBackup };
