#!/usr/bin/env python3
"""One accumulated-damage figure from results/baseline-results.csv (Cycle 2B).

Reads the CSV written by analysis/baselines.py; plots nothing that is not in it.
Four series (A, B, C, D, main variant). C and D coincide by design on the main
variant and are drawn so the overlap is visible rather than hidden.

Also renders results/power-surface.md, a Markdown table (not a graph) from
results/power-surface.csv, with Catalan headers.

Dependencies: standard library + matplotlib (already installed; no pip).
"""

from __future__ import annotations

import csv
import sys
import textwrap
from collections import OrderedDict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "results"
SOURCE_CSV = RESULTS / "baseline-results.csv"
POWER_CSV = RESULTS / "power-surface.csv"
FIGURE_PNG = RESULTS / "accumulated-damage.png"
POWER_MD = RESULTS / "power-surface.md"

T_EMERGENCY = 3

# Validated categorical palette (light surface), fixed hue per entity.
# Validator (dataviz skill): all hard checks PASS; aqua and yellow are below
# 3:1 contrast on the light surface, relieved here by direct end labels + legend.
SERIES = OrderedDict([
    ("D", {"label": "D · Guardià DART (només revoca)", "color": "#2a78d6"}),
    ("A", {"label": "A · Revocació només per l'usuari", "color": "#eb6834"}),
    ("B", {"label": "B · Credencial de curta durada", "color": "#1baf7a"}),
    ("C", {"label": "C · Administrador central", "color": "#eda100"}),
])
INK = "#0b0b0b"
INK_2 = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
BASELINE = "#c3c2b7"
SURFACE = "#fcfcfb"

CAPTION_CA = (
    "Figura: dany acumulat per model a la variant principal de l'experiment comparatiu. "
    "El dany és la suma dels imports acceptats des de t ≥ 3, el pas en què l'agent queda "
    "compromès i l'usuari deixa d'estar disponible. L'eix horitzontal són passos d'escenari, "
    "no latència de xarxa; les unitats són simulades, no moneda. C i D coincideixen a la "
    "variant principal perquè reben la mateixa resposta simulada (revocació abans de t = 4); "
    "la diferència entre C i D és de poders, no de velocitat (vegeu la taula de la superfície "
    "de poder). Les variants late6 i late8 existeixen al CSV i no es representen: amb "
    "revocació abans de t = 6 el dany de C i D iguala el de B (30), i amb t = 8 el supera (50). "
    "Dades: results/baseline-results.csv. El resultat descriu només els escenaris definits."
)


def load_main_series() -> "OrderedDict[str, list]":
    with SOURCE_CSV.open(newline="", encoding="utf-8") as fh:
        rows = [r for r in csv.DictReader(fh) if r["variant"] == "main"]
    series: "OrderedDict[str, list]" = OrderedDict((m, []) for m in SERIES)
    for r in rows:
        if r["model"] in series:
            series[r["model"]].append((int(r["step"]), int(r["damage_after"])))
    for model, pts in series.items():
        pts.sort()
        steps = [s for s, _ in pts]
        assert steps == list(range(10)), f"{model}: expected steps 0..9, got {steps}"
        assert all(d == 0 for s, d in pts if s < T_EMERGENCY), f"{model}: damage before t=3"
        assert all(b >= a for (_, a), (_, b) in zip(pts, pts[1:])), f"{model}: not monotone"
    assert series["C"] == series["D"], "C and D must coincide on the main variant"
    return series


