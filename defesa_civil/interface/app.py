"""
APS - Painel web da Defesa Civil de São José dos Campos
Lê o banco aps_defesa_civil (PostgreSQL) e mostra status, gráficos, eventos e histórico.

Rodar:  streamlit run app.py
"""
import os
from datetime import date, timedelta

import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import psycopg2
import streamlit as st

st.set_page_config(page_title="Monitoramento Meteorológico – Defesa Civil SJC", page_icon="🌧️", layout="wide")

COR_STATUS = {"OPERACIONAL": "#2e7d32", "ALERTA": "#ed6c02", "FALHA": "#c62828"}
COR_ESTACAO = {"Estação Centro": "#1f77b4", "Estação Zona Norte": "#9467bd"}
TIPOS = ["Alarme", "Falha de sensor", "Falha de transmissão", "Transmissão OK"]


# ---------------------------------------------------------------------
# Conexão
# ---------------------------------------------------------------------
def segredo(chave, padrao):
    try:
        return st.secrets["banco"][chave]
    except Exception:
        return os.environ.get(f"PG{chave.upper()}", padrao)


with st.sidebar:
    st.header("Conexão com o banco")
    host = st.text_input("Servidor", segredo("host", "localhost"))
    porta = st.text_input("Porta", str(segredo("port", "5432")))
    banco = st.text_input("Banco", segredo("database", "aps_defesa_civil"))
    usuario = st.text_input("Usuário", segredo("user", "postgres"))
    senha = st.text_input("Senha", segredo("password", ""), type="password")


@st.cache_resource(show_spinner=False)
def conectar(host, porta, banco, usuario, senha):
    conn = psycopg2.connect(host=host, port=porta, dbname=banco, user=usuario, password=senha,
                            connect_timeout=5, options="-c timezone=America/Sao_Paulo")
    conn.autocommit = True
    return conn


def conexao():
    conn = conectar(host, porta, banco, usuario, senha)
    if conn.closed:
        conectar.clear()
        conn = conectar(host, porta, banco, usuario, senha)
    return conn


def consulta(sql, params=None):
    with conexao().cursor() as cur:
        cur.execute(sql, params)
        if cur.description is None:
            return pd.DataFrame()
        cols = [c.name for c in cur.description]
        df = pd.DataFrame(cur.fetchall(), columns=cols)
    for c in df.columns:  # NUMERIC chega como Decimal
        if df[c].dtype == object and len(df) and df[c].map(lambda v: v.__class__.__name__ == "Decimal").any():
            df[c] = pd.to_numeric(df[c])
    return df


def executar(sql, params=None):
    with conexao().cursor() as cur:
        cur.execute(sql, params)


try:
    conexao()
except Exception as erro:
    st.title("Monitoramento Meteorológico – Defesa Civil SJC")
    st.error("Não foi possível conectar ao banco. Confira os dados de conexão na barra lateral "
             "(a senha é a do usuário postgres definida na instalação).")
    st.caption(f"Detalhe: {erro}")
    st.stop()

with st.sidebar:
    st.success("Conectado")
    st.divider()
    st.subheader("Simulação")
    st.caption("Na vida real os dataloggers enviam lotes a cada 10 min. "
               "Aqui o simulador gera os dados que faltam até agora.")
    if st.button("Simular transmissões até agora", use_container_width=True):
        with st.spinner("Gerando leituras e rodando as triggers..."):
            disp = consulta("""
                SELECT d.id_dispositivo, d.nome,
                       COALESCE((SELECT MAX(l.data_hora) FROM leitura l WHERE l.id_dispositivo = d.id_dispositivo),
                                date_trunc('day', now())) + INTERVAL '1 minute' AS inicio
                  FROM dispositivo d WHERE d.ativo ORDER BY 1""")
            executar("CALL sp_criar_particoes(CURRENT_DATE, 2)")
            for _, d in disp.iterrows():
                executar("CALL sp_simular_dispositivo(%s, %s, date_trunc('minute', now()))",
                         (int(d.id_dispositivo), d.inicio))
            executar("CALL sp_atualizar_resumo_horario()")
        st.success("Dados atualizados.")
    if st.button("Verificar comunicação", use_container_width=True):
        n = consulta("SELECT fn_verificar_comunicacao() AS n").n.iloc[0]
        st.info(f"{n} estação(ões) marcada(s) com falha de transmissão." if n else "Todas as estações estão comunicando.")
    if st.button("Atualizar resumo horário", use_container_width=True,
                 help="REFRESH da view materializada mv_resumo_horario"):
        executar("CALL sp_atualizar_resumo_horario()")
        st.success("View materializada atualizada.")

cliente = consulta("SELECT nome FROM cliente ORDER BY id_cliente LIMIT 1")
st.title("Monitoramento Meteorológico")
st.caption(f"Cliente: **{cliente.nome.iloc[0] if len(cliente) else '-'}** · dados do banco PostgreSQL `{banco}`")

