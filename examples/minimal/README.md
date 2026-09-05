# Minimal consumer project

This directory is a complete Zig project that uses zooi as a dependency. From
the zooi checkout, run it with:

```sh
cd examples/minimal
zig build run
```

Its `build.zig.zon` uses a local path so the example can build before a release
is published. In a separate project, add the released dependency instead:

```sh
zig fetch --save git+https://github.com/vrypan/zooi.git#v0.3.1
```

Then use the same `build.zig` import and application structure shown here.
