const std = @import("std");
const builtin = @import("builtin");

pub fn burrito_plugin_entry(install_dir: []const u8, program_manifest_json: []const u8) void {
    _ = install_dir;
    _ = program_manifest_json;

    // Acknowledge that tailscale-rs is experimental software as required by the library.
    // We set the TS_RS_EXPERIMENT environment variable in the wrapper process so that it is inherited by the Erlang VM.
    if (builtin.os.tag == .windows) {
        const kernel32 = struct {
            extern "kernel32" fn SetEnvironmentVariableA(lpName: [*:0]const u8, lpValue: [*:0]const u8) callconv(.Stdcall) c_int;
        };
        _ = kernel32.SetEnvironmentVariableA("TS_RS_EXPERIMENT", "this_is_unstable_software");
    } else {
        const libc = struct {
            extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        };
        _ = libc.setenv("TS_RS_EXPERIMENT", "this_is_unstable_software", 1);
    }
}
