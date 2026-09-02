const editor = @import("../editor.zig");

pub const BufferHandle = struct {
    id: editor.BufferId,

    pub fn eql(self: BufferHandle, other: BufferHandle) bool {
        return self.id == other.id;
    }
};

pub const WindowHandle = struct {
    id: editor.WindowId,

    pub fn eql(self: WindowHandle, other: WindowHandle) bool {
        return self.id == other.id;
    }
};

pub const TabHandle = struct {
    id: editor.TabId,

    pub fn eql(self: TabHandle, other: TabHandle) bool {
        return self.id == other.id;
    }
};
