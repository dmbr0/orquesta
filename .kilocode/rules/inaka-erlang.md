# inaka-erlang.md

Erlang coding conventions from Inaka's Erlang Coding Standards & Guidelines. These are enforceable rules that may be used as grounds to reject a pull request, distilled from the full guideline set at https://github.com/inaka/erlang_guidelines.

## Guidelines

### Source Code Layout

- **Maintain existing style.** When editing a module written by someone else, match its formatting and conventions. If the project has a house style, follow it in new modules too. A consistently ugly module is better than a half-refactored one.

- **Spaces over tabs; 2-space indentation.** Never use tabs. Indent with 2 spaces. This is not a license for deep nesting — 2 spaces works precisely because the code should be clean enough not to need more.

- **Surround operators and commas with spaces.** `X = A + B`, not `X=A+B`. `foo(A, B)`, not `foo(A,B)`. Consistent spacing aids readability and grep.

- **No trailing whitespace.** Strip trailing spaces from every line before committing. They are noise in diffs and serve no purpose.

- **100 characters per line maximum.** Longer lines require horizontal scrolling or ugly soft-wrap. 100 characters allows two files side by side on a laptop, or three on a 1080p display.

- **Prefer multiple small functions over top-level `case` expressions.** When a `case` is the top-level expression of a function body — especially a large one — replace it with pattern-matched function clauses. Each branch becomes a named function clause, making the decision point explicit and giving each path a meaningful name.

- **Group exported functions before unexported ones.** Separate the two groups clearly within the module, unless a different arrangement genuinely aids readability. Well-structured modules are easier to navigate.

- **Place all type definitions at the top of the file.** Types define the data structures used by multiple functions; they belong at the module level, not buried near the functions that happen to use them.

- **No god modules.** A module must have a single, clearly stated responsibility. Modules that accumulate functions across many unrelated concerns become impossible to reason about. Split early.

- **Simple unit tests; 1–2 assertions per test.** Single responsibility applies to tests. A test with many assertions fails at the first and hides the rest. Multiple focused tests identify multiple errors in a single run.

- **Honor DRY.** Do not copy logic across functions or modules. Extract shared behavior into a function or variable. Reviewers may reject PRs that duplicate code that already exists elsewhere.

- **Group modules in subdirectories by functionality.** When a project contains many modules, organise them into named subdirectories that describe the package's purpose.

- **Header files must not contain type, record, or function definitions.** `.hrl` files may contain macro definitions (used sparingly). Types belong in the modules that own the data; records belong in their owning module; function definitions in headers cause duplication.

### Syntax

- **No spaghetti code.** Do not write list comprehensions with `case` inside, or blocks with `begin/end` inside comprehensions, or deeply nested conditional structures. The function call graph should be a directed acyclic graph.

- **Avoid dynamic function calls.** Do not use `apply/3` or dynamic `Module:Function(Args)` calls unless there is a specific, documented reason. Dynamic calls cannot be checked by `xref`, which is one of Erlang's most valuable static analysis tools.

- **No more than 3 levels of nesting.** Deep nesting indicates a function doing too much — too many decisions, too many states handled inline. Extract inner blocks into named helper functions.

- **Do not use `if`.** Use `case` expressions or pattern-matched function clauses instead. Erlang's `if` uses guard syntax and has no catch-all `else`, making it confusing for newcomers and restrictive compared to `case`.

- **Do not nest `try...catch` blocks.** Nesting error-handling code defeats its purpose. The golden path and the error path should be clearly separated; nesting conflates them.

- **Do not use `throw` and non-local `catch` returns.** `throw` is for non-local exits, not for general control flow. Use tail-recursive functions or explicit `{ok, _} | {error, _}` returns instead. Throwing across distant call sites makes code very hard to reason about.

### Naming

- **Use the same variable name for the same concept everywhere.** If a user identifier is `UserId` in one module it must be `UserId` everywhere — not `Uid`, `UserID`, or `Id`. Consistent naming makes grep reliable.

- **Name OTP state records `#mod_state{}` and define `-type state() :: #mod_state{}`** in every module implementing an OTP behaviour. This makes state identifiable when dumped in the shell and lets Dialyzer detect when internal state leaks across module boundaries.

