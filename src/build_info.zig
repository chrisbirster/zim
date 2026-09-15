pub const version = "1.0.0";
pub const public_api_version: u32 = 1;
pub const plugin_api_version: u32 = 1;
pub const rpc_protocol_version: u32 = 1;
pub const rpc_api_version: u32 = 1;
pub const session_format_version: u32 = 1;
pub const compatibility_policy = "semver-major";
pub const product = "zim";

pub const Metadata = struct {
    version: []const u8,
    public_api_version: u32,
    plugin_api_version: u32,
    rpc_protocol_version: u32,
    rpc_api_version: u32,
    session_format_version: u32,
    compatibility_policy: []const u8,
};

pub fn metadata() Metadata {
    return .{
        .version = version,
        .public_api_version = public_api_version,
        .plugin_api_version = plugin_api_version,
        .rpc_protocol_version = rpc_protocol_version,
        .rpc_api_version = rpc_api_version,
        .session_format_version = session_format_version,
        .compatibility_policy = compatibility_policy,
    };
}

test "v1 metadata is coherent" {
    const std = @import("std");
    const info = metadata();
    try std.testing.expectEqualStrings("1.0.0", info.version);
    try std.testing.expectEqual(@as(u32, 1), info.public_api_version);
    try std.testing.expectEqual(@as(u32, 1), info.rpc_api_version);
}
