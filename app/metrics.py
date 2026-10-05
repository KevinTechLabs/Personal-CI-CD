"""Prometheus metrics shared by the API and the worker.

Label cardinality is kept bounded: HTTP metrics use the matched route
template (e.g. /api/tasks/{task_id}), never the raw path.
"""

from __future__ import annotations

from prometheus_client import Counter, Gauge, Histogram, Info

BUILD_INFO = Info("app_build", "Build and deployment metadata")

HTTP_REQUESTS = Counter(
    "http_requests_total",
    "HTTP requests handled by the API",
    ["method", "route", "status"],
)

HTTP_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["method", "route"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)

TASKS_PROCESSED = Counter(
    "worker_tasks_processed_total",
    "Tasks processed by the worker",
    ["outcome"],
)

TASK_DURATION = Histogram(
    "worker_task_duration_seconds",
    "Time spent processing one task",
)

QUEUE_DEPTH = Gauge(
    "worker_queue_depth",
    "Tasks waiting in the pending state",
)


def set_build_info(version: str, environment: str, component: str) -> None:
    BUILD_INFO.info({"version": version, "environment": environment, "component": component})
