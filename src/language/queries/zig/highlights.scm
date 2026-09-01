; Zim-owned editor-neutral highlight captures for the Zig grammar.
; Keep predicates out of the baseline service so the core query executor remains host-agnostic.

(function_declaration
  name: (identifier) @function)

(parameter
  name: (identifier) @variable.parameter)

(container_field
  name: (identifier) @variable.member)

(field_expression
  member: (identifier) @variable.member)

(builtin_identifier) @function.builtin
(builtin_type) @type.builtin
(comment) @comment
(character) @character
(string) @string
(multiline_string) @string
(integer) @number
(float) @number.float
(boolean) @boolean
(escape_sequence) @string.escape

[
  "const"
  "var"
  "test"
  "defer"
  "errdefer"
] @keyword

[
  "struct"
  "union"
  "enum"
  "opaque"
] @keyword.type

"fn" @keyword.function
"return" @keyword.return

[
  "if"
  "else"
  "switch"
] @keyword.conditional

[
  "for"
  "while"
  "break"
  "continue"
] @keyword.repeat

[
  "pub"
  "inline"
  "noinline"
  "extern"
  "comptime"
  "packed"
  "threadlocal"
  "noalias"
] @keyword.modifier

[
  "="
  "+"
  "-"
  "*"
  "/"
  "%"
  "=="
  "!="
  "<"
  ">"
  "<="
  ">="
  "and"
  "or"
  "orelse"
] @operator
