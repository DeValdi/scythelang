# scythelang
A programming language with nice syntax that transpiles to ISO-C, focussing on embedded development.

## Building
Call `zig build test --summary all`. This will also run the tests used by GitHub Actions, currently only encompassing the parser.

## Usage
Run `zig-out/bin/scc.exe` with `stdin` and `stdout` redirected to your source and destination file, respectively.

The file `TestSynthesis.bat` is an example of how this works on Windows. It currently compiles a minimal struct type example.