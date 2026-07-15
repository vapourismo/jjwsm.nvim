# jjwsm.nvim

`jjwsm.nvim` is a small Jujutsu workspace manager for Neovim. It can switch the
invoking tabpage to another workspace or create a temporary workspace in a new
tabpage. There is no `setup()` call, configuration schema, default mapping, or
filesystem-deletion command.

## Requirements

- Neovim 0.10 or newer
- [Jujutsu 0.40 or newer](https://github.com/jj-vcs/jj/releases/tag/v0.40.0)
- [Snacks.nvim](https://github.com/folke/snacks.nvim) with its picker enabled
- [Tabby.nvim](https://github.com/nanozuki/tabby.nvim) is optional and names
  tabs after successful workspace activation

Jujutsu 0.40 is the minimum because workspace templates need the workspace
`root()` method.

## Installation

With lazy.nvim:

```lua
{
  "vapourismo/jjwsm.nvim",
  dependencies = {
    {
      "folke/snacks.nvim",
      opts = { picker = {} },
    },
  },
}
```

The command is registered automatically when Neovim loads the plugin.

## Commands

### `:Jjwsm switch`

Lists the repository's other live workspaces in a Snacks picker. Both workspace
name and absolute root are displayed and searchable. The workspace containing
the invoking tabpage's cwd is excluded.

The tabpage and its tab-local cwd are captured when the command starts. On
confirmation, the selected root is checked again and `:tcd` is applied only to
that captured tabpage, even if another tab has since become current. If the root
disappeared while the picker was open, its Jujutsu record is forgotten and no
cwd is changed.

### `:Jjwsm new`

Prompts for a workspace name with `vim.ui.input()`, creates that workspace,
opens one blank tabpage, and sets the tabpage's cwd to the new workspace root.
The prompt is `Workspace name: ` and has no generated default, so installed UI
providers can customize it. A nonblank name is preserved verbatim and becomes
the Jujutsu workspace identifier. Cancelling reports an informational notice;
blank names and names already registered in the repository are rejected.

The temporary path is generated independently from the prompted name. It uses
this layout:

```text
$TMPDIR/jjwsm.nvim/jjwsm-my-repo-1
```

Here, `my-repo` is the basename of the retained `default` workspace root. The
basename is used verbatim, including spaces, case, dots, and punctuation.
Allocation starts at `N = 1` and uses the lowest counter whose generated path
does not exist. For example, a prompted name of `feature: parser work` can be
registered at the path above; the identifier does not affect the path.

The operating system temporary root comes from `vim.uv.os_tmpdir()`, so
`$TMPDIR` above is descriptive rather than a literal environment-variable
lookup. The shared parent is created as mode `0700` when absent. An existing
parent must be a real directory; symlinks and non-directory paths are rejected.
The final repository-specific directory must not exist before creation and is
created and populated by `jj workspace add` itself.

If another process wins a generated-path race, allocation resumes from the next
counter with the same prompted workspace name and derived repository basename.
If the rescan instead shows that the prompted name was concurrently registered,
creation stops. Other Jujutsu validation and creation failures are reported
without opening a tab. Because the path namespace is shared, an existing
candidate directory is never reused, even when it belongs to another repository
or is empty. Creation is aborted before prompting or touching the temporary
parent if the `default` workspace root and its non-empty basename cannot be
determined. Cancellation and invalid input also leave the parent untouched.

## Tab names

After a new workspace or a non-default workspace switch is successfully
activated, jjwsm.nvim asks Tabby.nvim to name the tab
`<repository>[<workspace>]`. `<repository>` is the retained `default` workspace
root's basename, with its original case, spaces, and punctuation, and
`<workspace>` is the selected or prompted workspace name. For example, creating
`feature: parser work` for `/work/Repo With Spaces.v1+Draft` produces:

```text
Repo With Spaces.v1+Draft[feature: parser work]
```

Switching updates the tabpage that invoked the picker, even if another tabpage
is current when the selection is confirmed. A successful switch to the
`default` workspace invokes `:Tabby rename_tab` without a name, removing that
tab's previous explicit Tabby name. Other successful activations intentionally
replace the previous Tabby name. Naming is best-effort: if Tabby is not
installed, its command fails, or the default basename is unavailable during a
non-default switch, jjwsm.nvim warns but keeps the activated cwd and previous
tab name. Failed or stale activations do not update a tab name.

## Cleanup and safety

Before either command, the plugin inspects every workspace registered in the
repository associated with the invoking tabpage cwd:

- live directories are retained, regardless of which tool created them;
- records for roots that definitively do not exist or are not directories are
  forgotten with `jj workspace forget`;
- roots that cannot be inspected, for example because of a permission error,
  are retained and produce a warning;
- if Jujutsu cannot forget stale records, the requested operation is aborted.

This metadata cleanup is limited to the current repository. The plugin never
deletes, empties, or reuses a filesystem path. Temporary workspace directories
remain until the user or operating system removes them; a later invocation will
skip any path that still exists.

The `:Jjwsm` command is global because Neovim has no tab-local user commands.
Every invocation nevertheless resolves and validates the invoking tabpage's
tab-local cwd. Jujutsu processes run asynchronously with argument arrays, so
workspace names and paths are never interpolated into shell commands.

## Development

Run the dependency-light mocked tests and real Jujutsu integration tests with:

```sh
make test
```

The integration suite expects `nvim` and `jj` on `PATH`. It is currently tested
with Neovim 0.12.2 and Jujutsu 0.43.0.
