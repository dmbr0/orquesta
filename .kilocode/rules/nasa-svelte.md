# NASA Power of 10 — Svelte Adaptation

Adapted from Gerard J. Holzmann's *Power of 10: Rules for Developing Safety-Critical Code* (NASA/JPL, 2006) for Svelte application development. The original rules target C and aim to make code statically verifiable and free of hidden failure modes. This adaptation maps each principle onto Svelte's reactivity model, component architecture, and TypeScript toolchain.

---

## Rule 1 — No Recursive Components or Circular Reactivity

**Original:** Avoid `goto`, `setjmp`/`longjmp`, and recursive functions.

**Svelte adaptation:** Never render a component that directly or indirectly renders itself without a strict depth-limiting guard. Never create `$derived` expressions or `$effect` callbacks that form a cycle — where A depends on B which depends on A.

```svelte
<!-- ❌ Non-compliant: component renders itself with no hard depth limit -->
<script>
  let { depth } = $props<{ depth: number }>();
</script>
<TreeNode />  <!-- same component, unbounded -->

<!-- ✅ Compliant: explicit depth guard that a static reader can verify -->
<script>
  let { depth, maxDepth = 5 } = $props<{ depth: number; maxDepth?: number }>();
</script>
{#if depth < maxDepth}
  <TreeNode depth={depth + 1} {maxDepth} />
{/if}
```

```svelte
<!-- ❌ Non-compliant: $effect that writes state it also reads — cycles -->
<script>
  let a = $state(0);
  let b = $state(0);
  $effect(() => { a = b + 1; }); // reads b, writes a
  $effect(() => { b = a + 1; }); // reads a, writes b — infinite loop
</script>

<!-- ✅ Compliant: one-directional derivation with $derived -->
<script>
  let base = $state(0);
  let derived = $derived(base + 1);
</script>
```

**Why it matters:** Svelte's compiler can optimise linear reactive graphs but cannot statically prove termination of cyclic ones. Circular `$effect` writes cause infinite update loops at runtime; recursive components without guards can exhaust the call stack silently.

---

## Rule 2 — Reactive Loops Must Have a Statically Verifiable Bound

**Original:** Every loop must have a fixed, compile-time checkable upper bound.

**Svelte adaptation:** Every `{#each}` block and every imperative `for`/`while` loop must iterate over a collection whose maximum size is declared as a named constant or enforced by a type. Stores and derived values that accumulate data must cap growth at a known limit.

```svelte
<!-- ❌ Non-compliant: iterates over an unbounded, ever-growing array -->
<script>
  let log: string[] = [];
  function append(msg: string) { log = [...log, msg]; }
</script>
{#each log as entry}<p>{entry}</p>{/each}

<!-- ✅ Compliant: bounded by a declared constant -->
<script>
  const MAX_LOG_ENTRIES = 200;
  let log: string[] = [];
  function append(msg: string) {
    log = [...log, msg].slice(-MAX_LOG_ENTRIES);
  }
</script>
{#each log as entry}<p>{entry}</p>{/each}
```

```ts
// ❌ Non-compliant: unbounded while loop in a store updater
while (!queue.isEmpty()) { process(queue.pop()); }

// ✅ Compliant: loop with explicit iteration ceiling
const MAX_ITERATIONS = 1000;
let i = 0;
while (!queue.isEmpty() && i < MAX_ITERATIONS) {
  process(queue.pop());
  i++;
}
```

**Why it matters:** An unbounded reactive list will silently consume memory and slow the DOM. An unbounded imperative loop inside a reactive context will block the main thread. Declaring the bound makes the worst-case resource cost visible to a reviewer without running the code.

---

## Rule 3 — No Uncontrolled Dynamic Component or Store Creation at Runtime

**Original:** Do not use dynamic memory allocation (`malloc`/`free`) after initialisation.

**Svelte adaptation:** Do not create `$state` objects, Svelte stores (`writable`/`derived`), or dynamically import and mount unknown components inside event handlers or reactive `$effect` callbacks that run continuously. All shared state and dynamically-imported modules must be created at module initialisation time or under a one-time setup guard.

```ts
// ❌ Non-compliant: creates a new store on every button click
function handleClick() {
  const temp = writable(0); // leaks; never cleaned up
  temp.set(42);
}

// ✅ Compliant: store created once at module scope
const counter = writable(0);
function handleClick() {
  counter.update(n => n + 1);
}
```