aba_painel, aba_graf, aba_chuva, aba_eventos, aba_hist, aba_export = st.tabs(
    ["Painel", "Gráficos", "Chuva", "Eventos", "Histórico", "Exportar"])

# ---------------------------------------------------------------------
# Painel
# ---------------------------------------------------------------------
with aba_painel:
    est = consulta("SELECT * FROM vw_status_estacoes ORDER BY estacao")
    cols = st.columns(len(est) or 1)
    for col, (_, e) in zip(cols, est.iterrows()):
        with col:
            cor = COR_STATUS.get(e.status, "#555")
            st.markdown(
                f"<div style='border-left:6px solid {cor};padding:4px 12px;margin-bottom:8px'>"
                f"<div style='font-size:1.25rem;font-weight:600'>{e.estacao}</div>"
                f"<span style='background:{cor};color:white;border-radius:4px;padding:2px 8px;font-size:0.85rem'>{e.status}</span>"
                f"<span style='color:gray;font-size:0.85rem'> &nbsp;última leitura "
                f"{pd.Timestamp(e.ultima_leitura).strftime('%d/%m %H:%M') if pd.notna(e.ultima_leitura) else '-'}"
                f" · {int(e.minutos_sem_comunicacao or 0)} min sem comunicação</span></div>",
                unsafe_allow_html=True)
            a, b, c = st.columns(3)
            a.metric("Temperatura", f"{e.temperatura_ar:.1f} °C" if pd.notna(e.temperatura_ar) else "–")
            b.metric("Umidade", f"{e.umidade_ar:.0f} %" if pd.notna(e.umidade_ar) else "–")
            c.metric("Chuva hoje", f"{e.chuva_hoje_mm:.1f} mm" if pd.notna(e.chuva_hoje_mm) else "–")
            a, b, c = st.columns(3)
            a.metric("Vento", f"{e.velocidade_vento:.1f} m/s" if pd.notna(e.velocidade_vento) else "–")
            b.metric("Direção", f"{e.direcao_vento:.0f}°" if pd.notna(e.direcao_vento) else "–")
            c.metric("Radiação (W/m²)", f"{e.radiacao_solar:.0f}" if pd.notna(e.radiacao_solar) else "–")
            st.caption(f"Eventos pendentes: **{e.eventos_pendentes}**")

    st.subheader("Últimos alarmes e falhas")
    ult = consulta("""SELECT data_hora, estacao, tipo, mensagem FROM vw_log_eventos
                       WHERE tipo <> 'Transmissão OK' ORDER BY data_hora DESC LIMIT 10""")
    st.dataframe(ult, hide_index=True, use_container_width=True,
                 column_config={"data_hora": st.column_config.DatetimeColumn("Data/hora", format="DD/MM/YY HH:mm"),
                                 "estacao": "Estação", "tipo": "Tipo", "mensagem": "Mensagem"})

# ---------------------------------------------------------------------
# Gráficos
# ---------------------------------------------------------------------
with aba_graf:
    c1, c2 = st.columns([1, 2])
    periodo = c1.radio("Período", ["Últimas 24 horas", "Últimos 7 dias", "Últimos 30 dias"], horizontal=False)
    nomes = est.estacao.tolist()
    escolha = c2.multiselect("Estações", nomes, default=nomes)
    if periodo == "Últimas 24 horas":
        df = consulta("""
            SELECT d.nome AS estacao, l.data_hora AS momento, l.temperatura_ar AS temperatura,
                   l.umidade_ar AS umidade, l.chuva, l.velocidade_vento AS vento, l.radiacao_solar AS radiacao
              FROM leitura l JOIN dispositivo d USING (id_dispositivo)
             WHERE l.data_hora >= (SELECT MAX(data_hora) FROM leitura) - INTERVAL '24 hours'
             ORDER BY l.data_hora""")
        fonte = "tabela leitura (1 ponto por minuto)"
    else:
        dias = 7 if "7" in periodo else 30
        df = consulta(f"""
            SELECT d.nome AS estacao, m.hora AS momento, m.temp_media AS temperatura,
                   m.umidade_media AS umidade, m.chuva_hora AS chuva, m.vento_max AS vento, m.radiacao_media AS radiacao
              FROM mv_resumo_horario m JOIN dispositivo d USING (id_dispositivo)
             WHERE m.hora >= (SELECT MAX(hora) FROM mv_resumo_horario) - INTERVAL '{dias} days'
             ORDER BY m.hora""")
        fonte = "view materializada mv_resumo_horario (1 ponto por hora)"
    df = df[df.estacao.isin(escolha)]
    if df.empty:
        st.info("Sem dados para o período.")
    else:
        def linha(y, titulo, unidade, limite=None, nome_limite=""):
            fig = px.line(df, x="momento", y=y, color="estacao", color_discrete_map=COR_ESTACAO,
                          labels={"momento": "", y: unidade, "estacao": "Estação"})
            if limite is not None:
                fig.add_hline(y=limite, line_dash="dash", line_color="#c62828",
                              annotation_text=nome_limite, annotation_position="top left")
            fig.update_layout(title=titulo, height=320, margin=dict(l=10, r=10, t=70, b=10), legend_title_text="",
                              legend=dict(orientation="h", y=1.12, x=0))
            return fig
        g1, g2 = st.columns(2)
        g1.plotly_chart(linha("temperatura", "Temperatura do ar", "°C", 35, "alarme 35 °C"), use_container_width=True)
        g2.plotly_chart(linha("umidade", "Umidade do ar", "%", 20, "alarme 20 %"), use_container_width=True)
        g3, g4 = st.columns(2)
        g3.plotly_chart(linha("vento", "Velocidade do vento" + (" (máxima da hora)" if periodo != "Últimas 24 horas" else ""),
                              "m/s", 17, "alarme 17 m/s"), use_container_width=True)
        g4.plotly_chart(linha("radiacao", "Radiação solar", "W/m²"), use_container_width=True)
        st.caption(f"Fonte: {fonte}.")

