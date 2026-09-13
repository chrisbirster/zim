const std = @import("std");
const scene_module = @import("../scene.zig");

const c = @cImport({
    @cInclude("quickjs.h");
});

const runtime_stack_size = 8 * 1024 * 1024;
const runtime_bootstrap =
    \\if (typeof globalThis.queueMicrotask !== "function") {
    \\  globalThis.queueMicrotask = function queueMicrotask(callback) {
    \\    if (typeof callback !== "function") {
    \\      throw new TypeError("queueMicrotask callback must be a function");
    \\    }
    \\    Promise.resolve().then(callback);
    \\  };
    \\}
    \\if (typeof globalThis.console !== "object" || globalThis.console === null) {
    \\  const noop = function noop() {};
    \\  globalThis.console = new Proxy({}, {
    \\    get: function getConsoleMethod() { return noop; },
    \\  });
    \\}
;

pub const RuntimeError = error{
    RuntimeCreationFailed,
    ContextCreationFailed,
    BootstrapFailed,
    HostBridgeInstallFailed,
    EvaluationFailed,
    PendingJobFailed,
};

pub const Runtime = struct {
    runtime: *c.JSRuntime,
    context: *c.JSContext,

    pub fn init() RuntimeError!Runtime {
        const runtime = c.JS_NewRuntime() orelse return RuntimeError.RuntimeCreationFailed;
        errdefer c.JS_FreeRuntime(runtime);
        c.JS_SetMaxStackSize(runtime, runtime_stack_size);

        const context = c.JS_NewContext(runtime) orelse return RuntimeError.ContextCreationFailed;
        errdefer c.JS_FreeContext(context);
        c.JS_SetRuntimeInfo(runtime, "hondo-official-quickjs");

        const bootstrap = c.JS_Eval(
            context,
            runtime_bootstrap.ptr,
            runtime_bootstrap.len,
            "hondo-runtime-bootstrap.js",
            c.JS_EVAL_TYPE_GLOBAL,
        );
        defer c.JS_FreeValue(context, bootstrap);
        if (c.JS_IsException(bootstrap) != 0) {
            dumpException(context);
            return RuntimeError.BootstrapFailed;
        }

        return .{
            .runtime = runtime,
            .context = context,
        };
    }

    pub fn deinit(self: *Runtime) void {
        c.JS_SetContextOpaque(self.context, null);
        c.JS_FreeContext(self.context);
        c.JS_FreeRuntime(self.runtime);
        self.* = undefined;
    }

    pub fn installSceneBridge(self: *Runtime, scene: *scene_module.Scene) RuntimeError!void {
        c.JS_SetContextOpaque(self.context, scene);

        const global = c.JS_GetGlobalObject(self.context);
        defer c.JS_FreeValue(self.context, global);

        const host_call = c.JS_NewCFunction2(
            self.context,
            jsHostCall,
            "__hondoHostCall",
            4,
            c.JS_CFUNC_generic,
            0,
        );
        if (c.JS_SetPropertyStr(self.context, global, "__hondoHostCall", host_call) < 0) {
            c.JS_SetContextOpaque(self.context, null);
            return RuntimeError.HostBridgeInstallFailed;
        }
    }

    pub fn eval(self: *Runtime, source: []const u8, filename: [*:0]const u8) RuntimeError!void {
        const value = c.JS_Eval(
            self.context,
            source.ptr,
            source.len,
            filename,
            c.JS_EVAL_TYPE_GLOBAL,
        );
        defer c.JS_FreeValue(self.context, value);

        if (c.JS_IsException(value) != 0) {
            dumpException(self.context);
            return RuntimeError.EvaluationFailed;
        }

        try self.drainJobs();
    }

    pub fn drainJobs(self: *Runtime) RuntimeError!void {
        while (c.JS_IsJobPending(self.runtime) != 0) {
            var job_context: ?*c.JSContext = null;
            if (c.JS_ExecutePendingJob(self.runtime, &job_context) < 0) {
                dumpException(job_context orelse self.context);
                return RuntimeError.PendingJobFailed;
            }
        }
    }
};