```svelte
<!-- ❌ Non-compliant: dynamic import inside a reactive effect that re-runs freely -->
<script>
  let name = $state('alpha');
  let Widget = $state(null);
  $effect(() => {
    import(`./widgets/${name}.svelte`).then(m => (Widget = m.default));
  });
</script>

<!-- ✅ Compliant: import map declared at initialisation, keyed lookup at runtime -->
<script>
  import Alpha from './widgets/Alpha.svelte';
  import Beta  from './widgets/Beta.svelte';
  const WIDGETS = { alpha: Alpha, beta: Beta };

  let name = $state('alpha');
  let Widget = $derived(WIDGETS[name] ?? null);
</script>
```

**Why it matters:** Stores and async module loads spawned inside reactive callbacks but never destroyed are the Svelte equivalent of `malloc` without `free`. They cause memory pressure and make the component lifecycle impossible to audit.

---

## Rule 4 — Components and Functions Must Fit on One Screen (~60 Lines)

**Original:** No function body longer than roughly 60 lines (one printed page).

**Svelte adaptation:** The `<script>` block of a component should not exceed 60 lines of logic. Any single TypeScript/JavaScript function inside or outside a component should not exceed 60 lines. Extract larger concerns into dedicated modules, helper functions, or child components.

```svelte
<!-- ❌ Non-compliant: 150-line <script> mixing fetch, state, and formatting -->
<script>
  // ... 150 lines of tangled logic ...
</script>

<!-- ✅ Compliant: thin orchestration script; details live in dedicated modules -->
<script lang="ts">
  import { loadUser }       from '$lib/api/user';
  import { formatProfile }  from '$lib/format/profile';
  import ProfileCard        from './ProfileCard.svelte';
  import ErrorBanner        from './ErrorBanner.svelte';

  export let userId: string;

  let profile = loadUser(userId);
</script>

{#await profile}
  <p>Loading…</p>
{:then data}
  <ProfileCard user={formatProfile(data)} />
{:catch err}
  <ErrorBanner message={err.message} />
{/await}
```

**Why it matters:** A reviewer cannot hold a 200-line component in working memory long enough to spot subtle reactive bugs. Small components expose their full contract at a glance and make the reactive dependency graph tractable for both humans and tooling.

---

## Rule 5 — Every Component and Function Must Have Defensive Checks

**Original:** Use at least two `assert` statements per function to validate invariants.

**Svelte adaptation:** Every exported prop must have a runtime guard at component entry. Every function that accepts external data must validate its inputs before use. Use TypeScript strict types as the first layer; add explicit runtime guards as the second.

```svelte
<!-- ❌ Non-compliant: no validation; crashes silently on bad input -->
<script lang="ts">
  let { items, limit } = $props<{ items: string[]; limit: number }>();
</script>
{#each items.slice(0, limit) as item}<li>{item}</li>{/each}

<!-- ✅ Compliant: two defensive checks mirror the two-assert NASA requirement -->
<script lang="ts">
  let { items, limit } = $props<{ items: string[]; limit: number }>();

  // Guard 1: structural validity
  if (!Array.isArray(items)) throw new TypeError('items must be an array');
  // Guard 2: numeric range
  if (limit < 1 || limit > 500) throw new RangeError('limit must be 1–500');

  let safeItems = $derived(items.slice(0, limit));
</script>
{#each safeItems as item}<li>{item}</li>{/each}
```

```ts
// ✅ Compliant utility function with two guards
function paginate<T>(data: T[], page: number, pageSize: number): T[] {
  if (data.length === 0) return [];                         // Guard 1
  if (page < 0 || pageSize < 1) throw new RangeError(      // Guard 2
    `Invalid pagination params: page=${page}, pageSize=${pageSize}`
  );
  return data.slice(page * pageSize, (page + 1) * pageSize);
}
```

**Why it matters:** TypeScript types disappear at runtime. Without explicit guards, malformed server responses or incorrect parent props produce confusing cascading failures deep in the component tree rather than clear, localised errors at the boundary.

---

## Rule 6 — Declare State at the Narrowest Possible Scope

**Original:** Restrict variable scope to the smallest enclosing block; minimise globals.

**Svelte adaptation:** Prefer local component `let` declarations over module-level variables. Prefer module-level variables over context-provided values. Prefer context over Svelte stores. Reserve stores for application-wide state that genuinely needs to be shared across unrelated subtrees.

