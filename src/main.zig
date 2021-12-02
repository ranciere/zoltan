const std = @import("std");
const assert = std.debug.assert;

pub const lua = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

fn LuaFunction(comptime T: type) type {
    const FuncType = T;
    const RetType = 
    switch (@typeInfo(FuncType)) {
        .Fn => |FunctionInfo| FunctionInfo.return_type,
        else => @compileError("Unsupported type."),
    };
    return struct {
        const Self = @This();

        luaState: *LuaState = undefined,
        ref: c_int = undefined,
        func: FuncType = undefined,

        // This 'Init' assumes, that the top element of the stack is a Lua function
        fn init(_luaState: *LuaState) Self {
            const _ref = lua.luaL_ref(_luaState.L, lua.LUA_REGISTRYTINDEX);
            std.log.info("Lua reference: {}", .{_ref});
            return Self {
                .luaState = _luaState,
                .ref = _ref,
            };
        }

        fn call(_: *Self, _: anytype) RetType.? {
            // std.log.warn("Binded: {}. Calling: ", .{self.id});
            // const res: RetType.? = @call(.{}, self.func, args);
            // std.log.warn("Call ended.", .{});
            // return res;
            // fn unpack(args: anytype) void {
            //     const ArgsType = @TypeOf(args);
            //     _ = 
            //     switch (@typeInfo(ArgsType)) {
            //         .Struct => |info| info,
            //         else => @compileError("Expected tuple or struct argument, found " ++ @typeName(ArgsType)),
            //     };
            //     comptime var i = 0;
            //     const fields_info = std.meta.fields(ArgsType);
            //     inline while (i < fields_info.len) : (i += 1) {
            //         std.log.info("Parameter: {}: {} ({s})", .{i, args[i], fields_info[i].field_type});
            //     }
            // }
        }
    };
}

