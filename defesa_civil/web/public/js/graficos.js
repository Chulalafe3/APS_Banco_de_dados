// Gráficos em SVG sem biblioteca: linhas (com mira e dica), barras,
// minicurva e o pluviômetro dos cartões das estações.
import { h, s, fmt, limpar } from './ui.js';

const M = { topo: 14, dir: 16, base: 28, esq: 44 };

// escala "bonita" para o eixo Y
function escala(min, max, passos = 5) {
  if (min === max) { min -= 1; max += 1; }
  const bruto = (max - min) / passos;
  const mag = 10 ** Math.floor(Math.log10(bruto));
  const passo = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((p) => p >= bruto) || bruto;
  const ini = Math.floor(min / passo) * passo;
  const fim = Math.ceil(max / passo) * passo;
  const ticks = [];
  for (let v = ini; v <= fim + passo / 2; v += passo) ticks.push(+v.toFixed(6));
  return { min: ini, max: fim, ticks };
}

function ticksTempo(t0, t1, largura) {
  const alvo = Math.max(2, Math.floor(largura / 95));
  const opcoes = [3600e3, 3 * 3600e3, 6 * 3600e3, 12 * 3600e3, 86400e3, 2 * 86400e3, 7 * 86400e3, 14 * 86400e3, 30 * 86400e3];
  const passo = opcoes.find((p) => (t1 - t0) / p <= alvo) || opcoes[opcoes.length - 1];
  // alinha ao fuso de Brasília (UTC-3)
  const off = 3 * 3600e3;
  const out = [];
  for (let t = Math.ceil((t0 - off) / passo) * passo + off; t <= t1; t += passo) out.push(t);
  return { lista: out, diario: passo >= 86400e3 };
}

// Mantém o gráfico do tamanho do contêiner
function responsivo(alvo, desenhar) {
  let larg = 0;
  const ro = new ResizeObserver(() => {
    const w = Math.floor(alvo.clientWidth);
    if (w && w !== larg) { larg = w; desenhar(w); }
  });
  ro.observe(alvo);
  return () => ro.disconnect();
}

/**
 * series: [{ id, nome, cor, pontos: [{ t: ms, v }] }]
 * limites: [{ valor, rotulo, cor }]
 */
