const std = @import("std");
const assert = std.debug.assert;

pub const lua = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

const LuaTable = struct {

};

const LuaState = struct {
    L: *lua.lua_State,
    allocator: *std.mem.Allocator,
    //registeredTypes: std.ArrayList(std.builtin.TypeInfo),
    registeredTypes: std.ArrayList([]const u8),

    pub fn init(allocator: *std.mem.Allocator) !LuaState {
        var _state = lua.lua_newstate(alloc, allocator) orelse return error.OutOfMemory;
        var state = LuaState {
            .L = _state,
            .allocator = allocator,
            .registeredTypes = std.ArrayList([]const u8).init(allocator),
        };
        return state;        
    }

    pub fn destroy(self: *LuaState) void {
        _ = lua.lua_close(self.L);
    }


    pub fn openLibs(self: *LuaState) void {
        _ = lua.luaL_openlibs(self.L);
    }

    pub fn run(self: *LuaState, script: []const u8) void {
        _ = lua.luaL_loadstring(self.L, @ptrCast([*c]const u8, script));
        _ = lua.lua_pcallk(self.L, 0, 0, 0, 0, null);
    }

    pub fn newUserType(self: *LuaState, comptime T: type) !void {
        if (@typeInfo(T) == .Type)
        {
            try self.registeredTypes.append(@typeName(T));
        }
        else @compileError("New user type is invalid: '" ++ @typeName(T) ++ "'. Only 'struct'-s allowed." );
    }

    pub fn set(self: *LuaState, name: [] const u8, value: anytype) void {
        _ = self.push(value);
        _ = lua.lua_setglobal(self.L, @ptrCast([*c] const u8, name));
    }

    pub fn get(self: *LuaState, comptime T: type, name: [] const u8) !T {
        const typ = lua.lua_getglobal(self.L, @ptrCast([*c] const u8, name));
        if (typ != lua.LUA_TNIL) {
            return try self.pop(T);
        }
        else {
            return error.novalue;
        }
    }

    pub fn allocGet(self: *LuaState, comptime T: type, name: [] const u8) !T {
        const typ = lua.lua_getglobal(self.L, @ptrCast([*c] const u8, name));
        if (typ != lua.LUA_TNIL) {
            return try self.allocPop(T);
        }
        else {
            return error.novalue;
        }
    }

    fn pushSlice(self: *LuaState, comptime T: type, values: []const T) void {
        lua.lua_createtable(self.L, @intCast(c_int, values.len), 0);

        for (values) |value, i| {
            self.push(i);
            self.push(value);
            lua.lua_settable(self.L, -3);
        }
    }

    fn push(self: *LuaState, value: anytype) void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .Void => lua.lua_pushnil(self.L),
            .Bool => lua.lua_pushboolean(self.L, @boolToInt(value)),
            .Int, .ComptimeInt => lua.lua_pushinteger(self.L, @intCast(c_longlong, value)),
            .Float, .ComptimeFloat => lua.lua_pushnumber(self.L, value),
            .Array => |info| {
                self.pushSlice(info.child, value[0..]);
            },
            .Pointer => |PointerInfo| switch (PointerInfo.size) {
                .Slice => {
                    if (PointerInfo.child == u8) {
                        _ = lua.lua_pushlstring(self.L, value.ptr, value.len);
                    } else {
                        @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                    }
                },
                .One => {
                    if (@TypeOf(PointerInfo.child) == @TypeOf([]u8)) {
                        _ = lua.lua_pushstring(self.L, @ptrCast([*c]const u8, value));
                    } else {
                        @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                    }
                },
                .Many => {
                    if (@TypeOf(PointerInfo.child) == @TypeOf([]u8)) {
                        _ = lua.lua_pushstring(self.L, @ptrCast([*c]const u8, value));
                    } else {
                        @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                    }
                },
                .C => {
                    if (@TypeOf(PointerInfo.child) == @TypeOf([]u8)) {
                        _ = lua.lua_pushstring(self.L, value);
                    } else {
                        @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                    }
                },
            },
            // .Fn => {
            // },
            // .Type => {
            // },
            else => @compileError("invalid type: '" ++ @typeName(@TypeOf(value)) ++ "'"),
        }
    }

    fn pop(self: *LuaState, comptime T: type) !T {
        defer lua.lua_pop(self.L, 1);
        switch (@typeInfo(T)) {
            .Void => {},    // just pop
            .Bool => {
                var res = lua.lua_toboolean(self.L, -1);
                return if (res > 0) true else false;
            },
            .Int => {
                var isnum: i32 = 0;
                var result: T = @intCast(T, lua.lua_tointegerx(self.L, -1, isnum));
                return result;
            },
            .Float => {
                var isnum: i32 = 0;
                var result: T = @floatCast(T, lua.lua_tonumberx(self.L, -1, isnum));
                return result;
            },
            // Only string, allocless get (Lua holds the pointer, it is only a slice pointing to it)
            .Pointer => |PointerInfo| switch (PointerInfo.size) {
                .Slice => {
                    // [] const u8 case
                    if (PointerInfo.child == u8 and PointerInfo.is_const)
                    {
                        var len: usize = 0;
                        var ptr = lua.lua_tolstring(self.L, -1, @ptrCast([*c]usize, &len));
                        var result: T = ptr[0..len];
                        return result;
                    }
                    else @compileError("Only '[]const u8' (aka string) is supported allocless.");
                },
                else => @compileError("invalid type: '" ++ @typeName(T) ++ "'"),
            },
            else => @compileError("invalid type: '" ++ @typeName(T) ++ "'"),
        }
    }

    fn allocPop(self: *LuaState, comptime T: type) !T {
        defer lua.lua_pop(self.L, 1);
        switch (@typeInfo(T)) {
            .Pointer => |PointerInfo| switch (PointerInfo.size) {
                .One => @compileError("One"),
                .Many => @compileError("Many"),
                .Slice => @compileError("Slice"),
                .C => @compileError("C"),

                // if (lua.lua_isstring(self.L, -1) > 0)
                // {
                //     @compileLog("Type: '" ++ @typeName(T) ++ "'");
                //     if (PointerInfo.child != u8 or !PointerInfo.is_const) return error.type_mismatch;
                //     var len: usize = 0;
                //     var ptr = lua.lua_tolstring(self.L, -1, @ptrCast([*c]usize, &len));
                //     //var result = try self.allocator.alloc(u8, len);
                //     //std.mem.copy(u8, result, ptr[0..len]);
                //     var result: T = ptr[0..len];
                //     return result;
                // }
                // else if (lua.lua_type(self.L, -1) == lua.LUA_TTABLE)
                // {
                //     std.log.info("Ajjaj 1", .{});
                //     return error.not_string;
                // } else
                // {
                //     std.log.info("Ajjaj 2", .{});
                //     return error.not_string;
                // }
            },
            else => @compileError("invalid type: '" ++ @typeName(T) ++ "'"),
        }
    }

    // Credit: https://github.com/daurnimator/zig-autolua
    fn alloc(ud: ?*c_void, ptr: ?*c_void, osize: usize, nsize: usize) callconv(.C) ?*c_void {
        const c_alignment = 16;
        const allocator = @ptrCast(*std.mem.Allocator, @alignCast(@alignOf(std.mem.Allocator), ud));
        if (@ptrCast(?[*]align(c_alignment) u8, @alignCast(c_alignment, ptr))) |previous_pointer| {
            const previous_slice = previous_pointer[0..osize];
            if (osize >= nsize) {
                // Lua assumes that the allocator never fails when osize >= nsize.
                return allocator.alignedShrink(previous_slice, c_alignment, nsize).ptr;
            } else {
                return (allocator.reallocAdvanced(previous_slice, c_alignment, nsize, .exact) catch return null).ptr;
            }
        } else {
            // osize is any of LUA_TSTRING, LUA_TTABLE, LUA_TFUNCTION, LUA_TUSERDATA, or LUA_TTHREAD
            // when (and only when) Lua is creating a new object of that type.
            // When osize is some other value, Lua is allocating memory for something else.
            return (allocator.alignedAlloc(u8, c_alignment, nsize) catch return null).ptr;
        }
    }
};

