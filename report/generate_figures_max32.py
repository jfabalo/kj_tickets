"""Generate max32 autoscaling figures from local benchmark CSV files.

This script does not contact AWS. It reads the benchmark artifacts already stored
under report/results and writes an isolated figure set under report/figures/max32.
"""

from __future__ import annotations

import math
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd

REPORT_ROOT = Path(__file__).resolve().parent
REPO_ROOT = REPORT_ROOT.parent
# Datos reales ya exportados: no se consulta AWS al regenerar graficas.
RESULTS = REPORT_ROOT / "results"
# Carpeta separada para no pisar las figuras principales max8.
FIGURES = REPORT_ROOT / "figures" / "max32"
FIGURES.mkdir(parents=True, exist_ok=True)

# Constantes iguales a las usadas por el autoscaler durante las pruebas max32.
SAFE_CAPACITY_PER_WORKER = 6.5
TARGET_RESPONSE_TIME_SECONDS = 10.0
MAX_WORKERS = 32

COLORS = {
    "blue": "#2563eb",
    "orange": "#f97316",
    "green": "#16a34a",
    "red": "#dc2626",
    "purple": "#7c3aed",
    "teal": "#0891b2",
    "gray": "#64748b",
    "dark": "#111827",
}

plt.rcParams.update(
    {
        "figure.figsize": (11, 6),
        "figure.dpi": 145,
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

RUNS = {
    # Cada entrada enlaza un experimento real con sus CSV summary/latencies/timeseries.
    "baseline_original": {
        "label": "Original Z, 1 worker fijo",
        "profile": "original",
        "max_workers": 1,
        "summary": "summary-baseline-z-w1-final-uniform-n-f029fc7a.csv",
        "latencies": "latencies-baseline-z-w1-final-uniform-n-f029fc7a.csv",
        "timeseries": "scaling-timeseries-baseline-z-w1-final-f029fc7a.csv",
    },
    "autoscale_max8_original": {
        "label": "Original Z, autoscale max8",
        "profile": "original",
        "max_workers": 8,
        "summary": "summary-autoscale-z-min1-final-uniform-n-f9026410.csv",
        "latencies": "latencies-autoscale-z-min1-final-uniform-n-f9026410.csv",
        "timeseries": "scaling-timeseries-autoscale-z-min1-final-f9026410.csv",
    },
    "autoscale_max32_original": {
        "label": "Original Z, autoscale max32",
        "profile": "original",
        "max_workers": 32,
        "summary": "summary-autoscale-z-max32-original-uniform-n-a327c742.csv",
        "latencies": "latencies-autoscale-z-max32-original-uniform-n-a327c742.csv",
        "timeseries": "scaling-timeseries-autoscale-z-max32-original-a327c742.csv",
    },
    "baseline_aggressive": {
        "label": "Aggressive Z, 1 worker fijo",
        "profile": "aggressive",
        "max_workers": 1,
        "summary": "summary-baseline-z-w1-max32profile-uniform-n-19b1448c.csv",
        "latencies": "latencies-baseline-z-w1-max32profile-uniform-n-19b1448c.csv",
        "timeseries": "scaling-timeseries-baseline-z-w1-max32profile-19b1448c.csv",
    },
    "autoscale_max32_aggressive": {
        "label": "Aggressive Z, autoscale max32",
        "profile": "aggressive",
        "max_workers": 32,
        "summary": "summary-autoscale-z-max32profile-uniform-n-13c3c429.csv",
        "latencies": "latencies-autoscale-z-max32profile-uniform-n-13c3c429.csv",
        "timeseries": "scaling-timeseries-autoscale-z-max32profile-13c3c429.csv",
    },
}

NUMERIC_SUMMARY = [
    "requests",
    "completed",
    "sold",
    "sold_out",
    "seat_unavailable",
    "errored",
    "experiment_window_seconds",
    "completed_per_second_experiment_window",
    "server_processing_window_seconds",
    "completed_per_second_server_window",
    "processing_p50_seconds",
    "processing_p95_seconds",
    "processing_p99_seconds",
    "end_to_end_p50_seconds",
    "end_to_end_p95_seconds",
    "end_to_end_p99_seconds",
]

NUMERIC_TS = [
    "elapsed_seconds",
    "rabbit_ready",
    "rabbit_unacked",
    "rabbit_total",
    "rabbit_consumers",
    "rabbit_publish_rate",
    "rabbit_deliver_rate",
    "rabbit_ack_rate",
    "worker_desired",
    "worker_running",
    "worker_pending",
    "scaler_desired",
    "scaler_running",
    "scaler_pending",
]


def read_csv(name: str) -> pd.DataFrame:
    """Lee un CSV y falla explicitamente si falta."""
    path = RESULTS / name
    if not path.exists():
        raise FileNotFoundError(path)
    return pd.read_csv(path)


def numeric(df: pd.DataFrame, columns: list[str]) -> pd.DataFrame:
    """Normaliza columnas numericas para evitar problemas de locale."""
    df = df.copy()
    for col in columns:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col].astype(str).str.replace(",", "."), errors="coerce")
    return df


