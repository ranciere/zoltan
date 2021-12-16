const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zoltan", "src/main.zig");
    // Lua headers + required source files
    exe.addIncludeDir("src/lua-5.4.3/src");

    const flags = [_][]const u8{
        "-std=c99",
        "-O2",
    };
    exe.addCSourceFiles(&lua_files, &flags);
    exe.linkLibC();
    
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    // Lua 
    exe_tests.addIncludeDir("src/lua-5.4.3/src");
    exe_tests.addCSourceFiles(&lua_files, &flags);
    
    exe_tests.linkLibC();

    //
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}

const lua_files = [_] []const u8{
    "src/lua-5.4.3/src/lapi.c",
    "src/lua-5.4.3/src/lauxlib.c",
    "src/lua-5.4.3/src/lbaselib.c",
    "src/lua-5.4.3/src/lcode.c",
    "src/lua-5.4.3/src/lcorolib.c",
    "src/lua-5.4.3/src/lctype.c",
    "src/lua-5.4.3/src/ldblib.c",
    "src/lua-5.4.3/src/ldebug.c",
    "src/lua-5.4.3/src/ldo.c",
    "src/lua-5.4.3/src/ldump.c",
    "src/lua-5.4.3/src/lfunc.c",
    "src/lua-5.4.3/src/lgc.c",
    "src/lua-5.4.3/src/linit.c",
    "src/lua-5.4.3/src/liolib.c",
    "src/lua-5.4.3/src/llex.c",
    "src/lua-5.4.3/src/lmathlib.c",
    "src/lua-5.4.3/src/lmem.c",
    "src/lua-5.4.3/src/loadlib.c",
    "src/lua-5.4.3/src/lobject.c",
    "src/lua-5.4.3/src/lopcodes.c",
    "src/lua-5.4.3/src/loslib.c",
    "src/lua-5.4.3/src/lparser.c",
    "src/lua-5.4.3/src/lstate.c",
    "src/lua-5.4.3/src/lstring.c",
    "src/lua-5.4.3/src/lstrlib.c",
    "src/lua-5.4.3/src/ltable.c",
    "src/lua-5.4.3/src/ltablib.c",
    "src/lua-5.4.3/src/ltm.c",
    "src/lua-5.4.3/src/lundump.c",
    "src/lua-5.4.3/src/lutf8lib.c",
    "src/lua-5.4.3/src/lvm.c",
    "src/lua-5.4.3/src/lzio.c",
};
