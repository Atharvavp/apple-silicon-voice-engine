#!/usr/bin/env python3
"""Writes docs/assets/architecture-{light,dark}.svg (static, no scripts). Edit the layout here.

    python3 docs/assets/make_architecture_svg.py
"""
from pathlib import Path

W, H = 1100, 560
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
PALETTES = {
    "light": dict(bg="#ffffff", band="#f6f8fa", border="#d0d7de", text="#1f2328", muted="#59636e",
                  box="#ffffff", swift="#e8590c", swift_soft="#fff4e6", rec="#6e40c9", rec_soft="#f5f0ff",
                  py="#0969da", py_soft="#ddf4ff", arrow="#59636e", opt="#8c959f"),
    "dark": dict(bg="#0d1117", band="#151b23", border="#3d444d", text="#e6edf3", muted="#9198a1",
                 box="#0d1117", swift="#ff922b", swift_soft="#2b1d12", rec="#a371f7", rec_soft="#221a33",
                 py="#4493f8", py_soft="#0f2540", arrow="#9198a1", opt="#656c76"),
}

def box(x, y, w, h, title, sub, c, accent, soft, dashed=False):
    dash = ' stroke-dasharray="5 4"' if dashed else ""
    lines = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{soft}" stroke="{accent}" stroke-width="1.5"{dash}/>',
             f'<text x="{x + w / 2}" y="{y + 26}" text-anchor="middle" font-family="{FONT}" font-size="15" font-weight="600" fill="{c["text"]}">{title}</text>']
    for i, s in enumerate(sub):
        lines.append(f'<text x="{x + w / 2}" y="{y + 46 + i * 17}" text-anchor="middle" font-family="{FONT}" font-size="12.5" fill="{c["muted"]}">{s}</text>')
    return "\n".join(lines)

def arrow(x1, y1, x2, y2, c, label=None, lx=None, ly=None, dashed=False):
    dash = ' stroke-dasharray="4 4"' if dashed else ""
    out = f'<path d="M{x1},{y1} L{x2},{y2}" stroke="{c["arrow"]}" stroke-width="1.6" fill="none" marker-end="url(#head)"{dash}/>'
    if label:
        out += f'\n<text x="{lx}" y="{ly}" text-anchor="middle" font-family="{FONT}" font-size="11.5" fill="{c["muted"]}">{label}</text>'
    return out

def band(y, h, title, accent, c, right=False):
    tx, anchor = (W - 36, "end") if right else (36, "start")
    return (f'<rect x="16" y="{y}" width="{W - 32}" height="{h}" rx="14" fill="{c["band"]}" stroke="{c["border"]}"/>\n'
            f'<rect x="16" y="{y}" width="6" height="{h}" rx="3" fill="{accent}"/>\n'
            f'<text x="{tx}" y="{y + 22}" text-anchor="{anchor}" font-family="{FONT}" font-size="12" font-weight="700" letter-spacing="1.2" fill="{accent}">{title}</text>')

