const std = @import("std");
const assert = std.debug.assert;

var luaAllocator: *std.mem.Allocator = undefined;

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

        L: *lua.lua_State,
        allocator: *std.mem.Allocator,
        ref: c_int = undefined,
        func: FuncType = undefined,

        // This 'Init' assumes, that the top element of the stack is a Lua function
        fn init(_L: *lua.lua_State, _allocator: *std.mem.Allocator) Self {
            const _ref = lua.luaL_ref(_L, lua.LUA_REGISTRYINDEX);
            var res = Self{
                .L = _L,
                .allocator = _allocator,
                .ref = _ref,
            };
            return res;
        }

        fn destroy(self: *const Self) void {
            lua.luaL_unref(self.L, lua.LUA_REGISTRYINDEX, self.ref);
        }

        fn call(self: *const Self, args: anytype) !RetType.? {
            const ArgsType = @TypeOf(args);
            if (@typeInfo(ArgsType) != .Struct) {
                ("Expected tuple or struct argument, found " ++ @typeName(ArgsType));
            }
            // Getting function reference
            _ = lua.lua_rawgeti(self.L, lua.LUA_REGISTRYINDEX, self.ref);
            // Preparing arguments
            comptime var i = 0;
            const fields_info = std.meta.fields(ArgsType);
            inline while (i < fields_info.len) : (i += 1) {
                //std.log.info("Parameter: {}: {} ({s})", .{i, args[i], fields_info[i].field_type});
                LuaState.push(self.L, args[i]);
            }
            // Calculating retval count
            comptime var retValCount = switch (@typeInfo(RetType.?)) {
                .Void => 0,
                .Struct => |StructInfo| StructInfo.fields.len,
                else => 1,
            };
            // Calling
            if (lua.lua_pcallk(self.L, fields_info.len, retValCount, 0, 0, null) != lua.LUA_OK) {
                return error.lua_runtime_error;
            }
            // Getting return value(s)
            if (retValCount > 0) {
                return LuaState.pop(RetType.?, self.L);
            }
        }
    };
}

