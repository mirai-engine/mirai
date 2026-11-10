# Tasks (`std/jobs`)

Work-stealing scheduler with an explicit context. It depends on `core:` and, for the profile zones,
on `std/base`.

## Workers

`system_init(&js, Job_System_Desc)` creates the system. `threads` are the threads in addition to the
caller (`THREADS_AUTO`: one per remaining core; 0: none); capacities at zero take the defaults of
`jobs.odin`. The `allocator` provides all the memory, also the temporary memory that the threads
request and return, so it must admit simultaneous calls.

- The thread that calls `system_init` is worker 0 (`OWNER`); each thread of the system is another.
- Every procedure that enqueues or waits receives the index of the worker that calls it: the owner
  passes `OWNER` and a task, the index it received. No other thread may call the system.
- Two threads never execute at the same time with the same index, so it works to index buffers per
  worker. A task that waits may execute another, nested, with its same index.
- The `Job_System` does not move after being initialized. `system_destroy` executes what remains
  enqueued, stops the threads and releases the memory.
- The threads inherit the `context` of whoever called `system_init` (logger, `context.allocator`).
- Each worker has a fixed-capacity Chase-Lev deque: it pushes and pops at the bottom and the others
  steal from the top. Without work, it tries its deque, steals from a random victim, yields the
  processor a few times and sleeps on a futex until someone enqueues.

- `Worker_Ref` (system, index and `Profile`) is where code that does not receive a system of its own
  runs: whoever calls it passes it, and a task rebuilds it with its index (`worker_ref_at`). Without
  a system, everything goes on the calling thread; `worker_zone` records a zone in the ring of that
  worker.

## Tasks and counters

- `run(&js, worker, procedure, data, &counter)` enqueues in the deque of the calling worker; it
  accepts `proc(data:^T, worker:int)`. With the deque full it executes the task inside the call and
  adds to `Stats.queue_full`.
- A zeroed `Counter` is ready for use and must live until its tasks finish. `wait` returns when it
  reaches zero; meanwhile it executes enqueued tasks, its own first, and sleeps only if there are
  none. `pending` asks without waiting or executing.
- Without threads, a task without a counter is executed before `run` returns; with a counter, at the
  latest inside `wait`.

## `parallel_for`

- `parallel_for(&js, worker, count, grain, procedure, data)` splits `[0,count)` into ranges of
  `grain` and returns when all have run.
- Range `k` is always `[k*grain, min((k+1)*grain, count))`, with any number of workers: what changes
  is who executes it and in what order. The ranges must not depend on each other.
- The caller executes ranges alongside the others. It enqueues at most one helper task per worker,
  whatever `count` is; all take the next range from an atomic cursor.
- It can be nested: a range may call `parallel_for` with its worker index.

## Temporary memory

- Inside a task or a range, `context.temp_allocator` is the Odin temporary allocator of the thread
  that executes it, and what is requested is released on return.
- `runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD` bounds a region also inside a task, and the `std` code
  that uses it releases the same in a job as on the main thread.
- Each thread of the system starts with a block of `temp_bytes`, reserved before `system_init`
  returns: a task that fits in it does not allocate. One that needs more adds blocks, which are
  released when it returns. On the owner, each task uses a region of the thread's temporary
  allocator.

## Without threads

With `threads=0` everything runs on the caller with the same code paths: same ranges, same nodes,
same results as long as the tasks do not depend on the order among them. It is the mode of tests and
deterministic runs.

## Profile zones and statistics

- `system_profile_set` records in a `base.Profile` with a ring per worker, which must outlive the
  system, a `job` zone per task and a `range` zone per range, in the ring of the worker that runs it
  (the owner is 0). With `nil` it stops recording; without a profile it costs one atomic read per
  task.
- `system_stats` adds the counters of the workers; `temp_peak` is the most that a single task or
  range requested from temporary memory.

## Verification

- After touching deques or waiting, repeat the executable at least 20 times and once with
  `--release`: `./mirai test std/jobs -keep-executable`.
- Benchmarks:
  `./mirai test std/jobs --release -define:MIRAI_BENCH=true -define:ODIN_TEST_THREADS=1`.
