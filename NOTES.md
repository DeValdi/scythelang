# Parser notes

Handoff file: update it at the end of every feature. Paste or upload it (plus the
source files below) at the start of a new chat.

## Setup

- Language: Zig **0.16** (the code uses the new `std.Io` API; 0.17 changed reflection and does not compile it).
- Layout: `src/main.zig`, `src/syntax/Parser.zig`, `src/syntax/types.zig`, `src/syntax/util.zig`, and `syntax.ebnf` (the grammar is the spec).
- Run tests: `zig test src/main.zig` (also `-O ReleaseSafe`, and `--test-filter "<name>"`).
- Run the program: `zig build-exe src/main.zig`, then `main < file.scy` (reads all of stdin, dumps the AST via `util.dump`, prints `error: ...` and exits 1 on a syntax error).
- Windows: use `cmd /c "main.exe < file.scy"`. Input must be UTF-8 without BOM (a BOM or UTF-16 is rejected at line 1, column 1).

## Status

Done: `import_stmt`, and the lexical layer (`sp`, `nl`, `ws`, `sep`, `value_name`, comments).

Stubs (signature only, no body; they compile only once referenced): every other `parse*` function in `Parser.zig`.
To enable a rule, implement it and add it to `parseTopItem`'s alternatives. The order there is the priority order.

Current test count: 18 (all in `Parser.zig`).

## Design (keep these invariants)

- The whole input is read into memory; the parser works on `source: []const u8`.
- Parser state is one integer, `pos`. Backtracking is `const start = self.pos; ... self.pos = start;`. There is no frame stack.
- **Failure contract:** a parse function that fails (`false`, `null` or `.failure`) leaves `pos` exactly where it found it.
- Line and column are not tracked while parsing; `lineCol(pos)` computes them (bytes, ignoring `\r`) only when reporting an error.
- Function shapes:
  - lexical helpers return `bool` or `?[]const u8` and cannot fail with an error;
  - grammar rules return `ParseResult(T)`, an `error{OutOfMemory}!union { success: T, failure: []const u8 }`.
- **Ownership:**
  - names and text in the AST are slices of `source` (no copies), so the AST is only valid while `source` is alive. Text fields in `types.zig` are `[]const u8`;
  - slices that hold nodes (item list, import path, ...) are allocated with `gpa` and owned by the caller;
  - the message of a `.failure` from `parseAbstractSyntaxTree` is allocated and owned by the caller.
- **Never let a failing `append` leak an item that owns memory.** Call `ensureUnusedCapacity(gpa, 1)` first, then `appendAssumeCapacity`. When returning a slice from an `ArrayList`, use `toOwnedSlice`, never `.items`.
- When a function fails *after* allocating, it must free those allocations before returning `.failure` (an `errdefer` only covers real errors). Do the `pos` reset first, then the cleanup.
- Extend `discardItems` whenever a `TopItem` variant owns allocations.
- `parseUnion(T, .{ .{ "field_name", parseFn }, ... })` pairs alternatives with union fields by name and checks the return type at compile time.

## Error reporting

- `noteFailure(msg)` records the failure that got furthest into the input (strictly greater `pos` wins, ties keep the first, innermost message). Call it **before** resetting `pos`.
- Only call it after the rule is "committed" (e.g. after seeing the `import` keyword). A plain "this alternative did not match" must not call it, or it will hide the specific message.
- `describeFailure` turns it into `line L, column C: message`. If nothing got further than the current position, it says `Unexpected input`.
- `parseAbstractSyntaxTree` fails if any input is left over; there is no silent truncation.

## Grammar decisions already made

- Comments are **single-line**: `$` ... `$` closing on the same line. An empty comment `$$` is valid. A line break before the closing `$` is an "Unterminated comment".
- Because of that, `sp` never contains a newline, so `sep = { sp }, nl, { ws };` is unambiguous. The trailing `{ws}` (not `{sp}`) is what allows blank lines between items.
- `nl` is `\n` or `\r\n`. A lone `\r` is **not** a newline (and is not allowed inside a comment).
- `ws` includes newlines, so `import\n  a.b` is valid. The dots of an import path allow no whitespace.
- Keywords are listed in `keywords` in `Parser.zig` and in the EBNF; keep them in sync.

## Adding a rule: checklist

1. Write the tests first (valid input, every malformed shape, exact error positions).
2. Implement against the EBNF, following the invariants above.
3. Add `noteFailure` calls for the committed parts of the rule.
4. Run `zig test src/main.zig`. Tests run under `std.testing.allocator`, so leaks and double frees fail them.
5. If the rule allocates, add a case to the out-of-memory sweep test (it fails the n-th allocation for every n).
6. Update this file (status + any new decision) and commit.

## Open questions / not done

- UTF-8 BOM is rejected rather than skipped.
- Columns count bytes, not Unicode characters.
- stdin is read with no size limit (`.unlimited`).