def summary_frame() -> pd.DataFrame:
    """Construye una tabla resumen unica para todos los runs max32."""
    rows = []
    for key, meta in RUNS.items():
        # Cada summary CSV viene de PostgreSQL y contiene una fila por experimento.
        df = numeric(read_csv(meta["summary"]), NUMERIC_SUMMARY)
        row = df.iloc[0].to_dict()
        # Anadimos metadatos humanos para que las graficas no dependan del nombre del fichero.
        row.update({"test_key": key, "label": meta["label"], "profile": meta["profile"], "max_workers_config": meta["max_workers"]})
        rows.append(row)
    out = pd.DataFrame(rows)
    out.to_csv(RESULTS / "scaling-comparison-max32.csv", index=False)
    return out


def timeseries(key: str) -> pd.DataFrame:
    """Carga serie temporal y recalcula los terminos de la formula del scaler."""
    df = numeric(read_csv(RUNS[key]["timeseries"]), NUMERIC_TS)
    # backlog_total incluye mensajes ready y unacked; ready es el usado por formula.
    df["backlog_total"] = df["rabbit_ready"].fillna(0) + df["rabbit_unacked"].fillna(0)
    # Reproducimos ceil(lambda/C) usando lambda observada por RabbitMQ.
    df["workers_by_lambda_observed"] = df["rabbit_publish_rate"].fillna(0).apply(lambda x: math.ceil(max(x, 0) / SAFE_CAPACITY_PER_WORKER))
    # Reproducimos ceil(B/(Tr*C)) usando backlog ready.
    df["workers_by_backlog_observed"] = df["rabbit_ready"].fillna(0).apply(
        lambda x: math.ceil(max(x, 0) / (TARGET_RESPONSE_TIME_SECONDS * SAFE_CAPACITY_PER_WORKER))
    )
    # Target teorico observado, limitado al cap max32.
    df["formula_target_observed"] = df[["workers_by_lambda_observed", "workers_by_backlog_observed"]].max(axis=1).clip(0, MAX_WORKERS)
    return df


def timeseries_summary_frame() -> pd.DataFrame:
    """Extrae maximos de backlog/workers para comparar perfiles rapidamente."""
    rows = []
    for key, meta in RUNS.items():
        ts = timeseries(key)
        row = {
            "test_key": key,
            "label": meta["label"],
            "profile": meta["profile"],
            "max_workers_config": meta["max_workers"],
            "max_rabbit_ready": int(ts["rabbit_ready"].max()),
            "max_rabbit_total": int(ts["rabbit_total"].max()),
            "max_publish_rate": float(ts["rabbit_publish_rate"].max()),
            "max_ack_rate": float(ts["rabbit_ack_rate"].max()),
            "max_worker_desired": int(ts["worker_desired"].max()),
            "max_worker_running": int(ts["worker_running"].max()),
            "max_formula_target_observed": int(ts["formula_target_observed"].max()),
        }
        # Primera muestra con worker_running > 0: estima cuando ECS tuvo capacidad real.
        active = ts[ts["worker_running"] > 0]
        row["first_worker_running_at_s"] = float(active["elapsed_seconds"].min()) if not active.empty else None
        max_running = row["max_worker_running"]
        # Momento en el que se alcanza el maximo de workers running observado.
        at_max = ts[ts["worker_running"] == max_running]
        row["first_max_worker_running_at_s"] = float(at_max["elapsed_seconds"].min()) if not at_max.empty else None
        rows.append(row)
    out = pd.DataFrame(rows)
    out.to_csv(RESULTS / "scaling-timeseries-summary-max32.csv", index=False)
    return out


def save(fig: plt.Figure, name: str) -> None:
    path = FIGURES / name
    fig.tight_layout()
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)
    print(path.relative_to(REPO_ROOT))