export function graficoLinhas(alvo, { series, limites = [], unidade = '', altura = 240, casas = 1, minZero = false, rotulo }) {
  const caixa = h('div', { class: 'grafico', role: 'img', 'aria-label': rotulo || 'Gráfico' });
  limpar(alvo).append(caixa);

  const todos = series.flatMap((se) => se.pontos.filter((p) => p.v !== null && p.v !== undefined));
  if (!todos.length) { caixa.append(h('div', { class: 'vazio' }, 'Sem leituras neste período.')); return () => {}; }

  return responsivo(alvo, (W) => {
    limpar(caixa);
    const H = altura;
    const t0 = Math.min(...todos.map((p) => p.t));
    const t1 = Math.max(...todos.map((p) => p.t));
    const vals = todos.map((p) => p.v).concat(limites.map((l) => l.valor));
    const ey = escala(minZero ? 0 : Math.min(...vals), Math.max(...vals));
    const x = (t) => M.esq + ((t - t0) / Math.max(1, t1 - t0)) * (W - M.esq - M.dir);
    const y = (v) => M.topo + (1 - (v - ey.min) / (ey.max - ey.min)) * (H - M.topo - M.base);

    const svg = s('svg', { viewBox: `0 0 ${W} ${H}`, width: W, height: H });
    const grade = s('g', { class: 'grade' });
    const eixo = s('g', { class: 'eixo' });
    for (const v of ey.ticks) {
      grade.append(s('line', { x1: M.esq, x2: W - M.dir, y1: y(v), y2: y(v) }));
      eixo.append(s('text', { x: M.esq - 8, y: y(v) + 4, 'text-anchor': 'end' }, fmt.num(v, Math.abs(ey.ticks[1] - ey.ticks[0]) < 1 ? 1 : 0)));
    }
    const tt = ticksTempo(t0, t1, W - M.esq - M.dir);
    for (const t of tt.lista) {
      eixo.append(s('text', { x: x(t), y: H - 8, 'text-anchor': 'middle' }, tt.diario ? fmt.diaMes(t) : fmt.hora(t)));
    }
    svg.append(grade, eixo);

    for (const l of limites) {
      if (l.valor < ey.min || l.valor > ey.max) continue;
      svg.append(s('g', { class: 'limite' },
        s('line', { x1: M.esq, x2: W - M.dir, y1: y(l.valor), y2: y(l.valor), stroke: l.cor }),
        s('text', { x: W - M.dir, y: y(l.valor) - 5, 'text-anchor': 'end', fill: l.cor }, l.rotulo)));
    }

    for (const se of series) {
      let d = ''; let anterior = null;
      for (const p of se.pontos) {
        if (p.v === null || p.v === undefined) { anterior = null; continue; }
        // buraco nos dados (> 3 intervalos) quebra a linha
        const quebra = anterior && p.t - anterior > (se.intervalo || 600e3) * 3;
        d += `${!anterior || quebra ? 'M' : 'L'}${x(p.t).toFixed(1)},${y(p.v).toFixed(1)}`;
        anterior = p.t;
      }
      svg.append(s('path', { class: 'serie', d, stroke: se.cor }));
    }

    // mira + dica
    const mira = s('line', { class: 'mira', y1: M.topo, y2: H - M.base, visibility: 'hidden' });
    const pontos = series.map((se) => s('circle', { r: 3.5, fill: se.cor, visibility: 'hidden' }));
    svg.append(mira, ...pontos);
    const dica = h('div', { class: 'dica', hidden: true });
    const area = s('rect', { x: M.esq, y: 0, width: W - M.esq - M.dir, height: H, fill: 'transparent' });
    svg.append(area);

    function mover(ev) {
      const r = svg.getBoundingClientRect();
      const px = ((ev.clientX - r.left) / r.width) * W;
      const t = t0 + ((px - M.esq) / (W - M.esq - M.dir)) * (t1 - t0);
      limpar(dica);
      let mostrado = false;
      series.forEach((se, i) => {
        let melhor = null;
        for (const p of se.pontos) {
          if (p.v === null || p.v === undefined) continue;
          if (!melhor || Math.abs(p.t - t) < Math.abs(melhor.t - t)) melhor = p;
        }
        if (!melhor || Math.abs(melhor.t - t) > (se.intervalo || 600e3) * 2) { pontos[i].setAttribute('visibility', 'hidden'); return; }
        if (!mostrado) {
          dica.append(h('div', { class: 't' }, tt.diario && !se.intervalo ? fmt.dataHora(melhor.t) : `${fmt.data(melhor.t)} ${fmt.hora(melhor.t)}`));
          mira.setAttribute('x1', x(melhor.t)); mira.setAttribute('x2', x(melhor.t));
          mostrado = true;
        }
        pontos[i].setAttribute('cx', x(melhor.t)); pontos[i].setAttribute('cy', y(melhor.v));
        pontos[i].setAttribute('visibility', 'visible');
        dica.append(h('div', { class: 'l' }, h('span', { class: 'pt', style: { background: se.cor } }),
          `${se.nome}: `, h('strong', {}, `${fmt.num(melhor.v, casas)} ${unidade}`)));
      });
      mira.setAttribute('visibility', mostrado ? 'visible' : 'hidden');
      dica.hidden = !mostrado;
      if (mostrado) {
        dica.style.left = `${Math.min(Math.max(ev.clientX - r.left, 90), r.width - 90)}px`;
        dica.style.top = `${M.topo + 8}px`;
      }
    }
    function sair() { dica.hidden = true; mira.setAttribute('visibility', 'hidden'); pontos.forEach((p) => p.setAttribute('visibility', 'hidden')); }
    area.addEventListener('pointermove', mover);
    area.addEventListener('pointerleave', sair);
    caixa.append(svg, dica);
  });
}

