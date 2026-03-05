# nasa-erlang-elixir.md

Adapted from Gerard J. Holzmann's *Power of 10: Rules for Developing Safety-Critical Code* (NASA/JPL, 2006) for Erlang and Elixir on the BEAM. The original rules target C and aim to make code statically verifiable and free of hidden failure modes. Each principle is mapped onto BEAM's process model, OTP supervision trees, pattern-matching semantics, and the Dialyzer/Credo toolchain.

## Guidelines

- **Base cases first, tail calls always.** Every recursive function must have its base case as the first pattern-matched clause. All recursion must be tail-recursive. Mutual recursion across modules is forbidden unless both directions have clearly separated, locally visible base cases.

- **Bound every loop, receive, and retry.** Every `receive` must have an `after` timeout. Every `Stream` pipeline must be capped with `Stream.take(@max_items)`. Every retry loop must carry a decrementing counter. Declare all limits as named module attributes (`@max_retries 3`), never as bare literals.

- **Spawn only through supervisors; create ETS once.** Never call `spawn`, `spawn_link`, or `Task.start` directly inside `handle_*` callbacks or request handlers. All long-lived processes must be started through a supervision tree. ETS tables must be created once at application startup, not per-request. Process pools must declare a maximum size.

- **Function clauses ≤ 30 lines; GenServer callbacks are dispatchers only.** Individual function clause bodies must not exceed 30 lines. `handle_call`, `handle_cast`, and `handle_info` clauses must immediately delegate to private helper functions — they should contain no business logic themselves. Modules must have a single declared responsibility.

- **Two guards per public function: head pattern + `when` clause.** Use pattern matching in the function head as the first precondition (a `function_clause` crash at the boundary). Add a `when` guard as the second. Functions that accept external data (API payloads, socket messages, ETS reads) must validate structure with `with` before data enters the processing pipeline.

- **State at the narrowest possible scope.** Prefer local variables over GenServer state. Prefer GenServer state over ETS. Prefer ETS over `Application.get_env`. Never use the process dictionary as a general-purpose store. Module attributes are constants, not mutable runtime config. Scope decision order: local variable → function argument → GenServer state → ETS → `Application.get_env`.

- **Every tagged tuple return must be matched explicitly.** Every `{:ok, _} | {:error, _}` return must be handled. Bare `_` patterns on tagged tuples are forbidden. Every `with` chain must include an `else` branch enumerating all expected error shapes. `Task.await` results must be wrapped to handle `:exit` and `:timeout`.

- **Single-purpose macros; prefer `def` over `defmacro`.** Elixir macros and Erlang parse transforms must do one clearly described thing. Never write a macro that expands into another macro. Never use `defmacro` to implement logic expressible as a plain `def`. Erlang `-define` is for constants and simple inline guards only.

- **Flat message payloads; flat GenServer state.** GenServer message schemas must be flat tagged tuples with at most one level of nesting. GenServer state structs must not nest live PIDs or process references more than one level deep. Never send MFA tuples (`{module, fun, args}`) as messages between processes — messages are data commands, not encoded behaviour.

- **Zero warnings from compiler, Dialyzer, and Credo.** Every PR must pass `mix compile --warnings-as-errors`, `mix dialyzer` (with `:error_handling`, `:underspecs`, `:unknown`, and `:unmatched_returns` flags), and `mix credo --strict` with zero issues. Every public function must have a `@spec`. Suppression comments require a reviewer-approved explanation.