const LuaValue = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
};

pub fn mucu(mit: i32) LuaValue {
    switch (mit) {
        0 => return .{.int = 5},
        1 => return .{.float = 1.5},
        else => return .{.int = 0},
    }
}

const Inner = struct {
    a: i32,
    b: bool,
};

const Outer = struct {
    i: Inner,
    c: i64,
};

pub fn allocArray(allocator: *std.mem.Allocator) ![]u32 {
    var res = try allocator.alloc(u32, 32768);
    return res;
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var luaState = try LuaState.init(&gpa.allocator);
    defer luaState.destroy();
    luaState.openLibs();

    const values = [_]i32 { 4, 5, 3, 4, 0 };
    const chValues = [_]u8 { 'A', 'P', 'A' };
    const strValues = [_][] const u8 {"Maci", "Kutyu"};
    const arr = try allocArray(&gpa.allocator);
    std.log.info("Size: {}, 10th elem: {}", .{arr.len, arr[10]});

    lua.lua_createtable(luaState.L, 2, 0);
    luaState.push(0);
    luaState.push(true);
    lua.lua_settable(luaState.L, -3);
    luaState.push(1);
    luaState.push(42);
    lua.lua_settable(luaState.L, -3);
    lua.lua_setglobal(luaState.L, @ptrCast([*c] const u8, "tablicsku"));

    luaState.set("elso", values);
    luaState.set("chElso", chValues);
    luaState.set("strArray", strValues);

    luaState.run("print('Bela'); print(tablicsku); print(tablicsku[0]); print(tablicsku[1]); print(tablicsku[2]);");
    luaState.run("print('--------'); print(elso[0]); print(elso[1]); print(elso[2]); print(elso[3]); print(elso[4]); print(elso[5]);");
    luaState.run("print('--------'); print(chElso[0]); print(chElso[1]); print(chElso[2]); print(chElso[3]); print(chElso[4]); print(chElso[5]);");
    luaState.run("print('--------'); print(strArray[0]); print(strArray[1]); print(strArray[2]); print(strArray[3]); print(strArray[4]); print(strArray[5]);");
    //try luaState.newUserType(LuaState);
}