# ---------------------------------------------------------------------
# Chuva
# ---------------------------------------------------------------------
with aba_chuva:
    chuva = consulta("""
        SELECT d.nome AS estacao, (l.data_hora AT TIME ZONE 'America/Sao_Paulo')::date AS dia,
               MAX(l.chuva_acumulada) AS chuva_mm
          FROM leitura l JOIN dispositivo d USING (id_dispositivo)
         GROUP BY 1, 2
        UNION ALL
        SELECT d.nome, r.dia, r.chuva_total FROM leitura_diaria r JOIN dispositivo d USING (id_dispositivo)
         ORDER BY 2""")
    ini = st.date_input("A partir de", value=date.today() - timedelta(days=30))
    ch = chuva[chuva.dia >= ini]
    fig = px.bar(ch, x="dia", y="chuva_mm", color="estacao", barmode="group", color_discrete_map=COR_ESTACAO,
                 labels={"dia": "", "chuva_mm": "mm no dia", "estacao": "Estação"})
    fig.add_hline(y=50, line_dash="dash", line_color="#c62828", annotation_text="alarme crítico 50 mm",
                  annotation_position="top left")
    fig.update_layout(title="Chuva acumulada por dia", height=420, legend_title_text="", margin=dict(t=70),
                      legend=dict(orientation="h", y=1.1, x=0))
    st.plotly_chart(fig, use_container_width=True)
    top = ch.sort_values("chuva_mm", ascending=False).head(5)
    st.caption("Dias mais chuvosos no período: " +
               "; ".join(f"{r.dia:%d/%m} {r.estacao.replace('Estação ', '')} {r.chuva_mm:.1f} mm" for _, r in top.iterrows()))

# ---------------------------------------------------------------------
# Eventos
# ---------------------------------------------------------------------
with aba_eventos:
    c1, c2, c3 = st.columns(3)
    f_est = c1.multiselect("Estação", nomes, default=nomes, key="ev_est")
    f_tipo = c2.multiselect("Tipo", TIPOS, default=TIPOS[:3])
    f_dias = c3.selectbox("Período", [7, 30, 90, 365], index=1, format_func=lambda d: f"Últimos {d} dias")
    ev = consulta("""SELECT data_hora, estacao, tipo, mensagem, reconhecido FROM vw_log_eventos
                      WHERE data_hora >= now() - make_interval(days => %s)
                      ORDER BY data_hora DESC""", (int(f_dias),))
    ev = ev[ev.estacao.isin(f_est) & ev.tipo.isin(f_tipo)]
    m = st.columns(4)
    for col, t in zip(m, TIPOS):
        col.metric(t, int((ev.tipo == t).sum()) if t in f_tipo else "–")
    st.dataframe(ev.head(1000), hide_index=True, use_container_width=True, height=420,
                 column_config={"data_hora": st.column_config.DatetimeColumn("Data/hora", format="DD/MM/YY HH:mm"),
                                "estacao": "Estação", "tipo": "Tipo", "mensagem": "Mensagem",
                                "reconhecido": st.column_config.CheckboxColumn("Visto")})
    if len(ev) > 1000:
        st.caption(f"Mostrando 1.000 de {len(ev)} eventos.")
    if st.button("Marcar alarmes e falhas filtrados como vistos"):
        executar("""UPDATE evento e SET reconhecido = TRUE FROM dispositivo d
                     WHERE d.id_dispositivo = e.id_dispositivo AND NOT e.reconhecido
                       AND e.tipo <> 'TRANSMISSAO_OK' AND d.nome = ANY(%s)
                       AND e.data_hora >= now() - make_interval(days => %s)""", (f_est, int(f_dias)))
        st.rerun()