const LuaState = struct {
    L: *lua.lua_State,
    allocator: *std.mem.Allocator,
    //registeredTypes: std.ArrayList(std.builtin.TypeInfo),
    registeredTypes: std.ArrayList([]const u8),

    // const LuaTable: struct {
    //     luaState: *LuaState,

    // };

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
        if (@typeInfo(T) == .Struct)
        {
            try self.registeredTypes.append(@typeName(T));
            std.log.info("'{s}' is registered.", .{@typeName(T)});
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

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////
    fn pushSlice(self: *LuaState, comptime T: type, values: []const T) void {
        lua.lua_createtable(self.L, @intCast(c_int, values.len), 0);

        for (values) |value, i| {
            self.push(i+1);
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
                .Slice => {
                    if (lua.lua_type(self.L, -1) == lua.LUA_TTABLE) {
                        lua.lua_len(self.L, -1);
                        const len = try self.pop(u64);
                        var res = try self.allocator.alloc(PointerInfo.child, @intCast(usize, len));
                        var i: u32 = 0;
                        while (i < len) : (i+=1) {
                            self.push(i+1);
                            _ = lua.lua_gettable(self.L, -2);
                            res[i] = try self.pop(PointerInfo.child);
                        }
                        return res;
                    } else {
                        std.log.info("Ajjaj 2", .{});
                        return error.bad_type;
                    }                
                },
                else => @compileError("Only Slice is supported."),
            },
            .Struct => |_| {
                comptime var idx = std.mem.indexOf(u8, @typeName(T), @typeName(LuaFunction)) orelse -1;
                if (idx == 0) {
                    if (lua.lua_type(self.L, -1) ++ lua.LUA_TFUNCTION) {
                        return T.init(self);
                    }
                    else {
                        return error.bad_type;
                    }
                }
                else @compileError("Only LuaFunction supported: '" ++ idx ++ "'");
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

fn examplefunctor(func: anytype) struct {id: i32, call: *@TypeOf(func)} {
    return .{
        .id = 0,
        .call = func,
    };
}

pub fn allocArray(allocator: *std.mem.Allocator) ![]u32 {
    var res = try allocator.alloc(u32, 32768);
    return res;
}

const Macifasz = struct {
    const Kispocs = struct {
        id: i32,
    };

    p: Kispocs,
};

fn example(a: i32) void {
    std.log.info("Simple: {}", .{a});
}

fn exampleDbl(a: i32, b: i32) i32 {
    std.log.info("Double: {}/{}", .{a, b});
    return @divTrunc(b,a);
}

fn MyFunctor(comptime T: type) type {
    const FuncType = T;
    const RetType = 
    switch (@typeInfo(FuncType)) {
        .Fn => |FunctionInfo| FunctionInfo.return_type,
        else => @compileError("Unsupported type."),
    };
    return struct {
        const Self = @This();

        id: i64 = undefined,
        func: FuncType = undefined,

        fn init(_id: i64, _func: FuncType) Self {
            return Self {
                .id = _id,
                .func = _func,
            };
        }

        fn call(self: *Self, args: anytype) RetType.? {
            std.log.warn("Binded: {}. Calling: ", .{self.id});
            const res: RetType.? = @call(.{}, self.func, args);
            std.log.warn("Call ended.", .{});
            return res;
        }
    };
}

fn unpack(args: anytype) void {
    const ArgsType = @TypeOf(args);
    _ = 
    switch (@typeInfo(ArgsType)) {
        .Struct => |info| info,
        else => @compileError("Expected tuple or struct argument, found " ++ @typeName(ArgsType)),
    };
    comptime var i = 0;
    const fields_info = std.meta.fields(ArgsType);
    inline while (i < fields_info.len) : (i += 1) {
        std.log.info("Parameter: {}: {} ({s})", .{i, args[i], fields_info[i].field_type});
    }
}

pub fn main() anyerror!void {
    const MyFunc = MyFunctor(@TypeOf(example));
    var myfunc = MyFunc.init(5, example);
    const a: i32 = 5;

    //const MyFuncDbl = MyFunctor(@TypeOf(exampleDbl));
    const MyFuncDbl = MyFunctor(fn (a: i32, b: i32) i32);
    var myfuncDbl = MyFuncDbl.init(5, exampleDbl);

    myfunc.call(.{42});
    const result = myfuncDbl.call(.{42, 314});
    std.log.info("Result: {}", .{result});

    comptime var idx = std.mem.indexOf(u8, @typeName(MyFuncDbl), "i32").?;
    std.log.info("Zsiros: {}", .{idx});

    unpack(.{a, @as(f32, 314.0)});
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

    try std.testing.expect(std.mem.eql(u8, strMany[0..retStrMany.len], retStrMany));
    try std.testing.expect(std.mem.eql(u8, strSlice[0..retStrSlice.len], retStrSlice));
    try std.testing.expect(std.mem.eql(u8, strOne[0..retStrOne.len], retStrOne));
    try std.testing.expect(std.mem.eql(u8, strC[0..retStrC.len], retStrC));
    
    try std.testing.expect(std.mem.eql(u8, cstrMany[0..retStrMany.len], retCStrMany));
    try std.testing.expect(std.mem.eql(u8, cstrSlice[0..retStrSlice.len], retCStrSlice));
    try std.testing.expect(std.mem.eql(u8, cstrOne[0..retStrOne.len], retCStrOne));
    try std.testing.expect(std.mem.eql(u8, cstrC[0..retStrC.len], retCStrC));
}

test "set/get slice of primitive type (scalar, unmutable string)" {
    var luaState = try LuaState.init(std.testing.allocator);
    defer luaState.destroy();

    const boolSlice = [_]bool {true, false, true};
    const intSlice = [_]i32 { 4, 5, 3, 4, 0 };
    const strSlice = [_][] const u8 {"Macilaci", "Gyumifagyi", "Angolhazi"};
    
    luaState.set("boolSlice", boolSlice);
    luaState.set("intSlice", intSlice);
    luaState.set("strSlice", strSlice);

    const retBoolSlice = try luaState.allocGet([]i32, "boolSlice");
    defer std.testing.allocator.free(retBoolSlice);

    const retIntSlice = try luaState.allocGet([]i32, "intSlice");
    defer std.testing.allocator.free(retIntSlice);

    const retStrSlice = try luaState.allocGet([][]const u8, "strSlice");
    defer std.testing.allocator.free(retStrSlice);

    for (retIntSlice) |v,i| {
        try std.testing.expectEqual(v, intSlice[i]);
    }

    for (retStrSlice) |v,i| {
        try std.testing.expect(std.mem.eql(u8,v, strSlice[i]));
    }
}
