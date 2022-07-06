![zoltan](zoltan.png)
# zoltan

A Sol-inspired minimalist Lua binding for Zig.

## Features

- Supports Zig 0.9.0
- Lua tables
  - table creation from Zig
  - get/set/create methods
  - possible key types: numerical, string
- Scalars
  - int, float, bool
  - Lua string (equals `[] const u8`)
- Functions
  - calling Zig function from Lua and vice-versa
  - Zig functions can accept
    - scalars, Lua types (table, functions, custom types)
- Custom types
  - registered types could be instantiated from Lua
  - public functions are registered in Lua
  - supports `self`
- Scalar array support (equals Lua tables without metatables + numeric keys)
- All of the supported use-cases are intensively tested & leak-free

## Tutorial

### Installing

In addition to the binding facilities, `zoltan` contains the vanilla Lua source (v5.4.3) and the necessary code to compile it. If `zoltan` is installed in the `third_party` library in your application's root, then you have to add to your `build.zig` the following:

```zig
// At the beginning of the file
const addLuaLib = @import("third_party/zoltan/build.zig").addLuaLibrary;

pub fn build(b: *std.build.Builder) void {
...
  // Exe part
  exe.addPackage(.{ .name = "lua", .path = .{ .path="third_party/zoltan/src/lua.zig" }});
  addLuaLib(exe);
...
  // Test part
  const lua_tests = b.addTest("third_party/zoltan/src/tests.zig");
  addLuaLib(lua_tests);
  lua_tests.setBuildMode(mode);
```
You can found an example integration [here](https://github.com/ranciere/zoltan_example_app).

### Instantiating and destroying Lua engine

```zig
const Lua = @import("lua").Lua;
...
pub fn main() anyerror!void {
  ...
  var lua = try Lua.init(std.testing.allocator);
  defer lua.destroy();

  lua.openLibs();  // Open common standard libraries
```

### Running Lua code

```zig
_ = lua.run("print('Hello World!')");
```

### Getting/setting Lua global varibles

```zig
lua.set("int32", 42);
var int = lua.get(i32, "int32");
std.log.info("Int: {}", .{int});  // 42

lua.set("string", "I'm a string");
const str = lua.get([] const u8, "string");
std.log.info("String: {s}", .{str});  // I'm a string
```

### Resource handling

The following functions acquire some kind of resource (heap, Lua reference):

- `getResource`
- `createTable`
- `createUserType`

You have to release the acquired resources by calling the `release` method:

```zig
var tbl = try lua.createTable();
....
lua.release(tbl);         // You have to release
```

### Lua tables

```zig
var tbl = try lua.createTable();
defer lua.release(tbl);

lua.set("tbl", tbl);

var inTbl = try lua.createTable();

// Set, integer key
inTbl.set(1, "string");
inTbl.set(2, 3.1415);
inTbl.set(3, 42);

var tst1 = inTbl.get([]const u8, 1);
var tst2 = inTbl.get(f32, 2);
var tst3 = inTbl.get(i32, 3);

try std.testing.expect(std.mem.eql(u8, test1, "string"));
try std.testing.expect(tst2 == 3.1415);
try std.testing.expect(tst3 == 42);

// Set, string key
inTbl.set("bool", true);

var tst4 = inTbl.get(bool, "bool");
try std.testing.expect(tst4 == true);

// Set table in parent
tbl.set("inner", inTbl);
// Now we can release the inTbl directly (tbl refers it)
lua.release(inTbl);
```

### Calling Lua function from Zig

```zig
_ = lua.run("function double_me(a) return 2*a; end");

var doubleMe = lua.get(Lua.Function(fn(a: i32) i32), "double_me");
// As Zig doesn't handle variable args, one should pass the arguments as anonymous struct
var res = doubleMe.call(.{42});

std.log.info("Result: {}", .{res});   // 84
```

### Calling Zig function from Lua

```zig
var testResult: i32 = 0;

fn test_fun(a: i32, b: i32) void {
    std.log.info("I'm a test: {}", .{a*b});
    testResult = a*b;
}
...
lua.set("test_fun", test_fun);

lua.run("test_fun(3,15)");
try std.testing.expect(testResult == 45);

```

### Passing Lua function to Zig function

```zig
fn testLuaInnerFun(fun: Lua.Function(fn(a: i32) i32)) i32 {
    var res = fun.call(.{42}) catch unreachable;
    std.log.warn("Result: {}", .{res});
    return res;
}
...
```

#### Mechanism on Zig side

```zig
lua.run("function getInt(a) print(a); return a+1; end");
var luafun = try lua.getResource(Lua.Function(fn(a: i32) i32), "getInt");
defer lua.release(luafun);

var result = testLuaInnerFun(luafun);
std.log.info("Zig Result: {}", .{result});
```

#### Mechanism on Lua side

```zig
lua.set("zigFunction", testLuaInnerFun);

const lua_command =
    \\function getInt(a) print(a); return a+1; end
    \\print("Preppare");
    \\zigFunction(getInt);
    \\print("Oppare");
;
lua.run(lua_command);
```

### Custom types

#### Registering Zig structs in Lua

```zig
const TestCustomType = struct {
    a: i32,
    b: f32,
    c: []const u8,
    d: bool,

    pub fn init(_a: i32, _b: f32, _c: []const u8, _d: bool) TestCustomType {
        return TestCustomType{ ... };
    }

    pub fn destroy(_: *TestCustomType) void {}

    pub fn getA(self: *TestCustomType) i32 { return self.a; }
    pub fn getB(self: *TestCustomType) f32 { return self.b; }
    pub fn getC(self: *TestCustomType) []const u8 { return self.c; }
    pub fn getD(self: *TestCustomType) bool { return self.d; }

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
...
// ******************************************
try lua.newUserType(TestCustomType);
// ******************************************
```

#### Instantiating custom type in Zig

```zig
var obj = try lua.createUserType(TestCustomType, .{42, 42.0, "life", true});
defer lua.release(obj);

// One can access the inner struct via the ptr field
std.testing.expect(obj.ptr.getA() == 42);

// One can set as global
lua.set("zigObj", obj);

// And then use it
lua.run("zigObj:reset()");

std.testing.expect(obj.ptr.getA() == 0);

```

#### Instantiating custom type in Lua

```zig
lua.run("obj = TestCustomType.new(42, 42.0, 'life', true)");

// Get as a reference (it doesn't hold reference to the inner object,
// therefore the lifetime is managed totally by the Lua engine
// => storing is dangerous)
var ptr = try lua.get(*TestCustomType, "obj");
std.testing.expect(ptr.getA() == 42);
```

## TODO
In order of importance:
- The current error handling is a little bit rustic, sometimes rough :) A proper error handling strategy would be better.
- Run Lua code from file
- zigmod support
- LuaJIT support
- `Lua.Table` should deep-copy between table and user structs
- Lua Coroutine support
- `Lua.Table` should support JSON
- Option for building without libc (if possible)
- Performance benchmarks
