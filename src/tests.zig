const std = @import("std");
const Lua = @import("lua.zig").Lua;
const assert = std.debug.assert;

test "set/get scalar" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();
    const int16In: i16 = 1;
    const int32In: i32 = 2;
    const int64In: i64 = 3;

    const f16In: f16 = 3.1415;
    const f32In: f32 = 3.1415;
    const f64In: f64 = 3.1415;

    const bIn: bool = true;

    lua.set("int16", int16In);
    lua.set("int32", int32In);
    lua.set("int64", int64In);

    lua.set("float16", f16In);
    lua.set("float32", f32In);
    lua.set("float64", f64In);

    lua.set("bool", bIn);

    var int16Out = try lua.get(i16, "int16");
    var int32Out = try lua.get(i32, "int32");
    var int64Out = try lua.get(i64, "int64");

    var f16Out = try lua.get(f16, "float16");
    var f32Out = try lua.get(f32, "float32");
    var f64Out = try lua.get(f64, "float64");

    var bOut = try lua.get(bool, "bool");

    try std.testing.expectEqual(int16In, int16Out);
    try std.testing.expectEqual(int32In, int32Out);
    try std.testing.expectEqual(int64In, int64Out);

    try std.testing.expectEqual(f16In, f16Out);
    try std.testing.expectEqual(f32In, f32Out);
    try std.testing.expectEqual(f64In, f64Out);

    try std.testing.expectEqual(bIn, bOut);
}

test "set/get string" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    var strMany: [*]const u8 = "macilaci";
    var strSlice: []const u8 = "macilaic";
    var strOne = "macilaci";
    var strC: [*c]const u8 = "macilaci";

    const cstrMany: [*]const u8 = "macilaci";
    const cstrSlice: []const u8 = "macilaic";
    const cstrOne = "macilaci";
    const cstrC: [*c]const u8 = "macilaci";

    lua.set("stringMany", strMany);
    lua.set("stringSlice", strSlice);
    lua.set("stringOne", strOne);
    lua.set("stringC", strC);

    lua.set("cstringMany", cstrMany);
    lua.set("cstringSlice", cstrSlice);
    lua.set("cstringOne", cstrOne);
    lua.set("cstringC", cstrC);

    const retStrMany = try lua.get([]const u8, "stringMany");
    const retCStrMany = try lua.get([]const u8, "cstringMany");
    const retStrSlice = try lua.get([]const u8, "stringSlice");
    const retCStrSlice = try lua.get([]const u8, "cstringSlice");

    const retStrOne = try lua.get([]const u8, "stringOne");
    const retCStrOne = try lua.get([]const u8, "cstringOne");
    const retStrC = try lua.get([]const u8, "stringC");
    const retCStrC = try lua.get([]const u8, "cstringC");

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
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    const boolSlice = [_]bool{ true, false, true };
    const intSlice = [_]i32{ 4, 5, 3, 4, 0 };
    const strSlice = [_][]const u8{ "Macilaci", "Gyumifagyi", "Angolhazi" };

    lua.set("boolSlice", boolSlice);
    lua.set("intSlice", intSlice);
    lua.set("strSlice", strSlice);

    const retBoolSlice = try lua.getResource([]i32, "boolSlice");
    defer lua.release(retBoolSlice);

    const retIntSlice = try lua.getResource([]i32, "intSlice");
    defer lua.release(retIntSlice);

    const retStrSlice = try lua.getResource([][]const u8, "strSlice");
    defer lua.release(retStrSlice);

    for (retIntSlice, 0..) |v, i| {
        try std.testing.expectEqual(v, intSlice[i]);
    }

    for (retStrSlice, 0..) |v, i| {
        try std.testing.expect(std.mem.eql(u8, v, strSlice[i]));
    }
}

