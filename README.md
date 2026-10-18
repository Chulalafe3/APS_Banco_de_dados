# APS — Banco de Dados de Telemetria IoT (Estação Meteorológica)

> **Versão atual: pasta [`defesa_civil/`](defesa_civil/)** — monitoramento para a Defesa Civil de São José dos Campos
> (2 estações, eventos de transmissão/falha/alarme, partições com arquivamento mensal e testes de desempenho).
> Instruções no [`defesa_civil/LEIAME.md`](defesa_civil/LEIAME.md).
> Os scripts na raiz abaixo são a versão anterior (1 estação, 9 sensores), mantidos como histórico.

APS Independente — LPBD (UNIP). PostgreSQL + PL/pgSQL.

## Ordem de execução (banco novo)

No pgAdmin: crie o banco `aps_estacao_iot`, abra o **Query Tool nele** e rode
cada arquivo inteiro (F5), nesta ordem:

| # | Arquivo | O que faz |
|---|---------|-----------|
| 1 | `01_schema.sql` | Tabelas, telemetria particionada por mês (uma coluna por sensor), partições de 3 meses para trás e 3 para frente |
| 2 | `02_procedures_simulador.sql` | Gerador de valores realista + procedures de carga e transmissão |
| 3 | `03_sensores_iniciais.sql` | Estação de SJC e os 9 sensores |
| 4 | `04_limites_alerta.sql` | Regras de alerta configuráveis |
| 5 | `05_trigger_alertas.sql` | Trigger de falha/alerta e status da estação |
| 6 | **Carga histórica** | `CALL sp_gerar_historico(1, 3);` (3 meses, um mês por vez) |
| 7 | `06_arquivamento.sql` | Data Lifecycle: arquivamento > 30 dias, partições futuras, view completa |
| 8 | Teste do arquivamento | `CALL sp_arquivar_telemetria();` |

A carga histórica roda **depois** da trigger, para que cada leitura passe pela
verificação como passaria em produção. Tempo de referência (teste em
PostgreSQL 16): 3 meses = cerca de 132 mil linhas (1,2 milhão de valores) em
1,5 minuto, com a trigger ligada.

## Formato da telemetria

Uma linha por estação por minuto, com uma coluna por sensor:

| id_leitura | id_estacao | data_hora | temperatura_ar | umidade_ar | velocidade_vento | direcao_vento | rajada_vento | pressao_barometrica | radiacao_solar | pluviometro | umidade_solo |
|---|---|---|---|---|---|---|---|---|---|---|---|

O nome da coluna é o `tipo_sensor` da tabela `sensores` em minúsculas. A trigger
usa essa regra para ligar cada coluna ao sensor, aos limites e aos alertas.
Para adicionar um sensor: `ALTER TABLE telemetria ADD COLUMN <tipo> NUMERIC(10,2);`
(e na `telemetria_historico`), cadastrar o sensor com o mesmo `tipo_sensor` e
incluir a coluna no `sp_gerar_carga_massiva`.

## Banco criado com a versão antiga (uma linha por sensor)

Rode `07_migrar_formato_colunas.sql` e depois, de novo, `02`, `05` e `06`.
A migração converte os dados atuais e arquivados e mantém os alertas.

## Demonstração ao vivo

```sql
CALL sp_transmitir_leituras(1);   -- envia o lote dos últimos 10 minutos
```

Pode chamar mais de uma vez: minutos que já existem são ignorados (índice único
sensor + minuto).
