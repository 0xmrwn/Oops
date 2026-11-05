"""Independent bounded judge queues; only the coordinator writes journals and progress."""

import json
import signal
import threading
import time
from collections import Counter
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from contextlib import contextmanager
from datetime import datetime, timezone

from . import judges
from .records import append, digest, write_json
from .tasks import validate


def now():
    return datetime.now(timezone.utc).isoformat()


@contextmanager
def interrupts(stop):
    if threading.current_thread() is not threading.main_thread():
        yield
        return
    previous = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        for sig in previous:
            signal.signal(sig, lambda *_: stop.set())
        yield
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def review(task, engine, rubric, key):
    began = time.monotonic()
    row = {
        "key": task["key"],
        "case": task["evidence"]["case"],
        "judge": engine,
        "rubric": digest(rubric),
        "at": now(),
        "status": "ok",
    }
    try:
        result, metadata = judges.decisions(task, rubric, key) if engine == "decisions" else judges.codex(task, rubric)
        row.update(judgment=validate(result, task), metadata=metadata)
    except (ValueError, OSError, json.JSONDecodeError) as error:
        row.update(
            status="error",
            error=str(error) if isinstance(error, ValueError) else f"{engine} adapter failed; raw details omitted.",
        )
        if isinstance(error, judges.JudgeError):
            row.update(unvalidated_judgment=error.judgment, metadata=error.metadata)
    row["elapsed_ms"] = round((time.monotonic() - began) * 1000)
    return row


def run(directory, rubric, pending, key, workers, stop=None):
    stop = stop if stop is not None else threading.Event()
    queues = {engine: iter([task for task, engines in pending if engine in engines]) for engine in workers}
    progress = {
        "started": now(),
        "updated": now(),
        "status": "running",
        "total": sum(len(es) for _, es in pending),
        "done": 0,
        "errors": 0,
        "workers": workers,
        "by_judge": {
            engine: {"total": sum(engine in es for _, es in pending), "done": 0, "errors": 0, "active": 0}
            for engine in workers
        },
    }
    futures, streaks = {}, Counter()
    pools = {
        engine: ThreadPoolExecutor(max_workers=count, thread_name_prefix=engine) for engine, count in workers.items()
    }

    def publish():
        active = Counter(engine for future, engine in futures.items() if not future.done())
        for engine in workers:
            progress["by_judge"][engine]["active"] = active[engine]
        progress["updated"] = now()
        write_json(directory / "judge_progress.json", progress)

    def submit(engine):
        if not stop.is_set() and (task := next(queues[engine], None)) is not None:
            futures[pools[engine].submit(review, task, engine, rubric, key)] = engine

    try:
        with interrupts(stop):
            for engine, count in workers.items():
                for _ in range(count):
                    submit(engine)
            publish()
            while futures:
                completed, _ = wait(futures, timeout=0.2, return_when=FIRST_COMPLETED)
                for future in completed:
                    engine = futures.pop(future)
                    if future.cancelled():
                        continue
                    row = future.result()
                    append(directory / "judgments.jsonl", row)
                    failed = row["status"] != "ok"
                    progress["done"] += 1
                    progress["errors"] += failed
                    progress["by_judge"][engine]["done"] += 1
                    progress["by_judge"][engine]["errors"] += failed
                    streaks[engine] = streaks[engine] + 1 if failed else 0
                    if streaks[engine] >= 6:
                        progress["stop_reason"] = (
                            f"Six consecutive {engine} failures; inspect the saved errors before resuming."
                        )
                        stop.set()
                    submit(engine)
                    publish()
                if stop.is_set():
                    for future in futures:
                        future.cancel()
            progress["status"] = (
                "partial"
                if progress.get("stop_reason")
                else "interrupted"
                if stop.is_set()
                else "partial"
                if progress["errors"]
                else "complete"
            )
    finally:
        # SIGINT stops new submissions and drains at most the bounded in-flight set.
        for pool in pools.values():
            pool.shutdown(wait=True, cancel_futures=True)
        if progress["status"] == "running":
            progress["status"] = "interrupted"
        publish()
    return progress
