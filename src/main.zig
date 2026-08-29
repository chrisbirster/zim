const std = @import("std");
const app = @import("app.zig");

pub fn main(init: std.process.Init) !u8 {
    return app.run(init);
}