def annotate_bars(ax, values, fmt="{:.1f}", offset=0.5) -> None:
    for i, value in enumerate(values):
        if pd.notna(value):
            # Etiquetas numericas encima de barras para que el informe se lea sin tabla auxiliar.
            ax.text(i, value + offset, fmt.format(value), ha="center", va="bottom", fontsize=9)


def plot_original_max8_vs_max32(summary: pd.DataFrame) -> None:
    """Compara el mismo Z(t) con max1, max8 y max32."""
    keys = ["baseline_original", "autoscale_max8_original", "autoscale_max32_original"]
    fig, axes = plt.subplots(3, 1, figsize=(12, 11), sharex=True)
    colors = [COLORS["red"], COLORS["blue"], COLORS["green"]]
    for key, color in zip(keys, colors):
        ts = timeseries(key)
        axes[0].plot(ts["elapsed_seconds"], ts["rabbit_ready"], label=RUNS[key]["label"], color=color, linewidth=2)
        axes[1].step(ts["elapsed_seconds"], ts["worker_running"], where="post", label=RUNS[key]["label"], color=color, linewidth=2)
        axes[2].plot(ts["elapsed_seconds"], ts["rabbit_publish_rate"], label=RUNS[key]["label"], color=color, linewidth=2)
    axes[0].set_title("Original Z profile: backlog comparison")
    axes[0].set_ylabel("RabbitMQ ready messages")
    axes[1].set_title("Original Z profile: running workers")
    axes[1].set_ylabel("Workers")
    axes[2].set_title("Original Z profile: measured arrival rate")
    axes[2].set_ylabel("Messages / second")
    axes[2].set_xlabel("Monitor elapsed seconds")
    for ax in axes:
        ax.legend(loc="upper right")
    save(fig, "01_original_profile_max8_vs_max32.png")

    subset = summary[summary["test_key"].isin(keys)].set_index("test_key").loc[keys].reset_index()
    labels = ["1 worker", "max8", "max32"]
    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    axes[0].bar(labels, subset["completed_per_second_experiment_window"], color=colors)
    axes[0].set_title("Original Z: throughput")
    axes[0].set_ylabel("Completed requests / second")
    annotate_bars(axes[0], subset["completed_per_second_experiment_window"], "{:.1f}", 0.2)
    width = 0.25
    x = list(range(len(labels)))
    # Tres percentiles juntos muestran cola de latencia, no solo media.
    axes[1].bar([i - width for i in x], subset["end_to_end_p50_seconds"], width, label="p50", color=COLORS["green"])
    axes[1].bar(x, subset["end_to_end_p95_seconds"], width, label="p95", color=COLORS["orange"])
    axes[1].bar([i + width for i in x], subset["end_to_end_p99_seconds"], width, label="p99", color=COLORS["purple"])
    axes[1].set_xticks(x, labels)
    axes[1].set_title("Original Z: end-to-end latency")
    axes[1].set_ylabel("Seconds")
    axes[1].legend()
    save(fig, "02_original_profile_throughput_latency.png")


