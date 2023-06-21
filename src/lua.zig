const std = @import("std");
const assert = std.debug.assert;

pub const lualib = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

pub const Lua = struct {
    const LuaUserData = struct {
        allocator: std.mem.Allocator,
        registeredTypes: std.StringArrayHashMap([]const u8) = undefined,

        fn init(_allocator: std.mem.Allocator) LuaUserData {
            return LuaUserData{ .allocator = _allocator, .registeredTypes = std.StringArrayHashMap([]const u8).init(_allocator) };
        }

        fn destroy(self: *LuaUserData) void {
            self.registeredTypes.clearAndFree();
        }
    };

    L: *lualib.lua_State,
    ud: *LuaUserData,

    pub fn init(allocator: std.mem.Allocator) !Lua {
        var _ud = try allocator.create(LuaUserData);
        _ud.* = LuaUserData.init(allocator);

        var _state = lualib.lua_newstate(alloc, _ud) orelse return error.OutOfMemory;
        var state = Lua{
            .L = _state,
            .ud = _ud,
        };
        return state;
    }

    pub fn destroy(self: *Lua) void {
        _ = lualib.lua_close(self.L);
        self.ud.destroy();
        var allocator = self.ud.allocator;
        allocator.destroy(self.ud);
    }

    pub fn openLibs(self: *Lua) void {
        _ = lualib.luaL_openlibs(self.L);
    }

    pub fn injectPrettyPrint(self: *Lua) void {
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

    pub fn run(self: *Lua, script: []const u8) void {
        _ = lualib.luaL_loadstring(self.L, @ptrCast([*c]const u8, script));
        _ = lualib.lua_pcallk(self.L, 0, 0, 0, 0, null);
    }

    pub fn set(self: *Lua, name: []const u8, value: anytype) void {
        _ = push(self.L, value);
        _ = lualib.lua_setglobal(self.L, @ptrCast([*c]const u8, name));
    }

    pub fn get(self: *Lua, comptime T: type, name: []const u8) !T {
        const typ = lualib.lua_getglobal(self.L, @ptrCast([*c]const u8, name));
        if (typ != lualib.LUA_TNIL) {
            return try pop(T, self.L);
        } else {
            return error.novalue;
        }
    }

    pub fn getResource(self: *Lua, comptime T: type, name: []const u8) !T {
        const typ = lualib.lua_getglobal(self.L, @ptrCast([*c]const u8, name));
        if (typ != lualib.LUA_TNIL) {
            return try popResource(T, self.L);
        } else {
            return error.novalue;
        }
    }

    pub fn createTable(self: *Lua) !Lua.Table {
        _ = lualib.lua_createtable(self.L, 0, 0);
        return try popResource(Lua.Table, self.L);
    }

    pub fn createUserType(self: *Lua, comptime T: type, params: anytype) !Ref(T) {
        var metaTableName: []const u8 = undefined;
        // Allocate memory
        var ptr = @ptrCast(*T, @alignCast(@alignOf(T), lualib.lua_newuserdata(self.L, @sizeOf(T))));
        // set its metatable
        if (getUserData(self.L).registeredTypes.get(@typeName(T))) |name| {
            metaTableName = name;
        } else {
            return error.unregistered_type;
        }
        _ = lualib.luaL_getmetatable(self.L, @ptrCast([*c]const u8, metaTableName[0..]));
        _ = lualib.lua_setmetatable(self.L, -2);
        // (3) init & copy wrapped object
        // Call init
        const ArgTypes = std.meta.ArgsTuple(@TypeOf(T.init));
        var args: ArgTypes = undefined;
        const fields_info = std.meta.fields(@TypeOf(params));
        const len = args.len;
        comptime var idx = 0;
        inline while (idx < len) : (idx += 1) {
            args[idx] = @field(params, fields_info[idx].name);
        }
        ptr.* = @call(.auto, T.init, args);
        // (4) check and store the callback table
        //_ = lua.luaL_checktype(L, 1, lua.LUA_TTABLE);
        _ = lualib.lua_pushvalue(self.L, 1);
        _ = lualib.lua_setuservalue(self.L, -2);
        var res = try popResource(Ref(T), self.L);
        res.ptr = ptr;
        return res;
    }

    pub fn release(self: *Lua, v: anytype) void {
        _ = allocateDeallocateHelper(@TypeOf(v), true, self.ud.allocator, v);
    }

    // Zig 0.10.0+ returns a fully qualified struct name, so require an explicit UserType name
    pub fn newUserType(self: *Lua, comptime T: type, comptime name: []const u8) !void {
        comptime var hasInit: bool = false;
        comptime var hasDestroy: bool = false;
        comptime var metaTblName: [1024]u8 = undefined;
        _ = comptime try std.fmt.bufPrint(metaTblName[0..], "{s}", .{name});
        // Init Lua states
        comptime var allocFuns = struct {
            fn new(L: ?*lualib.lua_State) callconv(.C) c_int {
                // (1) get arguments
                var caller = ZigCallHelper(@TypeOf(T.init)).LowLevelHelpers.init();
                caller.prepareArgs(L) catch unreachable;

                // (2) create Lua object
                var ptr = @ptrCast(*T, @alignCast(@alignOf(T), lualib.lua_newuserdata(L, @sizeOf(T))));
                // set its metatable
                _ = lualib.luaL_getmetatable(L, @ptrCast([*c]const u8, metaTblName[0..]));
                _ = lualib.lua_setmetatable(L, -2);
                // (3) init & copy wrapped object
                caller.call(T.init) catch unreachable;
                ptr.* = caller.result;
                // (4) check and store the callback table
                //_ = lua.luaL_checktype(L, 1, lua.LUA_TTABLE);
                _ = lualib.lua_pushvalue(L, 1);
                _ = lualib.lua_setuservalue(L, -2);

                return 1;
            }

            fn gc(L: ?*lualib.lua_State) callconv(.C) c_int {
                var ptr = @ptrCast(*T, @alignCast(@alignOf(T), lualib.luaL_checkudata(L, 1, @ptrCast([*c]const u8, metaTblName[0..]))));
                ptr.destroy();
                return 0;
            }
        };
        // Create metatable
        _ = lualib.luaL_newmetatable(self.L, @ptrCast([*c]const u8, metaTblName[0..]));
        // Metatable.__index = metatable
        lualib.lua_pushvalue(self.L, -1);
        lualib.lua_setfield(self.L, -2, "__index");

        //lua.luaL_setfuncs(self.L, &methods, 0); =>
        lualib.lua_pushcclosure(self.L, allocFuns.gc, 0);
        lualib.lua_setfield(self.L, -2, "__gc");

        // Collect information
        switch (@typeInfo(T)) {
            .Struct => |StructInfo| {
                inline for (StructInfo.decls) |decl| {
                    if (comptime std.mem.eql(u8, decl.name, "init") == true) {
                        hasInit = true;
                    } else if (comptime std.mem.eql(u8, decl.name, "destroy") == true) {
                        hasDestroy = true;
                    } else if (decl.is_pub) {
                        comptime var field = @field(T, decl.name);
                        const Caller = ZigCallHelper(@TypeOf(field));
                        Caller.pushFunctor(self.L, field) catch unreachable;
                        lualib.lua_setfield(self.L, -2, @ptrCast([*c]const u8, decl.name));
                    }
                }
            },
            else => @compileError("Only Struct supported."),
        }
        if ((hasInit == false) or (hasDestroy == false)) {
            @compileError("Struct has to have init and destroy methods.");
        }
        // Only the 'new' function
        // <==_ = lua.luaL_newlib(lua.L, &arraylib_f); ==>
        lualib.luaL_checkversion(self.L);
        lualib.lua_createtable(self.L, 0, 1);
        // lua.luaL_setfuncs(self.L, &funcs, 0); =>
        lualib.lua_pushcclosure(self.L, allocFuns.new, 0);
        lualib.lua_setfield(self.L, -2, "new");

        // Set as global ('require' requires luaopen_{libraname} named static C functionsa and we don't want to provide one)
        _ = lualib.lua_setglobal(self.L, @ptrCast([*c]const u8, metaTblName[0..]));

        // Store in the registry
        try getUserData(self.L).registeredTypes.put(@typeName(T), metaTblName[0..]);
    }

    pub fn Function(comptime T: type) type {
        const FuncType = T;
        const RetType = blk: {
            const FuncInfo = @typeInfo(FuncType);
            if (FuncInfo == .Pointer) {
                const PointerInfo = @typeInfo(FuncInfo.Pointer.child);
                if (PointerInfo == .Fn) {
                    break :blk PointerInfo.Fn.return_type;
                }
            }

            @compileError("Unsupported type");
        };
        return struct {
            const Self = @This();

            L: *lualib.lua_State,
            ref: c_int = undefined,
            func: FuncType = undefined,

            // This 'Init' assumes, that the top element of the stack is a Lua function
            pub fn init(_L: *lualib.lua_State) Self {
                const _ref = lualib.luaL_ref(_L, lualib.LUA_REGISTRYINDEX);
                var res = Self{
                    .L = _L,
                    .ref = _ref,
                };
                return res;
            }

            pub fn destroy(self: *const Self) void {
                lualib.luaL_unref(self.L, lualib.LUA_REGISTRYINDEX, self.ref);
            }

            pub fn call(self: *const Self, args: anytype) !RetType.? {
                const ArgsType = @TypeOf(args);
                if (@typeInfo(ArgsType) != .Struct) {
                    ("Expected tuple or struct argument, found " ++ @typeName(ArgsType));
                }
                // Getting function reference
                _ = lualib.lua_rawgeti(self.L, lualib.LUA_REGISTRYINDEX, self.ref);
                // Preparing arguments
                comptime var i = 0;
                const fields_info = std.meta.fields(ArgsType);
                inline while (i < fields_info.len) : (i += 1) {
                    Lua.push(self.L, args[i]);
                }
                // Calculating retval count
                comptime var retValCount = switch (@typeInfo(RetType.?)) {
                    .Void => 0,
                    .Struct => |StructInfo| StructInfo.fields.len,
                    else => 1,
                };
                // Calling
                if (lualib.lua_pcallk(self.L, fields_info.len, retValCount, 0, 0, null) != lualib.LUA_OK) {
                    return error.lua_runtime_error;
                }
                // Getting return value(s)
                if (retValCount > 0) {
                    return Lua.pop(RetType.?, self.L);
                }
            }
        };
    }

    pub const Table = struct {
        const Self = @This();

        L: *lualib.lua_State,
        ref: c_int = undefined,

        // This 'Init' assumes, that the top element of the stack is a Lua table
        pub fn init(_L: *lualib.lua_State) Self {
            const _ref = lualib.luaL_ref(_L, lualib.LUA_REGISTRYINDEX);
            var res = Self{
                .L = _L,
                .ref = _ref,
            };
            return res;
        }

        // Unregister this shit
        pub fn destroy(self: *const Self) void {
            lualib.luaL_unref(self.L, lualib.LUA_REGISTRYINDEX, self.ref);
        }

        pub fn clone(self: *const Self) Self {
            _ = lualib.lua_rawgeti(self.L, lualib.LUA_REGISTRYINDEX, self.ref);
            return Table.init(self.L, self.allocator);
        }

        pub fn set(self: *const Self, key: anytype, value: anytype) void {
            // Getting table reference
            _ = lualib.lua_rawgeti(self.L, lualib.LUA_REGISTRYINDEX, self.ref);
            // Push key, value
            Lua.push(self.L, key);
            Lua.push(self.L, value);
            // Set
            lualib.lua_settable(self.L, -3);
        }

        pub fn get(self: *const Self, comptime T: type, key: anytype) !T {
            // Getting table by reference
            _ = lualib.lua_rawgeti(self.L, lualib.LUA_REGISTRYINDEX, self.ref);
            // Push key
            Lua.push(self.L, key);
            // Get
            _ = lualib.lua_gettable(self.L, -2);
            return try Lua.pop(T, self.L);
        }

        pub fn getResource(self: *const Self, comptime T: type, key: anytype) !T {
            // Getting table reference
            _ = lualib.lua_rawgeti(self.L, lualib.LUA_REGISTRYINDEX, self.ref);
            // Push key
            Lua.push(self.L, key);
            // Get
            _ = lualib.lua_gettable(self.L, -2);
            return try Lua.popResource(T, self.L);
        }
    };

    pub fn Ref(comptime T: type) type {
        return struct {
            const Self = @This();

            L: *lualib.lua_State,
            ref: c_int = undefined,
            ptr: *T = undefined,

            pub fn init(_L: *lualib.lua_State) Self {
                const _ref = lualib.luaL_ref(_L, lualib.LUA_REGISTRYINDEX);
                var res = Self{
                    .L = _L,
                    .ref = _ref,
                };
                return res;
            }

            pub fn destroy(self: *const Self) void {
                _ = lualib.luaL_unref(self.L, lualib.LUA_REGISTRYINDEX, self.ref);
            }

            pub fn clone(self: *const Self) Self {
                _ = lualib.lua_rawgeti(self.L, lualib.LUA_REGISTRYINDEX, self.ref);
                var result = Self.init(self.L);
                result.ptr = self.ptr;
                return result;
            }
        };
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////
    fn pushSlice(comptime T: type, L: *lualib.lua_State, values: []const T) void {
        lualib.lua_createtable(L, @intCast(c_int, values.len), 0);

        for (values, 0..) |value, i| {
            push(L, i + 1);
            push(L, value);
            lualib.lua_settable(L, -3);
        }
    }

    fn push(L: *lualib.lua_State, value: anytype) void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .Void => lualib.lua_pushnil(L),
            .Bool => lualib.lua_pushboolean(L, @boolToInt(value)),
            .Int, .ComptimeInt => lualib.lua_pushinteger(L, @intCast(c_longlong, value)),
            .Float, .ComptimeFloat => lualib.lua_pushnumber(L, value),
            .Array => |info| {
                pushSlice(info.child, L, value[0..]);
            },
            .Pointer => |PointerInfo| switch (PointerInfo.size) {
                .Slice => {
                    if (PointerInfo.child == u8) {
                        _ = lualib.lua_pushlstring(L, value.ptr, value.len);
                    } else {
                        @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                    }
                },
                .One => {
                    switch (@typeInfo(PointerInfo.child)) {
                        .Array => |childInfo| {
                            if (childInfo.child == u8) {
                                _ = lualib.lua_pushstring(L, @ptrCast([*c]const u8, value));
                            } else {
                                @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                            }
                        },
                        .Struct => {
                            unreachable;
                        },
                        else => @compileError("BAszomalassan"),
                    }
                },
                .Many => {
                    if (PointerInfo.child == u8) {
                        _ = lualib.lua_pushstring(L, @ptrCast([*c]const u8, value));
                    } else {
                        @compileError("invalid type: '" ++ @typeName(T) ++ "'. Typeinfo: '" ++ @typeInfo(PointerInfo.child) ++ "'");
                    }
                },
                .C => {
                    if (PointerInfo.child == u8) {
                        _ = lualib.lua_pushstring(L, value);
                    } else {
                        @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                    }
                },
            },
            .Fn => {
                const Helper = ZigCallHelper(@TypeOf(value));
                Helper.pushFunctor(L, value) catch unreachable;
            },
            .Struct => |_| {
                comptime var funIdx = std.mem.indexOf(u8, @typeName(T), "Function") orelse -1;
                comptime var tblIdx = std.mem.indexOf(u8, @typeName(T), "Table") orelse -1;
                comptime var refIdx = std.mem.indexOf(u8, @typeName(T), "Ref(") orelse -1;
                if (funIdx >= 0 or tblIdx >= 0 or refIdx >= 0) {
                    _ = lualib.lua_rawgeti(L, lualib.LUA_REGISTRYINDEX, value.ref);
                } else @compileError("Only Function ands Lua.Table supported; '" ++ @typeName(T) ++ "' not.");
            },
            // .Type => {
            // },
            else => @compileError("Unsupported type: '" ++ @typeName(@TypeOf(value)) ++ "'"),
        }
    }

    fn pop(comptime T: type, L: *lualib.lua_State) !T {
        defer lualib.lua_pop(L, 1);
        switch (@typeInfo(T)) {
            .Bool => {
                var res = lualib.lua_toboolean(L, -1);
                return if (res > 0) true else false;
            },
            .Int, .ComptimeInt => {
                var isnum: i32 = 0;
                var result: T = @intCast(T, lualib.lua_tointegerx(L, -1, isnum));
                return result;
            },
            .Float, .ComptimeFloat => {
                var isnum: i32 = 0;
                var result: T = @floatCast(T, lualib.lua_tonumberx(L, -1, isnum));
                return result;
            },
            // Only string, allocless get (Lua holds the pointer, it is only a slice pointing to it)
            .Pointer => |PointerInfo| switch (PointerInfo.size) {
                .Slice => {
                    // [] const u8 case
                    if (PointerInfo.child == u8 and PointerInfo.is_const) {
                        var len: usize = 0;
                        var ptr = lualib.lua_tolstring(L, -1, @ptrCast([*c]usize, &len));
                        var result: T = ptr[0..len];
                        return result;
                    } else @compileError("Only '[]const u8' (aka string) is supported allocless.");
                },
                .One => {
                    var optionalTbl = getUserData(L).registeredTypes.get(@typeName(PointerInfo.child));
                    if (optionalTbl) |tbl| {
                        var result = @ptrCast(T, @alignCast(@alignOf(PointerInfo.child), lualib.luaL_checkudata(L, -1, @ptrCast([*c]const u8, tbl[0..]))));
                        return result;
                    } else {
                        return error.invalidType;
                    }
                },
                else => @compileError("invalid type: '" ++ @typeName(T) ++ "'"),
            },
            .Struct => |StructInfo| {
                if (StructInfo.is_tuple) {
                    @compileError("Tuples are not supported.");
                }
                comptime var funIdx = std.mem.indexOf(u8, @typeName(T), "Function") orelse -1;
                comptime var tblIdx = std.mem.indexOf(u8, @typeName(T), "Table") orelse -1;
                if (funIdx >= 0 or tblIdx >= 0) {
                    @compileError("Only allocGet supports Lua.Function and Lua.Table. Your type '" ++ @typeName(T) ++ "' is not supported.");
                }

                var result: T = .{ 0, 0 };
                comptime var i = 0;
                const fields_info = std.meta.fields(T);
                inline while (i < fields_info.len) : (i += 1) {
                    result[i] = pop(@TypeOf(result[i]), L);
                }
            },
            else => @compileError("invalid type: '" ++ @typeName(T) ++ "'"),
        }
    }

    fn popResource(comptime T: type, L: *lualib.lua_State) !T {
        switch (@typeInfo(T)) {
            .Pointer => |PointerInfo| switch (PointerInfo.size) {
                .Slice => {
                    defer lualib.lua_pop(L, 1);
                    if (lualib.lua_type(L, -1) == lualib.LUA_TTABLE) {
                        lualib.lua_len(L, -1);
                        const len = try pop(u64, L);
                        var res = try getAllocator(L).alloc(PointerInfo.child, @intCast(usize, len));
                        var i: u32 = 0;
                        while (i < len) : (i += 1) {
                            push(L, i + 1);
                            _ = lualib.lua_gettable(L, -2);
                            res[i] = try pop(PointerInfo.child, L);
                        }
                        return res;
                    } else {
                        return error.bad_type;
                    }
                },
                else => @compileError("Only Slice is supported."),
            },
            .Struct => |_| {
                comptime var funIdx = std.mem.indexOf(u8, @typeName(T), "Function") orelse -1;
                comptime var tblIdx = std.mem.indexOf(u8, @typeName(T), "Table") orelse -1;
                comptime var refIdx = std.mem.indexOf(u8, @typeName(T), "Ref(") orelse -1;
                if (funIdx >= 0) {
                    if (lualib.lua_type(L, -1) == lualib.LUA_TFUNCTION) {
                        return T.init(L);
                    } else {
                        defer lualib.lua_pop(L, 1);
                        return error.bad_type;
                    }
                } else if (tblIdx >= 0) {
                    if (lualib.lua_type(L, -1) == lualib.LUA_TTABLE) {
                        return T.init(L);
                    } else {
                        defer lualib.lua_pop(L, 1);
                        return error.bad_type;
                    }
                } else if (refIdx >= 0) {
                    if (lualib.lua_type(L, -1) == lualib.LUA_TUSERDATA) {
                        return T.init(L);
                    } else {
                        defer lualib.lua_pop(L, 1);
                        return error.bad_type;
                    }
                } else @compileError("Only Function supported; '" ++ @typeName(T) ++ "' not.");
            },
            else => @compileError("invalid type: '" ++ @typeName(T) ++ "'"),
        }
    }

    // It is a helper function, with two responsibilities:
    // 1. When it's called with only a type (allocator and value are both null) in compile time it returns that
    //    the given type is allocated or not
    // 2. When it's called with full arguments it cleans up.
    fn allocateDeallocateHelper(comptime T: type, comptime deallocate: bool, allocator: ?std.mem.Allocator, value: ?T) bool {
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
                comptime var funIdx = std.mem.indexOf(u8, @typeName(T), "Function") orelse -1;
                comptime var tblIdx = std.mem.indexOf(u8, @typeName(T), "Table") orelse -1;
                comptime var refIdx = std.mem.indexOf(u8, @typeName(T), "Ref(") orelse -1;
                if (funIdx >= 0 or tblIdx >= 0 or refIdx >= 0) {
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

    fn ZigCallHelper(comptime funcType: type) type {
        const info = @typeInfo(funcType);
        if (info != .Fn) {
            @compileError("ZigCallHelper expects a function type");
        }

        const ReturnType = info.Fn.return_type.?;
        const ArgTypes = std.meta.ArgsTuple(funcType);
        const resultCnt = if (ReturnType == void) 0 else 1;

        return struct {
            pub const LowLevelHelpers = struct {
                const Self = @This();

                args: ArgTypes = undefined,
                result: ReturnType = undefined,

                pub fn init() Self {
                    return Self{};
                }

                fn prepareArgs(self: *Self, L: ?*lualib.lua_State) !void {
                    // Prepare arguments
                    if (self.args.len <= 0) return;
                    comptime var i: i32 = self.args.len - 1;
                    inline while (i > -1) : (i -= 1) {
                        if (comptime allocateDeallocateHelper(@TypeOf(self.args[i]), false, null, null)) {
                            self.args[i] = popResource(@TypeOf(self.args[i]), L.?) catch unreachable;
                        } else {
                            self.args[i] = pop(@TypeOf(self.args[i]), L.?) catch unreachable;
                        }
                    }
                }

                fn call(self: *Self, func: *const funcType) !void {
                    self.result = @call(.auto, func, self.args);
                }

                fn pushResult(self: *Self, L: ?*lualib.lua_State) !void {
                    if (resultCnt > 0) {
                        push(L.?, self.result);
                    }
                }

                fn destroyArgs(self: *Self, L: ?*lualib.lua_State) !void {
                    if (self.args.len <= 0) return;
                    comptime var i: i32 = self.args.len - 1;
                    inline while (i > -1) : (i -= 1) {
                        _ = allocateDeallocateHelper(@TypeOf(self.args[i]), true, getAllocator(L), self.args[i]);
                    }
                    _ = allocateDeallocateHelper(ReturnType, true, getAllocator(L), self.result);
                }
            };

            pub fn pushFunctor(L: ?*lualib.lua_State, func: *const funcType) !void {
                const funcPtrAsInt = @intCast(c_longlong, @ptrToInt(func));
                lualib.lua_pushinteger(L, funcPtrAsInt);

                const cfun = struct {
                    fn helper(_L: ?*lualib.lua_State) callconv(.C) c_int {
                        var f: LowLevelHelpers = undefined;
                        // Prepare arguments from stack
                        f.prepareArgs(_L) catch unreachable;
                        // Get func pointer upvalue as int => convert to func ptr then call
                        var ptr = lualib.lua_tointegerx(_L, lualib.lua_upvalueindex(1), null);
                        f.call(@intToPtr(*const funcType, @intCast(usize, ptr))) catch unreachable;
                        // The end
                        f.pushResult(_L) catch unreachable;
                        // Release arguments
                        f.destroyArgs(_L) catch unreachable;
                        return resultCnt;
                    }
                }.helper;
                lualib.lua_pushcclosure(L, cfun, 1);
            }
        };
    }

    fn getUserData(L: ?*lualib.lua_State) *Lua.LuaUserData {
        var ud: *anyopaque = undefined;
        _ = lualib.lua_getallocf(L, @ptrCast([*c]?*anyopaque, &ud));
        const userData = @ptrCast(*Lua.LuaUserData, @alignCast(@alignOf(Lua.LuaUserData), ud));
        return userData;
    }

    fn getAllocator(L: ?*lualib.lua_State) std.mem.Allocator {
        return getUserData(L).allocator;
    }

    // Credit: https://github.com/daurnimator/zig-autolua
    fn alloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.C) ?*anyopaque {
        const c_alignment = 16;
        const userData = @ptrCast(*Lua.LuaUserData, @alignCast(@alignOf(Lua.LuaUserData), ud));
        if (@ptrCast(?[*]align(c_alignment) u8, @alignCast(c_alignment, ptr))) |previous_pointer| {
            const previous_slice = previous_pointer[0..osize];
            return (userData.allocator.realloc(previous_slice, nsize) catch return null).ptr;
        } else {
            // osize is any of LUA_TSTRING, LUA_TTABLE, LUA_TFUNCTION, LUA_TUSERDATA, or LUA_TTHREAD
            // when (and only when) Lua is creating a new object of that type.
            // When osize is some other value, Lua is allocating memory for something else.
            return (userData.allocator.alignedAlloc(u8, c_alignment, nsize) catch return null).ptr;
        }
    }
};

pub fn main() anyerror!void {
    var lua = try Lua.init(std.heap.c_allocator);
    defer lua.destroy();
    lua.openLibs();

    var tbl = try lua.createTable();
    defer lua.release(tbl);
    tbl.set("welcome", "All your codebase are belong to us.");
    lua.set("zig", tbl);
    lua.run("print(zig.welcome)");
}
