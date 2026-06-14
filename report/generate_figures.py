"""Generate report figures from benchmark CSV files.

This script is intentionally local/offline: it reads `report/results/*.csv` and
writes PNG figures to `report/figures`. It does not contact AWS.
"""

from __future__ import annotations

from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd

REPORT_ROOT = Path(__file__).resolve().parent
REPO_ROOT = REPORT_ROOT.parent
# CSV exportados por collect-run-results.ps1 y monitor-scaling.ps1.
RESULTS = REPORT_ROOT / "results"
# Salida final que se inserta en el informe.
FIGURES = REPORT_ROOT / "figures"
FIGURES.mkdir(parents=True, exist_ok=True)

plt.rcParams.update(
    {
        "figure.figsize": (10, 6),
        "figure.dpi": 140,
        "axes.grid": True,
        "grid.alpha": 0.25,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "font.size": 10,
        "axes.titlesize": 13,
        "axes.labelsize": 10,
        "legend.frameon": False,
    }
)

COLORS = {
    "blue": "#1f77b4",
    "orange": "#ff7f0e",
    "green": "#2ca02c",
    "red": "#d62728",
    "purple": "#9467bd",
    "gray": "#6b7280",
}


def read_csv(name: str) -> pd.DataFrame:
    """Lee un CSV concreto desde report/results."""
    return pd.read_csv(RESULTS / name)


def numeric(df: pd.DataFrame, columns: list[str]) -> pd.DataFrame:
    """Convierte columnas numericas aunque el CSV venga con coma decimal."""
    for col in columns:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col].astype(str).str.replace(",", "."), errors="coerce")
    return df


def save(fig: plt.Figure, name: str) -> None:
    """Guarda la figura y cierra el objeto matplotlib para no acumular memoria."""
    path = FIGURES / name
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)
    print(path.relative_to(REPO_ROOT))


def plot_throughput_vs_workers() -> None:
    """Figura principal de capacidad: throughput observado al aumentar workers."""
    df = numeric(
        read_csv("throughput-vs-workers.csv"),
        ["workers", "throughput_experiment", "throughput_server"],
    )
    fig, ax = plt.subplots()
    ax.plot(df["workers"], df["throughput_experiment"], marker="o", linewidth=2.5, label="Throughput end-to-end")
    ax.plot(df["workers"], df["throughput_server"], marker="s", linewidth=2, linestyle="--", label="Throughput server window")
    ax.set_title("Throughput vs number of Fargate workers")
    ax.set_xlabel("Workers")
    ax.set_ylabel("Completed requests / second")
    ax.set_xticks(df["workers"])
    for _, row in df.iterrows():
        ax.annotate(f"{row['throughput_experiment']:.1f}", (row["workers"], row["throughput_experiment"]), textcoords="offset points", xytext=(0, 8), ha="center")
    ax.legend()
    save(fig, "01_throughput_vs_workers.png")


def plot_speedup_efficiency() -> None:
    """Calcula speedup relativo al caso de 1 worker y eficiencia N-real/N-ideal."""
    df = numeric(read_csv("throughput-vs-workers.csv"), ["workers", "throughput_server"])
    base = float(df.loc[df["workers"] == 1, "throughput_server"].iloc[0])
    df["speedup"] = df["throughput_server"] / base
    df["ideal"] = df["workers"]
    df["efficiency"] = df["speedup"] / df["workers"]

    fig, ax1 = plt.subplots()
    ax1.plot(df["workers"], df["speedup"], marker="o", linewidth=2.5, color=COLORS["blue"], label="Measured speedup")
    ax1.plot(df["workers"], df["ideal"], linestyle=":", linewidth=2, color=COLORS["gray"], label="Ideal linear speedup")
    ax1.set_xlabel("Workers")
    ax1.set_ylabel("Speedup vs 1 worker")
    ax1.set_xticks(df["workers"])

    ax2 = ax1.twinx()
    ax2.bar(df["workers"], df["efficiency"], alpha=0.18, color=COLORS["orange"], label="Efficiency")
    ax2.set_ylabel("Efficiency")
    ax2.set_ylim(0, 1.15)

    lines, labels = ax1.get_legend_handles_labels()
    bars, bar_labels = ax2.get_legend_handles_labels()
    ax1.legend(lines + bars, labels + bar_labels, loc="upper left")
    ax1.set_title("Speedup and scaling efficiency")
    save(fig, "02_speedup_efficiency.png")


