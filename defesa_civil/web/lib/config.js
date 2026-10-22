// Lê o config.json (criado a partir do config.exemplo.json na 1ª execução)
'use strict';
const fs = require('fs');
const path = require('path');

const RAIZ = path.join(__dirname, '..');
const ARQ = path.join(RAIZ, 'config.json');
const EXEMPLO = path.join(RAIZ, 'config.exemplo.json');

if (!fs.existsSync(ARQ)) {
  fs.copyFileSync(EXEMPLO, ARQ);
  console.log('[config] config.json criado a partir do config.exemplo.json');
}

const config = JSON.parse(fs.readFileSync(ARQ, 'utf8'));

// pastas relativas ao diretório do servidor
config.backup.pasta = path.resolve(RAIZ, config.backup.pasta);
config.contingencia.pasta = path.resolve(RAIZ, config.contingencia.pasta);
fs.mkdirSync(config.backup.pasta, { recursive: true });
fs.mkdirSync(config.contingencia.pasta, { recursive: true });

module.exports = config;
