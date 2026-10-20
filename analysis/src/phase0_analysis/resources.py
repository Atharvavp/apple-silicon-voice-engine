"""Runner-process resource metrics from the telemetry sidecar (plan E3/D6).

CPU % uses a one-core basis and may exceed 100 (no clamp). RSS is the current
resident size from ``task_info``; its peak is the *sampled* peak, not the
process's lifetime high-water mark. GPU, ANE and power are unsupported in the
v1 baseline and stay explicit; nothing is zero-filled or inferred.
"""

from __future__ import annotations

from typing import Any

from .timing import distribution, scalar

UNSUPPORTED = "no public per-process counter is used in the v1 baseline"


def compute(samples: list[dict[str, Any]] | None, sampler: dict[str, Any] | None) -> dict[str, Any]:
    r: dict[str, Any] = {}
    artifact = "telemetry.jsonl"
    if samples is None:
        for key, unit in (("cpu_percent", "percent_one_core"), ("rss_bytes", "bytes")):
            r[key] = distribution([], unit, f"{key}_v1", "monotonic", artifact, key, reason="telemetry_disabled")
        r["rss_peak_sampled_bytes"] = scalar(None, "bytes", "rss_peak_sampled_v1", "none", 0, "telemetry_disabled",
                                             status="unavailable")
    else:
        def values(key: str) -> tuple[list[float], dict[str, int]]:
            kept, skipped = [], {}
            for sample in samples:
                observation = sample["measurements"][key]
                if observation["status"] == "ok":
                    kept.append(observation["value"])
                else:
                    skipped[observation["reason"]] = skipped.get(observation["reason"], 0) + 1
            return kept, skipped

        cpu, cpu_skipped = values("cpu_percent")
        r["cpu_percent"] = distribution(cpu, "percent_one_core", "cpu_percent_one_core_v1", "monotonic", artifact,
                                        "measurements.cpu_percent.value",
                                        exclusions=[{"reason": k, "count": v} for k, v in sorted(cpu_skipped.items())])
        rss, rss_skipped = values("rss_bytes")
        r["rss_bytes"] = distribution(rss, "bytes", "rss_current_v1", "monotonic", artifact,
                                      "measurements.rss_bytes.value",
                                      exclusions=[{"reason": k, "count": v} for k, v in sorted(rss_skipped.items())])
        r["rss_peak_sampled_bytes"] = scalar(max(rss) if rss else None, "bytes", "rss_peak_sampled_v1", "none", len(rss),
                                             "no_rss_samples", {"note": "maximum of sampled current RSS, not the exact lifetime peak"},
                                             status=None if rss else "unavailable")
        footprint, _ = values("physical_footprint_bytes")
        r["physical_footprint_peak_sampled_bytes"] = scalar(max(footprint) if footprint else None, "bytes",
                                                            "footprint_peak_sampled_v1", "none", len(footprint),
                                                            "phys_footprint_unavailable",
                                                            status=None if footprint else "unavailable")
    for key, unit in (("gpu_utilization", "percent"), ("ane_utilization", "percent"), ("power_watts", "watts")):
        r[key] = scalar(None, unit, f"{key}_v1", "none", 0, UNSUPPORTED, status="unsupported")
    if sampler is None:
        r["telemetry_completeness"] = scalar(None, "ratio", "telemetry_completeness_v1", "none", 0,
                                             "telemetry_disabled", status="unavailable")
    else:
        expected = sampler["expected_periodic_samples"]
        r["telemetry_completeness"] = scalar(sampler["periodic_samples"] / expected if expected else None, "ratio",
                                             "telemetry_completeness_v1", "none", sampler["samples"],
                                             "run_shorter_than_one_interval",
                                             {"periodic_samples": sampler["periodic_samples"],
                                              "expected_periodic_samples": expected,
                                              "missed_intervals": sampler["missed_intervals"],
                                              "max_lateness_ns": sampler["max_lateness_ns"]})
        r["telemetry_collection_ns"] = scalar(sampler["total_collection_ns"], "ns", "telemetry_collection_v1",
                                              "monotonic", sampler["samples"])
    return r