test "set/get scalar" {
    var luaState = try LuaState.init(std.testing.allocator);
    defer luaState.destroy();
    const int16In: i16 = 1;
    const int32In: i32 = 2;
    const int64In: i64 = 3;
    
    const f16In: f16 = 3.1415;
    const f32In: f32 = 3.1415;
    const f64In: f64 = 3.1415;

    const bIn: bool = true;

    luaState.set("int16", int16In);
    luaState.set("int32", int32In);
    luaState.set("int64", int64In);
    
    luaState.set("float16", f16In);
    luaState.set("float32", f32In);
    luaState.set("float64", f64In);

    luaState.set("bool", bIn);
    
    var int16Out = try luaState.get(i16, "int16");
    var int32Out = try luaState.get(i32, "int32");
    var int64Out = try luaState.get(i64, "int64");
 
    var f16Out = try luaState.get(f16, "float16");
    var f32Out = try luaState.get(f32, "float32");
    var f64Out = try luaState.get(f64, "float64");
 
    var bOut = try luaState.get(bool, "bool");
    
    try std.testing.expectEqual(int16In, int16Out);
    try std.testing.expectEqual(int32In, int32Out);
    try std.testing.expectEqual(int64In, int64Out);

    try std.testing.expectEqual(f16In, f16Out);
    try std.testing.expectEqual(f32In, f32Out);
    try std.testing.expectEqual(f64In, f64Out);

    try std.testing.expectEqual(bIn, bOut);
}

test "set/get string" {
    var luaState = try LuaState.init(std.testing.allocator);
    defer luaState.destroy();
    
    var strMany: [*] const u8 = "macilaci";
    var strSlice: [] const u8 = "macilaic";
    var strOne = "macilaci";
    var strC: [*c] const u8 = "macilaci";

    const cstrMany: [*] const u8 = "macilaci";
    const cstrSlice: [] const u8 = "macilaic";
    const cstrOne = "macilaci";
    const cstrC: [*c] const u8 = "macilaci";

    luaState.set("stringMany", strMany);
    luaState.set("stringSlice", strSlice);
    luaState.set("stringOne", strOne);
    luaState.set("stringC", strC);

    luaState.set("cstringMany", cstrMany);
    luaState.set("cstringSlice", cstrSlice);
    luaState.set("cstringOne", cstrOne);
    luaState.set("cstringC", cstrC);

    const retStrMany = try luaState.get([]const u8, "stringMany");
    const retCStrMany = try luaState.get([]const u8, "cstringMany");
    const retStrSlice = try luaState.get([]const u8, "stringSlice");
    const retCStrSlice = try luaState.get([]const u8, "cstringSlice");

    const retStrOne = try luaState.get([]const u8, "stringOne");
    const retCStrOne = try luaState.get([]const u8, "cstringOne");
    const retStrC = try luaState.get([]const u8, "stringC");
    const retCStrC = try luaState.get([]const u8, "cstringC");

    try std.testing.expectEqual(std.mem.eql(u8, strMany[0..retStrMany.len], retStrMany), true);
    try std.testing.expectEqual(std.mem.eql(u8, strSlice[0..retStrSlice.len], retStrSlice), true);
    try std.testing.expectEqual(std.mem.eql(u8, strOne[0..retStrOne.len], retStrOne), true);
    try std.testing.expectEqual(std.mem.eql(u8, strC[0..retStrC.len], retStrC), true);

    try std.testing.expectEqual(std.mem.eql(u8, cstrMany[0..retStrMany.len], retCStrMany), true);
    try std.testing.expectEqual(std.mem.eql(u8, cstrSlice[0..retStrSlice.len], retCStrSlice), true);
    try std.testing.expectEqual(std.mem.eql(u8, cstrOne[0..retStrOne.len], retCStrOne), true);
    try std.testing.expectEqual(std.mem.eql(u8, cstrC[0..retStrC.len], retCStrC), true);
}