def plot_capacity_latency_percentiles() -> None:
    """Separa latencia end-to-end de tiempo interno del worker.

    Esta grafica demuestra que el worker tarda ~100 ms en procesar, pero la
    latencia percibida crece cuando las requests esperan en RabbitMQ.
    """
    df = numeric(
        read_csv("throughput-vs-workers.csv"),
        ["workers", "end_to_end_p50_seconds", "end_to_end_p95_seconds", "processing_p50_seconds", "processing_p95_seconds"],
    )
    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    axes[0].plot(df["workers"], df["end_to_end_p50_seconds"], marker="o", label="p50")
    axes[0].plot(df["workers"], df["end_to_end_p95_seconds"], marker="s", label="p95")
    axes[0].set_title("End-to-end latency under saturation")
    axes[0].set_xlabel("Workers")
    axes[0].set_ylabel("Seconds")
    axes[0].set_xticks(df["workers"])
    axes[0].legend()

    axes[1].plot(df["workers"], df["processing_p50_seconds"], marker="o", label="p50")
    axes[1].plot(df["workers"], df["processing_p95_seconds"], marker="s", label="p95")
    axes[1].axhline(0.1, color=COLORS["gray"], linestyle=":", label="100 ms artificial delay")
    axes[1].set_title("Worker processing latency")
    axes[1].set_xlabel("Workers")
    axes[1].set_ylabel("Seconds")
    axes[1].set_xticks(df["workers"])
    axes[1].legend()
    save(fig, "03_capacity_latency_percentiles.png")


def plot_scaling_backlog_workers() -> None:
    """Compara backlog y workers del perfil Z(t) con baseline vs autoscaling."""
    baseline = numeric(
        read_csv("scaling-timeseries-baseline-z-w1-final-f029fc7a.csv"),
        ["elapsed_seconds", "rabbit_ready", "worker_running", "worker_desired", "rabbit_publish_rate"],
    )
    autoscale = numeric(
        read_csv("scaling-timeseries-autoscale-z-min1-final-f9026410.csv"),
        ["elapsed_seconds", "rabbit_ready", "worker_running", "worker_desired", "rabbit_publish_rate"],
    )

    fig, axes = plt.subplots(3, 1, figsize=(11, 10), sharex=True)
    axes[0].plot(baseline["elapsed_seconds"], baseline["rabbit_ready"], label="Baseline: 1 worker", color=COLORS["red"], linewidth=2)
    axes[0].plot(autoscale["elapsed_seconds"], autoscale["rabbit_ready"], label="Autoscale: 1-8 workers", color=COLORS["blue"], linewidth=2)
    axes[0].set_title("RabbitMQ backlog during elastic workload Z(t)")
    axes[0].set_ylabel("Ready messages")
    axes[0].legend()

    axes[1].step(baseline["elapsed_seconds"], baseline["worker_running"], where="post", label="Baseline running", color=COLORS["red"], linewidth=2)
    axes[1].step(autoscale["elapsed_seconds"], autoscale["worker_running"], where="post", label="Autoscale running", color=COLORS["blue"], linewidth=2)
    axes[1].step(autoscale["elapsed_seconds"], autoscale["worker_desired"], where="post", label="Autoscale desired", color=COLORS["orange"], linestyle="--", linewidth=2)
    axes[1].set_title("Workers over time")
    axes[1].set_ylabel("Workers")
    axes[1].legend()

    axes[2].plot(baseline["elapsed_seconds"], baseline["rabbit_publish_rate"], label="Baseline measured publish rate", color=COLORS["gray"], linewidth=2)
    axes[2].plot(autoscale["elapsed_seconds"], autoscale["rabbit_publish_rate"], label="Autoscale measured publish rate", color=COLORS["green"], linewidth=2)
    axes[2].set_title("Measured arrival rate from RabbitMQ")
    axes[2].set_xlabel("Elapsed seconds")
    axes[2].set_ylabel("Messages / second")
    axes[2].legend()
    save(fig, "04_scaling_backlog_workers.png")


def plot_scaling_summary() -> None:
    """Resume el efecto del autoscaling en throughput y percentiles de latencia."""
    df = numeric(
        read_csv("scaling-comparison-final.csv"),
        [
            "completed_per_second_experiment_window",
            "end_to_end_p50_seconds",
            "end_to_end_p95_seconds",
            "end_to_end_p99_seconds",
        ],
    )
    labels = ["1 worker fixed", "Autoscale 1-8"]
    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    axes[0].bar(labels, df["completed_per_second_experiment_window"], color=[COLORS["red"], COLORS["blue"]])
    axes[0].set_title("Z(t) throughput comparison")
    axes[0].set_ylabel("Completed requests / second")
    for i, v in enumerate(df["completed_per_second_experiment_window"]):
        axes[0].text(i, v + 0.3, f"{v:.2f}", ha="center")

    x = range(len(labels))
    width = 0.24
    axes[1].bar([i - width for i in x], df["end_to_end_p50_seconds"], width, label="p50", color=COLORS["green"])
    axes[1].bar(x, df["end_to_end_p95_seconds"], width, label="p95", color=COLORS["orange"])
    axes[1].bar([i + width for i in x], df["end_to_end_p99_seconds"], width, label="p99", color=COLORS["purple"])
    axes[1].set_title("Z(t) end-to-end latency comparison")
    axes[1].set_ylabel("Seconds")
    axes[1].set_xticks(list(x), labels)
    axes[1].legend()
    save(fig, "05_scaling_throughput_latency_comparison.png")


