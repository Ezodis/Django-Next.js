"""Container-aware web capacity; root environment values can override defaults."""
import math
import os
from pathlib import Path


def _read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return ''


def _capacity():
    cpus = len(os.sched_getaffinity(0)) if hasattr(os, 'sched_getaffinity') else (os.cpu_count() or 1)
    quota = _read('/sys/fs/cgroup/cpu.max').split()
    if len(quota) == 2 and quota[0] != 'max':
        cpus = min(cpus, max(1, math.ceil(int(quota[0]) / int(quota[1]))))
    else:
        quota = _read('/sys/fs/cgroup/cpu/cpu.cfs_quota_us')
        period = _read('/sys/fs/cgroup/cpu/cpu.cfs_period_us')
        if quota and period and int(quota) > 0:
            cpus = min(cpus, max(1, math.ceil(int(quota) / int(period))))
    memory = _read('/sys/fs/cgroup/memory.max') or _read('/sys/fs/cgroup/memory/memory.limit_in_bytes')
    # Reserve space for the master and budget each process conservatively.
    memory_workers = max(1, (int(memory) // (1024 * 1024) - 128) //
                         max(1, int(os.getenv('WEB_WORKER_MEMORY_MB', '256')))) if memory.isdigit() else 2
    return max(1, min(cpus, memory_workers, 4))


bind = '0.0.0.0:' + os.getenv('PORT', '8000')
workers = max(1, int(os.getenv('WEB_CONCURRENCY') or _capacity()))
threads = max(1, int(os.getenv('WEB_THREADS', '2')))
worker_class = 'gthread'
timeout = int(os.getenv('WEB_TIMEOUT', '120'))
graceful_timeout = int(os.getenv('WEB_GRACEFUL_TIMEOUT', '30'))
max_requests = int(os.getenv('WEB_MAX_REQUESTS', '1000'))
max_requests_jitter = int(os.getenv('WEB_MAX_REQUESTS_JITTER', '100'))
accesslog = '-'
errorlog = '-'
capture_output = True