/**
 * Barras por dia, uma cor por estação.
 * dias: ['AAAA-MM-DD'...]; series: [{ id, nome, cor, valores: { dia: v } }]
 */
export function graficoBarras(alvo, { dias, series, limite = null, unidade = 'mm', altura = 260, rotulo }) {
  const caixa = h('div', { class: 'grafico', role: 'img', 'aria-label': rotulo || 'Gráfico de barras' });
  limpar(alvo).append(caixa);
  if (!dias.length) { caixa.append(h('div', { class: 'vazio' }, 'Sem dados neste período.')); return () => {}; }
  return responsivo(alvo, (W) => {
    limpar(caixa);
    const H = altura;
    const maxV = Math.max(limite || 0, ...series.flatMap((se) => Object.values(se.valores)), 1);
    const ey = escala(0, maxV * 1.08);
    const larguraUtil = W - M.esq - M.dir;
    const passo = larguraUtil / dias.length;
    const gb = Math.max(1, passo * 0.18);
    const lb = Math.max(1, (passo - gb) / series.length);
    const y = (v) => M.topo + (1 - v / ey.max) * (H - M.topo - M.base);
    const svg = s('svg', { viewBox: `0 0 ${W} ${H}`, width: W, height: H });
    const grade = s('g', { class: 'grade' }); const eixo = s('g', { class: 'eixo' });
    for (const v of ey.ticks) {
      grade.append(s('line', { x1: M.esq, x2: W - M.dir, y1: y(v), y2: y(v) }));
      eixo.append(s('text', { x: M.esq - 8, y: y(v) + 4, 'text-anchor': 'end' }, fmt.num(v, 0)));
    }
    const cadaN = Math.ceil(dias.length / Math.max(2, Math.floor(larguraUtil / 60)));
    dias.forEach((d, i) => {
      if (i % cadaN === 0) {
        eixo.append(s('text', { x: M.esq + i * passo + passo / 2, y: H - 8, 'text-anchor': 'middle' }, `${d.slice(8, 10)}/${d.slice(5, 7)}`));
      }
    });
    svg.append(grade, eixo);
    const dica = h('div', { class: 'dica', hidden: true });
    dias.forEach((d, i) => {
      series.forEach((se, j) => {
        const v = se.valores[d] || 0;
        if (v <= 0) return;
        const acima = limite !== null && v > limite;
        const ret = s('rect', {
          x: M.esq + i * passo + gb / 2 + j * lb, y: y(v), width: Math.max(1, lb - 1), height: y(0) - y(v),
          fill: se.cor, rx: Math.min(2, lb / 3), opacity: acima ? 1 : 0.82,
        });
        ret.addEventListener('pointerenter', (ev) => {
          limpar(dica).append(h('div', { class: 't' }, `${d.slice(8, 10)}/${d.slice(5, 7)}/${d.slice(0, 4)}`),
            h('div', { class: 'l' }, h('span', { class: 'pt', style: { background: se.cor } }), `${se.nome}: `,
              h('strong', {}, `${fmt.num(v, 1)} ${unidade}`)));
          const r = svg.getBoundingClientRect();
          dica.style.left = `${Math.min(Math.max(ev.clientX - r.left, 90), r.width - 90)}px`;
          dica.style.top = `${y(v)}px`;
          dica.hidden = false;
        });
        ret.addEventListener('pointerleave', () => { dica.hidden = true; });
        svg.append(ret);
      });
    });
    if (limite !== null) {
      const cor = getComputedStyle(document.documentElement).getPropertyValue('--critico').trim();
      svg.append(s('g', { class: 'limite' },
        s('line', { x1: M.esq, x2: W - M.dir, y1: y(limite), y2: y(limite), stroke: cor }),
        s('text', { x: W - M.dir, y: y(limite) - 5, 'text-anchor': 'end', fill: cor }, `limite crítico ${fmt.num(limite, 0)} ${unidade}`)));
    }
    caixa.append(svg, dica);
  });
}

