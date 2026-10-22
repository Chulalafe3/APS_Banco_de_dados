# APS – Banco de Dados de Telemetria IoT (dados críticos)
## Monitoramento meteorológico para a Defesa Civil de São José dos Campos

Banco de dados PostgreSQL (PL/pgSQL) para receber, validar, armazenar e consultar dados de estações meteorológicas, com detecção de falhas e alarmes em tempo real. Por serem **dados críticos** (alertas de chuva forte e vento para a Defesa Civil), o banco também cuida de **integridade, segurança de acesso, auditoria à prova de adulteração e continuidade** (backup e contingência).

---

## Como rodar (Windows)

### 1. Banco de dados
1. No pgAdmin, crie o banco `aps_defesa_civil`.
2. Clique com o botão direito no banco → **PSQL Tool** e rode (barras normais no caminho):
   ```
   \i 'C:/caminho/APS_Banco_de_dados/defesa_civil/rodar_tudo.sql'
   ```
   Ele **apaga e recria** o schema `public` e roda `01` → `05` e `07` (~2,5 min).

> Não use a Query Tool para o `04`/`06`: o simulador faz `COMMIT` a cada lote e a Query Tool envia o arquivo inteiro como uma transação só (*invalid transaction termination*).

### 2. Painel web novo (HTML/CSS/JS puro + Node.js)
1. Instale o **Node.js LTS** (nodejs.org).
2. Dê dois cliques em `web\iniciar.bat`. Na 1ª vez ele instala a única dependência (`pg`) e cria o `web\config.json`.
3. O navegador abre em **http://127.0.0.1:8080**.

| Usuário | Senha inicial | Perfil |
|---|---|---|
| `admin` | `Admin@2026` | Administrador (todos os clientes) |
| `operador` | `Operador@2026` | Operador da Defesa Civil de SJC |
| `consulta` | `Consulta@2026` | Visualizador da Defesa Civil de SJC |

No 1º acesso cada um é obrigado a trocar a senha.

### 3. Painel antigo (Streamlit)
Continua funcionando: `interface\iniciar.bat` (conecta como `postgres`). Veja `interface/LEIAME.md`.

---

## Arquivos

| # | Arquivo | O que faz |
|---|---|---|
| 1 | `01_estrutura.sql` | Tabelas, chaves, índices, view materializada e tabela `configuracao` |
| 2 | `02_regras.sql` | Triggers, recepção e validação de lotes, evento imutável, partições e arquivamento |
| 3 | `03_simulador.sql` | Modelo do tempo, carga histórica e simulador em tempo real |
| 4 | `04_carga_inicial.sql` | Cliente, 2 estações, sensores, regras, 6 meses de dados e arquivamento |
| 5 | `05_consultas.sql` | Views para visualização e consultas de exemplo |
| 6 | `06_testes_desempenho.sql` | Testes de escrita e consulta (opcional, ~5 min, PSQL Tool) |
| 7 | `07_seguranca.sql` | Usuários, sessões, papéis, RLS, auditoria encadeada, backups |
| – | `rodar_tudo.sql` | Recria tudo (01–05 + 07) |
| – | `web/` | Servidor Node.js + painel web |
| – | `ferramentas/restaurar.bat` | Restaura um backup num banco novo |
| – | `ferramentas/dispositivo_teste.js` | Simula um datalogger real enviando para a API |

---

## Arquitetura (sensor → borda → nuvem)

| Camada | Na vida real | No projeto |
|---|---|---|
| Coleta | Datalogger ou CLP lê os sensores e armazena | Simulada (`fn_simular_leituras`) |
| Transmissão | 4G, LoRa, Ethernet, satélite | Citado; lote em JSON por HTTP (`POST /api/ingest` com chave da estação) |
| Servidor | API, filas, agendador | **Node.js** (`web/`): API, tempo real, agendador, backup, contingência |
| Banco de dados | Armazenamento, regras, alarmes, histórico | **Implementado** (PostgreSQL) |
| Acesso do cliente | Login, senha, permissões | **Implementado**: usuários, perfis, RLS por cliente |

