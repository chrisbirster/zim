# Hondo styling decision

Status: selected for M4

Hondo uses **terminal-native typed style objects** as its styling model, with small Hondo-owned helpers for named styles, tokens, and composition.

The public primitives are:

```ts
const tokens = defineTokens({
  accent: 'bright-cyan' as const,
  spacing: 2,
});

const styles = defineStyles({
  panel: {
    padding: tokens.spacing,
    foreground: tokens.accent,
  },
  selected: {
    reverse: true,
    bold: true,
  },
});

const style = composeStyles(
  styles.panel,
  selected() && styles.selected,
  { width: width() },
);
```

`composeStyles` accepts styles, false/null/undefined conditional values, and nested arrays. Properties resolve last-wins. The result is still a plain `HondoStyle` object and is the same value serialized through the Hondo host boundary.

## Invariant

Hondo does not embed a CSS engine. Styling remains terminal-native and the Zig renderer remains authoritative for layout and painting.

## Evidence

M4 compared three executable spikes against the same current Hondo component model.

| Dimension | StyleX authoring adapter | Modifier composition | Hondo-native typed objects |
| --- | --- | --- | --- |
| TypeScript ergonomics | Excellent familiar `create`/`props` shape | Readable for short chains; noisy for larger layouts | Excellent; existing component props already use this type |
| Static extraction potential | High at the authoring layer, but normal StyleX extraction targets CSS | Low-to-medium; function calls/closures obscure values | High enough for a future Hondo compiler to recognize `defineStyles` literals |
| Dynamic/reactive styles | Requires a Hondo-specific escape hatch once values are not CSS variables | Good, but produces runtime modifier calls | Excellent; reactive getters can compose plain values directly |
| Serialization cost | Adapter must reconstruct Hondo values after StyleX-style resolution | Multiple intermediate objects as modifiers apply | One merged plain object; no representation conversion |
| Zig representation | Requires translation from a CSS-oriented model | Requires translation from modifier semantics | Direct correspondence with native layout/paint fields |
| Themes/tokens | Strong conceptually, but StyleX themes ultimately feed CSS output | Requires another modifier/token layer | Plain typed tokens feed native values directly |
| Variants | Strong conditional composition API | Natural but function-heavy | Conditional `composeStyles` inputs are simple and typed |
| Composability | Strong | Strong for small sets; order becomes less obvious in long chains | Strong; arrays, conditionals, named styles, and last-wins semantics |

## StyleX spike

StyleX was evaluated as an authoring influence, not as a runtime dependency. The current StyleX compiler is designed to extract JavaScript style declarations into optimized CSS artifacts. Hondo has no CSS target, DOM, or browser cascade.

A spike proved that Hondo can mimic the attractive `create` + `props` authoring shape while returning `HondoStyle`. That also exposed the problem: once CSS extraction is removed, Hondo would be maintaining a StyleX-compatible dialect and compiler surface while receiving little of StyleX's core output machinery.

Rejected as the primary model because:

- actual StyleX extraction produces CSS rather than Hondo's terminal style IR;
- a custom compiler target would couple Hondo to StyleX AST/compiler behavior;
- dynamic terminal values still need Hondo-native representation;
- CSS concepts such as selectors, media queries, pseudo states, cascade, and browser property validation are not Hondo primitives;
- Hondo would carry significant compatibility surface for an API it only partially uses.

Useful ideas retained: named immutable style maps, typed tokens, last-wins composition, and future static extraction.

## Modifier-composition spike

A second spike modeled styling as modifier functions such as `padding(2)`, `foreground('cyan')`, and `when(active, bold())`.

Rejected as the primary model because:

- each modifier is a runtime function/closure;
- applying a chain creates repeated intermediate objects unless a second specialized representation is introduced;
- large components become more verbose than object literals;
- static extraction and serialization would require understanding modifier call semantics;
- Hondo would now own two representations: modifier programs and the native style object they eventually produce.

Modifiers may still be appropriate as application-level helpers, but they are not the framework style representation.

## Selected model: Hondo-native typed style objects

The existing `HondoStyle` shape already matches the native renderer's vocabulary: dimensions, flow/overlay positioning, padding/gap/alignment, clipping, colors, and terminal text attributes. M3-M5 also proved that reactive component code can update this shape directly without introducing a CSS abstraction.

M4 therefore formalizes that model and adds only:

- `defineStyles()` for typed named style maps and a future static-extraction marker;
- `defineTokens()` for typed theme/design values without imposing a theme runtime;
- `composeStyles()` for conditional/nested composition with last-wins resolution.

### Themes and tokens

Tokens are ordinary typed values. Applications can create multiple token sets and choose them reactively:

```ts
const dark = defineTokens({ foreground: 'white' as const, background: 'black' as const });
const light = defineTokens({ foreground: 'black' as const, background: 'white' as const });

const theme = () => darkMode() ? dark : light;
const style = () => ({
  foreground: theme().foreground,
  background: theme().background,
});
```

There is no hidden global theme registry and no CSS-variable layer.

### Variants

Variants are ordinary named styles selected through composition:

```ts
composeStyles(
  styles.button,
  intent === 'danger' && styles.danger,
  disabled && styles.disabled,
);
```

This keeps variant state in Solid/application logic rather than creating another styling language.

### Static extraction

Static extraction is deliberately optional. `defineStyles({...})` gives a future Hondo build transform a stable marker for extracting constant style maps into a compact native table if profiling demonstrates that serialization is significant. Hondo does not need that compiler in order for the API to work correctly.

## Decision consequences

- No CSS engine.
- No StyleX runtime/compiler dependency in Hondo core.
- No framework-level modifier DSL.
- Dynamic/reactive styling remains first-class.
- Zig continues to receive terminal-native style fields.
- The public styling API stays small and can be statically optimized later without changing component authoring.
