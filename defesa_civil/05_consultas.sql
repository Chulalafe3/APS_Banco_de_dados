-- =====================================================================
-- APS - 05_consultas.sql
-- Views para a tela de visualização e consultas de exemplo para o relatório
-- =====================================================================
SET TIME ZONE 'America/Sao_Paulo';

-- ---------------------------------------------------------------------
-- 1. Leitura completa: dados recentes + histórico arquivado
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_leitura_completa AS
SELECT * FROM leitura
UNION ALL
SELECT * FROM leitura_arquivo;

-- ---------------------------------------------------------------------
-- 2. Painel das estações: status, última leitura e pendências
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_status_estacoes AS
SELECT c.nome                                   AS cliente,
       d.nome                                   AS estacao,
       d.status,
       d.ultima_comunicacao,
       ROUND(EXTRACT(EPOCH FROM now() - d.ultima_comunicacao) / 60) AS minutos_sem_comunicacao,
       u.data_hora                              AS ultima_leitura,
       u.temperatura_ar,
       u.umidade_ar,
       u.chuva_acumulada                        AS chuva_hoje_mm,
       u.velocidade_vento,
       u.direcao_vento,
       u.radiacao_solar,
       (SELECT COUNT(*) FROM evento e
         WHERE e.id_dispositivo = d.id_dispositivo
           AND NOT e.reconhecido
           AND e.tipo <> 'TRANSMISSAO_OK')      AS eventos_pendentes
  FROM dispositivo d
  JOIN cliente c USING (id_cliente)
  LEFT JOIN LATERAL (
        SELECT * FROM leitura l
         WHERE l.id_dispositivo = d.id_dispositivo
         ORDER BY l.data_hora DESC
         LIMIT 1) u ON TRUE
 WHERE d.ativo;

-- ---------------------------------------------------------------------
-- 3. Log de eventos (no estilo do log da LI-COR Cloud)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_log_eventos AS
SELECT e.data_hora,
       d.nome AS estacao,
       CASE e.tipo
            WHEN 'TRANSMISSAO_OK'    THEN 'Transmissão OK'
            WHEN 'FALHA_TRANSMISSAO' THEN 'Falha de transmissão'
            WHEN 'FALHA_SENSOR'      THEN 'Falha de sensor'
            WHEN 'ALARME'            THEN 'Alarme'
       END AS tipo,
       e.mensagem,
       e.reconhecido
  FROM evento e
  JOIN dispositivo d USING (id_dispositivo);

-- ---------------------------------------------------------------------
-- 4. Exportação no formato de planilha (como o CSV da LI-COR)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_exportacao AS
SELECT d.nome                                                   AS "Estação",
       to_char(l.data_hora, 'DD/MM/YY')                         AS "Data",
       to_char(l.data_hora, 'HH24:MI:SS')                       AS "Hora",
       l.temperatura_ar                                         AS "Temperatura do ar (°C)",
       l.umidade_ar                                             AS "Umidade do ar (%)",
       l.chuva                                                  AS "Chuva (mm)",
       l.chuva_acumulada                                        AS "Chuva acumulada no dia (mm)",
       l.direcao_vento                                          AS "Direção do vento (°)",
       l.velocidade_vento                                       AS "Velocidade do vento (m/s)",
       l.radiacao_solar                                         AS "Radiação solar (W/m²)",
       l.id_dispositivo,
       l.data_hora
  FROM vw_leitura_completa l
  JOIN dispositivo d USING (id_dispositivo);


-- =====================================================================
-- CONSULTAS DE EXEMPLO (rodar uma de cada vez no pgAdmin)
-- =====================================================================

-- Painel das estações
SELECT * FROM vw_status_estacoes;

-- Últimos 20 eventos que exigem atenção (usa o índice parcial)
SELECT * FROM vw_log_eventos
 WHERE tipo <> 'Transmissão OK' AND NOT reconhecido
 ORDER BY data_hora DESC
 LIMIT 20;

-- Quantidade de eventos por tipo e estação
SELECT estacao, tipo, COUNT(*) AS quantidade
  FROM vw_log_eventos
 GROUP BY estacao, tipo
 ORDER BY estacao, tipo;

-- Alarmes registrados
SELECT * FROM vw_log_eventos WHERE tipo = 'Alarme' ORDER BY data_hora;

-- Exportação: últimas 2 horas da Estação Centro, no formato da planilha
SELECT "Estação", "Data", "Hora", "Temperatura do ar (°C)", "Umidade do ar (%)",
       "Chuva (mm)", "Chuva acumulada no dia (mm)", "Direção do vento (°)",
       "Velocidade do vento (m/s)", "Radiação solar (W/m²)"
  FROM vw_exportacao
 WHERE id_dispositivo = 1
   AND data_hora >= now() - INTERVAL '2 hours'
 ORDER BY data_hora;

-- Chuva por dia nos últimos 30 dias (dados recentes)
SELECT d.nome AS estacao,
       (l.data_hora AT TIME ZONE 'America/Sao_Paulo')::DATE AS dia,
       MAX(l.chuva_acumulada) AS chuva_mm
  FROM leitura l
  JOIN dispositivo d USING (id_dispositivo)
 WHERE l.data_hora >= now() - INTERVAL '30 days'
 GROUP BY d.nome, dia
HAVING MAX(l.chuva_acumulada) > 0
 ORDER BY dia, estacao;

-- Comparativo mensal das estações (histórico, via resumo diário)
SELECT d.nome AS estacao,
       to_char(r.dia, 'YYYY-MM')         AS mes,
       ROUND(AVG(r.temp_media), 1)       AS temp_media,
       MIN(r.temp_min)                   AS temp_min,
       MAX(r.temp_max)                   AS temp_max,
       MIN(r.umidade_min)                AS umidade_min,
       SUM(r.chuva_total)                AS chuva_total_mm,
       MAX(r.vento_max)                  AS vento_max,
       SUM(r.qtd_valores_invalidos)      AS valores_invalidos
  FROM leitura_diaria r
  JOIN dispositivo d USING (id_dispositivo)
 GROUP BY d.nome, mes
 ORDER BY mes, estacao;

-- Gráfico das últimas 24 h (lido da view materializada)
SELECT hora, temp_media, umidade_media, chuva_hora, vento_max
  FROM mv_resumo_horario
 WHERE id_dispositivo = 1
   AND hora >= now() - INTERVAL '24 hours'
 ORDER BY hora;

-- Histórico de arquivamento
SELECT * FROM log_arquivamento ORDER BY id_log;

-- Verificação de comunicação "ao vivo" (em produção roda num agendador)
SELECT fn_verificar_comunicacao();

-- Marcar os eventos de uma estação como vistos (reconhecidos)
-- UPDATE evento SET reconhecido = TRUE
--  WHERE id_dispositivo = 1 AND NOT reconhecido AND tipo <> 'TRANSMISSAO_OK';

-- Simular uma transmissão manual (como se viesse da API do dispositivo)
-- SELECT fn_receber_lote(1, '[{"data_hora": "2026-10-18T16:40:00-03:00",
--        "temperatura_ar": 24.1, "umidade_ar": 61, "chuva": 0, "direcao_vento": 130,
--        "velocidade_vento": 2.8, "radiacao_solar": 410}]'::jsonb);