def plot_latency_cdf() -> None:
    """CDF de latencia: muestra toda la distribucion, no solo p95/p99."""
    baseline = numeric(read_csv("latencies-baseline-z-w1-final-uniform-n-f029fc7a.csv"), ["end_to_end_seconds"])
    autoscale = numeric(read_csv("latencies-autoscale-z-min1-final-uniform-n-f9026410.csv"), ["end_to_end_seconds"])
    fig, ax = plt.subplots()
    for df, label, color in [(baseline, "1 worker fixed", COLORS["red"]), (autoscale, "Autoscale 1-8", COLORS["blue"] )]:
        values = df["end_to_end_seconds"].dropna().sort_values().reset_index(drop=True)
        y = (values.index + 1) / len(values)
        ax.plot(values, y, linewidth=2.5, label=label, color=color)
    ax.set_title("End-to-end latency CDF for Z(t)")
    ax.set_xlabel("End-to-end latency (seconds)")
    ax.set_ylabel("Cumulative fraction of requests")
    ax.legend()
    save(fig, "06_latency_cdf_baseline_vs_autoscale.png")


def plot_uniform_hotspot() -> None:
    """Valida el escenario de alta contencion pedido por el enunciado."""
    uniform = numeric(read_csv("summary-capacity-w4-uniform-n-eba2f751.csv"), ["sold", "seat_unavailable", "end_to_end_p95_seconds", "processing_p95_seconds"])
    hotspot = numeric(read_csv("summary-hotspot-w4-hotspot-n-fb7f61c9.csv"), ["sold", "seat_unavailable", "end_to_end_p95_seconds", "processing_p95_seconds"])
    df = pd.concat([uniform.assign(test="Uniform"), hotspot.assign(test="Hotspot")], ignore_index=True)

    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    axes[0].bar(df["test"], df["sold"], label="sold", color=COLORS["green"])
    axes[0].bar(df["test"], df["seat_unavailable"], bottom=df["sold"], label="seat_unavailable", color=COLORS["orange"])
    axes[0].set_title("Uniform vs hotspot outcomes")
    axes[0].set_ylabel("Requests")
    axes[0].legend()

    axes[1].bar(df["test"], df["end_to_end_p95_seconds"], color=[COLORS["blue"], COLORS["purple"]])
    axes[1].set_title("Uniform vs hotspot p95 end-to-end latency")
    axes[1].set_ylabel("Seconds")
    for i, v in enumerate(df["end_to_end_p95_seconds"]):
        axes[1].text(i, v + 0.5, f"{v:.1f}s", ha="center")
    save(fig, "07_uniform_vs_hotspot.png")


def plot_steady_vs_saturated() -> None:
    """Muestra degradacion: misma cantidad de workers con carga estable vs saturada."""
    steady = numeric(read_csv("summary-steady-w4-r24-uniform-n-1ab3084b.csv"), ["completed_per_second_experiment_window", "end_to_end_p50_seconds", "end_to_end_p95_seconds"])
    saturated = numeric(read_csv("summary-capacity-w4-uniform-n-eba2f751.csv"), ["completed_per_second_experiment_window", "end_to_end_p50_seconds", "end_to_end_p95_seconds"])
    df = pd.concat([steady.assign(test="4 workers @ 24 req/s"), saturated.assign(test="4 workers @ 120 req/s")], ignore_index=True)

    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    axes[0].bar(df["test"], df["completed_per_second_experiment_window"], color=[COLORS["green"], COLORS["blue"]])
    axes[0].set_title("Stable load vs saturated load throughput")
    axes[0].set_ylabel("Completed requests / second")
    axes[0].tick_params(axis="x", rotation=10)

    x = range(len(df))
    axes[1].bar([i - 0.15 for i in x], df["end_to_end_p50_seconds"], width=0.3, label="p50", color=COLORS["orange"])
    axes[1].bar([i + 0.15 for i in x], df["end_to_end_p95_seconds"], width=0.3, label="p95", color=COLORS["red"])
    axes[1].set_xticks(list(x), df["test"], rotation=10)
    axes[1].set_title("Stable load vs saturated load latency")
    axes[1].set_ylabel("Seconds")
    axes[1].legend()
    save(fig, "08_steady_vs_saturated_w4.png")


def main() -> None:
    plot_throughput_vs_workers()
    plot_speedup_efficiency()
    plot_capacity_latency_percentiles()
    plot_scaling_backlog_workers()
    plot_scaling_summary()
    plot_latency_cdf()
    plot_uniform_hotspot()
    plot_steady_vs_saturated()


if __name__ == "__main__":
    main()
