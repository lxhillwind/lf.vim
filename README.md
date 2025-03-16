# lf.vim
directory travesal, with simple extension (cp, mv, rm...)

<!-- from issues -->
![gif](https://github.com/user-attachments/assets/af09cc60-8fac-4b51-b69f-b7e28953becd)

(a gif showing coping files between different directories)

## Features
- Supports UNC path on Windows, like wsl folder, Virtual Box shared folder.
- When there are exactly two lf.vim buffers in a Vim tab, commands like
  `:LfMoveTo` / `:LfCopyTo` can be used without a destination argument,
  emulating behavior like in **Dual-Pane** file manager.
- Files copy operation (`:LfCopyTo`) is implemented as async operation: it
  does not block UI.

## Usage

### create an **lf buffer** to list files / directories
- From normal buffer, press `-` (the cursor is moved to the line representing the file);
- In any buffer, run command `:Lf {argument}`: the argument can be a directory
  or a file; in the latter case, the parent directory of the file is open,
  while the cursor is moved to the line representing the file.
- In one `lf buffer`, use window creating operation (like `CTRL-W_v` /
  `:split`) to create a new window; operations in this new window is
  independent from the original window. (This is how we emulate Dual-Pane UI)

### map in an **lf buffer**
- `e` to edit the file where the cursor is on;
- `h` to go to one level up (of the parent directory of current file);
- `l` to go to one level down;
- `K` (`shift+k`) to show file info of current file;
- `r` to refresh current `lf buffer`;
- `R` to refresh all `lf buffers` in current Vim tab;
- `f` / `F` accepts a following character, which will move cursor to the next
  (or previous) entry beginning with the character;
- `;` / `,` is like `f` / `F`, but reuse the character;
- `yy` to yank full path of current entry;
- `q` to quit Vim if there is only one `lf buffer`;
- all other key mappings operating on a buffer (like `gg`, `G`, `j`, `k`, `p`...).

### UserCommand
- `:Lf {file-or-dir}`: create an `lf buffer` (introduced above).
*All following commands ask for user confirmation before doing actions on files.*
- `:LfCopyTo [dest]`: copy entries selected by range, to `[dest]` dir; the
`[dest]` can be omitted if exactly one another `lf buffer` exists in current
Tab;
- `:LfMoveTo [dest]`: like `:LfCopyTo`, but operation is replaced with `move`;
- `:LfDelete`: delete entries selected by range.

## About

The plugin name `lf.vim` comes from Terminal file manager
[lf](https://github.com/gokcehan/lf), which I used in Vim as a file selector.

`lf` does not support Dual-Pane UI natively (though can be done with terminal
multiplexer or terminal emulator), so I decided to implement it myself (in a
Vim plugin).

In this plugin, I also add support for Windows UNC path, which is missing from
`vim-dirvish` (the directory viewer I used years ago).