def plot_aggressive_baseline_vs_autoscale(summary: pd.DataFrame) -> None:
    """Muestra la prueba agresiva donde el autoscaler realmente llega a 32."""
    keys = ["baseline_aggressive", "autoscale_max32_aggressive"]
    fig, axes = plt.subplots(3, 1, figsize=(12, 11), sharex=True)
    for key, color in [(keys[0], COLORS["red"]), (keys[1], COLORS["blue"] )]:
        ts = timeseries(key)
        axes[0].plot(ts["elapsed_seconds"], ts["rabbit_ready"], label=RUNS[key]["label"], color=color, linewidth=2)
        axes[1].step(ts["elapsed_seconds"], ts["worker_running"], where="post", label=f"{RUNS[key]['label']} running", color=color, linewidth=2)
        if key == "autoscale_max32_aggressive":
            axes[1].step(ts["elapsed_seconds"], ts["worker_desired"], where="post", label="Autoscale desired", color=COLORS["orange"], linestyle="--", linewidth=2)
        axes[2].plot(ts["elapsed_seconds"], ts["rabbit_publish_rate"], label=RUNS[key]["label"], color=color, linewidth=2)
    axes[0].set_title("Aggressive Z profile: backlog comparison")
    axes[0].set_ylabel("RabbitMQ ready messages")
    axes[1].set_title("Aggressive Z profile: worker growth")
    axes[1].set_ylabel("Workers")
    axes[2].set_title("Aggressive Z profile: measured arrival rate")
    axes[2].set_ylabel("Messages / second")
    axes[2].set_xlabel("Monitor elapsed seconds")
    for ax in axes:
        ax.legend(loc="upper right")
    save(fig, "03_aggressive_profile_backlog_workers.png")

    subset = summary[summary["test_key"].isin(keys)].set_index("test_key").loc[keys].reset_index()
    labels = ["1 worker", "autoscale max32"]
    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    bars = axes[0].bar(labels, subset["completed_per_second_experiment_window"], color=[COLORS["red"], COLORS["blue"]])
    axes[0].set_title("Aggressive Z: throughput")
    axes[0].set_ylabel("Completed requests / second")
    annotate_bars(axes[0], subset["completed_per_second_experiment_window"], "{:.1f}", 0.5)
    # Speedup se calcula con throughput end-to-end porque es la metrica del enunciado.
    speedup = subset["completed_per_second_experiment_window"].iloc[1] / subset["completed_per_second_experiment_window"].iloc[0]
    axes[0].text(0.5, max(subset["completed_per_second_experiment_window"]) * 0.85, f"speedup {speedup:.1f}x", ha="center", color=COLORS["dark"])

    width = 0.25
    x = list(range(len(labels)))
    axes[1].bar([i - width for i in x], subset["end_to_end_p50_seconds"], width, label="p50", color=COLORS["green"])
    axes[1].bar(x, subset["end_to_end_p95_seconds"], width, label="p95", color=COLORS["orange"])
    axes[1].bar([i + width for i in x], subset["end_to_end_p99_seconds"], width, label="p99", color=COLORS["purple"])
    axes[1].set_xticks(x, labels)
    axes[1].set_title("Aggressive Z: end-to-end latency")
    axes[1].set_ylabel("Seconds")
    axes[1].legend()
    save(fig, "04_aggressive_profile_throughput_latency.png")


def plot_latency_cdfs() -> None:
    """CDFs para ver cola completa de latencia en perfil original y agresivo."""
    groups = [
        ("original", ["baseline_original", "autoscale_max8_original", "autoscale_max32_original"], "05_original_profile_latency_cdf.png"),
        ("aggressive", ["baseline_aggressive", "autoscale_max32_aggressive"], "06_aggressive_profile_latency_cdf.png"),
    ]
    palette = [COLORS["red"], COLORS["blue"], COLORS["green"], COLORS["purple"]]
    for title, keys, filename in groups:
        fig, ax = plt.subplots()
        for key, color in zip(keys, palette):
            df = numeric(read_csv(RUNS[key]["latencies"]), ["end_to_end_seconds"])
            values = df["end_to_end_seconds"].dropna().sort_values().reset_index(drop=True)
            # y=(ranking/N) convierte latencias ordenadas en CDF empirica.
            y = (values.index + 1) / len(values)
            ax.plot(values, y, linewidth=2.3, label=RUNS[key]["label"], color=color)
        ax.set_title(f"{title.capitalize()} Z: end-to-end latency CDF")
        ax.set_xlabel("End-to-end latency (seconds)")
        ax.set_ylabel("Cumulative fraction of requests")
        ax.legend(loc="lower right")
        save(fig, filename)


def plot_formula_terms() -> None:
    """Grafica que conecta datos observados con la formula del enunciado."""
    ts = timeseries("autoscale_max32_aggressive")
    fig, axes = plt.subplots(2, 1, figsize=(12, 9), sharex=True)
    axes[0].plot(ts["elapsed_seconds"], ts["rabbit_publish_rate"], label="Observed lambda from RabbitMQ", color=COLORS["teal"], linewidth=2)
    axes[0].plot(ts["elapsed_seconds"], ts["rabbit_ready"], label="Backlog ready", color=COLORS["orange"], linewidth=2)
    axes[0].set_title("Autoscaler inputs: lambda and backlog")
    axes[0].set_ylabel("Messages/s or messages")
    axes[0].legend(loc="upper right")

    axes[1].step(ts["elapsed_seconds"], ts["workers_by_lambda_observed"], where="post", label="ceil(lambda / 6.5)", color=COLORS["teal"], linewidth=2)
    axes[1].step(ts["elapsed_seconds"], ts["workers_by_backlog_observed"], where="post", label="ceil(backlog / (10 * 6.5))", color=COLORS["orange"], linewidth=2)
    # Esta curva es la decision teorica reconstruida desde datos observados.
    axes[1].step(ts["elapsed_seconds"], ts["formula_target_observed"], where="post", label="max(formulas), capped at 32", color=COLORS["purple"], linewidth=2.4)
    axes[1].step(ts["elapsed_seconds"], ts["worker_desired"], where="post", label="ECS desired workers", color=COLORS["blue"], linestyle="--", linewidth=2)
    axes[1].step(ts["elapsed_seconds"], ts["worker_running"], where="post", label="ECS running workers", color=COLORS["green"], linewidth=2)
    axes[1].set_title("Autoscaler formula vs actual ECS workers")
    axes[1].set_xlabel("Monitor elapsed seconds")
    axes[1].set_ylabel("Workers")
    axes[1].legend(loc="upper right")
    save(fig, "07_scaler_formula_terms_aggressive.png")


