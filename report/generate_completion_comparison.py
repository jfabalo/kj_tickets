"""Generate completion-time comparison figures for equal Z-profile experiments.

Compares the same workload shape across:
- fixed 1 worker
- autoscale max8
- autoscale max32

It reads local CSV artifacts only and writes figures under report/figures/max32.
"""

from __future__ import annotations

from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd

REPORT_ROOT = Path(__file__).resolve().parent
REPO_ROOT = REPORT_ROOT.parent
# Datos de summary/latencies exportados desde PostgreSQL.
RESULTS = REPORT_ROOT / "results"
# Se guarda dentro de max32 porque la comparacion incluye max32.
FIGURES = REPORT_ROOT / "figures" / "max32"
FIGURES.mkdir(parents=True, exist_ok=True)

RUNS = [
    # Misma forma Z(t), distintas politicas de workers.
    {
        "label": "max1 / 1 worker fijo",
        "short": "max1",
        "color": "#dc2626",
        # CSV de la prueba baseline: mismo workload Z(t), sin autoscaling real.
        "summary": "summary-baseline-z-w1-final-uniform-n-f029fc7a.csv",
        "latencies": "latencies-baseline-z-w1-final-uniform-n-f029fc7a.csv",
    },
    {
        "label": "max8 / autoscale",
        "short": "max8",
        "color": "#2563eb",
        # CSV de la prueba principal con autoscaler limitado a 8 workers.
        "summary": "summary-autoscale-z-min1-final-uniform-n-f9026410.csv",
        "latencies": "latencies-autoscale-z-min1-final-uniform-n-f9026410.csv",
    },
    {
        "label": "max32 / autoscale",
        "short": "max32",
        "color": "#16a34a",
        # CSV de la misma carga Z(t) permitiendo hasta 32 workers.
        "summary": "summary-autoscale-z-max32-original-uniform-n-a327c742.csv",
        "latencies": "latencies-autoscale-z-max32-original-uniform-n-a327c742.csv",
    },
]

plt.rcParams.update(
    {
        "figure.figsize": (10, 6),
        "figure.dpi": 150,
        "axes.grid": True,
        "grid.alpha": 0.25,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "font.size": 10,
        "legend.frameon": False,
    }
)


def read_csv(name: str) -> pd.DataFrame:
    """Lee CSV desde report/results."""
    return pd.read_csv(RESULTS / name)


def to_numeric(df: pd.DataFrame, columns: list[str]) -> pd.DataFrame:
    """Convierte columnas numericas a floats/ints reales."""
    df = df.copy()
    for col in columns:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col].astype(str).str.replace(",", "."), errors="coerce")
    return df


def save(fig: plt.Figure, filename: str) -> None:
    path = FIGURES / filename
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)
    print(path.relative_to(REPO_ROOT))


def summary_table() -> pd.DataFrame:
    """Crea una tabla comparable con finish time, throughput y percentiles."""
    rows = []
    for run in RUNS:
        # Cada summary tiene una sola fila agregada por run_id.
        row = to_numeric(
            read_csv(run["summary"]),
            [
                "requests",
                "completed",
                "errored",
                "experiment_window_seconds",
                "completed_per_second_experiment_window",
                "end_to_end_p50_seconds",
                "end_to_end_p95_seconds",
                "end_to_end_p99_seconds",
            ],
        ).iloc[0]
        rows.append(
            {
                "config": run["short"],
                "label": run["label"],
                "requests": row["requests"],
                "completed": row["completed"],
                "errored": row["errored"],
                "experiment_window_seconds": row["experiment_window_seconds"],
                "throughput_end_to_end": row["completed_per_second_experiment_window"],
                "end_to_end_p50_seconds": row["end_to_end_p50_seconds"],
                "end_to_end_p95_seconds": row["end_to_end_p95_seconds"],
                "end_to_end_p99_seconds": row["end_to_end_p99_seconds"],
            }
        )
    df = pd.DataFrame(rows)
    # Este CSV intermedio facilita citar la tabla comparativa en el informe.
    df.to_csv(RESULTS / "completion-time-equal-z-max1-max8-max32.csv", index=False)
    return df


