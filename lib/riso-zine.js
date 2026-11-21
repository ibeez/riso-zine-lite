// riso-zine.js — Lite zero-dependency SVG engine for multi-panel digital-Riso zine scrolls.
// MIT License — https://github.com/ibeez
(function () {
  const NS = 'http://www.w3.org/2000/svg';
  const PAPER = [251, 245, 230];
  const PAPER_STR = 'rgb(' + PAPER.join() + ')';
  const INK = '#48545c';
  const ABS = {
    coral: [0, 1.09165, 0.95707],
    peach: [0, 0.35405, 0.36744],
    sky:   [0.45222, 0.13499, 0],
    blue:  [1.14163, 0.50752, 0]
  };
  const PALETTES = {
    ink:   { r: '0.18 0.30 0.66 0.96 0.99 0.99', g: '0.24 0.38 0.70 0.95 0.97 0.97', b: '0.30 0.44 0.70 0.89 0.91 0.91' },
    coral: { r: '0.88 0.94 0.98 0.99 0.99 0.99', g: '0.16 0.32 0.62 0.86 0.95 0.96', b: '0.22 0.36 0.60 0.82 0.90 0.91' },
    aqua:  { r: '0.10 0.22 0.50 0.84 0.97 0.99', g: '0.42 0.58 0.76 0.92 0.96 0.97', b: '0.54 0.66 0.78 0.88 0.90 0.91' },
    blue:  { r: '0.08 0.18 0.44 0.80 0.96 0.99', g: '0.22 0.36 0.64 0.88 0.96 0.97', b: '0.50 0.64 0.78 0.89 0.90 0.91' }
  };

  let seq = 0;
  const el = (tag, attrs = {}, parent = null) => {
    const node = document.createElementNS(NS, tag);
    for (const k in attrs) node.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(node);
    return node;
  };
  const tint = (k, t = 1) =>
    k[0] === '#'
      ? k
      : 'rgb(' + PAPER.map((p, i) => Math.round(p * Math.exp(-t * ABS[k][i]))).join() + ')';

  function ensureDefs(svg) {
    let defs = svg.querySelector('#riso-zine-defs');
    if (defs) return { defs, uid: defs.getAttribute('data-uid') };
    const uid = String(++seq);
    defs = el('defs', { id: 'riso-zine-defs', 'data-uid': uid }, svg);

    const angles = { coral: 25, peach: 10, sky: -15, blue: -35 };
    Object.keys(ABS).forEach(k => {
      const pat = el('pattern', {
        id: `pat-${k}-${uid}`, width: 6, height: 6,
        patternUnits: 'userSpaceOnUse', patternTransform: `rotate(${angles[k]})`
      }, defs);
      el('rect', { width: 6, height: 6, fill: tint(k, 0.22) }, pat);
      el('circle', { cx: 3, cy: 3, r: 1.15, fill: tint(k, 0.58) }, pat);
    });

    const grain = el('filter', { id: `riso-grain-${uid}`, x: '0%', y: '0%', width: '100%', height: '100%' }, defs);
    el('feTurbulence', { type: 'fractalNoise', baseFrequency: '0.85', numOctaves: '2', seed: '7', result: 'n' }, grain);
    el('feColorMatrix', {
      type: 'matrix',
      values: '0 0 0 0 0.28  0 0 0 0 0.33  0 0 0 0 0.36  0 0 0 0.09 0',
      in: 'n'
    }, grain);

    Object.keys(PALETTES).forEach(name => {
      const p = PALETTES[name];
      const flt = el('filter', {
        id: `zine-${name}-${uid}`, x: '0%', y: '0%', width: '100%', height: '100%',
        'color-interpolation-filters': 'sRGB'
      }, defs);
      el('feColorMatrix', { type: 'saturate', values: '0', result: 'g' }, flt);
      const ct = el('feComponentTransfer', { in: 'g' }, flt);
      el('feFuncR', { type: 'table', tableValues: p.r }, ct);
      el('feFuncG', { type: 'table', tableValues: p.g }, ct);
      el('feFuncB', { type: 'table', tableValues: p.b }, ct);
    });

    const silMap = { paper: PAPER.map(v => v / 255) };
    Object.keys(ABS).forEach(k => {
      silMap[k] = PAPER.map((p, i) => (p * Math.exp(-0.92 * ABS[k][i])) / 255);
    });
    Object.keys(silMap).forEach(k => {
      const [r, g, b] = silMap[k];
      const sf = el('filter', {
        id: `zine-sil-${k}-${uid}`, x: '0%', y: '0%', width: '100%', height: '100%',
        'color-interpolation-filters': 'sRGB'
      }, defs);
      el('feColorMatrix', {
        type: 'matrix',
        values: `0 0 0 0 ${r.toFixed(4)}  0 0 0 0 ${g.toFixed(4)}  0 0 0 0 ${b.toFixed(4)}  0 0 0 1 0`
      }, sf);
    });

    return { defs, uid };
  }

  function create(svg, opts = {}) {
    const { defs, uid } = ensureDefs(svg);
    const grainLevel = opts.grain ?? 0.85;
    const bgLayer    = el('g', {}, svg);
    const colorLayer = el('g', { style: 'mix-blend-mode:multiply' }, svg);
    const artLayer   = el('g', {}, svg);
    let clipN = 0;

    const m = {
      uid, defs, bg: bgLayer, color: colorLayer, art: artLayer,
      PAPER: PAPER_STR, INK, tint, el,
      pat: k => `url(#pat-${k}-${uid})`,

      paper(w, h, g = grainLevel) {
        el('rect', { x: 0, y: 0, width: w, height: h, fill: PAPER_STR }, bgLayer);
        if (g > 0) {
          el('rect', {
            x: 0, y: 0, width: w, height: h, fill: INK,
            opacity: Math.min(1, g) * 0.45,
            filter: `url(#riso-grain-${uid})`,
            'pointer-events': 'none'
          }, artLayer);
        }
      },

      inkFilter(id, w = 840, h = 1120, o = {}) {
        const fid = `${id}-${uid}`;
        const f = el('filter', {
          id: fid, filterUnits: 'userSpaceOnUse', x: 0, y: 0, width: w, height: h,
          'color-interpolation-filters': 'sRGB'
        }, defs);
        el('feTurbulence', {
          type: 'fractalNoise', baseFrequency: o.edgeFreq || '0.045',
          numOctaves: 2, seed: o.seed || 17, result: 'wobble'
        }, f);
        el('feDisplacementMap', {
          in: 'SourceGraphic', in2: 'wobble', scale: o.scale ?? 1.9,
          xChannelSelector: 'R', yChannelSelector: 'G', result: 'rough'
        }, f);
        el('feTurbulence', {
          type: 'fractalNoise', baseFrequency: o.grainFreq || '0.72',
          numOctaves: 2, seed: (o.seed || 17) + 37, result: 'grain'
        }, f);
        const ct = el('feComponentTransfer', { in: 'grain', result: 'mask' }, f);
        el('feFuncA', { type: 'discrete', tableValues: o.table || '0.62 0.82 0.94 1 1 1 1 1' }, ct);
        el('feComposite', { in: 'rough', in2: 'mask', operator: 'in' }, f);
        return `url(#${fid})`;
      },

      cutout(src, x, y, w, h, o = {}) {
        const target = o.parent || artLayer;
        const preserve = o.preserve || 'xMidYMid meet';
        const tone = o.tone || 'ink';
        if (o.backK) {
          const sh = o.backShift || [12, 12];
          el('image', {
            href: src, x: x + sh[0], y: y + sh[1], width: w, height: h,
            preserveAspectRatio: preserve,
            filter: `url(#zine-sil-${o.backK}-${uid})`,
            opacity: o.backOpacity ?? 0.55,
            style: 'mix-blend-mode:multiply'
          }, target);
        }
        if (o.lift === true) {
          el('image', {
            href: src, x, y, width: w, height: h,
            preserveAspectRatio: preserve,
            filter: `url(#zine-sil-paper-${uid})`,
            opacity: o.liftOpacity ?? 0.96
          }, target);
        }
        el('image', {
          href: src, x, y, width: w, height: h,
          preserveAspectRatio: preserve,
          filter: `url(#zine-${tone}-${uid})`,
          style: o.multiply === false ? '' : 'mix-blend-mode:multiply'
        }, target);
      },

      photo(src, x, y, w, h, o = {}) {
        if (o.cutout) return m.cutout(src, x, y, w, h, o);
        const target = o.parent || artLayer;
        const cid = `zine-crop-${uid}-${++clipN}`;
        const cp = el('clipPath', { id: cid }, defs);
        el('rect', { x, y, width: w, height: h }, cp);
        if (o.backK) {
          const sh = o.backShift || [12, 12];
          el('rect', {
            x: x + sh[0], y: y + sh[1], width: w, height: h,
            fill: o.backPat ? m.pat(o.backK) : tint(o.backK, o.backT ?? 0.36),
            style: 'mix-blend-mode:multiply'
          }, target);
        }
        if (o.lift !== false) {
          el('rect', { x, y, width: w, height: h, fill: PAPER_STR, opacity: o.liftOpacity ?? 0.92 }, target);
        }
        const ig = el('g', { 'clip-path': `url(#${cid})` }, target);
        el('image', {
          href: src, x, y, width: w, height: h,
          preserveAspectRatio: o.preserve || 'xMidYMid slice',
          filter: `url(#zine-${o.tone || 'ink'}-${uid})`,
          style: 'mix-blend-mode:multiply'
        }, ig);
      },

      crosshairs(w, h, stepX = 280, stepY = 260, o = {}) {
        const target = o.parent || colorLayer;
        for (let cx = o.startX ?? 140; cx < w; cx += stepX) {
          for (let cy = o.startY ?? 180; cy < h; cy += stepY) {
            el('line', { x1: cx - 6, y1: cy, x2: cx + 6, y2: cy, stroke: INK, 'stroke-width': 1, opacity: o.opacity ?? 0.22 }, target);
            el('line', { x1: cx, y1: cy - 6, x2: cx, y2: cy + 6, stroke: INK, 'stroke-width': 1, opacity: o.opacity ?? 0.22 }, target);
          }
        }
      },

      stamp(x, y, text, k = 'coral', o = {}) {
        const target = o.parent || artLayer;
        const size = o.size || 14;
        const w = text.length * (size * 0.74) + 30;
        const h = size * 2.8;
        const rx = o.align === 'end' ? x - w : o.align === 'start' ? x : x - w / 2;
        el('rect', { x: rx, y: y - h / 2, width: w, height: h, fill: tint(k, 0.94) }, target);
        const t = el('text', {
          x: rx + w / 2, y: y + 1, fill: PAPER_STR,
          'font-family': 'Nunito, -apple-system, sans-serif',
          'font-size': size, 'font-weight': 900, 'letter-spacing': '0.10em',
          'text-anchor': 'middle', 'dominant-baseline': 'central'
        }, target);
        t.textContent = text;
        return t;
      }
    };
    return m;
  }

  async function svgToImage(svg) {
    const [, , w, h] = svg.getAttribute('viewBox').split(' ').map(Number);
    const copy = svg.cloneNode(true);
    copy.setAttribute('xmlns', NS);
    copy.setAttribute('width', w);
    copy.setAttribute('height', h);
    const dataUrl = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(new XMLSerializer().serializeToString(copy));
    const img = new Image();
    img.src = dataUrl;
    await img.decode();
    return { img, w, h };
  }

  function triggerDownload(canvas, filename) {
    canvas.toBlob(blob => {
      if (!blob) return;
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      a.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    }, 'image/png');
  }

  async function downloadPNG(svg, filename = 'panel.png', scale = 2) {
    const { img, w, h } = await svgToImage(svg);
    const c = document.createElement('canvas');
    c.width = w * scale;
    c.height = h * scale;
    const g = c.getContext('2d');
    g.fillStyle = PAPER_STR;
    g.fillRect(0, 0, c.width, c.height);
    g.drawImage(img, 0, 0, c.width, c.height);
    triggerDownload(c, filename);
  }

  async function downloadScrollPNG(svgs, filename = 'scroll-full.png', scale = 2) {
    const list = Array.from(svgs);
    const rendered = await Promise.all(list.map(svgToImage));
    const totalW = rendered.reduce((s, r) => s + r.w, 0);
    const maxH = Math.max(...rendered.map(r => r.h));
    const c = document.createElement('canvas');
    c.width = totalW * scale;
    c.height = maxH * scale;
    const g = c.getContext('2d');
    g.fillStyle = PAPER_STR;
    g.fillRect(0, 0, c.width, c.height);
    let x = 0;
    for (const r of rendered) {
      g.drawImage(r.img, x * scale, 0, r.w * scale, r.h * scale);
      x += r.w;
    }
    triggerDownload(c, filename);
  }

  window.RisoZine = {
    create, tint, el, downloadPNG, downloadScrollPNG,
    INK, PAPER: PAPER_STR, colors: Object.keys(ABS)
  };
})();
