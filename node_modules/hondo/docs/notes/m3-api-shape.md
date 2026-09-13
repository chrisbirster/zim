# M3 API shape

```ts
Text({ children, style, focusable, ref, onKey, onKeyCapture, onMouse })
Box({ children, style, focusable, ref, ...events })
Stack({ children, style, ...events })
Row({ children, style, ...events })
Column({ children, style, ...events })
Spacer({ size, grow, style })
```

`Stack` is a column alias by default. `Row` and `Column` set the native scene element type so layout direction is terminal-native. All style values are serialized through the existing `style` Scene property.
