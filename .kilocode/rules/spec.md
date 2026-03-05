# Agent Runtime Specification v2

## Status

This document defines the normative architecture and behavior of a deterministic, resumable agent runtime.

An implementation compliant with this specification guarantees:

* deterministic decision execution
* durable side-effect orchestration
* resumable execution after crashes
* observable execution with traceable causality
* safe coordination across agents

Normative keywords **MUST**, **MUST NOT**, **SHOULD**, and **MAY** are used as defined in RFC 2119.

---

# 1. Principles

The runtime is built around six architectural principles.

**Agents are state machines.**

**Inputs are immutable signals.**

**Decisions are pure transitions producing a plan.**

**Directives are effect intents.**

**Execution is separate, observable, and resumable.**

**The runtime itself is a state machine with explicit, auditable transitions.**

All mechanisms in this specification enforce one or more of these principles.

---

# 2. Non-Goals (v1)

The following capabilities are explicitly outside the scope of the core runtime.

## Plugin systems

No plugin framework exists in the core runtime.

Extensions may wrap agent modules or drain implementations.

## Routing DSLs

Signals are delivered directly to agents.
No routing DSL is defined.

## Sensor frameworks

External observers producing signals are ordinary processes and not part of the runtime.

## Workflow DSLs

Graph or DAG workflow definitions are not part of this runtime.

Coordination primitives are intentionally minimal.

## Built-in persistence backends

The runtime defines persistence behaviours but does not mandate specific databases.

## Embedded debug timelines

Agents do not maintain internal execution histories.
Observability is emitted externally.

---

# 3. Core Data Model

## 3.1 Identity and Causality

Every signal and directive carries causal metadata.

Required identifiers:

| Field               | Description                    |
| ------------------- | ------------------------------ |
| `signal_id`         | unique signal identifier       |
| `directive_id`      | unique directive identifier    |
| `agent_instance_id` | unique runtime instance        |
| `agent_revision`    | monotonic committed revision   |
| `correlation_id`    | cross-agent request chain      |
| `causation_id`      | triggering signal or directive |

### Rules

1. `agent_revision` increments **only during checkpointing**.
2. All directives generated during a committed decision share the same `agent_revision`.
3. Each directive has a globally unique `directive_id`, assigned by the agent at plan construction time.
4. `correlation_id` propagates unchanged through related operations.
5. `causation_id` references the signal or directive that triggered the operation.

---

## 3.2 Signal

Signals are immutable inputs.

```
Signal{
  signal_id
  agent_instance_id
  correlation_id
  causation_id
  payload
  metadata
}
```

Properties:

* Signals are immutable.
* Signals may originate from users, agents, or runtime events.

---

## 3.3 Directive Plan

A decision produces a plan.

```
DirectivePlan{
  pre:    [Directive]
  effect: [Directive]
  post:   [Directive]
  meta:   PlanMeta
}
```

### PlanMeta

```
PlanMeta{
  compensation_policy:  :none | :best_effort
  outcome_signals:      :none | :failures | :all
  compensators:         map<directive_id, Directive>
}
```

The `compensators` map keys are `directive_id` values assigned by the agent at plan construction time.
Each value is the compensating directive to execute if the keyed directive requires compensation.

### Phases

| Phase    | Description                       |
| -------- | --------------------------------- |
| `pre`    | deterministic runtime work        |
| `effect` | external side effects             |
| `post`   | replies, signal emission, logging |

Checkpointing occurs **between the `pre` and `effect` phases**.

---

## 3.4 Outbox Entry

```
OutboxEntry{
  directive_id
  scope_type
  scope_id
  agent_revision
  encoded_directive
  status
  inserted_at
  trace_context
  metadata
}
```

### scope_type values

Valid `scope_type` values are:

| Value          | Description                            |
| -------------- | -------------------------------------- |
| `:agent`       | entry belongs to an agent runtime      |
| `:coordinator` | entry belongs to a coordinator process |

