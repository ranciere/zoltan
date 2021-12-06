# zoltan
A Sol inspired minimalistic Lua binding for Zig.

## Running Lua code
```
var luaState = try LuaState.init(std.testing.allocator);
defer luaState.destroy();

luaState.openLibs();  // Open common standard libraries

_ = luaState.run("print('Hello World!')");
```

## Getting/setting Lua global varible

```
var luaState = try LuaState.init(std.testing.allocator);
defer luaState.destroy();

luaState.set("int32", @as(i32, 42));
var int = luaState.get(i32, "int32");
std.log.info("Int: {}", .{int});  // 42

luaState.set("string", "I'm a string");
const str = luaState.get([] const u8, "string");
std.log.info("String: {s}", .{str});  // I'm a string
```

## Calling Lua function from Zig

```
var luaState = try LuaState.init(std.testing.allocator);
defer luaState.destroy();

_ = luaState.run("function double_me(a) return 2*a; end");

var doubleMe = luaState.get(LuaFunction(fn(a: i32) i32), "double_me");
var res = doubleMe.call(42);
std.log.info("Result: {}", .{res});   // 84
```

## Calling Zig function from Lua

```
var testResult: i32 = 0;

fn test_fun(a: i32, b: i32) void {
    std.log.info("I'm a test: {}", .{a*b});
    testResult = a*b;
}

...

var luaState = try LuaState.init(std.testing.allocator);
defer luaState.destroy();

luaState.set("test_fun", test_fun);

luaState.run("test_fun(3,15)");
try std.testing.expect(testResult == 45);

```

## To be implemented

- table support
- registering Zig structs in Lua