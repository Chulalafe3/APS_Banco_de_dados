# APS — Banco de Dados de Telemetria IoT (Estação Meteorológica)

APS Independente — LPBD (UNIP). PostgreSQL + PL/pgSQL.

## Ordem de execução (banco novo)

No pgAdmin: crie o banco `aps_estacao_iot`, abra o **Query Tool nele** e rode
cada arquivo inteiro (F5), nesta ordem:

| # | Arquivo | O que faz |
|---|---------|-----------|
| 1 | `01_schema.sql` | Tabelas, telemetria particionada por mês, partições de 3 meses para trás e 3 para frente |
| 2 | `02_procedures_simulador.sql` | Gerador de valores realista + procedures de carga e transmissão |
| 3 | `03_sensores_iniciais.sql` | Estação de SJC e os 9 sensores |
| 4 | `04_limites_alerta.sql` | Regras de alerta configuráveis |
| 5 | `05_trigger_alertas.sql` | Trigger de falha/alerta e status da estação |
| 6 | **Carga histórica** | `CALL sp_gerar_historico(1, 3);` (3 meses, um mês por vez) |
| 7 | `06_arquivamento.sql` | Data Lifecycle: arquivamento > 30 dias, partições futuras, view completa |
| 8 | Teste do arquivamento | `CALL sp_arquivar_telemetria();` |

A carga histórica roda **depois** da trigger, para que cada leitura passe pela
verificação como passaria em produção. Tempo de referência (teste em
PostgreSQL 16): cerca de 1,2 milhão de leituras em 3–4 minutos, com a trigger ligada.

## Demonstração ao vivo

```sql
CALL sp_transmitir_leituras(1);   -- envia o lote dos últimos 10 minutos
```

Pode chamar mais de uma vez: minutos que já existem são ignorados (índice único
sensor + minuto).