```ts
// ❌ Non-compliant: top-level store for state that only one component uses
// stores.ts
export const modalOpen = writable(false);

// ✅ Compliant: local $state inside the component that owns it
// Modal.svelte
let open = $state(false);
```

```svelte
<!-- ✅ Compliant: use context for subtree-shared state, not a global store -->
<script lang="ts">
  import { setContext } from 'svelte';

  const theme = $state<'light' | 'dark'>('light');
  setContext('theme', { get value() { return theme; } });
</script>
```

**Scope decision ladder (most to least preferred):**

1. Local `$state` inside the component
2. Module-level variable in a `.svelte.ts` utility file imported where needed
3. Svelte `setContext` / `getContext` for a component subtree
4. `writable` store for cross-tree application state
5. *(Avoid)* Module-level mutable variables in `<script module>`

**Why it matters:** Every global store is a shared mutable variable accessible to any component in the application. Unnecessary globals make data-flow impossible to audit, cause accidental coupling, and complicate testing.

---

## Rule 7 — Handle All Promise Results and Validate All Incoming Data

**Original:** Every non-`void` return value must be checked; every function must validate its arguments.

**Svelte adaptation:** Every `fetch`, store subscription side-effect, and async action must handle both the success and error paths explicitly. No `await` expression may appear without an accompanying `catch` or surrounding `try/catch`. Incoming data from external APIs must be validated before it enters the reactive system.

```ts
// ❌ Non-compliant: unhandled rejection silently breaks the UI
async function loadData() {
  const res  = await fetch('/api/data');
  const json = await res.json();
  items = json.items; // crashes if json lacks `items`
}

// ✅ Compliant: both HTTP error and shape error are handled
async function loadData(): Promise<void> {
  try {
    const res = await fetch('/api/data');
    if (!res.ok) throw new Error(`HTTP ${res.status}`);

    const json = await res.json();
    if (!Array.isArray(json.items)) throw new TypeError('Unexpected shape');

    items = json.items;
  } catch (err) {
    errorMessage = err instanceof Error ? err.message : 'Unknown error';
  }
}
```

```svelte
<!-- ✅ Compliant: {#await} forces explicit handling of loading and error states -->
{#await loadData()}
  <Spinner />
{:then data}
  <DataView {data} />
{:catch err}
  <ErrorView message={err.message} />
{/await}
```

**Why it matters:** Svelte's reactivity system propagates values silently. An unhandled rejection or a silently `undefined` field will not throw an obvious error — it will produce a blank UI or corrupt downstream state in ways that are hard to trace.

---

## Rule 8 — Keep Preprocessors, Macros, and Meta-Programming Simple

**Original:** Use the preprocessor only for file inclusion and simple macros; no token pasting or conditional compilation tricks.

**Svelte adaptation:** Svelte preprocessors (`svelte-preprocess`, `mdsvex`, custom `markup`/`script`/`style` transformers) must do one clear job. Avoid layering multiple preprocessors that mutate the same region of a file. Avoid code generation patterns that produce Svelte components programmatically from templates or string interpolation.

```ts
// ❌ Non-compliant: preprocessor chain where two plugins both transform <script>
// svelte.config.js
preprocessors: [
  markdownToHtml(),   // transforms markup
  autoImport(),       // injects into <script> — conflicts with next
  componentAliases(), // also injects into <script>
]

// ✅ Compliant: each preprocessor owns one clearly distinct concern
preprocessors: [
  vitePreprocess(),           // TypeScript/PostCSS — single responsibility
]
// Auto-imports handled by Vite plugin, not a Svelte preprocessor
```

```ts
// ❌ Non-compliant: generating component source as a string at build time
const src = `<script>export let x = ${defaultValue};</script><p>{x}</p>`;
fs.writeFileSync('Gen.svelte', src);

// ✅ Compliant: use runtime props with defaults instead
// Gen.svelte
export let x: number = DEFAULT_VALUE;
```

**Why it matters:** Complex preprocessor stacks are the Svelte equivalent of deeply nested C macros. They obscure the actual source that the compiler sees, making errors cryptic and making it impossible to reason about a file by reading it directly.

---

## Rule 9 — Keep Reactive References Shallow; Avoid Deeply Nested Store Subscriptions

**Original:** Restrict pointer indirection to one level; no function pointers.