test "simple Zig => Lua function call" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();

    const lua_command =
        \\function test_1() end
        \\function test_2(a) end
        \\function test_3(a) return a; end
        \\function test_4(a,b) return a+b; end
    ;

    lua.run(lua_command);

    var fun1 = try lua.getResource(Lua.Function(*const fn () void), "test_1");
    defer lua.release(fun1);

    var fun2 = try lua.getResource(Lua.Function(*const fn (a: i32) void), "test_2");
    defer lua.release(fun2);

    var fun3_1 = try lua.getResource(Lua.Function(*const fn (a: i32) i32), "test_3");
    defer lua.release(fun3_1);

    var fun3_2 = try lua.getResource(Lua.Function(*const fn (a: []const u8) []const u8), "test_3");
    defer lua.release(fun3_2);

    var fun4 = try lua.getResource(Lua.Function(*const fn (a: i32, b: i32) i32), "test_4");
    defer lua.release(fun4);

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
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();

    lua.set("testFun0", testFun0);
    lua.set("testFun1", testFun1);
    lua.set("testFun2", testFun2);
    lua.set("testFun3", testFun3);

    lua.run("testFun0()");
    try std.testing.expect(testResult0 == true);

    lua.run("testFun1(42,10)");
    try std.testing.expect(testResult1 == 32);

    lua.run("testFun2('0123456789')");
    try std.testing.expect(testResult2 == 45);

    lua.run("testFun3('0123456789', -10)");
    try std.testing.expect(testResult3 == 55);

    testResult0 = false;
    testResult1 = 0;
    testResult2 = 0;
    testResult3 = 0;

    lua.run("testFun3('0123456789', -10)");
    try std.testing.expect(testResult3 == 55);

    lua.run("testFun2('0123456789')");
    try std.testing.expect(testResult2 == 45);

    lua.run("testFun1(42,10)");
    try std.testing.expect(testResult1 == 32);

    lua.run("testFun0()");
    try std.testing.expect(testResult0 == true);
}

fn testFun4(a: []const u8) []const u8 {
    return a;
}

fn testFun5(a: i32, b: i32) i32 {
    return a - b;
}

test "simple Zig => Lua => Zig function call" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();

    lua.set("testFun4", testFun4);
    lua.set("testFun5", testFun5);

    lua.run("function luaTestFun4(a) return testFun4(a); end");
    lua.run("function luaTestFun5(a,b) return testFun5(a,b); end");

    var fun4 = try lua.getResource(Lua.Function(*const fn (a: []const u8) []const u8), "luaTestFun4");
    defer lua.release(fun4);

    var fun5 = try lua.getResource(Lua.Function(*const fn (a: i32, b: i32) i32), "luaTestFun5");
    defer lua.release(fun5);

    var res4 = try fun4.call(.{"macika"});
    var res5 = try fun5.call(.{ 42, 1 });

    try std.testing.expect(std.mem.eql(u8, res4, "macika"));
    try std.testing.expect(res5 == 41);
}

fn testLuaInnerFun(fun: Lua.Function(*const fn (a: i32) i32)) i32 {
    var res = fun.call(.{42}) catch unreachable;
    return res;
}

test "Lua function injection into Zig function" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();
    // Binding on Zig side
    lua.run("function getInt(a) return a+1; end");
    var luafun = try lua.getResource(Lua.Function(*const fn (a: i32) i32), "getInt");
    defer lua.release(luafun);

    var result = testLuaInnerFun(luafun);
    std.log.info("Zig Result: {}", .{result});

    // Binding on Lua side
    lua.set("zigFunction", testLuaInnerFun);

    const lua_command =
        \\function getInt(a) return a+1; end
        \\zigFunction(getInt);
    ;

    lua.run(lua_command);
}

fn zigInnerFun(a: i32) i32 {
    return 2 * a;
}

test "Zig function injection into Lua function" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();

    // Binding
    lua.set("zigFunction", zigInnerFun);

    const lua_command =
        \\function test(a) res = a(2); return res; end
        \\test(zigFunction);
    ;

    lua.run(lua_command);
}

fn testSliceInput(a: []i32) i32 {
    var sum: i32 = 0;
    for (a) |v| {
        sum += v;
    }
    return sum;
}

test "Slice input to Zig function" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();

    // Binding
    lua.set("sumFunction", testSliceInput);

    const lua_command =
        \\res = sumFunction({1,2,3});
    ;

    lua.run(lua_command);
}

test "Lua.Table allocless set/get tests" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();

    // Create table
    var originalTbl = try lua.createTable();
    defer originalTbl.destroy();
    lua.set("tbl", originalTbl);

    originalTbl.set("owner", true);

    var tbl = try lua.getResource(Lua.Table, "tbl");
    defer lua.release(tbl);

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
    return 3 * a;
}

test "Lua.Table inner table tests" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();

    // Create table
    var tbl = try lua.createTable();
    defer lua.release(tbl);

    lua.set("tbl", tbl);

    var inTbl0 = try lua.createTable();
    defer lua.release(inTbl0);

    var inTbl1 = try lua.createTable();
    defer lua.release(inTbl1);

    inTbl1.set("str", "string");
    inTbl1.set("int32", 68);
    inTbl1.set("fn", tblFun);

    inTbl0.set(1, "string");
    inTbl0.set(2, 3.1415);
    inTbl0.set(3, 42);
    inTbl0.set("table", inTbl1);

    tbl.set("innerTable", inTbl0);

    var retTbl = try lua.getResource(Lua.Table, "tbl");
    defer lua.release(retTbl);

    var retInnerTable = try retTbl.getResource(Lua.Table, "innerTable");
    defer lua.release(retInnerTable);

    var str = try retInnerTable.get([]const u8, 1);
    var float = try retInnerTable.get(f32, 2);
    var int = try retInnerTable.get(i32, 3);

    try std.testing.expect(std.mem.eql(u8, str, "string"));
    try std.testing.expect(float == 3.1415);
    try std.testing.expect(int == 42);

    var retInner2Table = try retInnerTable.getResource(Lua.Table, "table");
    defer lua.release(retInner2Table);

    str = try retInner2Table.get([]const u8, "str");
    int = try retInner2Table.get(i32, "int32");
    var func = try retInner2Table.getResource(Lua.Function(*const fn (a: i32) i32), "fn");
    defer lua.release(func);
    var funcRes = try func.call(.{42});

    try std.testing.expect(std.mem.eql(u8, str, "string"));
    try std.testing.expect(int == 68);
    try std.testing.expect(funcRes == 3 * 42);
}

