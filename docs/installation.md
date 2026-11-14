# Install and run Tome

Tome builds on Windows, macOS, and Linux. The macOS build uses the system's
`libSystem`. Tome has no third-party runtime libraries.

Build from the checkout with [Zig `0.15.2`](../.zigversion). To open the editor,
use a [compatible terminal](terminal.md#open-and-restore-the-terminal).

## Install on Windows

Open Windows PowerShell 5.1 or PowerShell 7 in the checkout.

1. Run `.\install.ps1`. The script uses the version of Zig pinned in
   `.zigversion`. If that version is missing from `PATH`, the script downloads
   and verifies the official Windows archive and caches Zig under
   `%LOCALAPPDATA%\Programs\Tome\tools`.
2. Check that `Get-Command tome` points to
   `%LOCALAPPDATA%\Programs\Tome\bin\tome.exe`. The script builds in
   `ReleaseSafe` mode and adds the install directory to `PATH` for your user
   and the PowerShell session that ran the script.
3. Run `tome` from Windows Terminal to open the editor.

## Set up Zig on macOS

These steps require Homebrew.

1. Install the [`zig@0.15` formula](https://formulae.brew.sh/formula/zig@0.15):

   ```sh
   brew install zig@0.15
   ```

2. Put that version first on `PATH` for the current shell:

   ```sh
   export PATH="$(brew --prefix zig@0.15)/bin:$PATH"
   ```

3. Run `zig version`. If it does not print `0.15.2`, correct `PATH` before
   building Tome.

## Install on macOS or Linux

Start in the checkout with Zig on `PATH`.

1. Run `./install.sh`. The script builds `tome` in `ReleaseSafe` mode and
   installs it in `~/.local/bin`. If the script reports an error, fix it before
   continuing.
2. Add this line to your shell startup file if the script asks you to update
   `PATH`:

   ```sh
   export PATH="$HOME/.local/bin:$PATH"
   ```

3. Open a new terminal if you changed your shell startup file.
4. Run `command -v tome`. Check that it points to `~/.local/bin/tome`.

## Build and run from the checkout

Start in the checkout with Zig on `PATH`.

1. Run `zig build`. Check that `zig-out/bin` contains `tome` and `tome-measure`.
   On Windows, the executables end in `.exe`. Use
   `zig build -Doptimize=ReleaseSafe` for a release build.
2. Run `./zig-out/bin/tome` to browse the checkout, or pass a path as described
   under [Open a workspace](#open-a-workspace). On Windows, run
   `.\zig-out\bin\tome.exe`.

To build and open a file in one command, run `zig build run -- notes.txt`.
See [Performance measurement](measurement.md) for the measurement commands.
See [Check changes](source-layout.md#check-changes) for development checks.

## Open a workspace

Start in the directory you want to browse. Use `tome` if you installed it, or
the path to `zig-out/bin/tome` if you built it from the checkout.

| Task | Example command |
| --- | --- |
| Browse the current directory | `tome` |
| Browse a specific directory | `tome src` |
| Start at a file | `tome "draft notes.txt"` |
| Print the command-line reference | `tome --help` or `tome -h` |

Tome accepts at most one path. Quote paths that contain spaces. See
[Startup and discovery](workspace.md#startup-and-discovery) for workspace root
selection, file order, and open errors.