Fluxo: o dispositivo mede a cada **1 min** e transmite a cada **10 min** → `fn_receber_lote` valida e grava → triggers calculam e geram eventos → `NOTIFY` → o servidor avisa os navegadores (Server-Sent Events).

---

## Datas somente em tempo real

Ninguém digita data no sistema: toda data de registro vem do **relógio do servidor**.

| Onde | Como |
|---|---|
| Recepção de lote | `fn_receber_lote(estação, leituras)` não tem parâmetro de data: usa `now()`. A versão com data (`fn_receber_lote_interno`) é só para a carga histórica e não é liberada à aplicação |
| Leitura com data no futuro | Rejeitada (tolerância de 2 min, configurável); a trigger da tabela também recusa INSERT direto |
| Leitura antiga demais / mês arquivado / data inválida | Rejeitada sem derrubar o lote; vira evento `LEITURA_REJEITADA` com o motivo |
| Reconhecimento de evento | `reconhecido_em` e `reconhecido_por` preenchidos pelo banco; valores enviados são ignorados |
| Auditoria, sessões, configuração, backups | Datas forçadas por trigger/`DEFAULT` |
| Partições | Criadas com 2 meses de antecedência pela manutenção diária (antes: em jan/2027 tudo falharia) |
| Telas | A hora mostrada é a do servidor (o relógio do computador pode estar errado) |

---

## Segurança (07_seguranca.sql)

- **O banco não confia na aplicação**: o servidor só repassa o *token* da sessão (`app.sessao`); o banco valida e descobre usuário, perfil e cliente.
- **Senhas** com bcrypt (`pgcrypto`), política de 8+ caracteres com letras e números, troca obrigatória no 1º acesso, **bloqueio de 15 min após 5 erros**.
- **Sessões** guardam só o hash SHA-256 do token; expiram após 60 min sem uso (máx. 8 h).
- **Papéis de mínimo privilégio**: `aps_app` (painel), `aps_dispositivo` (só envia leituras), `aps_backup` (só lê, para o pg_dump), `aps_leitura` (relatórios).
- **Row Level Security**: cada usuário só vê as estações do seu cliente; regras/sensores só OPERADOR/ADMIN alteram; configuração, auditoria e backups só ADMIN.
- **Evento imutável**: só o reconhecimento pode mudar, e não pode ser desfeito.
- **Auditoria append-only encadeada por hash**: cada linha guarda o SHA-256 da anterior; `fn_verificar_auditoria()` aponta o primeiro registro adulterado. Registra alterações com antes/depois, logins, exportações, backups e até comandos de estrutura (DDL), inclusive quem desligar uma trigger de proteção.
- **Painel**: cookie HttpOnly/SameSite, cabeçalho anti-CSRF, Content-Security-Policy, nada de `innerHTML` com dados do banco (sem XSS).

---

## Continuidade: backup e queda

| Situação | O que acontece |
|---|---|
| Backup diário | `pg_dump` (papel `aps_backup`) às 02:00, SHA-256 de cada cópia, manifesto em disco, retenção de 7 dias mantendo as 3 últimas |
| Verificação | Recalcula o SHA-256 e lê o arquivo com `pg_restore --list` |
| Banco fora do ar | O servidor guarda os lotes recebidos em disco (`contingencia/`) e reenvia sozinho quando o banco volta |
| Queda de energia | `fsync`, `synchronous_commit` e `full_page_writes` ligados: nada confirmado se perde |
| Perda do banco | `ferramentas/restaurar.bat` restaura num banco novo; depois rodar o `07` (papéis ficam fora do pg_dump) |
| PITR (opcional) | `archive_mode = on` + `archive_command` copiando o WAL para outro disco |

