# slimchat.nvim

Inline suggestions and native code reviews in one Codex or Claude Code chat per Git worktree. The plugin needs Neovim 0.12, Git, and a current Codex or Claude Code command-line client.

## Setup

Add this to your Neovim configuration. The local Git source works with Neovim's built-in package manager.

```lua
vim.pack.add({ "file://" .. vim.fn.expand("~/Development/projects/slimchat.nvim") })

require("slimchat").setup({
  provider = "codex", -- or "claude" for Claude Code
  auth = {
    codex = {}, -- for example { "--device-auth" }
    claude = {}, -- for example { "--sso" }
  },
  prompts = {
    complete = {
      codex = "Complete the code near the cursor. Follow existing project style.",
      claude = "Complete the code near the cursor. Follow existing project style.",
    },
    review = {
      codex = "Review the current Git working tree. Run relevant tests. "
        .. "List findings by severity with path:line, impact, and a suggested fix.",
      claude = "Review the current Git working tree. Run relevant tests. "
        .. "List findings by severity with path:line, impact, and a suggested fix.",
    },
  },
})
```

Run `:SlimChatLogin` to sign in through the chosen client, or `:SlimChatLogin claude` to sign in to a specific provider. The plugin reuses the client's existing login. Set `command.codex` or `command.claude` to override the executable, and `env.codex` or `env.claude` to pass environment overrides from your Neovim configuration.

## Use

| Key | Action |
| --- | --- |
| Alt+C | Request ghost text for the current buffer in insert or normal mode. |
| Alt+A | Accept the suggestion under or within one line of the cursor. |
| Alt+D | Dismiss the suggestion under or within one line of the cursor. |
| Alt+R | Start a native review of the working tree in the same chat. |

Ghost text stays when you leave insert mode. Typing a matching prefix consumes that part of the ghost text, and a conflicting change at the suggestion clears it. Each change is accepted independently.

The first turn creates a native chat. The worktree's `.slimchat` contains one line, such as `codex:SESSION_ID` or `claude:SESSION_ID`. The plugin uses Git's local exclude file. To use an existing chat, run `:SlimChatLink codex SESSION_ID` or `:SlimChatLink claude SESSION_ID` before the first turn. The link determines which provider a worktree uses.

`:SlimChatOpen` opens that chat in the native client in a Neovim terminal tab. Exit the native client before starting another plugin turn in that worktree. Reviews open the native chat when they finish if you are still in the same worktree in normal mode. Set `open_on_review = false` to open it on demand.

The bottom-right status line animates while a turn runs and shows the used percentages for the five-hour and weekly windows. A dash means the client hasn't supplied a current value. Codex refreshes on project entry or focus, at most once every five minutes. `:SlimChatUsage` requests an immediate refresh. Claude Code supplies percentages during turns on versions and accounts that expose them. For a custom status line, set `statusline = false` and add `require("slimchat").status` as a component.

Alt+R uses [Codex's inline reviewer](https://learn.chatgpt.com/docs/app-server#review) or [Claude Code's bundled `/code-review` skill](https://code.claude.com/docs/en/skills). Put the desired review scope and format in `prompts.review`. Codex reviews can run tests with the default `codex.review_sandbox = "workspace-write"`. Claude Code uses the client's permissions. Set `claude.review_args` to pass additional arguments such as `{ "--allowedTools", "Bash(npm test)" }` in projects where that is appropriate.

Other options include `keys` (set an action to `false` to disable its mapping), `context_lines`, `timeout` in milliseconds, and `spinner`. Completion sends the nearby buffer context and its cursor position to the provider. Reviews use the native project's working directory and tools. If an editor crashes and leaves a chat locked, the reported lock directory can be removed once that chat is no longer running.
