#!/usr/bin/env python3
"""Compare two independent TCP RTT runs; paths below can be changed."""

from __future__ import annotations

import argparse
import csv
import math
from pathlib import Path
import statistics
import sys
import textwrap


ROOT = Path(__file__).resolve().parents[1]

# Пути можно менять: указывать CSV внутри нужных папок results/.
PLAIN_CSV = ROOT / "results/plain_wifi_20261109_232306_21290/rtt.csv"
FSTACK_CSV = ROOT / "results/fstack_20261109_232400_21325/rtt.csv"
OUTPUT_DIR = ROOT / "results/comparison"

LABELS = ("Обычные сокеты · Wi-Fi", "F-Stack + DPDK · Ethernet")
COLORS = ("#2878B5", "#E1812C")


def read_rtt(path: Path) -> list[float]:
    values: list[float] = []
    sequences: set[int] = set()
    with path.open(encoding="utf-8-sig", newline="") as file:
        reader = csv.DictReader(file)
        fields = set(reader.fieldnames or [])
        if not {"seq", "rtt_ns"} <= fields:
            raise ValueError(f"{path}: ожидаются столбцы seq и rtt_ns")
        for line, row in enumerate(reader, start=2):
            try:
                sequence, rtt = int(row["seq"]), int(row["rtt_ns"])
                if sequence in sequences or sequence < 0 or rtt <= 0:
                    raise ValueError("повторный/отрицательный seq или неположительный RTT")
                if {"send_timestamp_ns", "recv_timestamp_ns"} <= fields:
                    delta = int(row["recv_timestamp_ns"]) - int(row["send_timestamp_ns"])
                    if delta != rtt:
                        raise ValueError("rtt_ns не совпадает с разностью временных меток")
            except (ValueError, TypeError) as error:
                raise ValueError(f"{path}, строка {line}: {error}") from error
            sequences.add(sequence)
            values.append(rtt / 1_000_000)
    if not values:
        raise ValueError(f"{path}: нет измерений")
    return values


def summarize(values: list[float]) -> dict[str, float | int]:
    ordered = sorted(values)
    size = len(ordered)
    return {
        "n": size,
        "min": ordered[0],
        "median": statistics.median(ordered),
        "mean": math.fsum(ordered) / size,
        "p95": ordered[math.ceil(size * 0.95) - 1],
        "p99": ordered[math.ceil(size * 0.99) - 1],
        "max": ordered[-1],
    }


def display_path(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(ROOT))
    except ValueError:
        return str(path.resolve())


