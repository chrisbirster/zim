const c = @cImport({
    @cInclude("windows.h");
    @cInclude("io.h");
});

pub const WaitError = error{
    WaitFailed,
};

pub fn readable(input_fd: i32, timeout_ms: u32) WaitError!bool {
    const os_handle = c._get_osfhandle(input_fd);
    if (os_handle == -1) return WaitError.WaitFailed;
    const handle: c.HANDLE = @ptrFromInt(@as(usize, @intCast(os_handle)));

    const result = c.WaitForSingleObject(handle, @as(c.DWORD, @intCast(timeout_ms)));
    if (result == c.WAIT_TIMEOUT) return false;
    if (result != c.WAIT_OBJECT_0) return WaitError.WaitFailed;

    // A console input handle is signaled for any pending INPUT_RECORD, not just
    // characters that ReadFile/_read can return. ConPTY resize notifications are
    // WINDOW_BUFFER_SIZE_EVENT records; treating those as readable character
    // input can wedge the following CRT read. Drain non-key/key-up records here
    // and only let the existing VT byte decoder read a real key-down event.
    while (true) {
        var record: c.INPUT_RECORD = undefined;
        var count: c.DWORD = 0;
        if (c.PeekConsoleInputW(handle, &record, 1, &count) == 0) return WaitError.WaitFailed;
        if (count == 0) return false;

        if (record.EventType == c.KEY_EVENT and record.Event.KeyEvent.bKeyDown != 0) return true;

        var consumed: c.DWORD = 0;
        if (c.ReadConsoleInputW(handle, &record, 1, &consumed) == 0) return WaitError.WaitFailed;
        if (consumed == 0) return false;

        const next = c.WaitForSingleObject(handle, 0);
        if (next == c.WAIT_TIMEOUT) return false;
        if (next != c.WAIT_OBJECT_0) return WaitError.WaitFailed;
    }
}