const LuaTable = struct {
    const Self = @This();

    L: *lua.lua_State,
    allocator: *std.mem.Allocator,
    ref: c_int = undefined,

    // This 'Init' assumes, that the top element of the stack is a Lua table
    pub fn init(_L: *lua.lua_State, _allocator: *std.mem.Allocator) Self {
        const _ref = lua.luaL_ref(_L, lua.LUA_REGISTRYINDEX);
        var res = Self{
            .L = _L,
            .allocator = _allocator,
            .ref = _ref,
        };
        return res;
    }

    // Unregister this shit
    pub fn destroy(self: *const Self) void {
        lua.luaL_unref(self.L, lua.LUA_REGISTRYINDEX, self.ref);
    }

    pub fn reference(self: *const Self) Self {
        _ = lua.lua_rawgeti(self.L, lua.LUA_REGISTRYINDEX, self.ref);
        return init(self.L, self.allocator);
    }

    pub fn set(self: *const Self, key: anytype, value: anytype) void {
        // Getting table reference
        _ = lua.lua_rawgeti(self.L, lua.LUA_REGISTRYINDEX, self.ref);
        // Push key, value
        LuaState.push(self.L, key);
        LuaState.push(self.L, value);
        // Set
        lua.lua_settable(self.L, -3);
    }

    pub fn get(self: *const Self, comptime T: type, key: anytype) !T {
        // Getting table by reference
        _ = lua.lua_rawgeti(self.L, lua.LUA_REGISTRYINDEX, self.ref);
        // Push key
        LuaState.push(self.L, key);
        // Get
        _ = lua.lua_gettable(self.L, -2);
        return try LuaState.pop(T, self.L);
    }

    pub fn allocGet(self: *const Self, comptime T: type, key: anytype) !T {
        // Getting table reference
        _ = lua.lua_rawgeti(self.L, lua.LUA_REGISTRYINDEX, self.ref);
        // Push key
        LuaState.push(self.L, key);
        // Get
        _ = lua.lua_gettable(self.L, -2);
        return try LuaState.allocPop(T, self.L, self.allocator);
    }
};

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
        luaAllocator = allocator;
        var state = LuaState{
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

    pub fn injectPrettyPrint(self: *LuaState) void {
        const cmd = 
            \\-- Print contents of `tbl`, with indentation.
            \\-- `indent` sets the initial level of indentation.
            \\function pretty_print (tbl, indent)
            \\  if not indent then indent = 0 end
            \\  for k, v in pairs(tbl) do
            \\    formatting = string.rep("  ", indent) .. k .. ": "
            \\    if type(v) == "table" then
            \\      print(formatting)
            \\      pretty_print(v, indent+1)
            \\    elseif type(v) == 'boolean' then
            \\      print(formatting .. tostring(v))      
            \\    else
            \\      print(formatting .. v)
            \\    end
            \\  end
            \\end
        ;
        self.run(cmd);
    }

    pub fn run(self: *LuaState, script: []const u8) void {
        _ = lua.luaL_loadstring(self.L, @ptrCast([*c]const u8, script));
        _ = lua.lua_pcallk(self.L, 0, 0, 0, 0, null);
    }

    pub fn newUserType(self: *LuaState, comptime T: type) !void {
        if (@typeInfo(T) == .Struct) {
            try self.registeredTypes.append(@typeName(T));
            std.log.info("'{s}' is registered.", .{@typeName(T)});
        } else @compileError("New user type is invalid: '" ++ @typeName(T) ++ "'. Only 'struct'-s allowed.");
    }

    pub fn set(self: *LuaState, name: []const u8, value: anytype) void {
        _ = push(self.L, value);
        _ = lua.lua_setglobal(self.L, @ptrCast([*c]const u8, name));
    }

    pub fn get(self: *LuaState, comptime T: type, name: []const u8) !T {
        const typ = lua.lua_getglobal(self.L, @ptrCast([*c]const u8, name));
        if (typ != lua.LUA_TNIL) {
            return try pop(T, self.L);
        } else {
            return error.novalue;
        }
    }

    pub fn allocGet(self: *LuaState, comptime T: type, name: []const u8) !T {
        const typ = lua.lua_getglobal(self.L, @ptrCast([*c]const u8, name));
        if (typ != lua.LUA_TNIL) {
            return try allocPop(T, self.L, self.allocator);
        } else {
            return error.novalue;
        }
    }

    pub fn allocCreateTable(self: *LuaState) !LuaTable {
        _ = lua.lua_createtable(self.L, 0, 0);
        return try allocPop(LuaTable, self.L, self.allocator);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////
    fn pushSlice(comptime T: type, L: *lua.lua_State, values: []const T) void {
        lua.lua_createtable(L, @intCast(c_int, values.len), 0);

        for (values) |value, i| {
            push(L, i + 1);
            push(L, value);
            lua.lua_settable(L, -3);
        }
    }

    fn push(L: *lua.lua_State, value: anytype) void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .Void => lua.lua_pushnil(L),
            .Bool => lua.lua_pushboolean(L, @boolToInt(value)),
            .Int, .ComptimeInt => lua.lua_pushinteger(L, @intCast(c_longlong, value)),
            .Float, .ComptimeFloat => lua.lua_pushnumber(L, value),
            .Array => |info| {
                pushSlice(info.child, L, value[0..]);
            },
            .Pointer => |PointerInfo| switch (PointerInfo.size) {
                .Slice => {
                    if (PointerInfo.child == u8) {
                        _ = lua.lua_pushlstring(L, value.ptr, value.len);
                    } else {
                        @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                    }
                },
                .One => {
                    if (@TypeOf(PointerInfo.child) == @TypeOf([]u8)) {
                        _ = lua.lua_pushstring(L, @ptrCast([*c]const u8, value));
                    } else {
                        @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                    }
                },
                .Many => {
                    if (@TypeOf(PointerInfo.child) == @TypeOf([]u8)) {
                        _ = lua.lua_pushstring(L, @ptrCast([*c]const u8, value));
                    } else {
                        @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                    }
                },
                .C => {
                    if (@TypeOf(PointerInfo.child) == @TypeOf([]u8)) {
                        _ = lua.lua_pushstring(L, value);
                    } else {
                        @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                    }
                },
            },
            .Fn => {
                const funcType = @TypeOf(value);
                const Args = std.meta.ArgsTuple(funcType);
                // Function pointer will be a closure variable
                const _ptr = @intCast(c_longlong, @ptrToInt(value));
                lua.lua_pushinteger(L, _ptr);
                std.log.info("Function ptr: {}", .{_ptr});

                const cfun = struct {
                    fn helper(_L: ?*lua.lua_State) callconv(.C) c_int {
                        // Prepare arguments
                        var args: Args = undefined;
                        comptime var i = args.len - 1;
                        inline while (i > -1) : (i -= 1) {
                            if (comptime allocateDeallocateHelper(@TypeOf(args[i]), false, null, null)) {
                                args[i] = allocPop(@TypeOf(args[i]), _L.?, luaAllocator) catch unreachable;
                            } else {
                                args[i] = try pop(@TypeOf(args[i]), _L.?);
                            }
                        }
                        // Calling function
                        var ptr = lua.lua_tointegerx(_L, lua.lua_upvalueindex(1), null);
                        const result = @call(.{}, @intToPtr(funcType, @intCast(usize, ptr)), args);
                        comptime var resultCnt: i32 = 0;
                        // Return value 
                        if (@TypeOf(result) == void) {
                            resultCnt = 0;
                        } else {
                            push(_L.?, result);
                            resultCnt = 1;
                        }
                        // Release arguments
                        i = args.len - 1;
                        inline while (i > -1) : (i -= 1) {
                            _ = allocateDeallocateHelper(@TypeOf(args[i]), true, luaAllocator, args[i]);
                        }
                        _ = allocateDeallocateHelper(@TypeOf(result), true, luaAllocator, result);
                        return resultCnt;
                    }
                }.helper;

                lua.lua_pushcclosure(L, cfun, 1);
            },
            .Struct => |_| {
                comptime var funIdx = std.mem.indexOf(u8, @typeName(T), "LuaFunction") orelse -1;
                comptime var tblIdx = std.mem.indexOf(u8, @typeName(T), "LuaTable") orelse -1;
                if (funIdx == 0 or tblIdx == 0) {
                    _ = lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, value.ref);
                } else @compileError("Only LuaFunction ands LuaTable supported; '" ++ @typeName(T) ++ "' not.");
            },
            // .Type => {
            // },
            else => @compileError("Unsupported type: '" ++ @typeName(@TypeOf(value)) ++ "'"),
        }
    }

    fn pop(comptime T: type, L: *lua.lua_State) !T {
        defer lua.lua_pop(L, 1);
        switch (@typeInfo(T)) {
            .Bool => {
                var res = lua.lua_toboolean(L, -1);
                return if (res > 0) true else false;
            },
            .Int, .ComptimeInt => {
                var isnum: i32 = 0;
                var result: T = @intCast(T, lua.lua_tointegerx(L, -1, isnum));
                return result;
            },
            .Float, .ComptimeFloat => {
                var isnum: i32 = 0;
                var result: T = @floatCast(T, lua.lua_tonumberx(L, -1, isnum));
                return result;
            },
            // Only string, allocless get (Lua holds the pointer, it is only a slice pointing to it)
            .Pointer => |PointerInfo| switch (PointerInfo.size) {
                .Slice => {
                    // [] const u8 case
                    if (PointerInfo.child == u8 and PointerInfo.is_const) {
                        var len: usize = 0;
                        var ptr = lua.lua_tolstring(L, -1, @ptrCast([*c]usize, &len));
                        var result: T = ptr[0..len];
                        return result;
                    } else @compileError("Only '[]const u8' (aka string) is supported allocless.");
                },
                else => @compileError("invalid type: '" ++ @typeName(T) ++ "'"),
            },
            .Struct => |StructInfo| {
                if (StructInfo.is_tuple) {
                    @compileError("Tuples are not supported.");
                }
                comptime var idx = std.mem.indexOf(u8, @typeName(T), "Lua") orelse -1;
                if (idx == 0) {
                    @compileError("Only allocGet supports LuaFunction and LuaTable.");
                }

                var result: T = .{ 0, 0 };
                comptime var i = 0;
                const fields_info = std.meta.fields(T);
                inline while (i < fields_info.len) : (i += 1) {
                    //std.log.info("Parameter: {}: {} ({s})", .{i, args[i], fields_info[i].field_type});
                    result[i] = pop(@TypeOf(result[i]), L);
                }
            },
            else => @compileError("invalid type: '" ++ @typeName(T) ++ "'"),
        }
    }

    fn allocPop(comptime T: type, L: *lua.lua_State, allocator: *std.mem.Allocator) !T {
        switch (@typeInfo(T)) {
            .Pointer => |PointerInfo| switch (PointerInfo.size) {
                .Slice => {
                    defer lua.lua_pop(L, 1);
                    if (lua.lua_type(L, -1) == lua.LUA_TTABLE) {
                        lua.lua_len(L, -1);
                        const len = try pop(u64, L);
                        var res = try allocator.alloc(PointerInfo.child, @intCast(usize, len));
                        var i: u32 = 0;
                        while (i < len) : (i += 1) {
                            push(L, i + 1);
                            _ = lua.lua_gettable(L, -2);
                            res[i] = try pop(PointerInfo.child, L);
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
                comptime var funIdx = std.mem.indexOf(u8, @typeName(T), "LuaFunction") orelse -1;
                comptime var tblIdx = std.mem.indexOf(u8, @typeName(T), "LuaTable") orelse -1;
                if (funIdx == 0) {
                    if (lua.lua_type(L, -1) == lua.LUA_TFUNCTION) {
                        return T.init(L, allocator);
                    } else {
                        defer lua.lua_pop(L, 1);
                        return error.bad_type;
                    }
                } else if (tblIdx == 0) {
                    if (lua.lua_type(L, -1) == lua.LUA_TTABLE) {
                        return T.init(L, allocator);
                    } else {
                        defer lua.lua_pop(L, 1);
                        return error.bad_type;
                    }
                } else @compileError("Only LuaFunction supported; '" ++ @typeName(T) ++ "' not.");
            },
            else => @compileError("invalid type: '" ++ @typeName(T) ++ "'"),
        }
    }

    // It is a helper function, with two responsibilities:
    // 1. When it's called with only a type (allocator and value are both null) in compile time it returns that
    //    the given type is allocated or not
    // 2. When it's called with full arguments it cleans up.
    fn allocateDeallocateHelper(comptime T: type, comptime deallocate: bool, allocator: ?*std.mem.Allocator, value: ?T) bool {
        switch (@typeInfo(T)) {
            .Pointer => |PointerInfo| switch (PointerInfo.size) {
                .Slice => {
                    if (PointerInfo.child == u8 and PointerInfo.is_const) {
                        return false;
                    } else {
                        if (deallocate) {
                            allocator.?.free(value.?);
                        }
                        return true;
                    }
                },
                else => return false,
            },
            .Struct => |_| {
                comptime var funIdx = std.mem.indexOf(u8, @typeName(T), "LuaFunction") orelse -1;
                comptime var tblIdx = std.mem.indexOf(u8, @typeName(T), "LuaTable") orelse -1;
                if (funIdx == 0 or tblIdx == 0) {
                    if (deallocate) {
                        value.?.destroy();
                    }
                    return true;
                } else return false;
            },
            else => {
                return false;
            },
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

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var luaState = try LuaState.init(&gpa.allocator);
    defer luaState.destroy();

    luaState.openLibs();
    luaState.injectPrettyPrint();
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

    var strMany: [*]const u8 = "macilaci";
    var strSlice: []const u8 = "macilaic";
    var strOne = "macilaci";
    var strC: [*c]const u8 = "macilaci";

    const cstrMany: [*]const u8 = "macilaci";
    const cstrSlice: []const u8 = "macilaic";
    const cstrOne = "macilaci";
    const cstrC: [*c]const u8 = "macilaci";

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

    const boolSlice = [_]bool{ true, false, true };
    const intSlice = [_]i32{ 4, 5, 3, 4, 0 };
    const strSlice = [_][]const u8{ "Macilaci", "Gyumifagyi", "Angolhazi" };

    luaState.set("boolSlice", boolSlice);
    luaState.set("intSlice", intSlice);
    luaState.set("strSlice", strSlice);

    const retBoolSlice = try luaState.allocGet([]i32, "boolSlice");
    defer std.testing.allocator.free(retBoolSlice);

    const retIntSlice = try luaState.allocGet([]i32, "intSlice");
    defer std.testing.allocator.free(retIntSlice);

    const retStrSlice = try luaState.allocGet([][]const u8, "strSlice");
    defer std.testing.allocator.free(retStrSlice);

    for (retIntSlice) |v, i| {
        try std.testing.expectEqual(v, intSlice[i]);
    }

    for (retStrSlice) |v, i| {
        try std.testing.expect(std.mem.eql(u8, v, strSlice[i]));
    }
}

test "simple Zig => Lua function call" {
    var luaState = try LuaState.init(std.testing.allocator);
    defer luaState.destroy();

    luaState.openLibs();

    const lua_command =
        \\function test_1() end
        \\function test_2(a) end
        \\function test_3(a) return a; end
        \\function test_4(a,b) return a+b; end
    ;

    luaState.run(lua_command);

    var fun1 = try luaState.allocGet(LuaFunction(fn () void), "test_1");
    defer fun1.destroy();

    var fun2 = try luaState.allocGet(LuaFunction(fn (a: i32) void), "test_2");
    defer fun2.destroy();

    var fun3_1 = try luaState.allocGet(LuaFunction(fn (a: i32) i32), "test_3");
    defer fun3_1.destroy();

    var fun3_2 = try luaState.allocGet(LuaFunction(fn (a: []const u8) []const u8), "test_3");
    defer fun3_2.destroy();

    var fun4 = try luaState.allocGet(LuaFunction(fn (a: i32, b: i32) i32), "test_4");
    defer fun4.destroy();

    try fun1.call(.{});
    try fun2.call(.{42});
    const res3_1 = try fun3_1.call(.{42});
    try std.testing.expectEqual(res3_1, 42);

    const res3_2 = try fun3_2.call(.{"Bela"});
    try std.testing.expect(std.mem.eql(u8, res3_2, "Bela"));

    const res4 = try fun4.call(.{ 42, 24 });
    try std.testing.expectEqual(res4, 66);
}

var testResult0: bool = false;
fn testFun0() void {
    testResult0 = true;
}

var testResult1: i32 = 0;
fn testFun1(a: i32, b: i32) void {
    testResult1 = a - b;
}

var testResult2: i32 = 0;
fn testFun2(a: []const u8) void {
    for (a) |ch| {
        testResult2 += ch - '0';
    }
}

var testResult3: i32 = 0;
fn testFun3(a: []const u8, b: i32) void {
    for (a) |ch| {
        testResult3 += ch - '0';
    }
    testResult3 -= b;
}

test "simple Lua => Zig function call" {
    var luaState = try LuaState.init(std.testing.allocator);
    defer luaState.destroy();

    luaState.openLibs();

    luaState.set("testFun0", testFun0);
    luaState.set("testFun1", testFun1);
    luaState.set("testFun2", testFun2);
    luaState.set("testFun3", testFun3);

    luaState.run("testFun0()");
    try std.testing.expect(testResult0 == true);

    luaState.run("testFun1(42,10)");
    try std.testing.expect(testResult1 == 32);

    luaState.run("testFun2('0123456789')");
    try std.testing.expect(testResult2 == 45);

    luaState.run("testFun3('0123456789', -10)");
    try std.testing.expect(testResult3 == 55);

    testResult0 = false;
    testResult1 = 0;
    testResult2 = 0;
    testResult3 = 0;

    luaState.run("testFun3('0123456789', -10)");
    try std.testing.expect(testResult3 == 55);

    luaState.run("testFun2('0123456789')");
    try std.testing.expect(testResult2 == 45);

    luaState.run("testFun1(42,10)");
    try std.testing.expect(testResult1 == 32);

    luaState.run("testFun0()");
    try std.testing.expect(testResult0 == true);
}

fn testFun4(a: []const u8) []const u8 {
    return a;
}

fn testFun5(a: i32, b: i32) i32 {
    return a - b;
}

test "simple Zig => Lua => Zig function call" {
    var luaState = try LuaState.init(std.testing.allocator);
    defer luaState.destroy();

    luaState.openLibs();

    luaState.set("testFun4", testFun4);
    luaState.set("testFun5", testFun5);

    luaState.run("function luaTestFun4(a) return testFun4(a); end");
    luaState.run("function luaTestFun5(a,b) return testFun5(a,b); end");

    var fun4 = try luaState.allocGet(LuaFunction(fn (a: []const u8) []const u8), "luaTestFun4");
    defer fun4.destroy();

    var fun5 = try luaState.allocGet(LuaFunction(fn (a: i32, b: i32) i32), "luaTestFun5");
    defer fun5.destroy();

    var res4 = try fun4.call(.{"macika"});
    var res5 = try fun5.call(.{ 42, 1 });

    try std.testing.expect(std.mem.eql(u8, res4, "macika"));
    try std.testing.expect(res5 == 41);
}

fn testLuaInnerFun(fun: LuaFunction(fn (a: i32) i32)) i32 {
    var res = fun.call(.{42}) catch unreachable;
    return res;
}

test "Lua function injection into Zig function" {
    var luaState = try LuaState.init(std.testing.allocator);
    defer luaState.destroy();

    luaState.openLibs();
    // Binding on Zig side
    luaState.run("function getInt(a) return a+1; end");
    var luafun = try luaState.allocGet(LuaFunction(fn (a: i32) i32), "getInt");
    defer luafun.destroy();

    var result = testLuaInnerFun(luafun);
    std.log.info("Zig Result: {}", .{result});

    // Binding on Lua side
    luaState.set("zigFunction", testLuaInnerFun);

    const lua_command =
        \\function getInt(a) return a+1; end
        \\zigFunction(getInt);
    ;

    luaState.run(lua_command);
}

fn zigInnerFun(a: i32) i32 {
    return 2 * a;
}

test "Zig function injection into Lua function" {
    var luaState = try LuaState.init(std.testing.allocator);
    defer luaState.destroy();

    luaState.openLibs();

    // Binding
    luaState.set("zigFunction", zigInnerFun);

    const lua_command =
        \\function test(a) res = a(2); return res; end
        \\test(zigFunction);
    ;

    luaState.run(lua_command);
}

fn testSliceInput(a: []i32) i32 {
    var sum: i32 = 0;
    for (a) |v| {
        sum += v;
    }
    return sum;
}

test "Slice input to Zig function" {
    var luaState = try LuaState.init(std.testing.allocator);
    defer luaState.destroy();

    luaState.openLibs();

    // Binding
    luaState.set("sumFunction", testSliceInput);

    const lua_command =
        \\res = sumFunction({1,2,3});
    ;

    luaState.run(lua_command);
}

test "LuaTable allocless set/get tests" {
    var luaState = try LuaState.init(std.testing.allocator);
    defer luaState.destroy();

    luaState.openLibs();

    // Create table
    var originalTbl = try luaState.allocCreateTable();
    defer originalTbl.destroy();
    luaState.set("tbl", originalTbl);

    originalTbl.set("owner", true);

    var tbl = try luaState.allocGet(LuaTable, "tbl");
    defer tbl.destroy();

    const owner = try tbl.get(bool, "owner");
    try std.testing.expect(owner);

    // Numeric
    const int16In: i16 = 1;
    const int32In: i32 = 2;
    const int64In: i64 = 3;

    const f16In: f16 = 3.1415;
    const f32In: f32 = 3.1415;
    const f64In: f64 = 3.1415;

    const bIn: bool = true;

    tbl.set("int16", int16In);
    tbl.set("int32", int32In);
    tbl.set("int64", int64In);

    tbl.set("float16", f16In);
    tbl.set("float32", f32In);
    tbl.set("float64", f64In);

    tbl.set("bool", bIn);

    var int16Out = try tbl.get(i16, "int16");
    var int32Out = try tbl.get(i32, "int32");
    var int64Out = try tbl.get(i64, "int64");

    var f16Out = try tbl.get(f16, "float16");
    var f32Out = try tbl.get(f32, "float32");
    var f64Out = try tbl.get(f64, "float64");

    var bOut = try tbl.get(bool, "bool");

    try std.testing.expectEqual(int16In, int16Out);
    try std.testing.expectEqual(int32In, int32Out);
    try std.testing.expectEqual(int64In, int64Out);

    try std.testing.expectEqual(f16In, f16Out);
    try std.testing.expectEqual(f32In, f32Out);
    try std.testing.expectEqual(f64In, f64Out);

    try std.testing.expectEqual(bIn, bOut);

    // String
    const str: []const u8 = "Hello World";
    tbl.set("str", str);

    const retStr = try tbl.get([]const u8, "str");
    try std.testing.expect(std.mem.eql(u8, str, retStr));
}

fn tblFun(a: i32) i32 {
    return 3*a;
}

test "LuaTable inner table tests" {
    var luaState = try LuaState.init(std.testing.allocator);
    defer luaState.destroy();

    luaState.openLibs();

    // Create table
    var tbl = try luaState.allocCreateTable();
    defer tbl.destroy();
    luaState.set("tbl", tbl);

    var inTbl0 = try luaState.allocCreateTable();
    defer inTbl0.destroy();

    var inTbl1 = try luaState.allocCreateTable();
    defer inTbl0.destroy();

    inTbl1.set("str", "string");
    inTbl1.set("int32", 68);
    inTbl1.set("fn", tblFun);

    inTbl0.set(1, "string");
    inTbl0.set(2, 3.1415);
    inTbl0.set(3, 42);
    inTbl0.set("table", inTbl1);

    tbl.set("innerTable", inTbl0);
    
    var retTbl = try luaState.allocGet(LuaTable, "tbl");
    defer retTbl.destroy();

    var retInnerTable = try retTbl.allocGet(LuaTable, "innerTable");
    defer retInnerTable.destroy();

    var str = try retInnerTable.get([]const u8, 1);
    var float = try retInnerTable.get(f32, 2);
    var int = try retInnerTable.get(i32, 3);

    try std.testing.expect( std.mem.eql(u8, str, "string"));
    try std.testing.expect( float == 3.1415);
    try std.testing.expect( int == 42);

    var retInner2Table = try retInnerTable.allocGet(LuaTable, "table");
    defer retInner2Table.destroy();

    str = try retInner2Table.get([]const u8, "str");
    int = try retInner2Table.get(i32, "int32");
    var func = try retInner2Table.allocGet(LuaFunction(fn(a:i32) i32), "fn");
    defer func.destroy();
    var funcRes = try func.call(.{42});

    try std.testing.expect( std.mem.eql(u8, str, "string"));
    try std.testing.expect( int == 68);
    try std.testing.expect( funcRes == 3*42);
}

var luaTableArgSum: i32 = 0;
fn testLuaTableArg(t: LuaTable) i32 {
    var a = t.get(i32, "a") catch -1;
    var b = t.get(i32, "b") catch -1;
    luaTableArgSum = a+b;
    return luaTableArgSum;
}

test "Function with LuaTable argument" {
    var luaState = try LuaState.init(std.testing.allocator);
    defer luaState.destroy();

    luaState.openLibs();
    // Zig side
    var tbl = try luaState.allocCreateTable();
    defer tbl.destroy();

    tbl.set("a", 42);
    tbl.set("b", 128);
    var zigRes = testLuaTableArg(tbl);

    try std.testing.expect(zigRes == 42+128);

    // Lua side
    luaState.set("sumFn", testLuaTableArg);
    luaState.run("function test() return sumFn({a=1, b=2}); end");

    var luaFun = try luaState.allocGet(LuaFunction(fn() i32), "test");
    defer luaFun.destroy();

    var luaRes = try luaFun.call(.{});
    try std.testing.expect(luaRes == 1+2);
}

fn testLuaTableArgOut(t: LuaTable) LuaTable {
    t.set(1, 42);
    t.set(2, 128);
    return t;
}

test "Function with LuaTable result" {
    var luaState = try LuaState.init(std.testing.allocator);
    defer luaState.destroy();

    luaState.openLibs();
    luaState.injectPrettyPrint();
    // Zig side
    var tbl = try luaState.allocCreateTable();
    defer tbl.destroy();

    var zigRes = testLuaTableArgOut(tbl);

    var zigA = try zigRes.get(i32, 1);
    var zigB = try zigRes.get(i32, 2);

    try std.testing.expect((zigA + zigB) == 42+128);

    // Lua side
    luaState.set("tblFn", testLuaTableArgOut);
    //luaState.run("function test() tbl = tblFn({}); return tbl[1] + tbl[2]; end");
    luaState.run("function test() tbl = tblFn({}); return tbl[1] + tbl[2]; end");

    var luaFun = try luaState.allocGet(LuaFunction(fn() i32), "test");
    defer luaFun.destroy();

    var luaRes = try luaFun.call(.{});
    try std.testing.expect(luaRes == 42+128);
}