def make_figure(data: list[list[float]], summaries: list[dict], paths: list[Path]):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.lines import Line2D
    from matplotlib.ticker import LogLocator, PercentFormatter, ScalarFormatter

    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10})
    source_lines = []
    for label, path in zip(("Wi-Fi", "F-Stack"), paths):
        source_lines.extend(textwrap.wrap(f"{label}: {display_path(path)}", width=145))
    height = 8.5 + max(0, len(source_lines) - 2) * 0.17
    fig = plt.figure(figsize=(14, height), constrained_layout=True, facecolor="white")
    grid = fig.add_gridspec(4, 2, height_ratios=[0.9, 3.8, 1.15, 1.1])
    header = fig.add_subplot(grid[0, :])
    header.axis("off")
    header.text(0.5, 0.9, "Сравнение задержки TCP-обмена", ha="center", va="top",
                fontsize=18, fontweight="bold")
    header.text(0.5, 0.53, "Один сервер на Mac · две независимые серии · меньше RTT — быстрее ответ",
                ha="center", va="center", fontsize=11, color="#46505A")
    handles = [Line2D([0], [0], color=color, linewidth=3) for color in COLORS]
    header.legend(handles, LABELS, loc="lower center", ncol=2, frameon=False,
                  fontsize=11, borderaxespad=0, handlelength=2.5, columnspacing=2.5)

    distribution = fig.add_subplot(grid[1, 0])
    for values, color in zip(data, COLORS):
        ordered = sorted(values)
        distribution.step([ordered[0], *ordered], [0, *[(i + 1) / len(ordered) * 100
                          for i in range(len(ordered))]], where="post", color=color, linewidth=2)
    distribution.set_xscale("log")
    distribution.xaxis.set_major_locator(LogLocator(base=10, subs=(1, 2, 5)))
    distribution.xaxis.set_major_formatter(ScalarFormatter())
    distribution.set_ylim(0, 102)
    distribution.set_yticks([0, 25, 50, 75, 95, 100])
    distribution.yaxis.set_major_formatter(PercentFormatter(xmax=100, decimals=0))
    distribution.set_title("Доля ответов быстрее заданного RTT", loc="left", fontsize=12, pad=12)
    distribution.set_xlabel("RTT, мс · логарифмическая шкала", labelpad=9)
    distribution.set_ylabel("Доля измерений")
    distribution.grid(axis="both", which="major", color="#DFE4E8", linewidth=0.7)
    distribution.set_axisbelow(True)

    bars = fig.add_subplot(grid[1, 1])
    metrics = ("median", "mean", "p95", "p99")
    width = 0.35
    highest = max(float(stats[key]) for stats in summaries for key in metrics)
    for index, (stats, color) in enumerate(zip(summaries, COLORS)):
        positions = [i + (index - 0.5) * width for i in range(len(metrics))]
        rectangles = bars.bar(positions, [stats[key] for key in metrics], width=width,
                              color=color, zorder=3)
        bars.bar_label(rectangles, fmt="%.2f", padding=4, fontsize=10)
    bars.set_xticks(range(4), ["Медиана", "Среднее", "p95", "p99"])
    bars.set_ylim(0, highest * 1.2)
    bars.set_ylabel("RTT, мс")
    bars.set_title("Типичная задержка и медленные ответы", loc="left", fontsize=12, pad=12)
    bars.grid(axis="y", color="#DFE4E8", linewidth=0.7, zorder=0)
    bars.set_axisbelow(True)
    for axis in (distribution, bars):
        axis.spines[["top", "right"]].set_visible(False)

    table_axis = fig.add_subplot(grid[2, :])
    table_axis.axis("off")
    columns = ["Клиент / сеть", "N", "min, мс", "Медиана, мс", "Среднее, мс", "p95, мс", "p99, мс", "max, мс"]
    rows = []
    for label, stats in zip(("Сокеты / Wi-Fi", "F-Stack / Ethernet"), summaries):
        rows.append([label, str(stats["n"]), *[f"{stats[key]:.3f}" for key in
                    ("min", "median", "mean", "p95", "p99", "max")]])
    table = table_axis.table(cellText=rows, colLabels=columns, cellLoc="center", loc="center",
                             colWidths=[0.20, 0.07, 0.115, 0.13, 0.125, 0.115, 0.115, 0.13])
    table.auto_set_font_size(False)
    table.set_fontsize(10)
    table.scale(1, 1.75)
    for (row, column), cell in table.get_celld().items():
        cell.set_edgecolor("#E1E5E8")
        if row == 0:
            cell.set_facecolor("#EDF1F4")
            cell.set_text_props(fontweight="bold")
        else:
            cell.set_facecolor("#F9FAFB" if row == 1 else "white")
            if column == 0:
                cell.set_text_props(color=COLORS[row - 1], fontweight="bold")

    note = fig.add_subplot(grid[3, :])
    note.axis("off")
    reduction = (float(summaries[0]["median"]) - float(summaries[1]["median"])) / float(summaries[0]["median"]) * 100
    change = f"Медиана F-Stack ниже на {reduction:.1f}%." if reduction >= 0 else f"Медиана F-Stack выше на {-reduction:.1f}%."
    caption = "\n".join([
        f"{change} На левой панели более левая кривая означает меньшую задержку; показаны все измерения.",
        "Сравниваются Ethernet + F-Stack и Wi-Fi + сокеты: разница включает влияние сети и реализации клиента.",
        *source_lines,
    ])
    note.text(0, 0.92, caption, ha="left", va="top", fontsize=9.5, color="#46505A", linespacing=1.55)
    return fig


def main() -> int:
    parser = argparse.ArgumentParser(description="Сравнить RTT двух CSV и сохранить один PNG-график.")
    parser.add_argument("--plain", type=Path, default=PLAIN_CSV)
    parser.add_argument("--fstack", type=Path, default=FSTACK_CSV)
    parser.add_argument("--output", type=Path, default=OUTPUT_DIR)
    args = parser.parse_args()
    paths = [args.plain, args.fstack]
    try:
        data = [read_rtt(path) for path in paths]
        summaries = [summarize(values) for values in data]
        figure = make_figure(data, summaries, paths)
        args.output.mkdir(parents=True, exist_ok=True)
        figure.savefig(args.output / "rtt_comparison.png", dpi=200, facecolor="white")
        import matplotlib.pyplot as plt
        plt.close(figure)
    except (OSError, ValueError, ImportError) as error:
        print(f"Ошибка: {error}", file=sys.stderr)
        return 1
    print((args.output / "rtt_comparison.png").resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
