# tabin.nvim

Inline suggestions and native code reviews in one Codex or Claude Code chat per Git worktree. The plugin needs Neovim 0.12, Git, and a current Codex or Claude Code command-line client.

## Setup

Install with Neovim's built-in package manager and add the setup below to your configuration.

```lua
vim.pack.add({ { src = "https://github.com/gxddi/tabin", name = "tabin.nvim" } })

require("tabin").setup({
  provider = "codex", -- or "claude" for Claude Code
  auth = {
    codex = {}, -- for example { "--device-auth" }
    claude = {}, -- for example { "--sso" }
  },
  prompt_dir = vim.fn.stdpath("config") .. "/tabin", -- optional
})
```

Tabin creates `complete.md` and `review.md` under `prompt_dir` if they are missing. The default directory is `~/.config/nvim/tabin` on Linux. Edit the Markdown files to change the prompts. Each request reads the current file.

## Use

Run `:TabinLogin` to sign in through the chosen client, or `:TabinLogin claude` to sign in to a specific provider.

| Key | Action | Desc |
| --- | --- | --- |
| Alt+c | Complete | Request ghost text for the current buffer in insert or normal mode. |
| Alt+a | Accept | Accept the suggestion under or within one line of the cursor. |
| Alt+d | Dismiss | Dismiss the suggestion under or within one line of the cursor. |
| Alt+r | Review | Start a native code-review of the current buffer in the same chat. |

Ghost text stays when you leave insert mode. Typing a matching prefix consumes that part of the ghost text, and a conflicting change at the suggestion clears it. Each change is accepted independently.

The first turn creates a native chat. The worktree's `.tabin` contains one line, such as `codex:SESSION_ID` or `claude:SESSION_ID`. The plugin uses Git's local exclude file. To use an existing chat, run `:TabinLink codex SESSION_ID` or `:TabinLink claude SESSION_ID` before the first turn. The link determines which provider a worktree uses. Existing `.slimchat` pointers still work.

`:TabinOpen` opens that chat in the native client in a Neovim terminal tab. Exit the native client before starting another plugin turn in that worktree. Reviews open the native chat when they finish if you are still in the same worktree in normal mode. Set `open_on_review = false` to open it on demand.

The bottom-right status line uses [Avante’s generating spinner](https://github.com/avante-corp/avante.nvim/blob/main/lua/avante/config.lua) while a turn runs and shows the used percentages for the five-hour and weekly windows. A dash means the client hasn't supplied a current value. Codex refreshes on project entry or focus, at most once every five minutes. `:TabinUsage` requests an immediate refresh. Claude Code supplies percentages during turns on versions and accounts that expose them. For a custom status line, set `statusline = false` and add `require("tabin").status` as a component.

Alt+R reviews a snapshot of the open buffer, including unsaved edits. Edit `review.md` to set review criteria and output format. Codex uses its [inline reviewer](https://learn.chatgpt.com/docs/app-server#review), and Claude Code reviews the snapshot in the existing chat with its usual tools. Codex can run tests with the default `codex.review_sandbox = "workspace-write"`. Claude Code uses the client's permissions. Use `claude.review_args` to pass additional arguments such as `{ "--allowedTools", "Bash(npm test)" }`.

Other options include `keys` (set an action to `false` to disable its mapping), `context_lines`, `timeout` in milliseconds, and `spinner`. Completion sends the nearby buffer context and its cursor position to the provider. Reviews use the native project's working directory and tools. If an editor crashes and leaves a chat locked, the reported lock directory can be removed once that chat is no longer running.