### Status values

```
pending
running
completed
failed
cancelled
compensated
```

### Terminal states

```
completed
cancelled
compensated
```

Terminal states MUST NOT transition to any other state.

---

## 3.5 Agent Snapshot

```
AgentSnapshot{
  agent_instance_id
  agent_revision
  agent_module
  schema_version
  encoded_state
  inserted_at
}
```

Snapshots represent committed agent state.

---

# 4. Directive Plan Phases

## 4.1 Pre Phase

Executed synchronously by the runtime.

Allowed operations:

* runtime child creation
* coordination setup
* deterministic bookkeeping

Forbidden operations:

* network I/O
* database mutations
* filesystem writes
* drain-executed directives
* spawning unmanaged processes (`spawn`, `Task.async`, etc.)

If any pre directive fails:

* the decision cycle MUST abort
* no revision increment occurs
* no outbox entries are written
* the runtime transitions back to `idle`
* the input signal is handled according to the configured error policy:
  - `:reject` — signal is dropped and an error is emitted (default)
  - `:requeue` — signal is returned for later processing
  - `:escalate` — signal is forwarded to a dead-letter or escalation handler

---

## 4.2 Effect Phase

Effect directives represent external side effects.

Each directive MUST be persisted to the outbox before execution begins.

### Idempotency Rule

Effects MUST be idempotent with respect to `directive_id`.

Executing the same directive twice with the same `directive_id` MUST produce the same observable result as executing it once.

---

## 4.3 Post Phase

Executed after effect submission.

Used for:

* replies
* signal emission
* logging

Post directives are not persisted.

---

## 4.4 Phase Validation

Directive modules MUST declare phase affinity:

```
phase() :: :pre | :effect | :post
```

The runtime MUST validate that each directive appears in the correct phase.

Invalid plans MUST be rejected before checkpointing.

If a plan is rejected due to invalid phase placement:

* the decision cycle MUST abort
* no revision increment occurs
* no outbox entries are written
* the input signal is handled according to the configured error policy (see Section 4.1)

---

# 5. Persistence and State Evolution

## 5.1 Codec Contract

Serialization format is not mandated.

Required behavior:

```
encode_state(struct) -> term
decode_state(term) -> struct
encode_signal(signal) -> term
decode_signal(term) -> signal
encode_directive(directive) -> term
decode_directive(term) -> directive
```

Codecs operate only on the **current schema version**.

Upcasting (Section 5.2) MUST occur before decoding.
`decode_state/1` MUST only receive data conforming to the current schema version.

---

## 5.2 Upcasting

Schema evolution occurs through sequential single-version migrations.

```
v1 → v2 → v3 → v4
```

Direct version jumps are prohibited.

Each upcast step MUST be deterministic and side-effect free.

---

## 5.3 Checkpoint Ordering (Authoritative)

Checkpointing enforces durability ordering.

The runtime MUST execute the following steps in order:

1. Assign new `agent_revision` (`committed_revision + 1`)
2. Validate all directive IDs are present and unique; assign causal metadata (`agent_revision`, `correlation_id`, `causation_id`) to each directive
3. Atomically persist all effect directives to the outbox
4. Persist the agent snapshot at the new revision
5. Commit the revision (`committed_revision = pending_revision`)

No effect directive may begin execution until **Step 3 completes successfully**.

If Step 3 or Step 4 fails:

* the runtime MUST NOT submit any effects
* the runtime MUST NOT increment `committed_revision`
* the runtime transitions to `idle` or `stopping` per error policy

Outbox writes MUST be atomic: either all effect directives for the plan are written or none are.

---

## 5.4 Startup Recovery

This section implements resumable execution.

### Initialization Consistency

Initialization MUST read snapshot and outbox using:

* point-in-time consistent reads, or
* read-your-writes guarantees.

If the persistence implementation cannot guarantee either, the runtime MUST NOT apply the divergence rule (Case 2b below) without re-reading under a stronger consistency mode.

