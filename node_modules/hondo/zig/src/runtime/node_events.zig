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

pub const Result = struct {
    default_prevented: bool,
};

pub fn dispatch(
    runtime: *quickjs_runtime.Runtime,
    target_id: scene_module.NodeId,
    event_type: []const u8,
    payload_json: []const u8,
) (EventError || quickjs_runtime.RuntimeError)!Result {
    const context: *c.JSContext = @ptrCast(runtime.context);
    const global = c.JS_GetGlobalObject(context);
    defer c.JS_FreeValue(context, global);

    const dispatcher = c.JS_GetPropertyStr(context, global, "__hondoDispatchNodeEvent");
    defer c.JS_FreeValue(context, dispatcher);
    if (c.JS_IsFunction(context, dispatcher) == 0) return EventError.DispatcherMissing;

    var arguments = [_]c.JSValue{
        c.JS_NewInt32(context, @intCast(target_id)),
        c.JS_NewStringLen(context, event_type.ptr, event_type.len),
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

    const prevented = c.JS_ToBool(context, result);
    if (prevented < 0) {
        dumpException(context);
        return EventError.DispatchFailed;
    }

    try runtime.drainJobs();
    return .{ .default_prevented = prevented != 0 };
}

fn dumpException(context: *c.JSContext) void {
    const exception = c.JS_GetException(context);
    defer c.JS_FreeValue(context, exception);

    const message = c.JS_ToCString(context, exception);
    if (message == null) return;
    defer c.JS_FreeCString(context, message);

    const zero_terminated: [*:0]const u8 = @ptrCast(message);
    std.debug.print("Hondo node event exception: {s}\n", .{std.mem.span(zero_terminated)});
}

test "targeted node event dispatch reaches a Hondo host handler and updates Solid" {
    const counter_bundle = @embedFile("../generated/counter.js");

    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();

    var runtime = try quickjs_runtime.Runtime.init();
    defer runtime.deinit();
    try runtime.installSceneBridge(&scene);
    try runtime.eval(counter_bundle, "hondo-counter-node-event.js");

    const counter_node_id: scene_module.NodeId = 1;
    const text_node_id: scene_module.NodeId = 2;
    try std.testing.expectEqualStrings("true", (try scene.getPropertyJson(counter_node_id, "focusable")).?);
    try std.testing.expectEqualStrings("Count: 0", (try scene.getNode(text_node_id)).text.?);

    const result = try dispatch(&runtime, counter_node_id, "key", "{\"kind\":\"enter\"}");
    try std.testing.expect(result.default_prevented);
    try std.testing.expectEqualStrings("Count: 1", (try scene.getNode(text_node_id)).text.?);

    try runtime.eval(
        "globalThis.__hondoCounterDispose();",
        "hondo-counter-node-event-dispose.js",
    );
}
