import { describe, expect, it } from 'vitest';
import { composeStyles, defineStyles, defineTokens } from './styling.js';
import { applyModifiers, modifierSpike, stylexAuthoringSpike } from './styling_spikes.js';

describe('Hondo-native style objects', () => {
  it('defines named styles and composes static, conditional, nested, and dynamic inputs', () => {
    const tokens = defineTokens({ accent: 'bright-cyan' as const, spacing: 2 });
    const styles = defineStyles({
      root: { padding: tokens.spacing, foreground: tokens.accent },
      selected: { reverse: true, bold: true },
      compact: { padding: 1 },
    });

    const selected = true;
    const width = 24;
    expect(
      composeStyles(
        styles.root,
        selected && styles.selected,
        [false, null, undefined, styles.compact],
        { width },
      ),
    ).toEqual({
      padding: 1,
      foreground: 'bright-cyan',
      reverse: true,
      bold: true,
      width: 24,
    });
  });

  it('uses last-wins property resolution and leaves no runtime wrapper', () => {
    const result = composeStyles(
      { foreground: 'red', padding: 1 },
      { foreground: 'green' },
    );
    expect(result).toEqual({ foreground: 'green', padding: 1 });
    expect(Object.keys(result ?? {})).toEqual(['foreground', 'padding']);
  });
});

describe('StyleX authoring spike', () => {
  it('can preserve create/props ergonomics while producing terminal-native style data', () => {
    const styles = stylexAuthoringSpike.create({
      root: { padding: 2, foreground: 'cyan' },
      active: { bold: true, foreground: 'bright-cyan' },
    });

    expect(stylexAuthoringSpike.props(styles.root, styles.active)).toEqual({
      style: { padding: 2, foreground: 'bright-cyan', bold: true },
    });
  });
});

describe('modifier composition spike', () => {
  it('composes fluent terminal modifiers including conditional modifiers', () => {
    expect(
      applyModifiers(
        {},
        modifierSpike.padding(2),
        modifierSpike.gap(1),
        modifierSpike.foreground('cyan'),
        modifierSpike.when(true, modifierSpike.bold()),
        modifierSpike.when(false, modifierSpike.background('red')),
      ),
    ).toEqual({ padding: 2, gap: 1, foreground: 'cyan', bold: true });
  });
});
