const std = @import("std");
const quickjs_runtime = @import("quickjs.zig");
const scene_module = @import("../scene.zig");

const c = @cImport({
    @cInclude("quickjs.h");
});

pub const EventError = error{
    DispatcherMissing,
    DispatchFailed,
};

pub fn dispatch(
    runtime: *quickjs_runtime.Runtime,
    name: []const u8,
    payload_json: []const u8,
) (EventError || quickjs_runtime.RuntimeError)!void {
    const context: *c.JSContext = @ptrCast(runtime.context);
    const global = c.JS_GetGlobalObject(context);
    defer c.JS_FreeValue(context, global);

    const dispatcher = c.JS_GetPropertyStr(context, global, "__hondoDispatchNativeEvent");
    defer c.JS_FreeValue(context, dispatcher);
    if (c.JS_IsFunction(context, dispatcher) == 0) return EventError.DispatcherMissing;

    var arguments = [_]c.JSValue{
        c.JS_NewStringLen(context, name.ptr, name.len),
        c.JS_NewStringLen(context, payload_json.ptr, payload_json.len),
    };
    defer for (&arguments) |*argument| c.JS_FreeValue(context, argument.*);

    const result = c.JS_Call(
        context,
        dispatcher,
        global,
        @intCast(arguments.len),
        @ptrCast(&arguments),
    );
    defer c.JS_FreeValue(context, result);
    if (c.JS_IsException(result) != 0) {
        dumpException(context);
        return EventError.DispatchFailed;
    }

    try runtime.drainJobs();
}

fn dumpException(context: *c.JSContext) void {
    const exception = c.JS_GetException(context);
    defer c.JS_FreeValue(context, exception);

    const message = c.JS_ToCString(context, exception);
    if (message == null) return;
    defer c.JS_FreeCString(context, message);

    const zero_terminated: [*:0]const u8 = @ptrCast(message);
    std.debug.print("Hondo native event exception: {s}\n", .{std.mem.span(zero_terminated)});
}

test "Zig native event dispatch updates a Solid signal through QuickJS" {
    const counter_bundle = @embedFile("../generated/counter.js");

    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();

    var runtime = try quickjs_runtime.Runtime.init();
    defer runtime.deinit();
    try runtime.installSceneBridge(&scene);
    try runtime.eval(counter_bundle, "hondo-counter-native-event.js");

    const text_node_id: scene_module.NodeId = 2;
    try std.testing.expectEqualStrings("Count: 0", (try scene.getNode(text_node_id)).text.?);

    try dispatch(&runtime, "counter.increment", "{\"source\":\"keyboard\"}");

    const updated = try scene.getNode(text_node_id);
    try std.testing.expectEqual(text_node_id, updated.id);
    try std.testing.expectEqualStrings("Count: 1", updated.text.?);

    try runtime.eval(
        "globalThis.__hondoCounterDispose();",
        "hondo-counter-native-event-dispose.js",
    );
}

test "native event dispatch reports a missing dispatcher" {
    var runtime = try quickjs_runtime.Runtime.init();
    defer runtime.deinit();

    try std.testing.expectError(
        EventError.DispatcherMissing,
        dispatch(&runtime, "missing", "null"),
    );
}
