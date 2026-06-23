#!/usr/bin/env python3
"""Render Article 09 professional comparison charts with pandas, seaborn, and matplotlib."""

from __future__ import annotations

from pathlib import Path
import textwrap

import matplotlib.pyplot as plt
import pandas as pd
import seaborn as sns


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "analysis" / "output"
CHARTS = OUTPUT / "article09-professional-charts"

VARIANT_ORDER = ["go-http", "oracle-jdk-26-jvm", "oracle-jdk-26-aot"]
VARIANT_LABELS = {
    "go-http": "Go",
    "oracle-jdk-26-jvm": "Oracle JDK JVM",
    "oracle-jdk-26-aot": "Oracle JDK AOT",
}
PALETTE = {
    "Go": "#2C7FB8",
    "Oracle JDK JVM": "#D95F02",
    "Oracle JDK AOT": "#1B9E77",
}
VARIANT_LABEL_ORDER = [VARIANT_LABELS[v] for v in VARIANT_ORDER]
FIXTURE_LABELS = {
    "work-128b": "128 B",
    "work-2kb": "2 KB",
    "work-32kb": "32 KB",
}
CPU_ORDER = ["1", "4", "all"]
RATE_ORDER = ["fixed-5000", "80pct-go-peak", "95pct-go-peak"]
RATE_LABELS = {
    "fixed-5000": "Fixed 5k RPS",
    "80pct-go-peak": "80% Go peak",
    "95pct-go-peak": "95% Go peak",
}


def load_csv(name: str) -> pd.DataFrame:
    return pd.read_csv(OUTPUT / name)


