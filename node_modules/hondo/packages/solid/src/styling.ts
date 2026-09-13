import type { HondoStyle } from './components.js';

export type HondoStyleInput =
  | HondoStyle
  | false
  | null
  | undefined
  | readonly HondoStyleInput[];

export function defineStyles<const T extends Record<string, HondoStyle>>(
  styles: T,
): Readonly<T> {
  return Object.freeze(styles);
}

export function defineTokens<const T extends Record<string, unknown>>(
  tokens: T,
): Readonly<T> {
  return Object.freeze(tokens);
}

export function composeStyles(
  ...inputs: readonly HondoStyleInput[]
): HondoStyle | undefined {
  let result: HondoStyle | undefined;

  const merge = (input: HondoStyleInput): void => {
    if (!input) return;
    if (Array.isArray(input)) {
      for (const nested of input) merge(nested);
      return;
    }
    result = { ...(result ?? {}), ...(input as HondoStyle) };
  };

  for (const input of inputs) merge(input);
  return result;
}
