<h1 align="center">ZS</h1>

<p align="center">
<strong>Zig Shell</strong>
</p>

<p align="center">
  A lightweight Linux shell written in Zig, with a Bash-style language, live syntax highlighting, inline history suggestions and a customizable prompt.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/license-GPLv3-c39bf0?style=for-the-badge&labelColor=0d1117" alt="GPLv3">
  <img src="https://img.shields.io/badge/platform-Linux-4da3ff?style=for-the-badge&labelColor=0d1117" alt="Linux">
  <img src="https://img.shields.io/badge/written%20in-Zig-c39bf0?style=for-the-badge&labelColor=0d1117" alt="Zig">
  <img src="https://img.shields.io/badge/dependencies-none-4da3ff?style=for-the-badge&labelColor=0d1117" alt="No dependencies">
</p>

<p align="center">
  <a href="#-features">Features</a> ·
  <a href="#-installation">Installation</a> ·
  <a href="#-usage">Usage</a> ·
  <a href="#-shell-language">Language</a> ·
  <a href="#-builtins">Builtins</a> ·
  <a href="#-customization">Customization</a> ·
  <a href="#-how-zs-works">Internals</a> ·
  <a href="#-license">License</a>
</p>

---

## ✦ Features

- Bash-style language: pipelines, lists, redirections, here-documents,
  functions, subshells, `if`, `for`, `while`, `until` and `case`. See
  [shell language](#-shell-language).
- Live syntax highlighting while you type. Only builtins, functions and
  executables that really exist are colored as commands, and anything else
  turns red.
- Inline suggestions from your history, shown as dim text after the cursor.
- Tab completion for commands, builtins, functions and files.
- Persistent history in `~/.zs_history`.
- A customizable prompt with colors, git branch, time and exit status, changed
  at runtime with `zsprompt`. See [prompt](#prompt).
- Startup files: `~/.zsrc` for interactive shells and `/etc/profile` plus
  `~/.profile` for login shells.
- Can be used as a login shell, with `-c` for one-off commands and as a script
  runner.
- Prompt markers (OSC 133) for terminals with shell integration.
- Written in plain Zig with no dependencies besides the standard library and
  libc.

---

## ✦ Installation

ZS needs [Zig](https://ziglang.org/download/) 0.14.1 or newer and runs on
Linux.

```sh
git clone https://github.com/nullbyte6/zs.git
cd zs
./install.sh
```

`install.sh` builds with `zig build -Doptimize=ReleaseSafe` and installs the
binary to `/usr/local/bin/zs`, using `sudo` when the folder is not writable. It
then offers to list ZS in `/etc/shells`, which `chsh` requires.

| Variable          | Default           | Purpose                                  |
| ----------------- | ----------------- | ---------------------------------------- |
| `ZS_INSTALL_DIR`  | `/usr/local/bin`  | Folder the `zs` binary is installed into |
| `ZS_SHELLS_FILE`  | `/etc/shells`     | File that lists the allowed login shells |

To build without installing:

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/zs
```

To make ZS your login shell:

```sh
chsh -s /usr/local/bin/zs
```

---

## ✦ Usage

```
zs [-i] [-l | --login] [-c COMMAND [ARG...]] [--]
```

| Option            | Meaning                                                              |
| ----------------- | -------------------------------------------------------------------- |
| `-c COMMAND`      | Run `COMMAND`, then exit. Extra arguments become `$1`, `$2` and so on |
| `-i`              | Force interactive mode even when stdin is not a terminal             |
| `-l`, `--login`   | Behave as a login shell. Also implied when `argv[0]` starts with `-` |
| `--`              | Stop option parsing                                                  |

```sh
zs -c 'echo "hello from $0"'
zs -c 'for f in "$@"; do echo "$f"; done' zs a b c
```

### Line editor

| Key                          | Action                                          |
| ---------------------------- | ----------------------------------------------- |
| `←` `→`, `Ctrl-B` `Ctrl-F`   | Move the cursor                                 |
| `Home`, `Ctrl-A`             | Start of line                                   |
| `End`, `Ctrl-E`              | End of line. Also accepts an inline suggestion  |
| `→`, `Ctrl-F` at end of line | Accept the inline suggestion                    |
| `↑` `↓`, `Ctrl-P` `Ctrl-N`   | Previous and next history entry                 |
| `Tab`                        | Complete, insert the common prefix or list matches |
| `Backspace`, `Delete`        | Delete before and after the cursor              |
| `Ctrl-W`                     | Delete the previous word                        |
| `Ctrl-U`                     | Delete to the start of the line                 |
| `Ctrl-K`                     | Delete to the end of the line                   |
| `Ctrl-L`                     | Clear the screen                                |
| `Ctrl-C`                     | Cancel the current line                         |
| `Ctrl-D`                     | Exit on an empty line                           |

Unclosed quotes, blocks and trailing operators continue on a `> ` line, as in
Bash. Input that is not a terminal falls back to plain line reading.

---

## ✦ Shell language

### Commands and lists

```sh
ls -l | grep zs | wc -l
make && ./run || echo failed
sleep 1; echo done
! false
```

Pipelines, `;`, `&&`, `||` and `!` are supported. Compound commands can be
piped and redirected too.

### Quoting and expansion

| Feature                | Example                                              |
| ---------------------- | ---------------------------------------------------- |
| Quotes and escapes     | `'literal'`, `"with $vars"`, `\ `                    |
| Tilde                  | `~`, `~/bin`                                         |
| Variables              | `$NAME`, `${NAME}`, `$?`                             |
| Parameter operators    | `${v:-w}`, `${v:=w}`, `${v:+w}`, `${v:?msg}`, `${#v}` |
| Positional parameters  | `$1`, `${10}`, `$@`, `$*`, `$#`, `$0`, `$$`          |
| Command substitution   | `$(date)`, `` `date` ``                              |
| Arithmetic             | `$((1 + 2 * 3))`, `(( i++ ))`                        |
| Globs                  | `*`, `?`, `[a-z]`                                    |

### Redirections

| Syntax               | Meaning                                  |
| -------------------- | ---------------------------------------- |
| `< file`             | Read stdin from a file                   |
| `> file`, `>> file`  | Write or append stdout                   |
| `N> file`, `N>&M`    | Redirect or duplicate a file descriptor  |
| `&> file`, `&>> file`| Redirect stdout and stderr together      |
| `<<EOF`, `<<-EOF`    | Here-document, with `'EOF'` to disable expansion |

### Control flow

```sh
if [ -f ~/.zsrc ]; then echo present; elif true; then echo other; else echo none; fi

for name in a b c; do echo "$name"; done

i=0
while (( i < 3 )); do echo $i; i=$((i + 1)); done

case "$1" in
    start) echo starting ;;
    stop|halt) echo stopping ;;
    *) echo "usage: $0 start|stop" ;;
esac
```

`until`, `break` and `continue` work as in Bash.

### Functions, groups and subshells

```sh
greet() {
    local who=${1:-world}
    echo "hello, $who"
    return 0
}

function twice { "$@"; "$@"; }

{ echo one; echo two; } > out.txt
( cd /tmp && pwd )
```

Function names may contain hyphens and dots. `local` scopes variables to the
function, and `unset -f` removes a function.

### Variables and options

```sh
NAME=value
NAME=value command
export PATH="$HOME/bin:$PATH"
set -e
set -u
set -o errexit -o nounset
set -- first second
```

`set -e` stops on the first failing command and `set -u` makes unset variables
an error. `set` with no arguments lists all variables.

---

## ✦ Builtins

| Builtin                    | Description                                                               |
| -------------------------- | ------------------------------------------------------------------------- |
| `cd [DIR \| -]`            | Change directory. Updates `PWD` and `OLDPWD`, and `cd -` goes back         |
| `exit [N]`                 | Leave the shell with a status                                             |
| `export NAME[=VALUE]`      | Mark variables for child processes                                        |
| `unset [-f] NAME`          | Remove variables, or functions with `-f`                                  |
| `set [-eu] [-o OPT] [--]`  | Set shell options and positional parameters. Lists variables when bare    |
| `shift [N]`                | Drop positional parameters                                                |
| `local NAME[=VALUE]`       | Declare a function-local variable                                         |
| `return [N]`               | Return from a function                                                    |
| `break [N]`, `continue [N]`| Loop control                                                              |
| `read NAME...`             | Read a line from stdin into variables                                     |
| `source FILE`, `. FILE`    | Run a file in the current shell                                           |
| `exec COMMAND`             | Replace the shell process with a command                                  |
| `history [-c]`             | List the history, or clear it with `-c`                                   |
| `zsprompt [FORMAT]`        | Show, set or reset the prompt. See [prompt](#prompt)                      |
| `:`                        | Do nothing and succeed                                                    |

Everything else is looked up in `PATH` and run as an external command.

---

## ✦ Customization

### Startup files

| File            | Read by                      | Purpose                                 |
| --------------- | ---------------------------- | --------------------------------------- |
| `/etc/profile`  | Login shells                 | System-wide setup                       |
| `~/.profile`    | Login shells                 | Per-user login setup                    |
| `~/.zsrc`       | Interactive shells           | Aliases-style functions, exports, prompt |

`~/.zsrc` is plain ZS syntax. A typical one:

```sh
export EDITOR=nvim
export PATH="$HOME/.local/bin:$PATH"

mkcd() { mkdir -p "$1" && cd "$1"; }

zsprompt '\e[1;35m\u\e[0m in \e[1;34m\w\e[0m \e[33m\g\e[0m\n\$ '
```

Errors in startup files are reported as `zs: ~/.zsrc: ...` warnings and do not
stop the shell.

### Prompt

The prompt is a format string with Bash-like escapes. Run `zsprompt FORMAT` to
change it, `zsprompt` alone to print the current format and `zsprompt --reset`
to restore the default.

| Escape          | Expands to                                       |
| --------------- | ------------------------------------------------ |
| `\u`            | User name                                        |
| `\h`, `\H`      | Host name, short and full                        |
| `\w`            | Working directory, with `~` for `$HOME`          |
| `\W`            | Name of the working directory                    |
| `\t`            | Time as `HH:MM:SS`                               |
| `\A`            | Time as `HH:MM`                                  |
| `\d`            | Date, such as `Thu Oct 08`                       |
| `\g`            | Current git branch, or the short hash when detached |
| `\?`            | Exit status of the last command                  |
| `\$`            | `#` for root, `$` otherwise                      |
| `\n`            | Newline                                          |
| `\e`, `\033`    | Escape character, for colors                     |
| `\\`            | Backslash                                        |
| `\[`, `\]`      | Ignored, accepted for Bash compatibility         |

The format is also expanded for `$VAR` and `$(command)` every time the prompt
is drawn, so dynamic prompts work:

```sh
zsprompt '\e[32m\u\e[0m:\e[34m\W\e[0m $(date +%H:%M) \$ '
```

Unknown escapes are kept literally and ZS warns about them. The default prompt
is:

```
\e[1;32m\u@\h\e[0m \e[1;34m\W\e[0m\e[1;33m>>\e[0m
```

Escape sequences are ignored when ZS measures the prompt width, so wrapped
lines and wide characters redraw correctly.

### Syntax highlighting colors

| Element                                   | Color          |
| ----------------------------------------- | -------------- |
| Valid command, builtin or function        | Yellow         |
| Unknown command                           | Red            |
| Arguments                                 | Blue           |
| Quoted strings                            | Cyan           |
| Flags such as `-l` and `--help`           | Dark gray      |
| Operators, redirections, wildcards        | Bright cyan    |
| Reserved words (`if`, `for`, `case`, ...) | Purple         |
| Special parameters (`$?`, `$1`, `$@`, ...) | Red           |
| A lone `$`                                | Orange         |
| Brackets and subshell parentheses         | Dark gray      |
| Inline history suggestion                 | Dim gray       |

### Environment

| Variable   | Effect                                                          |
| ---------- | --------------------------------------------------------------- |
| `HISTFILE` | History file location. Defaults to `~/.zs_history`              |
| `HOME`     | Used for `~`, `~/.zsrc`, `~/.profile` and the default history   |
| `PATH`     | Searched for commands, validation and completion                |
| `TERM`     | OSC 133 prompt marks are disabled for `dumb` and `linux`        |

---

## ✦ How ZS works

### Source layout

| Module                | Role                                                                  |
| --------------------- | --------------------------------------------------------------------- |
| `src/main.zig`        | Entry point: argument parsing, startup files and the read-eval loop   |
| `src/editor.zig`      | Raw-mode line editor, key handling, redraw and inline suggestions     |
| `src/highlight.zig`   | Tokenizer-style renderer that colors a line as it is typed            |
| `src/complete.zig`    | Context analysis and Tab completion candidates                        |
| `src/parser.zig`      | Lexer and parser that turn text into an AST                           |
| `src/ast.zig`         | AST node types and the expansion machinery                            |
| `src/executor.zig`    | Evaluation, pipelines, redirections, builtins, signals and jobs       |
| `src/vars.zig`        | Shell and environment variables, positional parameters, scopes        |
| `src/functions.zig`   | Registry of user-defined functions                                    |
| `src/arith.zig`       | Integer evaluator for `$((...))` and `(( ... ))`                      |
| `src/glob.zig`        | Pattern matching and filesystem glob expansion                        |
| `src/prompt.zig`      | Prompt formatting, git branch lookup and escape stripping             |
| `src/history.zig`     | History storage backed by a file                                      |
| `src/rc.zig`          | Loader for `~/.zsrc`, `/etc/profile` and `~/.profile`                 |
| `src/commands.zig`    | Builtin table and command existence checks                            |
| `src/unicode.zig`     | Character widths for cursor placement                                 |
| `src/diag.zig`        | Colored `zs:` warnings and errors                                     |

### Life of a command

1. **Prompt.** `main` renders the prompt format, expanding `\` escapes first
   and then `$VAR` and `$(...)`, and hands it to the editor.
2. **Edit.** The editor puts the terminal in raw mode and reads bytes. After
   every key it redraws the line through the highlighter, appends the dim
   history suggestion and restores the cursor, accounting for line wrapping and
   wide characters. Typeahead is kept when the terminal switches modes between
   lines.
3. **Continue.** If the parser reports an unfinished construct, such as an
   open quote, `then` without `fi` or a trailing `|`, the shell asks the editor
   for another line with the `> ` prompt and keeps parsing.
4. **Parse.** The parser builds an AST of lists, pipelines, simple commands
   and compound commands. Command lists are parsed lazily, so a variable
   assigned earlier on the same line is visible when a later command expands.
5. **Expand.** Words go through tilde, parameter, command substitution,
   arithmetic and glob expansion, with quoting respected.
6. **Execute.** Builtins and functions run inside the shell process.
   External commands are launched with `fork` and `exec`, with the exported
   environment, redirections applied in the child and pipelines wired with
   pipes. Subshells and command substitutions run in a forked copy of the
   shell.
7. **Report.** The exit status is stored for `$?` and `\?`, the line is
   appended to the history, and the loop starts again.

### Syntax highlighting

The highlighter is a single left-to-right pass over the buffer that tracks
whether the next word is in command position. A word in command position is
checked with `commands.exists`, which looks at user functions, builtins and
finally every directory in `PATH` for an executable file, so typos show up in
red before you press Enter. It also follows state across `for ... in`,
`case ... esac` patterns, subshell parentheses and `${...}` expansions so that
each part gets the right color.

### History and suggestions

Each non-empty line is added to memory and appended to `HISTFILE` with mode
`0600`. Consecutive duplicates and multi-line entries are skipped, and the
latest 10 000 entries are loaded when an interactive shell starts. The
suggestion is the most recent history entry that starts with what you have
typed, and `→` or `End` accepts it.

### Completion

The editor analyzes the text before the cursor to decide what kind of word is
being typed. In command position it offers builtins, functions and executables
from `PATH`, and elsewhere it offers files and directories, with directories
getting a trailing `/`. A single match is inserted, several matches insert their common
prefix, and when there is nothing more to insert they are listed.

### Signals and interrupts

An interactive ZS ignores the interrupt, quit and stop signals for itself,
restores the default handlers in every child and interrupts only the
running foreground command on `Ctrl-C`. `exec` restores the default handlers
before replacing the process.

### Terminal integration

On terminals that are not `dumb` or `linux`, ZS emits OSC 133 marks around the
prompt (`A`, `B`), before running a command (`C`) and after it finishes
(`D;status`). Terminals with shell integration use these to jump between
prompts and to read exit codes.

### Memory

ZS uses Zig's `GeneralPurposeAllocator` for long-lived state and one arena per
command line, freed after the line has run, so there is no per-token cleanup
and leaks are caught in debug builds.

---

## ✦ License

ZS is free software released under the [GNU General Public License v3.0](LICENSE).
You can use, study, modify and share it, and anyone who distributes a modified
version must publish its source under the same license.
