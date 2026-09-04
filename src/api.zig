const root = @import("api/root.zig");

pub const Api = root.Api;
pub const handles = root.handles;
pub const options = root.options;
pub const commands = root.commands;
pub const keymaps = root.keymaps;
pub const events = root.events;
pub const extmarks = root.extmarks;
pub const plugin_ui = root.plugin_ui;

pub const BufferHandle = root.BufferHandle;
pub const WindowHandle = root.WindowHandle;
pub const TabHandle = root.TabHandle;
pub const NamespaceId = root.NamespaceId;
pub const ExtmarkId = root.ExtmarkId;