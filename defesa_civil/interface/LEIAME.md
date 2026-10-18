# Painel web – Monitoramento Meteorológico (APS)

Interface em Python (Streamlit) que lê o banco `aps_defesa_civil` ao vivo.

## Como abrir (Windows)

1. Instale o Python 3.11 ou mais novo em https://www.python.org/downloads/ (marque **Add python.exe to PATH**).
2. Dê dois cliques em `iniciar.bat`. Na primeira vez ele instala as bibliotecas (1–2 min).
3. O navegador abre em http://localhost:8501. Digite a senha do usuário `postgres` na barra lateral.

Para não digitar a senha sempre: renomeie `.streamlit/secrets.toml.exemplo` para `secrets.toml` e preencha `password`.

## Abas

| Aba | O que mostra | De onde vem |
|---|---|---|
| Painel | Status de cada estação, última leitura, eventos pendentes, últimos alarmes e falhas | `vw_status_estacoes`, `vw_log_eventos` |
| Gráficos | Temperatura, umidade, vento e radiação (24 h, 7 ou 30 dias), com as linhas de alarme | `leitura` (24 h) e `mv_resumo_horario` (7/30 dias) |
| Chuva | Chuva acumulada por dia, com o limite de 50 mm | `leitura` + `leitura_diaria` |
| Eventos | Log filtrável por estação, tipo e período; marcar como visto | `vw_log_eventos`, `evento` |
| Histórico | Meses arquivados: temperatura e chuva por mês, log do arquivamento | `leitura_diaria`, `log_arquivamento` |
| Exportar | Leituras no formato de planilha, com download em CSV | `vw_exportacao` |

## Botões da barra lateral

- **Simular transmissões até agora**: gera as leituras desde a última recebida até o minuto atual (as triggers rodam normalmente), como se os dataloggers tivessem transmitido.
- **Verificar comunicação**: roda `fn_verificar_comunicacao()` e marca FALHA nas estações atrasadas.
- **Atualizar resumo horário**: `REFRESH` da view materializada.