**Svelte adaptation:** Avoid stores-of-stores, `$derived` chains deeper than two levels, and `$effect` callbacks that write to state which feeds further derivations. Every piece of UI state should be traceable to its source within two hops.

```ts
// ❌ Non-compliant: three levels of $derived indirection
const raw      = $state<RawData[]>([]);
const filtered = $derived(raw.filter(isValid));
const sorted   = $derived(filtered.toSorted(byDate));
const paged    = $derived(sorted.slice(page * 10, (page + 1) * 10));
// 'paged' is three derivations from 'raw'; debugging requires tracing all four

// ✅ Compliant: flatten into a single $derived step
const VIEW_PAGE_SIZE = 10;
const displayItems = $derived(
  raw.filter(isValid)
     .toSorted(byDate)
     .slice(page * VIEW_PAGE_SIZE, (page + 1) * VIEW_PAGE_SIZE)
);
```

```ts
// ❌ Non-compliant: store of stores (double indirection on subscription)
const activeStore = writable<Writable<string>>(writable(''));
// reader must follow two dereferences to get a value

// ✅ Compliant: select a value, not a store
const OPTIONS = { a: writable('alpha'), b: writable('beta') } as const;
const activeKey = writable<keyof typeof OPTIONS>('a');
$: value = $OPTIONS[$activeKey];  // one reactive lookup, clear ownership
```

**Why it matters:** Each additional derivation layer is an indirection the reader must mentally dereference. Deep `$derived` chains are the functional equivalent of `int ***ptr` — technically valid but impossible to audit quickly or debug confidently.

---

## Rule 10 — Zero Warnings from `svelte-check`, TypeScript, and the Linter

**Original:** Compile with all warnings enabled; no release with outstanding warnings.

**Svelte adaptation:** Every pull request must pass `svelte-check --tsconfig ./tsconfig.json` and `tsc --noEmit` with zero errors and zero warnings. ESLint (or Biome) must report zero issues under the project's configured ruleset. Unused variables, missing `await`, unhandled accessibility attributes, and missing prop types are treated as blocking errors, not advisory hints.

```json
// tsconfig.json — ✅ Compliant: strict mode enabled
{
  "compilerOptions": {
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noImplicitReturns": true,
    "exactOptionalPropertyTypes": true
  }
}
```

```json
// package.json — ✅ Compliant: CI check blocks merge on any warning
{
  "scripts": {
    "check": "svelte-check --tsconfig ./tsconfig.json --fail-on-warnings",
    "lint":  "eslint . --max-warnings 0"
  }
}
```

```svelte
<!-- ❌ Non-compliant: reactive variable declared but never used in template -->
<script lang="ts">
  const unused = 42; // TypeScript noUnusedLocals will flag this
</script>

<!-- ✅ Compliant: every declaration is consumed -->
<script lang="ts">
  let { count } = $props<{ count: number }>();
  let doubled = $derived(count * 2);
</script>
<p>{doubled}</p>
```

**Why it matters:** Svelte, TypeScript, and accessibility warnings are not style suggestions — they identify real categories of bugs (incorrect prop types, missing `await`, inaccessible interactive elements). A codebase that habitually silences or ignores warnings loses its early-warning system entirely.

---

## Summary Table

| # | NASA Rule (C)                          | Svelte Adaptation                                             |
|---|----------------------------------------|---------------------------------------------------------------|
| 1 | No goto / recursion                    | No recursive components; no cyclic `$effect` / `$derived` updates |
| 2 | Fixed loop bounds                      | `{#each}` over bounded collections; loops with explicit ceilings |
| 3 | No runtime dynamic memory              | No store/component creation inside reactive or event handlers |
| 4 | Functions ≤ 60 lines                   | `<script>` ≤ 60 lines; extract to modules and child components |
| 5 | ≥ 2 asserts per function               | Two runtime guards per component/function on external inputs  |
| 6 | Minimal variable scope                 | State at narrowest scope; stores only for cross-tree globals  |
| 7 | Check all return values                | Handle every Promise; validate every API response shape       |
| 8 | Simple preprocessor only               | Single-responsibility preprocessors; no string-template codegen |
| 9 | Single-level pointers only             | Shallow `$derived` chains (≤2 levels); no stores-of-stores    |
|10 | Zero compiler warnings                 | Zero `svelte-check`, `tsc`, and linter warnings in CI         |