var luaTableArgSum: i32 = 0;
fn testLuaTableArg(t: Lua.Table) i32 {
    var a = t.get(i32, "a") catch -1;
    var b = t.get(i32, "b") catch -1;
    luaTableArgSum = a + b;
    return luaTableArgSum;
}

test "Function with Lua.Table argument" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();
    // Zig side
    var tbl = try lua.createTable();
    defer lua.release(tbl);

    tbl.set("a", 42);
    tbl.set("b", 128);
    var zigRes = testLuaTableArg(tbl);

    try std.testing.expect(zigRes == 42 + 128);

    // Lua side
    lua.set("sumFn", testLuaTableArg);
    lua.run("function test() return sumFn({a=1, b=2}); end");

    var luaFun = try lua.getResource(Lua.Function(*const fn () i32), "test");
    defer lua.release(luaFun);

    var luaRes = try luaFun.call(.{});
    try std.testing.expect(luaRes == 1 + 2);
}

fn testLuaTableArgOut(t: Lua.Table) Lua.Table {
    t.set(1, 42);
    t.set(2, 128);
    return t;
}

test "Function with Lua.Table result" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();
    lua.injectPrettyPrint();
    // Zig side
    var tbl = try lua.createTable();
    defer lua.release(tbl);

    var zigRes = testLuaTableArgOut(tbl);

    var zigA = try zigRes.get(i32, 1);
    var zigB = try zigRes.get(i32, 2);

    try std.testing.expect((zigA + zigB) == 42 + 128);

    // Lua side
    lua.set("tblFn", testLuaTableArgOut);
    //lua.run("function test() tbl = tblFn({}); return tbl[1] + tbl[2]; end");
    lua.run("function test() tbl = tblFn({}); return tbl[1] + tbl[2]; end");

    var luaFun = try lua.getResource(Lua.Function(*const fn () i32), "test");
    defer lua.release(luaFun);

    var luaRes = try luaFun.call(.{});
    try std.testing.expect(luaRes == 42 + 128);
}

const TestCustomType = struct {
    a: i32,
    b: f32,
    c: []const u8,
    d: bool,

    pub fn init(_a: i32, _b: f32, _c: []const u8, _d: bool) TestCustomType {
        return TestCustomType{
            .a = _a,
            .b = _b,
            .c = _c,
            .d = _d,
        };
    }

    pub fn destroy(_: *TestCustomType) void {}

    pub fn getA(self: *TestCustomType) i32 {
        return self.a;
    }

    pub fn getB(self: *TestCustomType) f32 {
        return self.b;
    }

    pub fn getC(self: *TestCustomType) []const u8 {
        return self.c;
    }

    pub fn getD(self: *TestCustomType) bool {
        return self.d;
    }

    pub fn reset(self: *TestCustomType) void {
        self.a = 0;
        self.b = 0;
        self.c = "";
        self.d = false;
    }

    pub fn store(self: *TestCustomType, _a: i32, _b: f32, _c: []const u8, _d: bool) void {
        self.a = _a;
        self.b = _b;
        self.c = _c;
        self.d = _d;
    }
};