def plot(series: "OrderedDict[str, list]") -> None:
    plt.rcParams.update({
        "font.family": "sans-serif",
        "font.size": 10,
        "axes.titlesize": 12,
        "axes.labelsize": 10,
        "legend.fontsize": 9,
    })
    fig, ax = plt.subplots(figsize=(8.6, 5.9), dpi=200)
    fig.patch.set_facecolor(SURFACE)
    ax.set_facecolor(SURFACE)

    # Draw order: C first (wide dashed, underneath), then A, B, then D on top.
    order = ["C", "A", "B", "D"]
    handles = {}
    for model in order:
        pts = series[model]
        xs = [s for s, _ in pts]
        ys = [d for _, d in pts]
        spec = SERIES[model]
        if model == "C":
            (line,) = ax.plot(
                xs, ys, color=spec["color"], linewidth=4.5, linestyle=(0, (2.5, 2.0)),
                solid_capstyle="round", dash_capstyle="round", zorder=2, label=spec["label"],
            )
        else:
            (line,) = ax.plot(
                xs, ys, color=spec["color"], linewidth=2, solid_joinstyle="round",
                solid_capstyle="round", zorder=3, label=spec["label"],
            )
            ax.scatter(
                xs, ys, s=48, color=spec["color"], edgecolors=SURFACE, linewidths=1.5, zorder=4,
            )
        handles[model] = line

    # Emergency step and the two policy events, in ink (not series color).
    ax.axvline(T_EMERGENCY, color=BASELINE, linewidth=1, zorder=1)
    ax.text(T_EMERGENCY + 0.1, 53, "t_emergency = 3\nagent compromès,\nusuari no disponible",
            color=INK_2, fontsize=8.5, va="top", ha="left")
    ax.annotate("C i D: revocació\nabans de t = 4", xy=(4, 10), xytext=(4.9, 22),
                color=INK_2, fontsize=8.5, ha="left",
                arrowprops=dict(arrowstyle="-", color=MUTED, linewidth=0.8))
    ax.annotate("B: caducitat a t = 6\n(no és revocació)", xy=(6, 30), xytext=(6.4, 19),
                color=INK_2, fontsize=8.5, ha="left",
                arrowprops=dict(arrowstyle="-", color=MUTED, linewidth=0.8))

    # Direct end labels at t = 9 (relief for low-contrast hues; identity not color-alone).
    end = {m: series[m][-1][1] for m in series}
    ax.text(9.15, end["A"], f"A · {end['A']}", color=INK, fontsize=9, va="center")
    ax.text(9.15, end["B"], f"B · {end['B']}", color=INK, fontsize=9, va="center")
    ax.text(9.15, end["D"], f"C = D · {end['D']}", color=INK, fontsize=9, va="center")

    ax.set_xlim(-0.3, 10.3)
    ax.set_ylim(0, 76)
    ax.set_xticks(range(10))
    ax.set_yticks(range(0, 80, 10))
    ax.set_xlabel("Pas d'escenari t (passos, no latència de xarxa)")
    ax.set_ylabel("Dany acumulat (unitats simulades, des de t ≥ 3)")
    ax.set_title("Dany acumulat per model de revocació, variant principal", color=INK, loc="left")

    ax.yaxis.grid(True, color=GRID, linewidth=1)
    ax.xaxis.grid(False)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(BASELINE)
    ax.tick_params(colors=MUTED, labelcolor=INK_2, length=3)

    legend = ax.legend(
        [handles[m] for m in SERIES], [SERIES[m]["label"] for m in SERIES],
        loc="upper left", frameon=False, handlelength=2.6,
    )
    for txt in legend.get_texts():
        txt.set_color(INK)

    fig.text(0.03, 0.02, textwrap.fill(CAPTION_CA, 132), fontsize=7.6, color=INK_2,
             ha="left", va="bottom", linespacing=1.35)
    fig.subplots_adjust(left=0.09, right=0.9, top=0.92, bottom=0.30)
    fig.savefig(FIGURE_PNG, dpi=200, facecolor=SURFACE)
    plt.close(fig)


def write_power_surface_md() -> None:
    with POWER_CSV.open(newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    labels = {
        "A": "A · Revocació només per l'usuari",
        "B": "B · Credencial de curta durada",
        "C": "C · Administrador central",
        "D": "D · Guardià DART",
    }
    actor_ca = {"user": "usuari", "agent": "agent", "guardian": "guardià",
                "admin": "administrador", "outsider": "extern"}
    cell = {"success": "sí", "failure": "no"}
    lines = [
        "# Superfície de poder observada (cicle 2A)",
        "",
        "Taula generada des de `results/power-surface.csv` pel simulador determinista",
        "(`analysis/baselines.py`); no està escrita a mà. Cada cel·la és el resultat",
        "observat d'intentar l'operació amb aquell actor sobre un estat mínim nou",
        "(delegació activa dins d'abast, saldo sense usar). Només el model D es",
        "contrasta també amb les proves Foundry (`results/dart-sequence-map.csv`).",
        "",
        "| Model | Actor | Concedir | Revocar | Executar |",
        "|---|---|---|---|---|",
    ]
    grouped: "OrderedDict[tuple, dict]" = OrderedDict()
    for r in rows:
        grouped.setdefault((r["model"], r["actor"]), {})[r["operation"]] = r["observed"]
    for (model, actor), ops in grouped.items():
        lines.append(
            f"| {labels[model]} | {actor_ca[actor]} | {cell[ops['grant']]} | "
            f"{cell[ops['revoke']]} | {cell[ops['execute']]} |"
        )
    lines += [
        "",
        "Lectura: el guardià de D només pot revocar; l'administrador de C pot concedir,",
        "revocar i executar (arquetip explícit, no descripció de tots els sistemes",
        "centralitzats). Cap fila afirma seguretat universal.",
        "",
    ]
    POWER_MD.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    series = load_main_series()
    plot(series)
    write_power_surface_md()
    print(f"wrote {FIGURE_PNG.relative_to(ROOT)} ({FIGURE_PNG.stat().st_size} bytes)")
    print(f"wrote {POWER_MD.relative_to(ROOT)}")
    print("series (step, damage_after):")
    for m, pts in series.items():
        print(f"  {m}: {[d for _, d in pts]}")
    print()
    print("caption (CA):")
    print(textwrap.fill(CAPTION_CA, 88))
    return 0


if __name__ == "__main__":
    sys.exit(main())
