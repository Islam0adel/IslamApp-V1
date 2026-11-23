"""Run blocking SDK I/O in AnyIO's shared bounded worker pool.

The worker returns facts only. Authorization/scope decisions remain on the
request's event loop, and callers still read current source on each request.
"""
from functools import partial
from starlette.concurrency import run_in_threadpool


async def run_blocking(function, *args, **kwargs):
    return await run_in_threadpool(partial(function, *args, **kwargs))