- **Do not use `_Ignored` variables.** Variables prefixed with `_` are still bound by the pattern match. If you prefix a variable with `_`, never use it. Use plain `_` when you genuinely do not care about the value.

- **Do not use boolean parameters to control clause selection.** Replace `do_thing(Pid, true)` / `do_thing(Pid, false)` with `do_thing(Pid)` / `skip_thing(Pid)` or an atom flag. Booleans require reading the function definition to understand what they mean at the call site.

- **Stick to one module naming convention across the project.** Pick one (`my_module` vs `mymodule` vs `app_my_module`) and apply it everywhere. Consistency gives the system coherence.

- **Atoms must be lowercase with underscores.** `my_atom`, not `MyAtom` or `myAtom`. Special cases like `'GET'` or `'POST'` are allowed where justified, but they require quoting and should be exceptions.

- **Function names must be lowercase with underscores.** Functions are atoms; the same rules apply. `my_function/1`, not `myFunction/1`.

- **Variable names must be CamelCase.** `UserId`, not `user_id` or `userid`. CamelCase visually distinguishes variables from atoms and matches OTP convention.

### Strings

- **Use iolists instead of string concatenation.** Build IO data as nested lists of binaries and integers rather than concatenating strings with `++` or `<<>>`. Iolists avoid copying and eliminate encoding conversion errors when writing to ports or sockets.

### Macros

- **Avoid macros.** The only acceptable macros are predefined ones (`?MODULE`, `?MODULE_STRING`, `?LINE`) and literal constants (`?DEFAULT_TIMEOUT`). For code reuse, use functions. Macros obscure errors and cannot be introspected or tested.

- **All macro names must be ALL\_UPPER\_CASE.** `?MAX_RETRIES`, not `?maxRetries` or `?MaxRetries`. Uppercase makes macros easy to grep and visually distinct from function calls.

- **Do not use macros for module or function names.** Pasting code into an Erlang shell for debugging — which happens constantly — becomes impractical if module and function names are macros that must be manually expanded.

### Records

- **Record names and field names must be lowercase with underscores.** Records and fields are atoms; the same naming rules apply. `#user_profile{}`, not `#UserProfile{}`.

- **Define records before any function bodies in the module.** Records define data structures used by multiple functions; they must be visible before the functions that use them.

- **Do not share records across modules via header files.** Records should be internal to the module that owns the data. Provide an opaque exported type and accessor functions instead. Sharing record definitions via `.hrl` increases coupling and makes structural changes expensive.

- **Use types in specs, not raw record syntax.** Define a `-type` for your record and reference that in `-spec` declarations. Exported types support documentation; opaque types enforce encapsulation.

- **Always add type definitions to record fields.** Every field in a record must have an explicit type annotation. Records define data structures; field types are a core part of that definition.

### Misc

- **Write `-spec` for all exported functions; for unexported functions when it adds documentation value.** Specs enable Dialyzer analysis and communicate the function's contract. Semantically meaningful type names make Dialyzer output actionable.

- **Use `-callback` attributes instead of `behaviour_info/1`.** Unless targeting R14 or lower, define behaviour callbacks with `-callback`. `behaviour_info/1` is deprecated.

- **Messages must be atoms or tagged tuples with a human-readable atom in element 1.** `{set_worker_pid, Pid}` not `{Pid}`. Tagged messages are self-documenting in logs and debuggers, and prevent different message types from being confused with each other.

- **Guard against nested header inclusion with `-ifndef`.** When a `.hrl` file may be included transitively, wrap it with `-ifndef(HEADER_FILE_HRL). ... -endif.` Unguarded nested includes cause duplication and hard-to-diagnose conflicts.

- **No `-type` definitions in `.hrl` files.** Type names are not namespaced in header files, leading to clashes between projects. Define types in their owning module, export with `-export_type/1`, and reference as `module:type()`.

- **Do not use `-import`.** Imported functions look like local functions. The module name is part of a function's identity — removing it makes code harder to read and harder to trace during debugging.

- **Do not use `-compile(export_all)`.** Export only the functions that form the module's documented external API. `export_all` prevents encapsulation, hides the true API surface, and makes aggressive internal refactoring risky.