Testado: backup de 35 MB restaurado com as mesmas contagens e a corrente de auditoria íntegra; PostgreSQL derrubado com o dispositivo enviando → lotes na fila → reenviados ao religar, sem perda.

---

## Tabelas

| Tabela | Conteúdo |
|---|---|
| `cliente` | Defesa Civil de SJC |
| `dispositivo` | Estações: intervalos, localização, `ativo`, `status`, `ultima_comunicacao`, hash da chave de API |
| `sensor` | Parâmetros de cada estação com a **faixa física válida** |
| `leitura` | 1 linha por estação por minuto, 1 coluna por parâmetro + `chuva_acumulada`. **Particionada por mês** |
| `leitura_arquivo` | Meses antigos (mesma estrutura), com índice **BRIN** |
| `leitura_diaria` | Resumo diário (mín/máx/média, chuva total, direção predominante) |
| `regra_alarme` | Limites definidos pelo cliente |
| `evento` | `TRANSMISSAO_OK`, `FALHA_TRANSMISSAO`, `FALHA_SENSOR`, `ALARME`, `LEITURA_REJEITADA` (+ quem/quando reconheceu) |
| `configuracao` | Tolerâncias de data, retenção e partições futuras |
| `usuario`, `sessao` | Acesso ao painel |
| `auditoria` | Trilha encadeada por hash |
| `log_arquivamento`, `log_backup` | Ciclo de vida e cópias de segurança |
| `mv_resumo_horario` | **View materializada** com o resumo por hora |

## Regras de alarme cadastradas

| Parâmetro | Condição | Nível |
|---|---|---|
| Chuva acumulada no dia | > 50 mm | CRÍTICO |
| Velocidade do vento | > 17 m/s (~61 km/h) | ALERTA |
| Temperatura do ar | > 35 °C | ALERTA |
| Umidade do ar | < 20 % | ALERTA |

## Simulação

- 2 estações (Centro e Zona Norte), 6 meses até a data da carga, e **depois continua em tempo real** (o servidor transmite a cada 10 min)
- Clima da cidade compartilhado pelas estações (sorteio determinístico por dia): chovem nos mesmos dias
- Sazonalidade, ciclo dia/noite, tardes chuvosas e um **dia de temporal** 5 dias antes da carga
- ~2 % dos lotes não enviados → falha de transmissão; ~0,5 % das leituras com -9999 → falha de sensor

## Otimizações testadas

| Técnica | Onde |
|---|---|
| Índice composto (estação, data_hora) | Chave primária de `leitura` |
| Particionamento mensal (partition pruning) | `leitura` e `leitura_arquivo` |
| Índice BRIN | `leitura_arquivo` |
| Índice parcial | `evento` (só eventos pendentes) |
| View materializada | `mv_resumo_horario` |
| Pré-agregação | `leitura_diaria` e coluna `chuva_acumulada` |
| Inserção em lote | Lotes de 10 leituras |

Metodologia dos testes adaptada de: GRZESIK, P.; MROZEK, D. *Comparative analysis of time series databases in the context of edge computing for low power sensor networks*. ICCS 2020, LNCS v. 12141, p. 371–383. DOI: 10.1007/978-3-030-50426-7_28.

## Limitações (para citar no documento)

- **Formato largo** (1 coluna por parâmetro): simples e rápido; um novo tipo de sensor exige alterar a tabela.
- **Custo da validação**: validar cada leitura deixou o envio de 1 leitura por lote ~30 % mais lento; em lotes de 10 o impacto é desprezível.
- **Agendador** no servidor Node.js (o PostgreSQL não tem agendador nativo; em produção, pg_cron).
- **Senhas dos papéis** padrão no `07` e no `config.exemplo.json`: trocar em produção; o painel roda em HTTP local (em produção, HTTPS na frente).
- **PITR e réplica** documentados, não configurados (exigem alterar o `postgresql.conf`).