### Recovery Procedure

1. Load latest snapshot.

   If none exists:
   ```
   snapshot_revision = 0
   committed_revision = 0
   agent = initial struct provided to Runtime.start_link
   ```

2. Query outbox entries where:
   ```
   scope_type == :agent
   AND scope_id == agent_instance_id
   ```

3. Determine `max_outbox_revision` from query results.

#### Case 1: `max_outbox_revision ≤ snapshot_revision`

No recovery required. Proceed to `idle`.

#### Case 2: `max_outbox_revision > snapshot_revision`

**Case 2a — Resumable**

If a snapshot exists at `max_outbox_revision`:

* perform a targeted read for the snapshot at `max_outbox_revision`
* load that snapshot
* set `committed_revision = max_outbox_revision`
* set `agent` to the decoded snapshot state
* reconstruct pending plan from outbox entries at that revision
* transition to `submitting_effects`

The runtime MUST NOT recompute the decision.

**Case 2b — Unrecoverable**

If no snapshot exists at `max_outbox_revision`:

* runtime MUST transition to `stopped`
* emit a divergence error
* require operator intervention

The runtime MUST NOT attempt to guess agent state or recompute the decision.

---

# 6. Drain Behavior

## 6.1 Drain Interface

```
submit(outbox_entry_id, opts) :: :ok | {:error, reason}
cancel(outbox_entry_id, opts) :: :ok | {:error, reason}
status(outbox_entry_id)       :: :pending | :running | :completed
                                  | :failed | :cancelled | :compensated
```

Drain implementations MUST read directive content from the outbox using `outbox_entry_id`.

Drain implementations MUST NOT accept directive content directly from the runtime.

---

## 6.2 Internal Drain

Internal drains run under supervision within the runtime supervision tree.

Startup reconciliation MUST query entries where:

```
status             == :running
AND scope_type     == :agent
AND scope_id       == agent_instance_id
AND agent_revision == committed_revision
```

Matching entries MUST be reset to `:pending` and resubmitted.

This ensures directives interrupted by drain crashes are retried safely.

---

## 6.3 External Drain

External workers perform:

1. fetch job referencing `outbox_entry_id`
2. atomically transition outbox entry status to `:running`
3. execute directive (reading content from outbox)
4. update final status

The transition to `:running` MUST be atomic with job acquisition to prevent duplicate execution.

The `:running` transition occurs when execution begins, not when `submit/2` is called.

---

## 6.4 Retry Constraints

Drain implementations MUST NOT retry directives with terminal status:

```
cancelled
compensated
```

---

# 7. Runtime Finite State Machine

## 7.1 Runtime State Variables

The runtime maintains internal state separate from the agent struct:

| Variable            | Description                                               |
| ------------------- | --------------------------------------------------------- |
| `agent`             | current agent struct                                      |
| `module`            | agent module implementing `cmd/2`                         |
| `agent_instance_id` | stable instance identifier                                |
| `committed_revision`| last successfully checkpointed revision                   |
| `pending_input`     | signal being processed                                    |
| `pending_plan`      | plan returned by current `cmd/2` call                     |
| `pending_revision`  | revision reserved for current checkpoint                  |
| `outbox_entry_ids`  | IDs of outbox entries for current plan                    |
| `cancel_requested`  | boolean cancellation flag                                 |
| `execution`         | module implementing `ExecutionBehaviour` (Section 7.7)    |

Runtime state MUST NOT be stored inside the agent struct.

---

## 7.2 Runtime States

```
init
idle
deciding
dispatching_pre
checkpointing
submitting_effects
dispatching_post
stopping
stopped
```

---

## 7.3 Transition Events

* signal input
* cancellation request
* timeout
* stop request

---

## 7.4 State Transitions

### `init` → `idle`

Perform startup recovery per Section 5.4 and initialize runtime state.

---

### `idle` → `deciding`