- **Encapsulate all OTP server interactions in API functions.** Never call `gen_server:call/cast` across module boundaries with a raw message. Every `handle_call`/`handle_cast`/`handle_info` clause must have a corresponding public API function in the same module. This makes call sites findable by searching for the API function, not for arbitrary `gen_server:call` invocations.

- **No `io:format` or debug log calls in production code.** `io:format`, `ct:pal`, and debug-level logger calls must not appear in `src/` modules in a production release. They degrade performance and clutter logs with context that is meaningless outside the original debugging session.

- **Do not use `case catch`.** Use `try ... of ... catch` instead. `case catch` conflates successful results with caught errors in the same clause set, which obscures the happy path.

### Tools

- **Lock dependency versions.** In `rebar.config` or `erlang.mk`, pin dependencies to a specific tag or commit hash, never to `main` or `master`. An unlocked dependency can break your build silently when the upstream changes.

- **Log all errors loudly with stack traces.** When an error or exception is caught and handled, always write a log line that includes the stack trace. Silent error handling hides failures from anyone monitoring the system.

- **Use logging levels correctly.** `debug` for verbose low-level traces; `info` for normal system lifecycle events; `notice` for meaningful but expected events (supervisor start/stop); `warning` for handled anomalies; `error` for unexpected failures — always log the stack trace; `critical` for partial system crash requiring human action.

- **Use HTTPS for all dependency URLs.** Specify dependency repositories using `https://` in both `rebar.config` and `erlang.mk` Makefiles. HTTPS is GitHub's recommended protocol and works reliably in CI environments without SSH key setup.

- **When using mixer, list all mixed-in functions explicitly.** Do not implicitly include every function from a module. Explicit listing makes the module's full API visible without jumping between files.

## Suggestions

These are strong recommendations that do not automatically warrant PR rejection, but should inform every design decision.

- **Prefer pattern matching over equality checks.** Instead of `if X =:= foo ->`, match on `foo` directly in a function head or `case` clause. Pattern matching is more declarative, more flexible to extend, and gives you a binding of the matched value for free.

- **Prefer higher-order functions and list comprehensions over manual recursion.** `lists:foldl`, `lists:map`, and `[F(X) || X <- List]` are predictable and immediately recognizable. A hand-written recursive function requires scrutiny to verify its base case and termination.

- **CamelCase for variables; underscores for atoms, functions, and modules.** This is the OTP convention and makes variables visually distinct from all other identifiers at a glance.

- **Prefer short but meaningful variable names.** `UserId` over `TheUserIdentifierForThisRequest`. Shorter names reduce line length and make the structure of the code visible.

- **Use three comment levels: `%%%` for module comments, `%%` for function comments, `%` for inline code comments.** Consistent comment levels make it easy to search for specific kinds of documentation and clearly signal what a comment describes.

- **Keep functions to 12 expressions or fewer.** A function that does one thing fits on one screen and can be understood and tested in isolation. If you need more expressions, extract helpers.

- **Use behaviours to encapsulate reusable patterns.** Define `-callback` attributes for any pattern that multiple modules implement. Behaviours are Erlang's mechanism for polymorphism and serve as machine-checkable documentation of a module's contract.

- **Validate inputs on the client side, not inside the server.** A `gen_server` that validates its own inputs crashes on bad data. A function that validates before calling the server fails fast at the call site with a clear error, avoiding a roundtrip and a server crash.

- **Avoid unnecessary calls to `length/1`.** To check whether a list has at least one element, match `[_ | _]` rather than calling `length(List) > 0`. `length/1` traverses the entire list; pattern matching is O(1).

- **Extract self-contained functionality into independent applications.** If a group of modules is logically independent of your main application's purpose, put it in a separate OTP application. Consider open-sourcing it. Do not extract functionality that is tightly coupled to a single project.

- **Use the facade pattern for libraries.** Expose a single top-level module with the functions that cover the common use cases. Reduce the surface a new user must navigate to get started.

- **Export custom types used in exported function specs.** Define types with `-type`, export them with `-export_type`, and reference them in `-spec` declarations. This documents the API and enables Dialyzer to enforce encapsulation with `-opaque`.