export function minicurva(valores, cor, { largura = 220, altura = 52, rotulo } = {}) {
  const v = valores.filter((x) => x !== null && x !== undefined);
  const svg = s('svg', { viewBox: `0 0 ${largura} ${altura}`, preserveAspectRatio: 'none', role: 'img', 'aria-label': rotulo || 'tendência' });
  if (v.length < 2) return svg;
  const min = Math.min(...v); const max = Math.max(...v); const amp = max - min || 1;
  const x = (i) => (i / (valores.length - 1)) * largura;
  const y = (val) => 4 + (1 - (val - min) / amp) * (altura - 8);
  let d = '';
  valores.forEach((val, i) => { if (val !== null && val !== undefined) d += `${d ? 'L' : 'M'}${x(i).toFixed(1)},${y(val).toFixed(1)}`; });
  const area = `${d}L${largura},${altura}L0,${altura}Z`;
  svg.append(
    s('path', { d: area, fill: cor, opacity: 0.1 }),
    s('path', { d, fill: 'none', stroke: cor, 'stroke-width': 2, 'vector-effect': 'non-scaling-stroke' }));
  return svg;
}

/**
 * Pluviômetro: tubo graduado que enche com a chuva do dia.
 * A escala vai até 1,6x o limite crítico; acima disso o tubo "transborda".
 */
export function pluviometro(valor, limite = 50, rotulo = 'Chuva acumulada hoje') {
  const W = 88; const H = 230;
  const topo = 14; const base = H - 12;
  const x0 = 34; const lt = 30;
  const max = Math.max(limite * 1.6, 10);
  const y = (v) => base - (Math.min(v, max) / max) * (base - topo);
  const raiz = getComputedStyle(document.documentElement);
  const cor = (n) => raiz.getPropertyValue(n).trim();
  const nivelCor = valor > limite ? cor('--critico') : valor > limite * 0.6 ? cor('--alerta') : cor('--agua');

  const svg = s('svg', { class: 'pluviometro', viewBox: `0 0 ${W} ${H}`, role: 'img',
    'aria-label': `${rotulo}: ${fmt.num(valor, 1)} mm de ${limite} mm do limite crítico` });
  svg.append(s('rect', { x: x0, y: topo, width: lt, height: base - topo, rx: 6, fill: cor('--agua-clara'), stroke: cor('--linha'), 'stroke-width': 1.5 }));
  // graduação a cada 10 mm
  for (let v = 0; v <= max; v += 10) {
    const grande = v % 20 === 0;
    svg.append(s('line', { x1: x0 - (grande ? 9 : 5), x2: x0, y1: y(v), y2: y(v), stroke: cor('--tinta-3'), 'stroke-width': 1 }));
    if (grande) svg.append(s('text', { x: x0 - 12, y: y(v) + 3.5, 'text-anchor': 'end', 'font-size': 10, fill: cor('--tinta-3'), 'font-family': 'Barlow' }, v));
  }
  // água
  const yv = y(valor);
  svg.append(s('rect', { class: 'agua', x: x0 + 3, y: yv, width: lt - 6, height: Math.max(0, base - 3 - yv), rx: 3, fill: nivelCor }));
  // linha do limite
  svg.append(
    s('line', { x1: x0 - 4, x2: x0 + lt + 8, y1: y(limite), y2: y(limite), stroke: cor('--critico'), 'stroke-width': 2, 'stroke-dasharray': '4 3' }),
    s('text', { x: x0 + lt + 10, y: y(limite) + 3.5, 'text-anchor': 'start', 'font-size': 10, 'font-weight': 600, fill: cor('--critico'), 'font-family': 'Barlow' }, `${limite}`));
  return svg;
}