# ---------------------------------------------------------------------
# Histórico (resumo diário dos meses arquivados)
# ---------------------------------------------------------------------
with aba_hist:
    hist = consulta("""
        SELECT d.nome AS estacao, date_trunc('month', r.dia)::date AS mes,
               ROUND(AVG(r.temp_media), 1) AS temp_media, MIN(r.temp_min) AS temp_min, MAX(r.temp_max) AS temp_max,
               MIN(r.umidade_min) AS umidade_min, SUM(r.chuva_total) AS chuva_total, MAX(r.vento_max) AS vento_max,
               SUM(r.qtd_valores_invalidos) AS valores_invalidos, COUNT(*) AS dias
          FROM leitura_diaria r JOIN dispositivo d USING (id_dispositivo)
         GROUP BY 1, 2 ORDER BY 2, 1""")
    if hist.empty:
        st.info("Ainda não há meses arquivados.")
    else:
        h1, h2 = st.columns(2)
        fig = go.Figure()
        for nome, g in hist.groupby("estacao"):
            cor = COR_ESTACAO.get(nome)
            fig.add_trace(go.Scatter(x=g.mes, y=g.temp_media, name=nome, mode="lines+markers", line=dict(color=cor),
                                     error_y=dict(type="data", symmetric=False, array=g.temp_max - g.temp_media,
                                                  arrayminus=g.temp_media - g.temp_min, color=cor, thickness=1)))
        fig.update_layout(title="Temperatura por mês (média, mínima e máxima)", yaxis_title="°C", height=360,
                          margin=dict(t=70), legend=dict(orientation="h", y=1.12, x=0))
        h1.plotly_chart(fig, use_container_width=True)
        fig = px.bar(hist, x="mes", y="chuva_total", color="estacao", barmode="group", color_discrete_map=COR_ESTACAO,
                     labels={"mes": "", "chuva_total": "mm no mês", "estacao": "Estação"})
        fig.update_layout(title="Chuva total por mês", height=360, legend_title_text="", margin=dict(t=70),
                          legend=dict(orientation="h", y=1.12, x=0))
        h2.plotly_chart(fig, use_container_width=True)
        st.dataframe(hist, hide_index=True, use_container_width=True,
                     column_config={"estacao": "Estação", "mes": st.column_config.DateColumn("Mês", format="MM/YYYY"),
                                    "temp_media": "Temp. média (°C)", "temp_min": "Temp. mín. (°C)", "temp_max": "Temp. máx. (°C)",
                                    "umidade_min": "Umidade mín. (%)", "chuva_total": "Chuva (mm)", "vento_max": "Vento máx. (m/s)",
                                    "valores_invalidos": "Valores inválidos", "dias": "Dias"})
        arq = consulta("SELECT particao, linhas_movidas, dias_resumidos, duracao_ms, executado_em FROM log_arquivamento ORDER BY particao")
        with st.expander("Log de arquivamento (Data Lifecycle)"):
            st.dataframe(arq, hide_index=True, use_container_width=True)

# ---------------------------------------------------------------------
# Exportar (formato planilha, como o CSV de plataformas comerciais)
# ---------------------------------------------------------------------
with aba_export:
    c1, c2, c3 = st.columns(3)
    e_est = c1.selectbox("Estação", nomes)
    e_ini = c2.date_input("De", value=date.today() - timedelta(days=1), key="ex_ini")
    e_fim = c3.date_input("Até", value=date.today(), key="ex_fim")
    ex = consulta("""SELECT "Estação", "Data", "Hora", "Temperatura do ar (°C)", "Umidade do ar (%%)", "Chuva (mm)",
                            "Chuva acumulada no dia (mm)", "Direção do vento (°)", "Velocidade do vento (m/s)",
                            "Radiação solar (W/m²)"
                       FROM vw_exportacao
                      WHERE "Estação" = %s AND data_hora >= %s AND data_hora < %s::date + 1
                      ORDER BY data_hora""", (e_est, e_ini, e_fim))
    st.caption(f"{len(ex):,} leituras".replace(",", "."))
    st.dataframe(ex.head(2000), hide_index=True, use_container_width=True, height=380)
    st.download_button("Baixar CSV", ex.to_csv(index=False, sep=";", decimal=",").encode("utf-8-sig"),
                       file_name=f"{e_est.replace(' ', '_')}_{e_ini}_{e_fim}.csv", mime="text/csv")

st.divider()
st.caption("APS – Banco de Dados de Telemetria IoT · UNIP São José dos Campos · Sensor → borda (datalogger) → nuvem (PostgreSQL) → este painel")
