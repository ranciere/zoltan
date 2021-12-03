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

## To be implemented

- table support
- export Zig method to Lua
