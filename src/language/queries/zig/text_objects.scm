(function_declaration
  body: (block) @object.function.body) @object.function.around

(variable_declaration
  (identifier)
  "="
  [
    (struct_declaration)
    (enum_declaration)
    (union_declaration)
    (opaque_declaration)
  ] @object.class.container) @object.class.around

(parameter) @object.parameter.inner
(block) @object.block.around
