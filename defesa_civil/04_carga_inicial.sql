-- =====================================================================
-- APS - 04_carga_inicial.sql
-- Cadastro da Defesa Civil de SJC, 2 estações, sensores, regras de
-- alarme e 6 meses de dados simulados. No fim, roda o arquivamento.
--
-- Tempo esperado: alguns minutos (são ~527 mil leituras passando
-- pelas triggers, uma a uma, como num sistema real).
-- =====================================================================
SET TIME ZONE 'America/Sao_Paulo';

-- ---------------------------------------------------------------------
-- 1. Cliente
-- ---------------------------------------------------------------------
INSERT INTO cliente (nome, cidade, uf)
VALUES ('Defesa Civil de São José dos Campos', 'São José dos Campos', 'SP');

-- ---------------------------------------------------------------------
-- 2. Dispositivos (estações)
-- ---------------------------------------------------------------------
INSERT INTO dispositivo (id_cliente, nome, intervalo_leitura_min, intervalo_transmissao_min,
                         latitude, longitude)
VALUES (1, 'Estação Centro',     1, 10, -23.179400, -45.886900),
       (1, 'Estação Zona Norte', 1, 10, -23.151000, -45.892000);

-- ---------------------------------------------------------------------
-- 3. Sensores com a faixa física válida (limites de segurança)
-- ---------------------------------------------------------------------
INSERT INTO sensor (id_dispositivo, parametro, unidade, limite_min, limite_max)
SELECT d.id_dispositivo, s.parametro, s.unidade, s.limite_min, s.limite_max
  FROM dispositivo d
 CROSS JOIN (VALUES
       ('temperatura_ar',   '°C',   -40,  60),
       ('umidade_ar',       '%',      0, 100),
       ('chuva',            'mm',     0,  10),     -- por minuto
       ('direcao_vento',    '°',      0, 360),
       ('velocidade_vento', 'm/s',    0,  75),
       ('radiacao_solar',   'W/m²',   0, 1500)
     ) AS s(parametro, unidade, limite_min, limite_max)
 ORDER BY d.id_dispositivo;

-- ---------------------------------------------------------------------
-- 4. Regras de alarme da Defesa Civil (ajuste os limites se quiser)
-- ---------------------------------------------------------------------
INSERT INTO regra_alarme (id_dispositivo, parametro, condicao, limite, nivel, nota)
SELECT d.id_dispositivo, r.parametro, r.condicao, r.limite, r.nivel, r.nota
  FROM dispositivo d
 CROSS JOIN (VALUES
       ('chuva_acumulada',  'ACIMA',  50, 'CRITICO', 'Chuva acumulada no dia acima de 50 mm - risco de alagamento e deslizamento'),
       ('velocidade_vento', 'ACIMA',  17, 'ALERTA',  'Vento forte (acima de 61 km/h) - risco de queda de árvores'),
       ('temperatura_ar',   'ACIMA',  35, 'ALERTA',  'Calor extremo'),
       ('umidade_ar',       'ABAIXO', 20, 'ALERTA',  'Umidade do ar muito baixa - estado de alerta')
     ) AS r(parametro, condicao, limite, nivel, nota)
 ORDER BY d.id_dispositivo;

-- ---------------------------------------------------------------------
-- 5. Partições: do mês de 6 meses atrás até 2 meses à frente
-- ---------------------------------------------------------------------
CALL sp_criar_particoes((CURRENT_DATE - INTERVAL '6 months')::DATE, 9);

-- ---------------------------------------------------------------------
-- 6. Simulação: 6 meses até agora, com um dia de temporal há 5 dias
-- ---------------------------------------------------------------------
CALL sp_simular_dispositivo(
    p_id_dispositivo     => 1,
    p_inicio             => date_trunc('day', now() - INTERVAL '6 months'),
    p_fim                => date_trunc('minute', now()),
    p_dia_temporal       => CURRENT_DATE - 5);

CALL sp_simular_dispositivo(
    p_id_dispositivo     => 2,
    p_inicio             => date_trunc('day', now() - INTERVAL '6 months'),
    p_fim                => date_trunc('minute', now()),
    p_dia_temporal       => CURRENT_DATE - 5,
    p_ajuste_temperatura => -0.8);       -- Zona Norte um pouco mais fresca

ANALYZE;
CALL sp_atualizar_resumo_horario();

-- ---------------------------------------------------------------------
-- 7. Situação antes do arquivamento
-- ---------------------------------------------------------------------
SELECT 'antes do arquivamento' AS momento,
       (SELECT COUNT(*) FROM leitura)          AS leituras_recentes,
       (SELECT COUNT(*) FROM leitura_arquivo)  AS leituras_arquivo;

-- ---------------------------------------------------------------------
-- 8. Ciclo de vida: mantém mês atual + anterior, arquiva o resto
-- ---------------------------------------------------------------------
CALL sp_arquivar_dados();
ANALYZE;

SELECT 'depois do arquivamento' AS momento,
       (SELECT COUNT(*) FROM leitura)          AS leituras_recentes,
       (SELECT COUNT(*) FROM leitura_arquivo)  AS leituras_arquivo,
       (SELECT COUNT(*) FROM leitura_diaria)   AS dias_resumidos;

SELECT * FROM log_arquivamento ORDER BY id_log;

-- Resumo dos eventos gerados
SELECT d.nome AS estacao, e.tipo, COUNT(*) AS quantidade
  FROM evento e
  JOIN dispositivo d USING (id_dispositivo)
 GROUP BY d.nome, e.tipo
 ORDER BY d.nome, e.tipo;
