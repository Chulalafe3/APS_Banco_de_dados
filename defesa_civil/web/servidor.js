// =====================================================================
// APS - Painel web da Defesa Civil de São José dos Campos
// Servidor Node.js sem framework: API + arquivos do painel (public/)
//   node servidor.js       (ou iniciar.bat no Windows)
// =====================================================================
'use strict';
const http = require('http');
const config = require('./lib/config');
const { tratar } = require('./lib/http');
require('./lib/api');                      // registra as rotas
const tempoReal = require('./lib/tempo-real');
const agendador = require('./lib/agendador');
const banco = require('./lib/banco');

const servidor = http.createServer((req, res) => { tratar(req, res); });
servidor.keepAliveTimeout = 65000;

servidor.listen(config.porta, config.host, () => {
  console.log('==============================================================');
  console.log(' Painel da Defesa Civil - APS Banco de Dados');
  console.log(` Acesse: http://${config.host === '0.0.0.0' ? 'localhost' : config.host}:${config.porta}`);
  console.log(` Banco:  ${config.banco.nome} em ${config.banco.host}:${config.banco.porta}`);
  console.log(` Simulador em tempo real: ${config.simulador.ativo ? 'ligado' : 'desligado'}`);
  console.log(` Backup diário: ${config.backup.hora_diaria} -> ${config.backup.pasta}`);
  console.log('==============================================================');
  tempoReal.iniciar();
  agendador.iniciar();
});

servidor.on('error', (e) => {
  if (e.code === 'EADDRINUSE') console.error(`A porta ${config.porta} já está em uso. Feche o outro programa ou mude "porta" no config.json.`);
  else console.error(e);
  process.exit(1);
});

async function encerrar() {
  console.log('Encerrando...');
  servidor.close();
  await Promise.allSettled(Object.values(banco.pools).map((p) => p.end()));
  process.exit(0);
}
process.on('SIGINT', encerrar);
process.on('SIGTERM', encerrar);
