# tabin.nvim

Provides on-request completion suggestions across a worktree and native code reviews in one Codex or Claude Code chat per Git worktree.

## Setup

### Pack
Install with Neovim's built-in package manager and add the setup below to your configuration.

```lua
vim.pack.add( { src = "https://github.com/gxddi/tabin"} )

require("tabin").setup({
  provider = "codex", -- or "claude" for Claude Code
  auth = {
    codex = {}, -- for example { "--device-auth" }
    claude = {}, -- for example { "--sso" }
  },
  prompt_dir = vim.fn.stdpath("config") .. "/tabin", -- optional
})
```

If your desktop-bundled Codex reports a packaging error on resume, set `codex = { no_daemon = true }`.

### Requirements
- Neovim 0.12
- Codex or Claude Code

## Use

Run `:TabinLogin` to sign in through the chosen client, or `:TabinLogin claude` to sign in to a specific provider.

### Bindings
| Key | Action | Desc |
| --- | --- | --- |
| Alt+c | Complete | Request ghost text for the task near the cursor in insert or normal mode. |
| Alt+a | Accept | Accept a suggestion within one line of the cursor. Otherwise, jump to a pending suggestion in this buffer or another file. Press again to accept it. |
| Alt+d | Dismiss | Dismiss the suggestion under or within one line of the cursor. |
| Alt+r | Review | Start a native code-review of the current buffer in the same chat. |

### Functions
Tabin stores the chat link in a Git-ignored `.tabin` file, and `:TabinLink <provider> <session-id>` lets you reuse an existing chat.

`:TabinOpen` opens the native chat, and `open_on_review = false` makes it open on demand after reviews.

The status line shows [Avante’s spinner](https://github.com/avante-corp/avante.nvim/blob/main/lua/avante/config.lua) and five-hour and weekly usage, with `:TabinUsage` to refresh Codex usage.

### Custom prompts
Tabin creates `complete.md` and `review.md` under `prompt_dir` if they are missing

## Motivations
