# Zig 0.15 API Notes

Zig 0.15.x API patterns used in this project.

## I/O
- Stdout: `std.fs.File.stdout()` returns a `File`. Use `.writeAll(data)` for unbuffered writes.
- For buffered writing: `var w = std.fs.File.stdout().writer(&buf); const stdout = &w.interface;` — must call `stdout.flush()`.
- Stdin: `std.fs.File.stdin()`, same pattern.

## Process
- `std.process.Child` StdIo enum uses PascalCase: `.Pipe`, `.Inherit`, `.Ignore`

## Format Strings
- Use `{any}` for errors, `{f}` for custom format methods, `{s}` for strings, `{d}` for integers.

## JSON
- Serialize: `std.json.Stringify.valueAlloc(allocator, value, .{})`
- Parse: `std.json.parseFromSlice(T, allocator, raw, .{ .allocate = .alloc_always })`

## Build System
- `addExecutable` requires `root_module: *Module`:
  ```zig
  const mod = b.createModule(.{
      .root_source_file = b.path("src/main.zig"),
      .target = target,
      .optimize = optimize,
      .imports = &.{ .{ .name = "protocol", .module = protocol_mod } },
  });
  const exe = b.addExecutable(.{ .name = "myapp", .root_module = mod });
  ```
- Tests follow the same pattern with `b.addTest(.{ .root_module = test_mod })`
