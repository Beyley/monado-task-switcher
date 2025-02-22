# monado-task-switcher

Switches between multiple active non-overlay sessions under Monado

will build for literally fucking everything as i only depend on libc, just get a zig compiler (i tested with `0.14.0-dev.3213+53216d2f2` but newer will *probably* also work) and go wild idk

## Building

### Prerequisites

- Zig `0.14.0-dev.3213+53216d2f2` (newer versions may work)
- Internet connection

### Commands

```bash
zig build -Doptimize=ReleaseSafe

zig-out/bin/monado-task-switcher
```