def svg(c):
    s, r, p = (c["swift"], c["swift_soft"]), (c["rec"], c["rec_soft"]), (c["py"], c["py_soft"])
    bw, bh, gap, x0, y1 = 148, 84, 28, 40, 44
    xs = [x0 + i * (bw + gap) for i in range(6)]
    top = [("WAV file", ["16/24/32-bit or float", "mono or stereo"]),
           ("Prepare", ["validate · decode", "downmix · resample"]),
           ("Spool", ["mono Float32", "SHA-256 hashed"]),
           ("Replay", ["realtime · accelerated", "or step (virtual clock)"]),
           ("Bounded queue", ["FIFO, capacity N", "block or drop_newest"]),
           ("Worker", ["ASR.consume, then", "diarization.consume"])]
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" '
             f'aria-labelledby="t d"><title id="t">voicebench architecture</title><desc id="d">A WAV file is prepared into a '
             f'hashed mono spool, replayed into a bounded queue and consumed by one worker that calls the ASR adapter, then the '
             f'diarization adapter. Events and telemetry are recorded to a run directory, which Python scores and validates before '
             f'the run is sealed.</desc>',
             f'<defs><marker id="head" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
             f'<path d="M0,0 L10,5 L0,10 z" fill="{c["arrow"]}"/></marker></defs>',
             f'<rect width="{W}" height="{H}" fill="{c["bg"]}"/>',
             band(16, 236, "SWIFT RUNTIME · ONE PROCESS, ONE STREAM", s[0], c)]
    for i, (title, sub) in enumerate(top):
        parts.append(box(xs[i], y1, bw, bh, title, sub, c, s[0], s[1] if i not in (0,) else c["box"]))
        if i:
            parts.append(arrow(xs[i - 1] + bw + 2, y1 + bh / 2, xs[i] - 3, y1 + bh / 2, c))
    # accounting note under the replay → queue → worker span
    parts.append(f'<text x="{(xs[3] + xs[4] + bw) / 2}" y="{y1 + bh + 22}" text-anchor="middle" font-family="{MONO}" '
                 f'font-size="12" fill="{c["muted"]}">produced = admitted + dropped · consumed = admitted</text>')
    # adapters under the worker
    ay = y1 + bh + 40
    parts.append(box(xs[4] - 10, ay, bw * 2 + gap + 10, 70, "Adapters",
                     ["mock ASR + diarization (default build)", "FluidAudio / speech-swift wrappers (optional)"], c, s[0], c["box"], dashed=False))
    parts.append(arrow(xs[5] + bw / 2, y1 + bh + 2, xs[5] + bw / 2, ay - 3, c))
    # recording band
    parts.append(band(268, 120, "RECORDING", r[0], c))
    ry = 300
    parts.append(box(xs[4] - 10, ry, bw * 2 + gap + 10, 70, "Event recorder",
                     ["validates · sequences · timestamps", "bounded write queue → events.jsonl"], c, r[0], r[1]))
    parts.append(arrow(xs[5] + bw / 2, ay + 72, xs[5] + bw / 2, ry - 3, c))
    parts.append(f'<text x="{xs[5] + bw / 2 - 10}" y="{ay + 92}" text-anchor="end" font-family="{FONT}" font-size="11.5" fill="{c["muted"]}">events via sink</text>')
    parts.append(box(xs[2] - 6, ry, bw * 2 + gap + 12, 70, "Run directory",
                     ["config · events · predictions", "runtime summary · telemetry"], c, r[0], r[1]))
    parts.append(arrow(xs[4] - 12, ry + 35, xs[2] + bw * 2 + gap + 9, ry + 35, c))
    parts.append(box(x0, ry, bw + 22, 70, "Telemetry", ["runner process", "CPU · RSS, ~1 Hz"], c, r[0], c["box"]))
    parts.append(arrow(x0 + bw + 24, ry + 35, xs[2] - 9, ry + 35, c))
    # python band
    parts.append(band(404, 140, "PYTHON ANALYSIS · AFTER FLUSH AND SHUTDOWN", p[0], c, right=True))
    py_y, pw = 436, 220
    pxs = [40 + i * (pw + 48) for i in range(4)]
    py = [("Score", ["WER · CER · DER · JER", "named policies"]),
          ("Validate", ["schemas · digests", "coverage · telemetry"]),
          ("Seal", ["status: completed", "SHA-256 of every artifact"]),
          ("Tools", ["validate · compare", "export (CSV / PNG)"])]
    for i, (title, sub) in enumerate(py):
        parts.append(box(pxs[i], py_y, pw, 76, title, sub, c, p[0], p[1] if i < 3 else c["box"]))
        if i:
            parts.append(arrow(pxs[i - 1] + pw + 2, py_y + 38, pxs[i] - 3, py_y + 38, c))
    # run directory feeds scoring
    rd_x = xs[2] - 6 + (bw * 2 + gap + 12) / 2
    parts.append(f'<path d="M{rd_x},{ry + 72} L{rd_x},{ry + 104} L{pxs[0] + pw / 2},{ry + 104} L{pxs[0] + pw / 2},{py_y - 3}" '
                 f'stroke="{c["arrow"]}" stroke-width="1.6" fill="none" marker-end="url(#head)"/>')
    parts.append("</svg>")
    return "\n".join(parts) + "\n"

if __name__ == "__main__":
    here = Path(__file__).resolve().parent
    for name, colors in PALETTES.items():
        (here / f"architecture-{name}.svg").write_text(svg(colors), encoding="utf-8")
        print(f"wrote architecture-{name}.svg")
