# Zig Regex

A regular expression engine written in Zig.

## Features

- **Core matching**: literals, concatenation, alternation (`|`)
- **Quantifiers**: `*`, `+`, `?`, `{n,m}`
- **Character classes**: `[a-z]`, `\d`, `\w`, `\s`, `\D`, `\W`, `\S`
- **Anchors**: `^` (start), `$` (end)
- **Groups**: capturing `(...)`, non-capturing `(?:...)`, named `(?<name>...)`
- **Assertions**: lookahead `(?=...)`, `(?!...)`, lookbehind `(?<=...)`, `(?<!...)`
- **Text operations**: `replace`, `split`, `find`, `findAll`
- **Options**: case sensitivity, multiline mode (framework ready)

## Usage

### Basic Matching

```zig
const regex = @import("regex");

var re = try regex.compile(allocator, "a+b");
defer re.deinit();

try std.testing.expect(try re.isMatch("ab"));
try std.testing.expect(try re.isMatch("aab"));
```

### Find

```zig
var result = try re.find("abc123def");
if (result) |*r| {
    defer r.deinit();
    const match = r.getGroup("abc123def", 0);
}
```

### Replace

```zig
var re = try regex.compile(allocator, "a+");
defer re.deinit();

const result = try re.replace("aabbaaa", "X");
defer allocator.free(result);
// result == "XbbX"
```

### Split

```zig
var re = try regex.compile(allocator, ",");
defer re.deinit();

var parts = try re.split("a,b,c");
defer parts.deinit(allocator);
// parts == ["a", "b", "c"]
```

### With Options

```zig
var re = try regex.compileWithOptions(allocator, "hello", .{
    .case_sensitive = false,
});
defer re.deinit();
```

## Building

```bash
zig build
```

## Testing

```bash
zig build test
```

## CLI Usage

```bash
zig build run -- "pattern" "text"
```

Example:
```bash
zig build run -- "\d+" "abc123def"
```

## Architecture

```
src/
  root.zig       - Public API
  main.zig       - CLI tool
  tokenizer.zig  - Lexical analyzer
  parser.zig     - Syntax analyzer (AST)
  compiler.zig   - AST to bytecode compiler
  vm.zig         - Bytecode virtual machine
  bytecode.zig   - Bytecode definitions
  regex.zig      - High-level Regex API
  options.zig    - Match options
```

The engine uses a Thompson NFA approach:
1. Tokenize regex pattern into tokens
2. Parse tokens into an AST
3. Compile AST to bytecode instructions
4. Execute bytecode in a VM with backtracking

## License

MIT