On signal input: set `pending_input` and transition to `deciding`.

Only one signal is processed per decision cycle.

---

### `deciding` → `dispatching_pre`

Call:

```
cmd(agent, signal) :: {:ok, agent, DirectivePlan} | {:error, reason, agent, DirectivePlan}
```

Validate all directive phase placements per Section 4.4.

If the plan is invalid:

* abort the decision cycle
* do not checkpoint
* apply the configured error policy to the input signal (Section 4.1)
* return to `idle`

Otherwise: set `pending_plan` and transition to `dispatching_pre`.

---

### `dispatching_pre`

Execute all `pre` directives synchronously inside the runtime.

Rules:

* no external I/O
* no unmanaged process creation

If any pre directive fails:

* abort decision cycle
* do not checkpoint
* apply configured error policy to input signal (Section 4.1)
* return to `idle`

---

### `checkpointing`

Commit the decision by executing steps 1–5 from Section 5.3, in order:

1. Assign `pending_revision = committed_revision + 1`
2. Validate directive IDs; assign causal metadata to each directive
3. Atomically persist all effect directives to the outbox
4. Persist agent snapshot at `pending_revision`
5. Set `committed_revision = pending_revision`

No effect execution may begin until step 3 completes successfully.

If steps 3 or 4 fail:

* MUST NOT submit effects
* MUST NOT increment `committed_revision`
* transition to `idle` or `stopping` per error policy

---

### `submitting_effects`

For each entry in `outbox_entry_ids`:

```
Drain.submit(outbox_entry_id, opts)
```

The drain MUST load directive content from the outbox.

---

### `dispatching_post`

Execute all `post` directives.

Emit replies and signals.

Post directive failures:

* MUST be logged
* MUST emit telemetry

Post failures MUST NOT prevent transition to `idle`, because effect directives have already been submitted and cannot be rolled back.

Clear `pending_input`, `pending_plan`, `outbox_entry_ids`.

Transition to `idle`.

---

## 7.5 Cancellation Semantics

Cancellation request fields:

```
agent_instance_id
directive_id | agent_revision
correlation_id
reason
requested_at
```

Stale cancellations MUST be rejected:

```
requested_at < directive.inserted_at
```

State-specific handling:

| State                            | Behavior                                                                                       |
| -------------------------------- | ---------------------------------------------------------------------------------------------- |
| `idle`                           | no effect                                                                                      |
| `deciding`                       | abort; apply error policy to signal                                                            |
| `dispatching_pre`                | abort; apply error policy to signal                                                            |
| `checkpointing` before step 3    | abort; no outbox written                                                                       |
| `checkpointing` after step 3     | runtime marks entries `:cancelled` via `Outbox.transition/2`; MUST NOT call `Drain.submit`    |
| `submitting_effects`             | best-effort via `Drain.cancel/2`                                                               |

In the "after step 3" case, the runtime performs the cancellation transition directly because the drain has not yet been invoked.

---

## 7.6 Determinism Rules

Terminal statuses are immutable.

Concurrent compensation ordering MUST use deterministic tie-breakers (ascending `directive_id` within the same completion timestamp bucket is recommended).

---

## 7.7 ExecutionBehaviour

All execution steps in Sections 5.3, 5.4, and 7.4 are dispatched through the module held in `RuntimeData.execution`, which MUST implement the `ExecutionBehaviour` callback contract.

### Rationale

Dynamic dispatch through a behaviour-holding field is required by the Elixir 1.18 compiler's interprocedural type inference. The compiler infers return types through statically-resolved call chains. If execution steps were implemented as private functions in the FSM module, the compiler would narrow the return type of each stub to its placeholder value and flag all other match arms at the call site as unreachable. Calling through a runtime-variable module forces the compiler to use the declared callback spec at the call site, preserving all match arms.

This is not a workaround. It is the correct idiom in any language that performs interprocedural inference: when a call site must be typed against a contract rather than a concrete body, the callee must be resolved at runtime.

