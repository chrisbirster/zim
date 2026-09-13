pub const capabilities = @import("capabilities.zig");
pub const input = @import("input.zig");
pub const control = @import("control.zig");
pub const frame = @import("frame.zig");
pub const renderer = @import("renderer.zig");
pub const session = @import("session.zig");
pub const size = @import("size.zig");
pub const wait = @import("wait.zig");

test {
    _ = capabilities;
    _ = input;
    _ = control;
    _ = frame;
    _ = renderer;
    _ = session;
    _ = size;
    _ = wait;
}
