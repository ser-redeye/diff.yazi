# diff.yazi

Compare one selected entry with the hovered entry using Git by default or a
command template of your choice. The plugin opens the tool in the terminal and
returns to Yazi after it exits.

> [!IMPORTANT]
> Default behavior with no configuration and no plugin argument, the plugin runs:
>
> ```text
> git diff --no-index -- <selected> <hovered>
> ```
>
> Git's `--no-index` mode compares arbitrary files or directories; neither entry
> needs to belong to a Git repository. Git controls its normal pager behavior,
> so your configured pager is used when applicable. The plugin requires exactly
> one selected entry and one hovered entry.

## Getting Started

### Requirements

- [Yazi](https://yazi-rs.github.io/) 26.5.6(tested) or newer
- [Git](https://git-scm.com/) in `PATH` for the built-in default
- Any executable named by a custom command template in `PATH`

### Installation

``` sh
ya pkg add ser-redeye/diff
```

### Setup

Setup is *optional*. Set `command` to replace the built-in Git command for every
plain `plugin diff` invocation:

```lua
require("diff"):setup({
  -- DEFAULT
  command = "git diff --no-index -- {left} {right}",
  -- nvim diff mode
  command = "nvim -d -- {left} {right}",
})
```

> [!WARNING]
> The entire command template must be quoted in `keymap.toml`; the plugin accepts
> exactly one command argument. Refer to [this section](#the-command-template) for more info.

### Usage

The command to use for comparison is selected in this order:

1. The quoted command template argument passed to `plugin diff`.
2. `command` from plugin setup (`require("diff"):setup()`).
3. The built-in Git template.

For example:

```toml
[[mgr.prepend_keymap]]
on   = [ "<A-d>", "<Enter>" ]
run  = "plugin diff"
desc = "Diff selected vs hovered"

[[mgr.prepend_keymap]]
on   = [ "<A-d>", "n" ]
run  = 'plugin diff -- "nvim -d -- {left} {right}"'
desc = "Diff selected vs hovered (nvim)"
```

## The Command Template

A template describes one executable and its arguments. It must contain exactly
one standalone `{left}` placeholder and one standalone `{right}` placeholder:

```text
command --option {left} {right}
```

`{left}` is replaced by the selected path and `{right}` by the hovered path.
They cannot be embedded inside another argument, such as `--left={left}`.

The parser supports:

- whitespace-separated arguments;
- single or double quotes to preserve whitespace inside an argument; and
- a backslash to escape the following character.

Use `--` before the placeholders when the chosen tool supports an end-of-options
marker. This prevents paths beginning with `-` from being interpreted as tool
options.

## Security and shell behavior

Templates are direct process invocations, not shell commands. The plugin does
not use `sh -c`, `cmd /C`, `eval`, or string interpolation of file paths.

Shell syntax—including pipes (`|`), redirections (`>`), chaining (`&&`, `;`),
variables, command substitutions, globs, and backticks—is passed literally to
the executable. For example, this will not pipe Git into `less`:

```lua
command = "git diff --no-index -- {left} {right} | less"
```

In this case Git receives `|` and `less` as ordinary arguments. If you need
shell features, invoke a trusted wrapper program and pass `{left}` and
`{right}` to it as normal arguments.

## Troubleshooting

Inspect debug events, start Yazi with `YAZI_LOG=debug`; the log is normally
written to `~/.local/state/yazi/yazi.log` on Unix-like systems. Refer to
[yazi-docs](https://yazi-rs.github.io/docs/plugins/overview#debugging) for more info.