### Callback Contract

```
do_startup_recovery(RuntimeData) ::
  {:ok, RuntimeData} | {:resume, RuntimeData} | {:stop, reason}

do_cmd(RuntimeData) ::
  {:ok, RuntimeData} | {:error, reason}

do_dispatch_pre(RuntimeData) ::
  {:ok, RuntimeData} | {:error, reason}

do_checkpoint(RuntimeData) ::
  {:ok, RuntimeData} | {:error, reason}

do_submit_effects(RuntimeData) ::
  {:ok, RuntimeData} | {:error, reason}

do_dispatch_post(RuntimeData) :: :ok

do_best_effort_cancel(RuntimeData, CancellationToken) :: :ok

apply_error_policy(RuntimeData, reason) :: RuntimeData

clear_pending(RuntimeData) :: RuntimeData
```

Each callback maps to the governing section:

| Callback               | Governing section                     |
| ---------------------- | ------------------------------------- |
| `do_startup_recovery`  | Section 5.4                           |
| `do_cmd`               | Section 7.4 deciding                  |
| `do_dispatch_pre`      | Section 7.4 dispatching_pre, 4.1      |
| `do_checkpoint`        | Section 5.3                           |
| `do_submit_effects`    | Section 7.4 submitting_effects, 6.1   |
| `do_dispatch_post`     | Section 7.4 dispatching_post, 4.3     |
| `do_best_effort_cancel`| Section 7.5                           |
| `apply_error_policy`   | Section 4.1                           |
| `clear_pending`        | Section 7.4 dispatching_post          |

### Configuration

The `execution` module is specified at `AgentRuntime` startup:

```
AgentRuntime.start_link([
  module:            MyAgent,
  agent_instance_id: id,
  execution:         Orquesta.Runtime.Execution,   # default
  drain:             MyDrain,
  outbox:            MyOutbox,
  persistence:       MyPersistence,
  codec:             MyCodec
])
```

The default implementation is `Orquesta.Runtime.Execution`.

### Testing

Injecting a controlled `execution` module is the primary mechanism for testing `AgentRuntime` behaviour without real persistence or drain infrastructure. A test implementation MAY return any valid combination of outcomes to exercise specific FSM paths.

---

# 8. Behaviours

The runtime defines seven normative behaviour contracts. Implementations MUST provide a module satisfying each.

| Behaviour             | Governs                                           |
| --------------------- | ------------------------------------------------- |
| `AgentBehaviour`      | `cmd/2`, `initial_state/0`, `error_policy/0`      |
| `DirectiveBehaviour`  | `phase/0`, `execute/2`                            |
| `DrainBehaviour`      | `submit/2`, `cancel/2`, `status/1`                |
| `CodecBehaviour`      | encode/decode for state, signals, directives      |
| `OutboxBehaviour`     | `write_entries/1`, `transition/2`, query ops      |
| `PersistenceBehaviour`| `save_snapshot/1`, `load_*`, `upcast/3`           |
| `ExecutionBehaviour`  | all execution steps dispatched by `AgentRuntime`  |

The first six behaviours define external integration contracts. `ExecutionBehaviour` is an internal runtime contract: it separates the FSM wiring in `AgentRuntime` from the execution logic, and provides the injection point for test doubles.

---

# 9. Cancellation and Compensation

## 9.1 Definitions

**Cancellation**: prevents an effect from executing. Applies only to directives that have not yet completed. Best-effort once execution has started.

**Compensation**: reverses or mitigates an effect that has already executed. Best-effort by design.

Cancellation and compensation share no mechanism and are handled independently.

---

## 9.2 Cancellation Token

Required fields:

```
agent_instance_id
directive_id | agent_revision
correlation_id
reason
requested_at
```

A cancellation request is invalid if stale (`requested_at < directive.inserted_at`).

---

## 9.3 Compensation

Each effect directive MAY declare a compensator in `PlanMeta.compensators`.