def prepare(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df["variantLabel"] = df["variant"].map(VARIANT_LABELS).fillna(df.get("variantLabel", df["variant"]))
    df["fixtureLabel"] = df["fixture"].map(FIXTURE_LABELS).fillna(df["fixture"])
    df["cpuShape"] = df["cpuShape"].astype(str)
    if "rateTier" in df.columns:
        df["rateLabel"] = df["rateTier"].map(RATE_LABELS).fillna(df["rateTier"])
    return df


def setup_theme() -> None:
    sns.set_theme(
        context="talk",
        style="whitegrid",
        rc={
            "figure.dpi": 140,
            "savefig.dpi": 180,
            "axes.titlesize": 15,
            "axes.labelsize": 12,
            "xtick.labelsize": 11,
            "ytick.labelsize": 11,
            "legend.fontsize": 10,
            "legend.title_fontsize": 10,
            "axes.spines.top": False,
            "axes.spines.right": False,
        },
    )


def present_variant_order(df: pd.DataFrame) -> list[str]:
    present = set(df["variantLabel"].dropna())
    return [label for label in VARIANT_LABEL_ORDER if label in present]


def save(fig: plt.Figure, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, bbox_inches="tight", facecolor="white")
    plt.close(fig)


def add_bar_labels(ax, fmt="{:.0f}", rotation=0) -> None:
    for container in ax.containers:
        labels = []
        for value in container.datavalues:
            if pd.isna(value) or value == 0:
                labels.append("")
            else:
                labels.append(fmt.format(value))
        ax.bar_label(container, labels=labels, fontsize=8, padding=2, rotation=rotation)


def grouped_bar_by_fixture(
    df: pd.DataFrame,
    y: str,
    title: str,
    ylabel: str,
    filename: str,
    *,
    value_format: str = "{:.0f}",
    yscale: str | None = None,
    legend: bool = True,
) -> None:
    df = df.copy()
    hue_order = present_variant_order(df)
    df["variantLabel"] = pd.Categorical(
        df["variantLabel"],
        hue_order,
        ordered=True,
    )
    df["cpuShape"] = pd.Categorical(df["cpuShape"], CPU_ORDER, ordered=True)
    df = df.sort_values(["fixtureLabel", "cpuShape", "variantLabel"])

    g = sns.catplot(
        data=df,
        kind="bar",
        x="cpuShape",
        y=y,
        hue="variantLabel",
        col="fixtureLabel",
        col_order=[FIXTURE_LABELS[f] for f in ["work-128b", "work-2kb", "work-32kb"]],
        hue_order=hue_order,
        palette=PALETTE,
        height=4.6,
        aspect=1.05,
        sharey=True,
        legend=legend,
        errorbar=None,
    )
    g.set_axis_labels("CPU shape", ylabel)
    g.set_titles("{col_name} fixture")
    if yscale:
        for ax in g.axes.flat:
            ax.set_yscale(yscale)
    for ax in g.axes.flat:
        add_bar_labels(ax, value_format, rotation=90 if yscale else 0)
        ax.margins(y=0.15)
        ax.grid(axis="y", alpha=0.35)
    if g.legend:
        g.legend.set_title("Runtime")
        sns.move_legend(g, "lower center", bbox_to_anchor=(0.5, -0.03), ncol=3, frameon=False)
    g.figure.suptitle(title, y=1.08, fontsize=18, fontweight="bold")
    g.figure.set_size_inches(15.5, 5.8)
    save(g.figure, CHARTS / filename)


def line_by_rate(
    df: pd.DataFrame,
    y: str,
    title: str,
    ylabel: str,
    filename: str,
    *,
    value_scale: float = 1.0,
    yscale: str | None = None,
) -> None:
    data = df.copy()
    hue_order = present_variant_order(data)
    data[y] = data[y] / value_scale
    data["variantLabel"] = pd.Categorical(
        data["variantLabel"],
        hue_order,
        ordered=True,
    )
    data["rateLabel"] = pd.Categorical(
        data["rateLabel"],
        [RATE_LABELS[r] for r in RATE_ORDER],
        ordered=True,
    )
    data["cell"] = data["fixtureLabel"] + " / CPU " + data["cpuShape"].astype(str)
    cell_order = [
        f"{FIXTURE_LABELS[f]} / CPU {c}"
        for f in ["work-128b", "work-2kb", "work-32kb"]
        for c in CPU_ORDER
    ]
    data["cell"] = pd.Categorical(data["cell"], cell_order, ordered=True)
    g = sns.relplot(
        data=data.sort_values(["cell", "rateLabel", "variantLabel"]),
        x="rateLabel",
        y=y,
        hue="variantLabel",
        style="variantLabel",
        col="cell",
        col_wrap=3,
        kind="line",
        marker="o",
        linewidth=2.2,
        markersize=7,
        hue_order=hue_order,
        palette=PALETTE,
        height=3.4,
        aspect=1.25,
        facet_kws={"sharey": False},
    )
    g.set_axis_labels("Comparable offered-rate basis", ylabel)
    g.set_titles("{col_name}")
    for ax in g.axes.flat:
        if yscale:
            ax.set_yscale(yscale)
        ax.tick_params(axis="x", rotation=20)
        ax.grid(axis="y", alpha=0.35)
    if g.legend:
        g.legend.set_title("Runtime")
        sns.move_legend(g, "upper center", bbox_to_anchor=(0.5, 0.935), ncol=3, frameon=False)
    g.figure.suptitle(title, y=0.985, fontsize=18, fontweight="bold")
    g.figure.set_size_inches(15.5, 12.4)
    g.figure.subplots_adjust(top=0.86, bottom=0.08, hspace=0.42, wspace=0.18)
    save(g.figure, CHARTS / filename)


def heatmap_ratio(
    df: pd.DataFrame,
    metric: str,
    title: str,
    filename: str,
    *,
    center: float = 1.0,
    fmt: str = ".2f",
) -> None:
    data = df[df["variant"] != "go-http"].copy()
    data["runtime"] = data["variant"].map(VARIANT_LABELS)
    data["cell"] = data["fixture"].map(FIXTURE_LABELS) + " / CPU " + data["cpuShape"].astype(str)
    pivot = data.pivot(index="cell", columns="runtime", values=metric)
    cell_order = [
        f"{FIXTURE_LABELS[f]} / CPU {c}"
        for f in ["work-128b", "work-2kb", "work-32kb"]
        for c in CPU_ORDER
    ]
    pivot = pivot.reindex(cell_order)
    fig, ax = plt.subplots(figsize=(9, 8))
    sns.heatmap(
        pivot,
        annot=True,
        fmt=fmt,
        cmap="vlag",
        center=center,
        linewidths=0.8,
        linecolor="white",
        cbar_kws={"label": "Ratio vs Go baseline"},
        ax=ax,
    )
    ax.set_title(title, fontsize=17, fontweight="bold", pad=16)
    ax.set_xlabel("")
    ax.set_ylabel("")
    ax.tick_params(axis="x", rotation=0)
    ax.tick_params(axis="y", rotation=0)
    save(fig, CHARTS / filename)


def scatter_tradeoff(
    df: pd.DataFrame,
    x: str,
    y: str,
    title: str,
    xlabel: str,
    ylabel: str,
    filename: str,
) -> None:
    hue_order = present_variant_order(df)
    data = df.copy()
    data["variantLabel"] = pd.Categorical(data["variantLabel"], hue_order, ordered=True)
    data["Runtime"] = data["variantLabel"]
    data["CPU shape"] = data["cpuShape"]
    data["fixtureLabel"] = pd.Categorical(
        data["fixtureLabel"],
        [FIXTURE_LABELS[f] for f in ["work-128b", "work-2kb", "work-32kb"]],
        ordered=True,
    )
    g = sns.relplot(
        data=data,
        x=x,
        y=y,
        hue="Runtime",
        style="CPU shape",
        size="CPU shape",
        sizes={"1": 90, "4": 130, "all": 170},
        col="fixtureLabel",
        col_order=[FIXTURE_LABELS[f] for f in ["work-128b", "work-2kb", "work-32kb"]],
        hue_order=hue_order,
        palette=PALETTE,
        height=4.8,
        aspect=1.05,
        facet_kws={"sharex": False, "sharey": False},
    )
    g.set_axis_labels(xlabel, ylabel)
    g.set_titles("{col_name} fixture")
    for ax in g.axes.flat:
        ax.grid(alpha=0.35)
        ax.margins(x=0.1, y=0.15)
    if g.legend:
        g.legend.set_title("")
        sns.move_legend(g, "upper center", bbox_to_anchor=(0.5, 0.89), ncol=5, frameon=False)
    g.figure.suptitle(title, y=0.99, fontsize=18, fontweight="bold")
    g.figure.set_size_inches(15.5, 5.8)
    g.figure.subplots_adjust(top=0.74, bottom=0.14, wspace=0.24)
    save(g.figure, CHARTS / filename)


def gc_bar(df: pd.DataFrame, rate_tier: str, y: str, title: str, ylabel: str, filename: str) -> None:
    data = df[df["rateTier"] == rate_tier].copy()
    data["variantLabel"] = data["variant"].map(VARIANT_LABELS)
    grouped_bar_by_fixture(
        data,
        y,
        title,
        ylabel,
        filename,
        value_format="{:.1f}",
    )


def main() -> None:
    setup_theme()
    CHARTS.mkdir(parents=True, exist_ok=True)

    peak = prepare(load_csv("article09-peak-best-by-cell.csv"))
    comparable = prepare(load_csv("article09-comparable-medians.csv"))
    near = prepare(load_csv("article09-near-limit-medians.csv"))
    ratios = prepare(load_csv("article09-near-limit-ratios-vs-go.csv"))
    peak_ratios = prepare(load_csv("article09-peak-ratios-vs-go.csv"))
    gc = prepare(load_csv("article09-gc-pause-medians.csv"))

    # Unit conversions for reader-friendly axes.
    comparable["p95Ms"] = comparable["p95Micros"] / 1000.0
    comparable["p99Ms"] = comparable["p99Micros"] / 1000.0
    near["p50Ms"] = near["p50Micros"] / 1000.0
    near["p95Ms"] = near["p95Micros"] / 1000.0
    near["p99Ms"] = near["p99Micros"] / 1000.0

    grouped_bar_by_fixture(
        peak,
        "achievedRps",
        "Peak Throughput by Runtime and CPU Shape (Higher Is Better)",
        "Achieved requests/sec",
        "article09_pro_01_peak_throughput_higher_is_better.png",
        value_format="{:.0f}",
    )
    grouped_bar_by_fixture(
        peak,
        "peakRpsPerCore",
        "Peak Throughput per Configured Core (Higher Is Better)",
        "Requests/sec/core",
        "article09_pro_02_peak_rps_per_core_higher_is_better.png",
        value_format="{:.0f}",
    )
    grouped_bar_by_fixture(
        peak,
        "serviceCpuPercent",
        "Service CPU at Peak Throughput (Lower Is Better at Similar Throughput)",
        "Service CPU %",
        "article09_pro_03_peak_service_cpu_lower_is_better.png",
        value_format="{:.0f}",
    )
    grouped_bar_by_fixture(
        peak,
        "serviceRssMiB",
        "Service RSS at Peak Throughput (Lower Is Better)",
        "Resident set size (MiB)",
        "article09_pro_04_peak_rss_lower_is_better.png",
        value_format="{:.0f}",
    )
    grouped_bar_by_fixture(
        peak_ratios,
        "peakRpsRatioVsGo",
        "Peak Throughput Ratio vs Go Baseline (Higher Is Better)",
        "Ratio vs Go",
        "article09_pro_05_peak_ratio_vs_go_higher_is_better.png",
        value_format="{:.2f}",
    )

    grouped_bar_by_fixture(
        near,
        "p95Ms",
        "Near-Limit P95 Response Time at 95% of Go Peak (Lower Is Better)",
        "P95 response time (ms)",
        "article09_pro_06_near_limit_p95_lower_is_better.png",
        value_format="{:.1f}",
    )
    grouped_bar_by_fixture(
        near,
        "p99Ms",
        "Near-Limit P99 Response Time at 95% of Go Peak (Lower Is Better)",
        "P99 response time (ms)",
        "article09_pro_07_near_limit_p99_lower_is_better.png",
        value_format="{:.1f}",
    )
    grouped_bar_by_fixture(
        near,
        "serviceCpuPercentPer1kRps",
        "Near-Limit CPU per 1k RPS (Lower Is Better)",
        "Service CPU % per 1k RPS",
        "article09_pro_08_near_limit_cpu_per_1k_lower_is_better.png",
        value_format="{:.1f}",
    )
    grouped_bar_by_fixture(
        near,
        "serviceRssMiB",
        "Near-Limit Resident Memory Footprint (Lower Is Better)",
        "RSS (MiB)",
        "article09_pro_09_near_limit_rss_lower_is_better.png",
        value_format="{:.0f}",
    )
    grouped_bar_by_fixture(
        near,
        "serviceRssMiBPer1kRps",
        "Near-Limit RSS per 1k RPS (Lower Is Better)",
        "RSS MiB per 1k RPS",
        "article09_pro_10_near_limit_rss_per_1k_lower_is_better.png",
        value_format="{:.1f}",
    )

    fixed = comparable[comparable["rateTier"] == "fixed-5000"].copy()
    fixed["p95Ms"] = fixed["p95Micros"] / 1000.0
    grouped_bar_by_fixture(
        fixed,
        "p95Ms",
        "Fixed 5k RPS P95 Response Time (Lower Is Better)",
        "P95 response time (ms)",
        "article09_pro_11_fixed_5k_p95_lower_is_better.png",
        value_format="{:.2f}",
    )

    eighty = comparable[comparable["rateTier"] == "80pct-go-peak"].copy()
    eighty["p95Ms"] = eighty["p95Micros"] / 1000.0
    grouped_bar_by_fixture(
        eighty,
        "p95Ms",
        "80% of Go Peak P95 Response Time (Lower Is Better)",
        "P95 response time (ms)",
        "article09_pro_12_80pct_p95_lower_is_better.png",
        value_format="{:.1f}",
    )

    line_by_rate(
        comparable,
        "p95Micros",
        "P95 Response Time Across Comparable Offered-Rate Tiers (Lower Is Better)",
        "P95 response time (ms)",
        "article09_pro_13_p95_across_rate_tiers_lower_is_better.png",
        value_scale=1000.0,
    )
    line_by_rate(
        comparable,
        "serviceRssMiBPer1kRps",
        "RSS per 1k RPS Across Comparable Offered-Rate Tiers (Lower Is Better)",
        "RSS MiB per 1k RPS",
        "article09_pro_14_rss_per_1k_across_rate_tiers_lower_is_better.png",
    )

    heatmap_ratio(
        ratios,
        "p95RatioVsGo",
        "Near-Limit P95 Ratio vs Go (Lower Is Better)",
        "article09_pro_15_p95_ratio_vs_go_lower_is_better.png",
    )
    heatmap_ratio(
        ratios,
        "rssRatioVsGo",
        "Near-Limit RSS Ratio vs Go (Lower Is Better)",
        "article09_pro_16_rss_ratio_vs_go_lower_is_better.png",
    )
    heatmap_ratio(
        ratios,
        "cpuPer1kRatioVsGo",
        "Near-Limit CPU per 1k RPS Ratio vs Go (Lower Is Better)",
        "article09_pro_17_cpu_per_1k_ratio_vs_go_lower_is_better.png",
    )

    scatter_tradeoff(
        near,
        "serviceRssMiBPer1kRps",
        "p95Ms",
        "Near-Limit Memory Cost vs P95 Response Time (Lower Left Is Better)",
        "RSS MiB per 1k RPS",
        "P95 response time (ms)",
        "article09_pro_18_memory_vs_p95_lower_left_is_better.png",
    )
    scatter_tradeoff(
        peak,
        "serviceRssMiB",
        "achievedRps",
        "Peak Throughput vs RSS Footprint (Higher and Left Is Better)",
        "RSS at peak (MiB)",
        "Achieved requests/sec",
        "article09_pro_19_peak_throughput_vs_rss_higher_left_is_better.png",
    )

    gc_bar(
        gc,
        "95pct-go-peak",
        "gcPauseMsPerWorkloadSecond",
        "Java GC Pause Burden at 95% of Go Peak (Lower Is Better)",
        "GC pause ms per workload second",
        "article09_pro_20_gc_pause_ms_per_second_lower_is_better.png",
    )
    line_by_rate(
        gc,
        "gcPauseMsPerWorkloadSecond",
        "Java GC Pause Burden Across Rate Tiers (Lower Is Better)",
        "GC pause ms per workload second",
        "article09_pro_21_gc_pause_across_rate_tiers_lower_is_better.png",
    )

    print(f"Rendered {len(list(CHARTS.glob('*.png')))} charts to {CHARTS}")


if __name__ == "__main__":
    main()
