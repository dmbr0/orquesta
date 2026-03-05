# elixir-style.md

Community-driven Elixir style conventions from https://github.com/christopheradams/elixir_style_guide. Rules in the Formatting section are enforced automatically by `mix format` — run it on every file. Rules in all other sections require code review.

## Guidelines

### Formatting (enforced by `mix format`)

- **No trailing whitespace; end every file with a newline.** Use Unix line endings. If the repo is shared with Windows users, set `git config --global core.autocrlf true`.

- **Lines are at most 98 characters.** Configure `:line_length` in `.formatter.exs` if a different project limit is agreed upon.

- **Spaces around operators, commas, colons, and semicolons. No spaces inside matched pairs.** `sum = 1 + 2`, `{a, b} = {2, 3}`, `Enum.map(list, fn x -> x end)`. Do not add spaces after unary operators or around the range operator: `-1`, `^pinned`, `1..10`.

- **Separate `def` blocks with blank lines.** Use blank lines inside a longer function to break it into logical paragraphs. Do not put a blank line immediately after `defmodule`.

- **When a `def` head and its `do:` clause are too long to fit on one line, put `do:` on the next line indented one level.** When `do:` starts on its own line, treat it as a multiline function and separate it from other clauses with a blank line.

- **Add a blank line after a multiline assignment** to visually signal that the binding is complete before the next expression.

- **Multiline lists, maps, and structs: one element per line, brackets on their own lines, elements indented one level.** When assigning a multiline collection, keep the opening bracket on the same line as the assignment operator.

- **Multiline `case`/`cond`: if any clause needs more than one line, use multiline syntax for all clauses and separate each with a blank line.**

- **Place comments on the line above the code they describe, never at the end of the line.** Use a single space between `#` and the comment text.

- **Align successive `with` clauses; put `do:` on a new line aligned with the clauses.** If the `do` block has more than one line or an `else` option, use multiline `with ... do ... else ... end` syntax.

- **Always include parentheses in pipeline steps.** `some_string |> String.downcase() |> String.trim()`, not `|> String.downcase`.

- **No space between a function name and its opening parenthesis.** `f(3)`, not `f (3)`.

- **Use parentheses in function calls, especially inside pipelines.** `2 |> rem(3) |> g()`. Omitting them inside a pipeline changes precedence silently.

- **Omit square brackets from keyword lists when they are optional** (i.e., the keyword list is the last argument): `some_function(foo, a: "baz")` not `some_function(foo, [a: "baz"])`.

### Expressions

- **Group single-line `def` clauses for the same function together; separate multiline `def` clauses with a blank line.** If the function has more than one multiline clause, do not mix in single-line `do:` clauses — convert all clauses to the multiline form.

- **Use the pipe operator to chain two or more function calls.** Start pipelines with a bare variable, not a function call. Avoid single-step pipelines — call the function directly instead.

- **Use parentheses on `def` when the function takes arguments; omit them when it takes none.** `def foo(a, b) do` / `def foo do`.

- **Use `do:` inline for single-line `if`/`unless`.** Never use `unless` with an `else` branch — rewrite it as an `if` with the positive case first.

- **Use `true` as the catch-all last condition in `cond`, not `:else` or `:otherwise`.**

- **Call zero-arity functions with parentheses** to distinguish them from variables: `do_stuff()`, not `do_stuff`. The compiler warns about this ambiguity since Elixir 1.4.

### Naming

- **`snake_case` for atoms, functions, and variables; `CamelCase` for modules.** Keep acronyms uppercase in module names: `SomeXML`, not `SomeXml`.

- **Functions returning a boolean take a trailing `?`.** `cool?(var)`, `valid?(input)`.

- **Guard-safe boolean checks use an `is_` prefix.** `defguard is_cool(var) when var == "cool"`.

- **Private functions must not share a name with a public function.** The `def name` / `defp do_name` pattern is discouraged — find a more descriptive name that reflects what differentiates the private helper.