Compensators MUST NOT have compensators.

Only directives that have completed successfully are eligible for compensation.

Compensation executes through the same drain machinery as effect directives, with separate outbox records per compensator.

Compensator outbox entries carry:

```
compensates_directive_id
```

---

## 9.4 Compensation Ordering

Compensations execute in reverse completion order (LIFO).

If two or more directives completed concurrently, ordering among them MUST be deterministic (ascending `directive_id` within the same completion timestamp bucket is recommended).

---

## 9.5 Compensation Failure

If a compensation directive fails:

* the runtime MUST NOT attempt further automated compensation
* the entry MUST be transitioned to a terminal failed state
* an escalation event MUST be emitted for operator action

Automated retry of compensations is prohibited.

---

## 9.6 Directive Outcome Signals

Directive outcomes MAY emit signals back to the agent, controlled by `PlanMeta.outcome_signals`.

```
Signal.DirectiveOutcome{
  signal_id
  agent_instance_id
  directive_id
  outcome:        :completed | :failed | :cancelled | :compensated
  correlation_id
  causation_id
}
```

Default behavior: outcome signals are not emitted (`outcome_signals: :none`).

If enabled, these signals enter the runtime inbox and are processed as normal inputs through the FSM.

The agent remains purely signal-driven. It is never invoked directly because a directive compensated — it is invoked because an outcome signal was emitted.

---

# 10. Coordination Primitives

## 10.1 Request / Reply

```
Directive.Request{
  directive_id
  to
  payload
  correlation_id
  causation_id
  timeout_ms
  reply_to
}
```

Response signals MUST include:

* same `correlation_id`
* `causation_id` set to the request `directive_id`

If timeout expires without a matching reply:

* outbox entry transitions to `:failed`
* drain emits `Signal.DirectiveOutcome` with `outcome: :failed, reason: :timeout`

---

## 10.2 Fan-Out / Gather

Fan-out expands `Directive.Fanout` into a plan:

```
pre:
  Directive.Spawn(coordinator)     ← must be in pre phase

effect:
  Directive.Request(target_A)      ← must be in effect phase
  Directive.Request(target_B)
  ...
```

The coordinator MUST exist before any requests are submitted.
Therefore `Directive.Spawn` MUST appear in `pre` and all `Directive.Request` entries MUST appear in `effect`.

If the coordinator spawn fails during `pre`:

* Section 4.1 pre failure rules apply
* decision cycle aborts
* no checkpoint occurs
* no effects are executed

---

## 10.3 Coordinator

The coordinator is a runtime-managed child process, supervised under the parent agent's runtime supervisor tree.

If the parent agent stops, the coordinator MUST stop.

The coordinator has its own stable identity:

```
coordinator_instance_id
```

It inherits the parent's `correlation_id` and sets `causation_id` to the fanout `directive_id`.

---

## 10.4 Coordinator Outbox Scope

The coordinator maintains its own outbox scope:

```
scope_type == :coordinator
scope_id   == coordinator_instance_id
```

Each received reply MUST produce an outbox entry in the coordinator's scope.

Reply entries are idempotent: duplicate replies with the same `signal_id` or `(request_directive_id, responder_id)` MUST be deduplicated.

---

## 10.5 Coordinator Recovery

On restart, the coordinator MUST:

1. Load its reply journal from its outbox scope
2. Reconstruct the set of collected replies
3. Deduplicate replies by stable identity
4. Evaluate completion criteria (`:all` or `{:n, k}`)
5. If criteria are met: emit aggregate reply and terminate normally
6. If timeout has elapsed: emit timeout reply and terminate normally
7. Otherwise: continue collecting

Timeout condition:

```
now() > fanout.inserted_at + timeout_ms
```

This check MUST be evaluated on restart to prevent the coordinator from restarting its timeout window indefinitely.

---

# 11. Observability Contract

## 11.1 Telemetry Events