fn jsHostCall(
    maybe_context: ?*c.JSContext,
    this_value: c.JSValueConst,
    argc: c_int,
    argv: [*c]c.JSValueConst,
) callconv(.c) c.JSValue {
    _ = this_value;

    const context = maybe_context orelse unreachable;
    if (argc < 1) return c.JS_ThrowTypeError(context, "Hondo host operation is required");

    const scene_opaque = c.JS_GetContextOpaque(context) orelse
        return c.JS_ThrowInternalError(context, "Hondo scene bridge is not installed");
    const scene: *scene_module.Scene = @ptrCast(@alignCast(scene_opaque));

    const operation_raw = c.JS_ToCString(context, argv[0]);
    if (operation_raw == null) return stringConversionFailed(context);
    defer c.JS_FreeCString(context, operation_raw);
    const operation_z: [*:0]const u8 = @ptrCast(operation_raw);
    const operation = std.mem.span(operation_z);

    if (std.mem.eql(u8, operation, "createElement")) {
        if (argc < 3) return invalidArguments(context);
        const id = readNodeId(context, argv[1]) orelse return invalidArguments(context);
        const type_raw = c.JS_ToCString(context, argv[2]);
        if (type_raw == null) return stringConversionFailed(context);
        defer c.JS_FreeCString(context, type_raw);
        const type_z: [*:0]const u8 = @ptrCast(type_raw);
        scene.createElement(id, std.mem.span(type_z)) catch return hostOperationFailed(context);
        return c.JS_NewInt32(context, 0);
    }

    if (std.mem.eql(u8, operation, "createTextNode")) {
        if (argc < 3) return invalidArguments(context);
        const id = readNodeId(context, argv[1]) orelse return invalidArguments(context);
        const value_raw = c.JS_ToCString(context, argv[2]);
        if (value_raw == null) return stringConversionFailed(context);
        defer c.JS_FreeCString(context, value_raw);
        const value_z: [*:0]const u8 = @ptrCast(value_raw);
        scene.createText(id, std.mem.span(value_z)) catch return hostOperationFailed(context);
        return c.JS_NewInt32(context, 0);
    }

    if (std.mem.eql(u8, operation, "replaceText")) {
        if (argc < 3) return invalidArguments(context);
        const id = readNodeId(context, argv[1]) orelse return invalidArguments(context);
        const value_raw = c.JS_ToCString(context, argv[2]);
        if (value_raw == null) return stringConversionFailed(context);
        defer c.JS_FreeCString(context, value_raw);
        const value_z: [*:0]const u8 = @ptrCast(value_raw);
        scene.replaceText(id, std.mem.span(value_z)) catch return hostOperationFailed(context);
        return c.JS_NewInt32(context, 0);
    }

    if (std.mem.eql(u8, operation, "setProperty")) {
        if (argc < 4) return invalidArguments(context);
        const id = readNodeId(context, argv[1]) orelse return invalidArguments(context);
        const name_raw = c.JS_ToCString(context, argv[2]);
        if (name_raw == null) return stringConversionFailed(context);
        defer c.JS_FreeCString(context, name_raw);
        const value_raw = c.JS_ToCString(context, argv[3]);
        if (value_raw == null) return stringConversionFailed(context);
        defer c.JS_FreeCString(context, value_raw);
        const name_z: [*:0]const u8 = @ptrCast(name_raw);
        const value_z: [*:0]const u8 = @ptrCast(value_raw);
        scene.setPropertyJson(
            id,
            std.mem.span(name_z),
            std.mem.span(value_z),
        ) catch return hostOperationFailed(context);
        return c.JS_NewInt32(context, 0);
    }

    if (std.mem.eql(u8, operation, "insertNode")) {
        if (argc < 4) return invalidArguments(context);
        const parent_id = readNodeId(context, argv[1]) orelse return invalidArguments(context);
        const node_id = readNodeId(context, argv[2]) orelse return invalidArguments(context);
        const anchor_id: ?scene_module.NodeId = if (c.JS_IsNull(argv[3]) != 0)
            null
        else
            readNodeId(context, argv[3]) orelse return invalidArguments(context);
        scene.insertNode(parent_id, node_id, anchor_id) catch return hostOperationFailed(context);
        return c.JS_NewInt32(context, 0);
    }

    if (std.mem.eql(u8, operation, "removeNode")) {
        if (argc < 3) return invalidArguments(context);
        const parent_id = readNodeId(context, argv[1]) orelse return invalidArguments(context);
        const node_id = readNodeId(context, argv[2]) orelse return invalidArguments(context);
        scene.removeNode(parent_id, node_id) catch return hostOperationFailed(context);
        return c.JS_NewInt32(context, 0);
    }

    return c.JS_ThrowTypeError(context, "Unknown Hondo host operation");
}

fn readNodeId(context: *c.JSContext, value: c.JSValueConst) ?scene_module.NodeId {
    var result: i32 = 0;
    if (c.JS_ToInt32(context, &result, value) < 0 or result < 0) return null;
    return @intCast(result);
}

fn invalidArguments(context: *c.JSContext) c.JSValue {
    return c.JS_ThrowTypeError(context, "Invalid Hondo host operation arguments");
}

fn stringConversionFailed(context: *c.JSContext) c.JSValue {
    return c.JS_ThrowTypeError(context, "Hondo host string conversion failed");
}

fn hostOperationFailed(context: *c.JSContext) c.JSValue {
    return c.JS_ThrowInternalError(context, "Hondo scene mutation failed");
}

