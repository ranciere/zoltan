# zoltan
A Sol inspired minimalistic Lua binding for Zig.

## Running Lua code
```zig
var luaState = try LuaState.init(std.testing.allocator);
defer luaState.destroy();

luaState.openLibs();  // Open common standard libraries
 
_ = luaState.run("print('Hello World!')");
```

## Getting/setting Lua global varible
```zig
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
```zig
var luaState = try LuaState.init(std.testing.allocator);
defer luaState.destroy();

_ = luaState.run("function double_me(a) return 2*a; end");

var doubleMe = luaState.get(LuaFunction(fn(a: i32) i32), "double_me");
var res = doubleMe.call(42);
std.log.info("Result: {}", .{res});   // 84
```

## Calling Zig function from Lua
```zig
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

## Passing Lua function to Zig function
```zig
fn testLuaInnerFun(fun: LuaFunction(fn(a: i32) i32)) i32 {
    var res = fun.call(.{42}) catch unreachable;
    std.log.warn("Result: {}", .{res});
    return res;
}
...

// Binding on Zig side
luaState.run("function getInt(a) print(a); return a+1; end");
var luafun = try luaState.allocGet(LuaFunction(fn(a: i32) i32), "getInt");
defer luafun.destroy();

var result = testLuaInnerFun(luafun);
std.log.info("Zig Result: {}", .{result});

// Binding on Lua side
luaState.set("zigFunction", testLuaInnerFun);

const lua_command =
    \\function getInt(a) print(a); return a+1; end
    \\print("Preppare");
    \\zigFunction(getInt);
    \\print("Oppare");
;

luaState.run(lua_command);

```

## To be implemented

- table support
- registering Zig structs in Lua