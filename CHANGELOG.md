# Changelog

## 2026-10-08

- Fix remove zig init boilerplate
- Add prompt loop with exit builtin
- Add raw mode line editor with cursor movement and editing keys
- Fix keep typeahead when switching terminal mode between lines
- Add live syntax highlighting for commands, arguments, strings and flags
- Fix prompt redraw for wrapped lines and wide characters
- Add history navigation with up/down arrows and Ctrl-L screen clear
- Add command validation so only builtins and executables on PATH are highlighted as commands
- Add command line parser for quotes, pipes, semicolons and tilde expansion
- Add command execution with pipelines, cd and exit builtins, and interrupt handling
- Add variable expansion for $VAR, ${VAR} and $? with lazily parsed command lists
- Add && and || operators for conditional command lists
- Add glob expansion for *, ? and [...] patterns
- Add user, host and working directory to the prompt
