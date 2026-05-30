# Zig Regex

A regular expression engine written in Zig.

## Features

- **Core matching**: literals, concatenation, alternation (`|`)
- **Quantifiers**: `*`, `+`, `?`, `{n,m}`
- **Character classes**: `[a-z]`, `\d`, `\w`, `\s`, `\D`, `\W`, `\S`, `\h`, `\H`, POSIX `[:alpha:]`
- **Escape sequences**: `\t`, `\n`, `\r`, `\a` (bell), `\e` (escape), `\f` (form feed), `\v` (vertical tab), `\xNN`, `\x{hhhh}`, `\uNNNN`, `\N`, `\R`, `\X`, `\b` (backspace in class), `\K`
- **Unicode properties**: `\p{L}`, `\p{Lu}`, `\p{Ll}`, `\p{N}`, `\p{Nd}`, `\p{P}`, `\p{S}`, `\p{Z}`, `\P{...}`
- **Unicode scripts**: `\p{Han}`, `\p{Latin}`, `\p{Greek}`, `\p{Cyrillic}`, `\p{Arabic}`, `\p{Hebrew}`, `\p{Armenian}`, `\p{Georgian}`, `\p{Thai}`, `\p{Devanagari}`, `\p{Hiragana}`, `\p{Katakana}`, `\p{Hangul}`
- **Grapheme clusters**: `\X` matches a single user-perceived character (including combining marks)
- **Anchors**: `^` (start), `$` (end), `\A`, `\z`, `\Z`, `\G`
- **Groups**: capturing `(...)`, non-capturing `(?:...)`, named `(?<name>...)`, atomic `(?>)`, branch reset `(?|...)`, backrefs `\1`, `\g<name>`, `\k<name>`, `\g{1}`, `\g{-1}`
- **Quantifiers**: greedy `*+`, `++`, `?+`, `{n,m}+` (possessive)
- **Assertions**: lookahead `(?=...)`, `(?!...)`, lookbehind `(?<=...)`, `(?<!...)` (fixed-width)
- **Subroutine calls**: `(?1)`, `(?&name)`
- **Conditional patterns**: `(?(1)yes|no)`, `(?(name)yes|no)`
- **Comments**: `(?#comment)`
- **Text operations**: `replace`, `replaceAll`, `split`, `find`, `findAll`, `matchAll`
- **Options**: case sensitivity (ASCII + Unicode), multiline mode, dot-matches-newline, free-spacing, max execution steps (backtracking protection)

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
if (result) |r| {
    const match = r.getGroup("abc123def", 0);
}
```

### Convenience Functions

The module also provides one-shot convenience functions that compile, execute, and deinit in one call. **These recompile the pattern on every call** — for repeated use, compile once and reuse the `Regex` object:

```zig
// One-shot (compiles pattern each time)
const matched = try regex.isMatch(allocator, "hello", "hello world");

// Better: compile once, match many
var re = try regex.compile(allocator, "hello");
defer re.deinit();
const matched = try re.isMatch("hello world");
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
defer parts.deinit();
// parts == ["a", "b", "c"]

// Split with a limit
var parts2 = try re.splitLimit("a,b,c,d", 2);
defer parts2.deinit();
// parts2 == ["a", "b", "c,d"]
```

### With Options

```zig
var re = try regex.compileWithOptions(allocator, "hello", .{
    .case_sensitive = false,
});
defer re.deinit();
```

Available options:
- `case_sensitive` — Enable case-sensitive matching (default: `true`)
- `multiline` — `^`/`$` match each line (default: `false`)
- `dot_matches_newline` — `.` matches `\n` (default: `false`)
- `free_spacing` — Ignore whitespace and allow `#` comments (default: `false`)
- `max_steps` — Backtracking limit (default: `1_000_000`, `null` for unlimited)

### Backtracking Protection

The engine has built-in protection against catastrophic backtracking. A default limit of 1,000,000 execution steps prevents pathological patterns like `(a+)+b` from hanging on malicious input:

```zig
var re = try regex.compile(allocator, "(a+)+b"); // uses default limit
defer re.deinit();
// Returns false quickly instead of hanging on long strings of 'a'
try std.testing.expect(!try re.isMatch("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
```

Customize or disable the limit:

```zig
// Stricter limit
var re = try regex.compileWithOptions(allocator, "(a+)+b", .{ .max_steps = 10000 });

// Unlimited (not recommended for untrusted input)
var re = try regex.compileWithOptions(allocator, "(a+)+b", .{ .max_steps = null });
```

### Named Backreferences

Reference a named capture group by name with `\g<name>` or `\k<name>`:

```zig
var re = try regex.compile(allocator, "(?<word>\\w+) \\g<word>");
defer re.deinit();
try std.testing.expect(try re.isMatch("hello hello"));
try std.testing.expect(!try re.isMatch("hello world"));
```

Case-insensitive matching supports Unicode simple case folding for Latin, Greek, Cyrillic, Armenian, Georgian, and Fullwidth Latin scripts:

```zig
var re = try regex.compileWithOptions(allocator, "café", .{ .case_sensitive = false });
defer re.deinit();
try std.testing.expect(try re.isMatch("CAFÉ")); // Unicode case folding

try std.testing.expect(try regex.isMatch(allocator, "αβγ", "ΑΒΓ")); // Greek
```

### Grapheme Clusters

`\X` matches a single user-perceived character, including sequences with combining marks:

```zig
var re = try regex.compile(allocator, "\\X");
defer re.deinit();

// Matches single characters
try std.testing.expect(try re.isMatch("a"));
try std.testing.expect(try re.isMatch("中"));

// Matches e + combining acute accent as one cluster
try std.testing.expect(try re.isMatch("e\u{0301}"));

// CR LF is treated as a single cluster
try std.testing.expect(try re.isMatch("\r\n"));
```

## Building

```bash
zig build
```

## Testing

```bash
zig build test
```

## Benchmark

```bash
zig build bench
```

Example output:

```
=== Regex Benchmark ===
                       Pattern |      Compile (us) |   isMatch (ns) |      find (ns)
--------------------------------------------------------------------------------
                 literal short | compile:       42 us | isMatch:  35767 ns | find:  35638 ns
                   alternation | compile:       81 us | isMatch:  53753 ns | find:  56821 ns
                          star | compile:       23 us | isMatch:  75423 ns | find:  72671 ns
            quantifier {10,20} | compile:      124 us | isMatch:  55492 ns | find:  56324 ns
      unicode property \p{Han} | compile:       40 us | isMatch:  57771 ns | find:  55647 ns
      unicode case insensitive | compile:       26 us | isMatch:  14460 ns | find:  14306 ns
           grapheme cluster \X | compile:       22 us | isMatch:  38365 ns | find:  37317 ns
             lookahead (?=...) | compile:       44 us | isMatch:  34726 ns | find:  35576 ns
               possessive a*+b | compile:       58 us | isMatch:  74515 ns | find:  73363 ns
```

## CLI Usage

```bash
zig build run -- [options] <pattern> <text>
```

Options:
- `-a, --find-all` — Find all matches
- `-r, --replace <repl>` — Replace matches with <repl>
- `-i, --case-insensitive` — Case insensitive matching
- `-m, --multiline` — Multiline mode
- `-s, --dot-matches-newline` — Dot matches newline
- `-d, --debug` — Dump bytecode instructions

Examples:
```bash
zig build run -- "\d+" "abc123def"
zig build run -- -a "\d+" "abc123def456"
zig build run -- -i "hello" "HELLO"
zig build run -- -r "[$&]" "\d+" "abc123def"
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
