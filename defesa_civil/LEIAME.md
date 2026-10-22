# APS – Banco de Dados de Telemetria IoT
## Monitoramento meteorológico para a Defesa Civil de São José dos Campos

Banco de dados PostgreSQL (PL/pgSQL) para receber, validar, armazenar e consultar dados de estações meteorológicas, com detecção de falhas e alarmes em tempo real.

---

## Ordem de execução

Criar um banco novo (ex.: `aps_defesa_civil`) e rodar, nesta ordem:

| # | Arquivo | O que faz | Tempo aprox. |
|---|---|---|---|
| 1 | `01_estrutura.sql` | Tabelas, chaves, índices e view materializada | segundos |
| 2 | `02_regras.sql` | Triggers, recepção de lotes, partições e arquivamento | segundos |
| 3 | `03_simulador.sql` | Procedure que simula o dispositivo | segundos |
| 4 | `04_carga_inicial.sql` | Cliente, 2 estações, sensores, regras, 6 meses de dados e arquivamento | ~1,5 min |
| 5 | `05_consultas.sql` | Views para visualização e consultas de exemplo | segundos |
| 6 | `06_testes_desempenho.sql` | Testes de escrita e consulta | ~2–3 min |

> O `04` e o `06` precisam do **PSQL Tool** (botão direito no banco → PSQL Tool → `\i 'caminho/arquivo.sql'`), não da Query Tool:
> o simulador faz `COMMIT` a cada lote, e a Query Tool envia o arquivo inteiro como uma única transação
> (erro *invalid transaction termination*). O `06` também usa variáveis do `psql`.

### Jeito mais fácil: um comando só

No PSQL Tool do banco `aps_defesa_civil` (use barras normais no caminho):

```
\i 'C:/caminho/APS_Banco_de_dados/defesa_civil/rodar_tudo.sql'
```

Ele **apaga e recria** o schema `public` e roda do `01` ao `05` (~2 min).

---

## Arquitetura (sensor → borda → nuvem)

| Camada | Na vida real | No projeto |
|---|---|---|
| Acesso do cliente | Login, senha, permissões | **Citado** no documento |
| Coleta | Datalogger ou CLP lê os sensores e armazena | **Simulada** (`sp_simular_dispositivo`) |
| Transmissão | 4G, LoRa, Ethernet, satélite | **Citado** no documento |
| Formato de envio | API, HTTP, TCP/IP, FTP | **Citado**; o lote chega em JSON, como numa API |
| Banco de dados (nuvem) | Armazenamento, regras, alarmes, histórico | **Implementado** |

Fluxo: o dispositivo mede a cada **1 min** e transmite um lote a cada **10 min** → `fn_receber_lote` grava as leituras → as triggers validam, calculam e geram eventos.

---

## Tabelas

| Tabela | Conteúdo |
|---|---|
| `cliente` | Defesa Civil de SJC |
| `dispositivo` | Estações: intervalos, localização, `ativo`, `status` e `ultima_comunicacao` |
| `sensor` | Parâmetros de cada estação com a **faixa física válida** (limites de segurança) |
| `leitura` | 1 linha por estação por minuto, 1 coluna por parâmetro + `chuva_acumulada`. **Particionada por mês** |
| `leitura_arquivo` | Meses antigos (mesma estrutura), com índice **BRIN** |
| `leitura_diaria` | Resumo diário (mín/máx/média, chuva total, direção predominante) |
| `regra_alarme` | Limites definidos pelo cliente |
| `evento` | Log: `TRANSMISSAO_OK`, `FALHA_TRANSMISSAO`, `FALHA_SENSOR`, `ALARME` |
| `log_arquivamento` | Auditoria do ciclo de vida |
| `mv_resumo_horario` | **View materializada** com o resumo por hora |

---

## Regras automáticas

| Regra | Onde | Como funciona |
|---|---|---|
| Falha de sensor | `trg_leitura_antes_inserir` | Valor fora da faixa do sensor (ex.: código -9999) vira NULL; o valor original fica no evento |
| Chuva acumulada | `trg_leitura_antes_inserir` | Soma a chuva do minuto ao acumulado do dia; zera à meia-noite |
| Alarme | `trg_leitura_depois_inserir` | Dispara quando o valor cruza o limite da regra; no máximo 1 vez por hora por regra |
| Status do dispositivo | `trg_leitura_depois_inserir` | `FALHA` (falha de sensor) > `ALERTA` (regra violada) > `OPERACIONAL` |
| Transmissão OK | `fn_receber_lote` | Registrada a cada lote recebido |
| Falha de transmissão | `fn_receber_lote` / `fn_verificar_comunicacao` | Lote atrasado mais de 10 + 5 min; ou verificação "ao vivo" |
| Data Lifecycle | `sp_arquivar_dados` | Mantém o mês atual + o anterior; meses antigos viram resumo diário e a partição inteira vai para o arquivo (DETACH/ATTACH) |

### Regras de alarme cadastradas

| Parâmetro | Condição | Nível |
|---|---|---|
| Chuva acumulada no dia | > 50 mm | CRÍTICO |
| Velocidade do vento | > 17 m/s (~61 km/h) | ALERTA |
| Temperatura do ar | > 35 °C | ALERTA |
| Umidade do ar | < 20 % | ALERTA |

---

## Simulação

- 2 estações (Centro e Zona Norte), 6 meses até a data da carga
- Sazonalidade (inverno mais frio e seco), ciclo dia/noite, tardes chuvosas
- **Dia de temporal** 5 dias antes da carga (chuva forte e rajadas de vento)
- ~2 % dos lotes não são enviados (seguem no lote seguinte) → falha de transmissão
- ~0,5 % das leituras com código de erro -9999 → falha de sensor

---

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

---

## Limitações (para citar no documento)

- **Formato largo** (1 coluna por parâmetro): simples e rápido para parâmetros fixos; incluir um novo tipo de sensor exige alterar a tabela.
- **Status** reflete a leitura mais recente; o histórico completo fica em `evento`.
- A verificação "ao vivo" (`fn_verificar_comunicacao`) e a atualização da view materializada precisariam de um agendador (ex.: pg_cron) em produção.
- Autenticação, transmissão e protocolos de envio não fazem parte do banco.
