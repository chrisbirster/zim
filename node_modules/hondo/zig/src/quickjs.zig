const std = @import("std");

pub const version = "2026-06-04";
pub const archive_url = "https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz";
pub const archive_sha256 = "b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a";

test "QuickJS pin is explicit" {
    try std.testing.expectEqualStrings("2026-06-04", version);
    try std.testing.expect(archive_url.len > 0);
    try std.testing.expectEqual(@as(usize, 64), archive_sha256.len);
}