def plot_completion_time_bars(df: pd.DataFrame) -> None:
    """Grafica mas directa: cuanto tarda cada configuracion en terminar el mismo Z."""
    fig, ax = plt.subplots(figsize=(9, 6))
    colors = [run["color"] for run in RUNS]
    bars = ax.bar(df["config"], df["experiment_window_seconds"], color=colors)
    ax.set_title("Same Z experiment: total completion time")
    ax.set_xlabel("Worker configuration")
    ax.set_ylabel("Experiment window (seconds)")
    for bar, value in zip(bars, df["experiment_window_seconds"]):
        ax.text(bar.get_x() + bar.get_width() / 2, value + 1.5, f"{value:.1f}s", ha="center", va="bottom")
    best = df["experiment_window_seconds"].min()
    for i, value in enumerate(df["experiment_window_seconds"]):
        speed = value / best
        ax.text(i, value * 0.5, f"{speed:.1f}x vs best", ha="center", va="center", color="white", fontweight="bold")
    save(fig, "11_equal_z_completion_time_bars.png")


def plot_cumulative_completions() -> None:
    """Curva acumulada de completadas usando timestamps de PostgreSQL."""
    fig, ax = plt.subplots(figsize=(11, 6))
    for run in RUNS:
        df = read_csv(run["latencies"])
        df["enqueued_at"] = pd.to_datetime(df["enqueued_at"], utc=True)
        df["completed_at"] = pd.to_datetime(df["completed_at"], utc=True)
        start = df["enqueued_at"].min()
        # El eje X usa el reloj de PostgreSQL: completed_at - primer enqueued_at.
        elapsed = (df["completed_at"] - start).dt.total_seconds().sort_values().reset_index(drop=True)
        # Serie 1..N para dibujar acumuladas con step().
        cumulative = pd.Series(range(1, len(elapsed) + 1))
        ax.step(elapsed, cumulative, where="post", label=run["label"], color=run["color"], linewidth=2.4)
        ax.scatter([elapsed.iloc[-1]], [cumulative.iloc[-1]], color=run["color"], s=35)
        ax.text(elapsed.iloc[-1] + 1.0, cumulative.iloc[-1] - 20, f"{elapsed.iloc[-1]:.1f}s", color=run["color"])
    ax.set_title("Same Z experiment: cumulative completed requests")
    ax.set_xlabel("Seconds since first enqueue")
    ax.set_ylabel("Completed requests")
    ax.set_ylim(0, 760)
    ax.legend(loc="lower right")
    save(fig, "12_equal_z_cumulative_completions.png")


def plot_completion_and_latency() -> None:
    """Combina tiempo total y percentiles de latencia para la misma carga."""
    df = summary_table()
    fig, axes = plt.subplots(1, 2, figsize=(13, 5))
    colors = [run["color"] for run in RUNS]

    axes[0].bar(df["config"], df["experiment_window_seconds"], color=colors)
    axes[0].set_title("Total finish time")
    axes[0].set_ylabel("Seconds")
    for i, value in enumerate(df["experiment_window_seconds"]):
        axes[0].text(i, value + 1.5, f"{value:.1f}s", ha="center")

    width = 0.25
    x = list(range(len(df)))
    # Barras desplazadas para comparar p50/p95/p99 lado a lado.
    axes[1].bar([i - width for i in x], df["end_to_end_p50_seconds"], width, label="p50", color="#16a34a")
    axes[1].bar(x, df["end_to_end_p95_seconds"], width, label="p95", color="#f97316")
    axes[1].bar([i + width for i in x], df["end_to_end_p99_seconds"], width, label="p99", color="#7c3aed")
    axes[1].set_xticks(x, df["config"])
    axes[1].set_title("End-to-end latency percentiles")
    axes[1].set_ylabel("Seconds")
    axes[1].legend()

    save(fig, "13_equal_z_finish_time_and_latency.png")


def main() -> None:
    df = summary_table()
    plot_completion_time_bars(df)
    plot_cumulative_completions()
    plot_completion_and_latency()
    print((RESULTS / "completion-time-equal-z-max1-max8-max32.csv").relative_to(REPO_ROOT))
    print(df.to_string(index=False))


if __name__ == "__main__":
    main()
