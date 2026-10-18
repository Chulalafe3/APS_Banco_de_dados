# Resultados dos testes – execução no PC do projeto

**Ambiente:** Windows, PostgreSQL 18, pgAdmin 4 (PSQL Tool) – banco `aps_defesa_civil` – 18/10/2026

## Carga inicial (04_carga_inicial.sql)

| Item | Valor |
|---|---|
| Leituras geradas (6 meses, 2 estações) | 529.107 |
| Leituras na tabela principal (set + out) | 137.427 |
| Leituras arquivadas (abr – ago) | 391.680 |
| Dias resumidos em `leitura_diaria` | 272 |
| Tempo de arquivamento por mês (DETACH/ATTACH + resumo) | 104 – 341 ms |

| Estação | Transmissão OK | Falha de transmissão | Falha de sensor | Alarme |
|---|---|---|---|---|
| Centro | 25.950 | 497 | 1.370 | 16 |
| Zona Norte | 25.945 | 500 | 1.305 | 20 |

## Escrita (1000 pontos, 20 repetições, triggers ativas)

| Modo | Média | Desvio | Registros/s (aprox.) |
|---|---|---|---|
| Um a um | 712,0 ms | 51,6 ms | ~1.400 |
| Lotes de 10 | 264,1 ms | 67,0 ms | ~3.800 |

Lote ≈ **2,7× mais rápido**.

## Consultas (500 repetições cada, tempo médio em ms)

| Consulta | A sem índice | B índice composto | C particionada | D view materializada |
|---|---|---|---|---|
| Q1 – estação, 1 dia, vento máx. | 32,10 | **0,41** (79×) | 0,47 (68×) | – |
| Q2 – temp. média 7 dias, por estação | 34,84 | 5,26 (6,6×) | 7,37 (4,7×) | **0,19** (185×) |
| Q3 – mín/máx 7 dias, por estação | 36,93 | 7,34 (5,0×) | 9,51 (3,9×) | **0,23** (161×) |
| Q4 – vento > 5 m/s por dia, 30 dias | 72,06 | **10,41** (6,9×) | 12,55 (5,7×) | – |

| Q5 – chuva do dia | Média |
|---|---|
| Somando os minutos | 0,367 ms |
| Lendo a coluna `chuva_acumulada` | **0,101 ms** (3,6×) |

## Observação para a discussão

No PostgreSQL 16 (ambiente de desenvolvimento), o índice composto (estação, data_hora) **não** acelerava Q2 e Q3,
que filtram só por período — o banco fazia varredura completa. No **PostgreSQL 18** (PC do projeto), o mesmo índice
passou a ajudar (≈ 5–7× mais rápido), porque a versão 18 introduziu o *skip scan* em índices B-tree de várias colunas:
o banco "pula" pelos poucos valores de estação e usa a segunda coluna (data_hora) do índice.
Mesmo assim, o particionamento e a view materializada continuam importantes: o particionamento reduz o volume
lido e facilita o arquivamento, e a view materializada é a mais rápida para os painéis.