All event names are normative and MUST remain stable across implementations.

Decision lifecycle:

```
:agent.decision.start
:agent.decision.complete
:agent.decision.error
```

Directive lifecycle:

```
:agent.directive.submit
:agent.directive.running
:agent.directive.completed
:agent.directive.failed
:agent.directive.cancelled
:agent.directive.compensated
```

Runtime lifecycle:

```
:agent.runtime.start
:agent.runtime.init
:agent.runtime.recover
:agent.runtime.stop
```

Coordinator events:

```
:agent.coordinator.spawn
:agent.coordinator.reply_received
:agent.coordinator.complete
:agent.coordinator.timeout
```

---

## 11.2 Required Event Fields

All events MUST include:

| Field               | Description                                              |
| ------------------- | -------------------------------------------------------- |
| `agent_instance_id` | identity of the agent runtime                            |
| `correlation_id`    | traces the operation across agents                       |
| `causation_id`      | identifier of the triggering signal or directive         |
| `agent_revision`    | revision associated with the decision                    |
| `timestamp`         | event emission time                                      |

Directive events MUST additionally include:

```
directive_id
directive_type
outbox_status
```

Coordinator events MUST use the **parent agent's revision** for `agent_revision`, and additionally include:

```
coordinator_instance_id
fanout_directive_id
```

---

## 11.3 OpenTelemetry Integration

Implementations SHOULD integrate with OpenTelemetry.

Trace context MUST propagate across asynchronous boundaries.

Outbox entries MUST store the W3C trace context (`traceparent`) at the time the entry is written.

Workers and coordinators MUST create spans using the stored trace context so that async spans link correctly to the originating decision span.

---

## 11.4 Span Model

One decision cycle equals one primary trace span.

```
agent.decision
 ├─ pre
 ├─ checkpoint
 ├─ directive.execute   (one child span per directive, async)
 └─ post
```

Directive execution spans MUST propagate `correlation_id` and reference the decision span via the stored `traceparent`.

---

# 12. Consistency Verification Pass

Before declaring compliance, implementations MUST verify all of the following.

### Terminology Consistency

Key terms (`agent_revision`, `directive_id`, `correlation_id`, `checkpointing`, `outbox entry`) are used identically across all sections.

### Data Structure Alignment

Every field referenced in Sections 4–11 is defined in the core data model (Section 3).

### Behaviour Coverage

All seven behaviours defined in Section 8 have implementing modules. The `ExecutionBehaviour` module is wired into `RuntimeData.execution` and all FSM execution dispatches go through it.

### FSM Alignment

Every runtime state transition in Section 7 references rules defined in the governing section:

| Transition             | Governing section      |
| ---------------------- | ---------------------- |
| `dispatching_pre`      | Section 4.1            |
| `checkpointing`        | Section 5.3            |
| `submitting_effects`   | Section 6.1            |
| cancellation paths     | Sections 7.5, 9.1–9.2  |

### ExecutionBehaviour Dispatch

Every FSM state that calls an execution step MUST dispatch through `data.execution.<callback>`. Direct calls to private execution functions within the FSM module are prohibited.

### Testability

An `AgentRuntime` MUST accept an `execution` opt at startup. A test that passes a controlled `ExecutionBehaviour` implementation MUST be able to exercise all startup recovery paths (`{:ok, _}`, `{:resume, _}`, `{:stop, _}`) and all execution failure paths without real persistence or drain infrastructure.

### Failure-Path Coverage

Every failure scenario defines behavior for:

* snapshot state
* outbox state
* revision state
* effect execution state

### Determinism Guarantees

All concurrent scenarios specify deterministic ordering rules.

**A runtime that fails any verification criterion MUST NOT be described as compliant with this specification.**

---

# End of Specification

This specification defines a deterministic, crash-resilient runtime for agent-based systems.

A compliant implementation guarantees:

* consistent decision semantics
* resumable side-effect execution
* causal traceability
* safe distributed coordination