def plot_worker_growth_detail() -> None:
    """Visualiza cold start: desired sube antes que running."""
    for key, filename in [
        ("autoscale_max32_original", "08_worker_growth_original_max32.png"),
        ("autoscale_max32_aggressive", "09_worker_growth_aggressive_max32.png"),
    ]:
        ts = timeseries(key)
        fig, ax1 = plt.subplots(figsize=(12, 6))
        ax1.step(ts["elapsed_seconds"], ts["worker_desired"], where="post", label="Desired workers", color=COLORS["blue"], linewidth=2.5)
        ax1.step(ts["elapsed_seconds"], ts["worker_running"], where="post", label="Running workers", color=COLORS["green"], linewidth=2.5)
        ax1.step(ts["elapsed_seconds"], ts["worker_pending"], where="post", label="Pending workers", color=COLORS["orange"], linewidth=1.8)
        ax1.set_xlabel("Monitor elapsed seconds")
        ax1.set_ylabel("Workers")
        ax1.set_ylim(bottom=0)
        ax2 = ax1.twinx()
        ax2.plot(ts["elapsed_seconds"], ts["rabbit_ready"], label="RabbitMQ ready", color=COLORS["red"], alpha=0.6, linewidth=2)
        ax2.set_ylabel("Ready messages")
        lines1, labels1 = ax1.get_legend_handles_labels()
        lines2, labels2 = ax2.get_legend_handles_labels()
        ax1.legend(lines1 + lines2, labels1 + labels2, loc="upper right")
        ax1.set_title(f"Worker growth detail: {RUNS[key]['label']}")
        save(fig, filename)


def plot_outcomes(summary: pd.DataFrame) -> None:
    """Comprueba que escalar no introduce errores ni cambia la correccion."""
    keys = ["baseline_original", "autoscale_max8_original", "autoscale_max32_original", "baseline_aggressive", "autoscale_max32_aggressive"]
    subset = summary.set_index("test_key").loc[keys].reset_index()
    labels = ["orig 1w", "orig max8", "orig max32", "aggr 1w", "aggr max32"]
    fig, axes = plt.subplots(1, 2, figsize=(13, 5))
    axes[0].bar(labels, subset["sold"], label="sold", color=COLORS["green"])
    axes[0].bar(labels, subset["seat_unavailable"], bottom=subset["sold"], label="seat_unavailable", color=COLORS["orange"])
    axes[0].bar(labels, subset["errored"], bottom=subset["sold"] + subset["seat_unavailable"], label="errored", color=COLORS["red"])
    axes[0].set_title("Request outcomes")
    axes[0].set_ylabel("Requests")
    axes[0].tick_params(axis="x", rotation=15)
    axes[0].legend()

    axes[1].bar(labels, subset["processing_p95_seconds"], color=COLORS["purple"])
    axes[1].axhline(0.1, color=COLORS["gray"], linestyle=":", label="100 ms artificial work")
    axes[1].set_title("Worker processing p95")
    axes[1].set_ylabel("Seconds")
    axes[1].tick_params(axis="x", rotation=15)
    axes[1].legend()
    save(fig, "10_outcomes_processing_latency.png")


def main() -> None:
    summary = summary_frame()
    ts_summary = timeseries_summary_frame()
    plot_original_max8_vs_max32(summary)
    plot_aggressive_baseline_vs_autoscale(summary)
    plot_latency_cdfs()
    plot_formula_terms()
    plot_worker_growth_detail()
    plot_outcomes(summary)
    print((RESULTS / "scaling-comparison-max32.csv").relative_to(REPO_ROOT))
    print((RESULTS / "scaling-timeseries-summary-max32.csv").relative_to(REPO_ROOT))
    print(ts_summary.to_string(index=False))


if __name__ == "__main__":
    main()