test "Custom types I: allocless in/out member functions arguments" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();
    lua.openLibs();

    try lua.newUserType(TestCustomType, "TestCustomType");

    const cmd =
        \\o = TestCustomType.new(42, 42.0, "life", true)
        \\function getA() return o:getA(); end
        \\function getB() return o:getB(); end
        \\function getC() return o:getC(); end
        \\function getD() return o:getD(); end
        \\function reset() o:reset() end
        \\function store(a,b,c,d) o:store(a,b,c,d) end
    ;
    lua.run(cmd);

    var getA = try lua.getResource(Lua.Function(*const fn () i32), "getA");
    defer lua.release(getA);

    var getB = try lua.getResource(Lua.Function(*const fn () f32), "getB");
    defer lua.release(getB);

    var getC = try lua.getResource(Lua.Function(*const fn () []const u8), "getC");
    defer lua.release(getC);

    var getD = try lua.getResource(Lua.Function(*const fn () bool), "getD");
    defer lua.release(getD);

    var reset = try lua.getResource(Lua.Function(*const fn () void), "reset");
    defer lua.release(reset);

    var store = try lua.getResource(Lua.Function(*const fn (_a: i32, _b: f32, _c: []const u8, _d: bool) void), "store");
    defer lua.release(store);

    var resA0 = try getA.call(.{});
    try std.testing.expect(resA0 == 42);

    var resB0 = try getB.call(.{});
    try std.testing.expect(resB0 == 42.0);

    var resC0 = try getC.call(.{});
    try std.testing.expect(std.mem.eql(u8, resC0, "life"));

    var resD0 = try getD.call(.{});
    try std.testing.expect(resD0 == true);

    try store.call(.{ 1, 1.0, "death", false });

    var resA1 = try getA.call(.{});
    try std.testing.expect(resA1 == 1);

    var resB1 = try getB.call(.{});
    try std.testing.expect(resB1 == 1.0);

    var resC1 = try getC.call(.{});
    try std.testing.expect(std.mem.eql(u8, resC1, "death"));

    var resD1 = try getD.call(.{});
    try std.testing.expect(resD1 == false);

    try reset.call(.{});

    var resA2 = try getA.call(.{});
    try std.testing.expect(resA2 == 0);

    var resB2 = try getB.call(.{});
    try std.testing.expect(resB2 == 0.0);

    var resC2 = try getC.call(.{});
    try std.testing.expect(std.mem.eql(u8, resC2, ""));

    var resD2 = try getD.call(.{});
    try std.testing.expect(resD2 == false);
}

test "Custom types II: set as global, get without ownership" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();
    lua.openLibs();

    _ = try lua.newUserType(TestCustomType, "TestCustomType");
    // Creation from Zig
    var ojjectum = try lua.createUserType(TestCustomType, .{ 42, 42.0, "life", true });
    defer lua.release(ojjectum);

    lua.set("zig", ojjectum);
    var ptrZig = try lua.get(*TestCustomType, "zig");

    try std.testing.expect(ptrZig.a == 42);
    try std.testing.expect(ptrZig.b == 42.0);
    try std.testing.expect(std.mem.eql(u8, ptrZig.c, "life"));
    try std.testing.expect(ptrZig.d == true);

    ptrZig.reset();

    try std.testing.expect(ptrZig.a == 0);
    try std.testing.expect(ptrZig.b == 0.0);
    try std.testing.expect(std.mem.eql(u8, ptrZig.c, ""));
    try std.testing.expect(ptrZig.d == false);

    // Creation From Lua
    lua.run("o = TestCustomType.new(42, 42.0, 'life', true)");

    var ptr = try lua.get(*TestCustomType, "o");

    try std.testing.expect(ptr.a == 42);
    try std.testing.expect(ptr.b == 42.0);
    try std.testing.expect(std.mem.eql(u8, ptr.c, "life"));
    try std.testing.expect(ptr.d == true);

    lua.run("o:reset()");

    try std.testing.expect(ptr.a == 0);
    try std.testing.expect(ptr.b == 0.0);
    try std.testing.expect(std.mem.eql(u8, ptr.c, ""));
    try std.testing.expect(ptr.d == false);
}

fn testCustomTypeSwap(ptr0: *TestCustomType, ptr1: *TestCustomType) void {
    var tmp: TestCustomType = undefined;
    tmp = ptr0.*;
    ptr0.* = ptr1.*;
    ptr1.* = tmp;
}

test "Custom types III: Zig function with custom user type arguments" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();
    lua.openLibs();

    _ = try lua.newUserType(TestCustomType, "TestCustomType");
    lua.set("swap", testCustomTypeSwap);

    const cmd =
        \\o0 = TestCustomType.new(42, 42.0, 'life', true)
        \\o1 = TestCustomType.new(0, 1.0, 'test', false)
        \\swap(o0, o1)
    ;

    lua.run(cmd);

    var ptr0 = try lua.get(*TestCustomType, "o0");
    var ptr1 = try lua.get(*TestCustomType, "o1");

    try std.testing.expect(ptr0.a == 0);
    try std.testing.expect(ptr0.b == 1.0);
    try std.testing.expect(std.mem.eql(u8, ptr0.c, "test"));
    try std.testing.expect(ptr0.d == false);

    try std.testing.expect(ptr1.a == 42);
    try std.testing.expect(ptr1.b == 42.0);
    try std.testing.expect(std.mem.eql(u8, ptr1.c, "life"));
    try std.testing.expect(ptr1.d == true);
}
