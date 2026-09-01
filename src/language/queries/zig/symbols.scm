(function_declaration
  name: (identifier) @symbol.name) @symbol.function

(variable_declaration
  (identifier) @symbol.name
  "="
  [
    (struct_declaration)
    (enum_declaration)
    (union_declaration)
    (opaque_declaration)
  ] @symbol.container) @symbol.class
