import type { HondoColor, HondoStyle } from './components.js';
import { composeStyles, defineStyles, type HondoStyleInput } from './styling.js';

/**
 * Experimental StyleX-shaped authoring adapter.
 *
 * This intentionally does not import StyleX or emit CSS. It tests whether the
 * familiar `create` + `props` authoring shape is useful when the output remains
 * a native HondoStyle object.
 */
export const stylexAuthoringSpike = {
  create<const T extends Record<string, HondoStyle>>(styles: T): Readonly<T> {
    return defineStyles(styles);
  },
  props(...styles: readonly HondoStyleInput[]): { style: HondoStyle | undefined } {
    return { style: composeStyles(...styles) };
  },
};

export type HondoStyleModifier = (style: HondoStyle) => HondoStyle;

export const modifierSpike = {
  padding(value: number): HondoStyleModifier {
    return style => ({ ...style, padding: value });
  },
  gap(value: number): HondoStyleModifier {
    return style => ({ ...style, gap: value });
  },
  foreground(value: HondoColor): HondoStyleModifier {
    return style => ({ ...style, foreground: value });
  },
  background(value: HondoColor): HondoStyleModifier {
    return style => ({ ...style, background: value });
  },
  bold(enabled = true): HondoStyleModifier {
    return style => ({ ...style, bold: enabled });
  },
  grow(value = 1): HondoStyleModifier {
    return style => ({ ...style, grow: value });
  },
  when(condition: boolean, modifier: HondoStyleModifier): HondoStyleModifier {
    return condition ? modifier : style => style;
  },
};

export function applyModifiers(
  base: HondoStyle = {},
  ...modifiers: readonly HondoStyleModifier[]
): HondoStyle {
  return modifiers.reduce((style, modifier) => modifier(style), base);
}