### Comments

- **Comments longer than one word are capitalized and use standard punctuation.** One space after periods. Keep comment lines to 100 characters.

- **Annotation keywords are uppercase, followed by a colon and a space:** `# TODO: Deprecate in v1.5.` Use standard keywords consistently: `TODO` for missing features, `FIXME` for broken code, `OPTIMIZE` for performance issues, `HACK` for code smells to be refactored, `REVIEW` for anything that needs verification. Document any custom keywords in the project README.

### Modules

- **One module per file**, unless the module is only used internally by another module (e.g., a test helper).

- **File names use `snake_case`; module names use `CamelCase`.** `some_module.ex` contains `defmodule SomeModule`. Each level of module nesting maps to a directory level.

- **Order module contents strictly:** `@moduledoc`, `@behaviour`, `use`, `import`, `require`, `alias`, `@module_attribute`, `defstruct`, `@type`, `@callback`, `@macrocallback`, `@optional_callbacks`, then function definitions. Separate each group with a blank line. Sort terms within each group alphabetically.

- **Use `__MODULE__` when a module refers to itself**, so self-references survive renames without edits. Alias it locally for readability: `alias __MODULE__, as: SomeModule`.

- **Do not repeat namespace fragments in module names.** `Todo.Item`, not `Todo.Todo`.

### Documentation

- **Every module must have a `@moduledoc` immediately after `defmodule`.** Use `@moduledoc false` if the module is intentionally undocumented. Separate `@moduledoc` from the following directives with a blank line.

- **Write `@doc` and `@moduledoc` in heredocs with Markdown.** Use `## Examples` sections with doctests formatted for ExDoc.

### Typespecs

- **Place `@typedoc` and `@type` pairs together at the top of the module**, separated from each other by a blank line.

- **Break long union types across lines**, with each alternative on its own line indented one level past the type name, prefixed with `|`.

- **Name the primary type for a module `t`.** The main struct type should be `@type t :: %__MODULE__{...}`.

- **Place `@spec` immediately before its `def`, after `@doc`, with no blank line between `@spec` and `def`.**

### Structs

- **List nil-defaulting fields as atoms first, then keyword fields with non-nil defaults.** `defstruct [:name, :params, active: true]`.

- **Omit square brackets in `defstruct` when the argument is a pure keyword list.** Brackets are required only when the list contains bare atoms alongside keyword pairs.

- **Multiline struct definitions align field values**, or use the multiline list format with brackets when bare atoms are present.

### Exceptions

- **Exception module names end with `Error`.** `BadHTTPCodeError`, not `BadHTTPCode` or `BadHTTPCodeException`.

- **Error messages passed to `raise` are lowercase with no trailing punctuation.** `raise ArgumentError, "this is not valid"`.

### Collections

- **Always use keyword list syntax for keyword lists.** `[a: "baz", b: "qux"]`, not `[{:a, "baz"}, {:b, "qux"}]`.

- **Use atom-key shorthand for maps when all keys are atoms.** `%{a: 1, b: 2}`. Use the arrow `=>` syntax when any key is not an atom, and apply it consistently to all keys in that map: `%{:a => 1, "c" => 0}`.

### Strings

- **Match on string prefixes using the concatenator, not binary pattern syntax.** `"my" <> _rest = "my string"`, not `<<"my"::utf8, _rest::bytes>> = "my string"`.

### Metaprogramming

- **Avoid metaprogramming unless it is genuinely necessary.** Macros that could be plain functions should be plain functions. Needless metaprogramming obscures intent, breaks tooling, and complicates debugging.

### Testing

- **In ExUnit assertions, put the expression under test on the left and the expected value on the right**, unless the assertion is a pattern match. `assert actual_function(1) == true`, not `assert true == actual_function(1)`. Pattern match assertions use `=`: `assert {:ok, expected} = actual_function(3)`.