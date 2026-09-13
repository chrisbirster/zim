/*
 * QuickJS's cutils.h provides a portable fallback for offsetof() using
 * &((type *)0)->field when the C environment has not already defined it.
 * Zig 0.16's Windows C build enables undefined-behavior checks, which reject
 * that null-member expression when QuickJS's allocator uses container_of().
 *
 * Use Clang's builtin offsetof for this translation unit, then include the
 * pinned upstream QuickJS source unchanged.
 */
#ifndef offsetof
#define offsetof(type, field) __builtin_offsetof(type, field)
#endif
#include "quickjs.c"