fn dumpException(context: *c.JSContext) void {
    const exception = c.JS_GetException(context);
    defer c.JS_FreeValue(context, exception);

    const message = c.JS_ToCString(context, exception);
    if (message != null) {
        defer c.JS_FreeCString(context, message);
        const zero_terminated: [*:0]const u8 = @ptrCast(message);
        std.debug.print("Hondo QuickJS exception: {s}\n", .{std.mem.span(zero_terminated)});
    }

    const stack = c.JS_GetPropertyStr(context, exception, "stack");
    defer c.JS_FreeValue(context, stack);
    if (c.JS_IsUndefined(stack) == 0) {
        const stack_text = c.JS_ToCString(context, stack);
        if (stack_text != null) {
            defer c.JS_FreeCString(context, stack_text);
            const stack_zero: [*:0]const u8 = @ptrCast(stack_text);
            std.debug.print("Hondo QuickJS stack:\n{s}\n", .{std.mem.span(stack_zero)});
        }
    }
}

test "QuickJS evaluates JavaScript in the Zig runtime" {
    var runtime = try Runtime.init();
    defer runtime.deinit();

    try runtime.eval(
        "globalThis.__hondoSmoke = 40 + 2;",
        "hondo-smoke.js",
    );
    try runtime.eval(
        "if (globalThis.__hondoSmoke !== 42) throw new Error('wrong result');",
        "hondo-smoke-verify.js",
    );
}

test "QuickJS drains Promise jobs" {
    var runtime = try Runtime.init();
    defer runtime.deinit();

    try runtime.eval(
        \\globalThis.__hondoPromise = 0;
        \\Promise.resolve(42).then(value => { globalThis.__hondoPromise = value; });
    , "hondo-promise.js");
    try runtime.eval(
        "if (globalThis.__hondoPromise !== 42) throw new Error('pending job did not run');",
        "hondo-promise-verify.js",
    );
}

test "QuickJS reports evaluation failures" {
    var runtime = try Runtime.init();
    defer runtime.deinit();

    try std.testing.expectError(
        RuntimeError.EvaluationFailed,
        runtime.eval("throw new Error('expected smoke failure');", "hondo-error.js"),
    );
}

test "QuickJS host bridge mutates the Zig scene" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();

    var runtime = try Runtime.init();
    defer runtime.deinit();
    try runtime.installSceneBridge(&scene);

    try runtime.eval(
        \\__hondoHostCall("createElement", 1, "text");
        \\__hondoHostCall("createTextNode", 2, "Count: 0");
        \\__hondoHostCall("setProperty", 1, "style", "{\"bold\":true}");
        \\__hondoHostCall("insertNode", 0, 1, null);
        \\__hondoHostCall("insertNode", 1, 2, null);
        \\__hondoHostCall("replaceText", 2, "Count: 1");
    , "hondo-host-bridge.js");

    try std.testing.expectEqualStrings("text", (try scene.getNode(1)).type_name);
    try std.testing.expectEqualStrings("Count: 1", (try scene.getNode(2)).text.?);
    try std.testing.expectEqual(@as(?scene_module.NodeId, 1), (try scene.getNode(2)).parent);
    try std.testing.expectEqualStrings(
        "{\"bold\":true}",
        (try scene.getPropertyJson(1, "style")).?,
    );

    try runtime.eval(
        "__hondoHostCall('removeNode', 1, 2);",
        "hondo-host-remove.js",
    );
    try std.testing.expectEqual(@as(?scene_module.NodeId, null), (try scene.getNode(2)).parent);
}

test "QuickJS host bridge turns invalid scene mutations into JavaScript exceptions" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();

    var runtime = try Runtime.init();
    defer runtime.deinit();
    try runtime.installSceneBridge(&scene);

    try std.testing.expectError(
        RuntimeError.EvaluationFailed,
        runtime.eval(
            "__hondoHostCall('removeNode', 0, 99);",
            "hondo-host-invalid.js",
        ),
    );
}

test "bundled Solid counter preserves native text identity across reactive update" {
    const counter_bundle = @embedFile("../generated/counter.js");

    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();

    var runtime = try Runtime.init();
    defer runtime.deinit();
    try runtime.installSceneBridge(&scene);

    try runtime.eval(counter_bundle, "hondo-counter.js");

    const text_node_id: scene_module.NodeId = 2;
    const mounted = try scene.getNode(text_node_id);
    try std.testing.expectEqual(text_node_id, mounted.id);
    try std.testing.expectEqualStrings("Count: 0", mounted.text.?);

    try runtime.eval(
        "globalThis.__hondoCounterIncrement();",
        "hondo-counter-increment.js",
    );

    const updated = try scene.getNode(text_node_id);
    try std.testing.expectEqual(text_node_id, updated.id);
    try std.testing.expectEqualStrings("Count: 1", updated.text.?);

    try runtime.eval(
        "globalThis.__hondoCounterDispose();",
        "hondo-counter-dispose.js",
    );
}
