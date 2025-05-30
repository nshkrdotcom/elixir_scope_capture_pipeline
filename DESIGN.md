# Design Document: ElixirScope.Capture.Pipeline (elixir_scope_capture_pipeline)

## 1. Purpose & Vision

**Summary:** Manages a pool of asynchronous worker processes (`AsyncWriter`s) that consume events from ring buffers (provided by `elixir_scope_capture_core`), enrich them, and forward them for storage or further analysis.

**(Greatly Expanded Purpose based on your existing knowledge of ElixirScope and CPG features):**

The `elixir_scope_capture_pipeline` library forms the backbone of ElixirScope's asynchronous event processing system. Its primary role is to decouple the high-speed, low-latency event capture mechanism (`elixir_scope_capture_core`) from the potentially more resource-intensive tasks of event enrichment, batching, and persistent storage (`elixir_scope_storage`). This separation ensures that the application's performance is minimally impacted by the overhead of comprehensive event processing.

This library aims to:
*   **Enable Asynchronous Processing:** Read events from ring buffers in batches and process them in dedicated worker processes, preventing backpressure on the instrumented application threads.
*   **Manage Worker Pools:** Supervise a configurable pool of `AsyncWriter` workers (`ElixirScope.Capture.AsyncWriterPool`) to handle event processing in parallel.
*   **Distribute Work:** Efficiently distribute segments of the ring buffer(s) or batches of events to available workers.
*   **Provide Fault Tolerance:** Monitor worker processes and automatically restart them in case of failures, ensuring continuous event processing.
*   **Facilitate Event Enrichment:** While primary enrichment might happen in `AsyncWriter` or later stages, this pipeline provides the framework where such steps can occur (e.g., adding common metadata, initial transformations).
*   **Batch Events for Storage:** Group events into batches before sending them to the `elixir_scope_storage` layer to optimize write performance.
*   **Offer Scalability and Metrics:** Allow for dynamic scaling of the worker pool and provide aggregated metrics on processing rates, backlogs, and errors.

While this library itself doesn't directly interact with CPGs, it processes the events that contain `ast_node_id`s. Its efficient operation is crucial for ensuring that all captured runtime data, including these vital correlation points, are reliably passed on to the storage and analysis layers that will use them for CPG-enhanced debugging.

This library will enable:
*   High-throughput event processing without blocking application threads.
*   Resilient event handling with automatic recovery from worker failures.
*   Efficient batching of events for optimized interaction with the `elixir_scope_storage` layer.
*   Scalable event processing by adjusting the size of the `AsyncWriterPool`.
*   Monitoring of the event processing pipeline's health and performance.

## 2. Key Responsibilities

This library is responsible for:

*   **Pipeline Management (`PipelineManager`):**
    *   Supervising the `AsyncWriterPool`.
    *   Potentially supervising other pipeline stages in the future (e.g., `EventCorrelator` if it's managed here, though currently planned as a separate library).
    *   Providing an API to get pipeline status, metrics, and update configuration.
*   **Async Worker Pool (`AsyncWriterPool`):**
    *   Starting, stopping, and managing a pool of `AsyncWriter` GenServer processes.
    *   Distributing work (e.g., ring buffer segments or event batches) to workers.
    *   Monitoring the health of individual workers and restarting them if they fail.
    *   Scaling the number of workers up or down based on load or configuration.
    *   Aggregating metrics from workers.
*   **Async Event Writing (`AsyncWriter`):**
    *   Periodically polling a `RingBuffer` (from `elixir_scope_capture_core`) to read batches of events.
    *   Potentially performing initial event enrichment (e.g., adding worker ID, processing timestamp).
    *   Batching events and sending them to the `elixir_scope_storage` (via `ElixirScope.Storage.EventStore.store_events/2`).
    *   Handling errors gracefully (e.g., storage errors, event processing errors) and reporting them.
    *   Tracking its own processing metrics.

## 3. Key Modules & Structure

The primary modules within this library will be:

*   `ElixirScope.Capture.PipelineManager` (Supervisor and main API for the pipeline)
*   `ElixirScope.Capture.AsyncWriterPool` (GenServer managing `AsyncWriter` workers)
*   `ElixirScope.Capture.AsyncWriter` (GenServer, the actual worker processing events)

### Proposed File Tree:

```
elixir_scope_capture_pipeline/
├── lib/
│   └── elixir_scope/
│       └── capture/
│           ├── pipeline_manager.ex
│           ├── async_writer_pool.ex
│           └── async_writer.ex
├── mix.exs
├── README.md
├── DESIGN.MD
└── test/
    ├── test_helper.exs
    └── elixir_scope/
        └── capture/
            ├── pipeline_manager_test.exs
            ├── async_writer_pool_test.exs
            └── async_writer_test.exs
```

**(Greatly Expanded - Module Description):**
*   **`ElixirScope.Capture.PipelineManager` (Supervisor & API):** This module acts as the top-level supervisor for the asynchronous processing components. It will primarily start and supervise the `AsyncWriterPool`. It may also expose an API for overall pipeline control (e.g., `start/stop_pipeline`, `get_pipeline_status`, `update_pipeline_config`). It ensures that critical components like the `AsyncWriterPool` are always running.
*   **`ElixirScope.Capture.AsyncWriterPool` (GenServer):** This GenServer is responsible for managing a dynamic pool of `AsyncWriter` workers.
    *   It starts an initial set of workers based on configuration.
    *   It implements logic to distribute work to these workers. A simple strategy could be round-robin, or if multiple ring buffers exist, each worker could be assigned to a specific buffer or a range of buffer segments.
    *   It monitors its child `AsyncWriter` processes and restarts them if they crash.
    *   It provides an API to scale the number of workers (`scale_pool/2`).
    *   It aggregates metrics from all its workers (e.g., total events processed, average processing rate).
*   **`ElixirScope.Capture.AsyncWriter` (GenServer):** This is the worker process.
    *   Each `AsyncWriter` is configured with a reference to a `RingBuffer` (from `elixir_scope_capture_core`) and connection details for `elixir_scope_storage`.
    *   In its `handle_info(:poll, state)` (or similar mechanism triggered by the pool), it calls `RingBuffer.read_batch/3` to fetch a batch of events.
    *   It processes each event (e.g., basic enrichment, validation).
    *   It then calls `ElixirScope.Storage.EventStore.store_events/2` to persist the batch.
    *   It handles errors during reading, processing, or writing, logs them, and updates its error count.
    *   It maintains its own metrics (events read, events processed, batch processing times, error count).

## 4. Public API (Conceptual)

The main public interface will likely be through `ElixirScope.Capture.PipelineManager`:

*   `ElixirScope.Capture.PipelineManager.start_link(opts :: keyword()) :: Supervisor.on_start()`
    *   Options: `:async_writer_pool_size`, `:batch_size` (for writers), `:poll_interval_ms` (for writers), `ring_buffer_ref` (reference to the `RingBuffer` instance from `elixir_scope_capture_core`), `storage_ref` (reference to `elixir_scope_storage`).
*   `ElixirScope.Capture.PipelineManager.get_state(pid :: pid() | atom()) :: map()`
    *   Returns overall pipeline state, including pool status and aggregated metrics.
*   `ElixirScope.Capture.PipelineManager.update_config(pid :: pid() | atom(), new_config :: map()) :: :ok`
    *   Allows runtime updates to pool size, batch size, etc. This would propagate to the `AsyncWriterPool`.
*   `ElixirScope.Capture.PipelineManager.health_check(pid :: pid() | atom()) :: map()`
*   `ElixirScope.Capture.PipelineManager.get_metrics(pid :: pid() | atom()) :: map()`
*   `ElixirScope.Capture.AsyncWriterPool.scale_pool(pool_ref :: pid() | atom(), new_size :: non_neg_integer()) :: :ok` (if exposed directly, or via `PipelineManager`)

The `AsyncWriter` itself might not have a direct public API for external calls other than what `AsyncWriterPool` uses to manage it.

## 5. Core Data Structures

*   **`ElixirScope.Capture.PipelineManager.State.t()` (Internal):**
    ```elixir
    defmodule ElixirScope.Capture.PipelineManager.State do
      @type t :: %__MODULE__{
              config: map(),
              async_writer_pool_pid: pid() | nil,
              # ... other managed components ...
              start_time: integer(),
              aggregated_metrics: map()
            }
      defstruct [:config, :async_writer_pool_pid, :start_time, :aggregated_metrics]
    end
    ```
*   **`ElixirScope.Capture.AsyncWriterPool.State.t()` (Internal):**
    ```elixir
    defmodule ElixirScope.Capture.AsyncWriterPool.State do
      @type t :: %__MODULE__{
              config: map(), # Includes ring_buffer_ref, storage_ref, batch_size, poll_interval
              workers: %{pid() => :worker_state_placeholder}, # Map of worker PIDs to their state/info
              worker_assignments: map(), # How work is distributed
              worker_monitors: %{pid() => reference()} # Monitors for worker processes
            }
      defstruct [:config, :workers, :worker_assignments, :worker_monitors]
    end
    ```
*   **`ElixirScope.Capture.AsyncWriter.State.t()` (Internal):**
    ```elixir
    defmodule ElixirScope.Capture.AsyncWriter.State do
      @type t :: %__MODULE__{
              config: map(), # ring_buffer_ref, storage_ref, batch_size
              ring_buffer_ref: ElixirScope.Capture.RingBuffer.t(),
              storage_ref: pid() | atom(), # Ref to EventStore
              current_read_position: non_neg_integer(),
              # Metrics
              events_read: non_neg_integer(),
              events_processed: non_neg_integer(),
              batches_processed: non_neg_integer(),
              error_count: non_neg_integer(),
              last_poll_time: integer()
            }
      defstruct [
        :config, :ring_buffer_ref, :storage_ref, :current_read_position,
        :events_read, :events_processed, :batches_processed, :error_count, :last_poll_time
      ]
    end
    ```
*   Consumes: `ElixirScope.Events.t()` (read from `RingBuffer`).

## 6. Dependencies

This library will depend on the following ElixirScope libraries:

*   `elixir_scope_utils` (for timestamps, ID generation if needed internally).
*   `elixir_scope_config` (for its own operational parameters like pool size, batch sizes, poll intervals).
*   `elixir_scope_events` (to understand the structure of events it's processing, though it mostly treats them as opaque data to pass to storage).
*   `elixir_scope_capture_core` (specifically, for the `RingBuffer.t()` type and API to read from).
*   `elixir_scope_storage` (specifically, for the `ElixirScope.Storage.EventStore` API to write to).

It will depend on Elixir core libraries (`GenServer`, `Supervisor`, `Process`, `Task`, `:ets` if used for internal state).

## 7. Role in TidewaveScope & Interactions

Within the `TidewaveScope` ecosystem, the `elixir_scope_capture_pipeline` library will:

*   Be started by the main `TidewaveScope` application as a critical part of the event capture and processing infrastructure.
*   Be configured (via `elixir_scope_config`) by `TidewaveScope`'s application configuration.
*   Consume events from `RingBuffer` instances managed by `elixir_scope_capture_core`.
*   Persist processed events into the `elixir_scope_storage` system.
*   Its performance and health metrics could be exposed via `TidewaveScope` MCP tools for monitoring purposes.

## 8. Future Considerations & CPG Enhancements

*   **Smart Batching/Prioritization:** `AsyncWriter`s could implement smarter batching strategies, e.g., prioritizing events with `ast_node_id`s if the system is under load, to ensure CPG-relevant data is processed quickly.
*   **Inline Enrichment/Filtering:** `AsyncWriter`s could be extended to perform lightweight event enrichment (e.g., adding geo-IP data to web request events) or filtering based on dynamic rules before storage.
*   **Backpressure Management:** The `AsyncWriterPool` or `PipelineManager` could implement more sophisticated backpressure mechanisms if the `elixir_scope_storage` layer becomes a bottleneck, potentially signaling `elixir_scope_capture_core` to adjust sampling or temporarily pause capture.
*   **Multiple Pipelines:** Support for multiple, independent capture pipelines, perhaps for different event types or with different processing priorities.

## 9. Testing Strategy

*   **`ElixirScope.Capture.AsyncWriter` Unit Tests:**
    *   Test `init/1` with various configurations.
    *   Test `handle_info(:poll, state)`:
        *   Correctly reads a batch from a mock `RingBuffer`.
        *   Correctly calls `ElixirScope.Storage.EventStore.store_events/2` with the batch.
        *   Updates its internal metrics (`events_read`, `events_processed`, `batches_processed`, `error_count`).
        *   Handles empty batches from the ring buffer gracefully.
        *   Handles errors from `RingBuffer.read_batch` or `EventStore.store_events`.
        *   Test polling interval logic.
*   **`ElixirScope.Capture.AsyncWriterPool` Unit Tests:**
    *   Test `init/1` starts the correct number of `AsyncWriter` workers.
    *   Test `scale_pool/2` to scale up and down, verifying workers are started/stopped correctly.
    *   Test worker monitoring and restart: simulate an `AsyncWriter` crashing and verify the pool restarts it.
    *   Test work distribution logic (if a specific strategy is implemented beyond workers pulling independently).
    *   Test aggregation of metrics from workers.
*   **`ElixirScope.Capture.PipelineManager` Unit Tests:**
    *   Test it correctly supervises `AsyncWriterPool`.
    *   Test its API functions for status, config updates, and metrics.
*   **Integration Tests (within this library):**
    *   Test the flow: `RingBuffer` -> `AsyncWriter` -> (Mock) `EventStore`.
    *   Simulate high load and verify behavior.
*   **Performance Benchmarks:**
    *   Measure event processing throughput (events/sec) of the entire pipeline under different loads and configurations.
    *   Measure latency introduced by the pipeline.
