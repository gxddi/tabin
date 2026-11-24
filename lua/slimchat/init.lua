local M = {}
local api = vim.api
local project = require("slimchat.project")
local providers = require("slimchat.providers")
local ghost = require("slimchat.ghost")

local review = "Review the current Git working tree. Use the project's existing review instructions and "
  .. "run relevant tests when useful. Leave the source unchanged. Report actionable findings by priority "
  .. "with path:line, impact, and a suggested fix. If there are no findings, say so and mention what you checked."
local complete = "Propose the smallest useful code edits near the cursor based on the surrounding code."

local defaults = {
  provider = "codex",
  command = { codex = "codex", claude = "claude" },
  env = { codex = {}, claude = {} },
  auth = { codex = {}, claude = {} },
  prompts = { complete = { codex = complete, claude = complete }, review = { codex = review, claude = review } },
  keys = { complete = "<M-c>", accept = "<M-a>", dismiss = "<M-d>", review = "<M-r>" },
  codex = { review_sandbox = "workspace-write" },
  claude = { review_args = {} },
  context_lines = 30,
  timeout = 600000,
  spinner = { "*", ".", "·", "✦" },
  statusline = true,
  open_on_review = true,
}

local opts
local active, locks = {}, {}
local usage = { codex = {}, claude = {} }
local frame, timer = 1, nil
local last_usage, reading_usage = nil, false
local original_statusline

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "SlimChat" })
end

local function guarded(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      notify(tostring(err), vim.log.levels.ERROR)
    end
  end
end

local function redraw()
  vim.cmd.redrawstatus()
end

local function busy(root, state)
  active[root] = state
  if state and not timer then
    frame = 1
    timer = vim.uv.new_timer()
    timer:start(120, 120, vim.schedule_wrap(function()
      frame = frame % #opts.spinner + 1
      redraw()
    end))
  elseif not next(active) and timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  redraw()
end

local function update_usage(provider, window, percent, resets)
  if type(percent) == "number" then
    usage[provider][window] = { percent = percent, resets = type(resets) == "number" and resets or nil }
    redraw()
  end
end

local function lock(root)
  if locks[root] then
    error("This project's chat is already in use", 0)
  end
  locks[root] = project.lock(root)
  return function()
    local release = locks[root]
    if release then
      locks[root] = nil
      release()
    end
  end
end

local function root_for(buf)
  return project.root(buf) or error("Open a file in a Git worktree first", 0)
end

local function require_cli(provider)
  if vim.fn.executable(opts.command[provider]) ~= 1 then
    error(opts.command[provider] .. " is not executable", 0)
  end
end

local function terminal(args, root, provider, on_exit)
  vim.cmd.tabnew()
  local ok, job = pcall(vim.fn.jobstart, args, {
    term = true, cwd = root, env = next(opts.env[provider]) and opts.env[provider] or nil, on_exit = on_exit,
  })
  if not ok or job <= 0 then
    vim.cmd.tabclose()
    error("Could not run " .. args[1], 0)
  end
  vim.cmd.startinsert()
end

local function open_chat(root)
  local release = lock(root)
  local ok, err = pcall(function()
    local link = project.prepare(root)
    if not link then
      error("Start a completion or review to create the project's chat", 0)
    end
    require_cli(link.provider)
    terminal(providers.resume(link, opts), root, link.provider, release)
  end)
  if not ok then
    release()
    error(err, 0)
  end
end

local function refresh_usage(root, provider, force)
  if provider ~= "codex" then
    if force then
      notify("Claude Code updates usage when it reports quota during a turn")
    end
    return
  end
  if reading_usage or (not force and last_usage and os.time() - last_usage < 300)
      or vim.fn.executable(opts.command.codex) ~= 1 then
    return
  end
  last_usage, reading_usage = os.time(), true
  providers.usage(root, opts, function(window, percent, reset)
    update_usage("codex", window, percent, reset)
  end, function(err)
    reading_usage = false
    if err and force then
      notify(err, vim.log.levels.WARN)
    end
  end)
end

local function visit(buf, force)
  local root = project.root(buf)
  if not root then
    return
  end
  local ok, link = pcall(project.read, root)
  refresh_usage(root, ok and link and link.provider or opts.provider, force)
end

local function request(kind)
  local buf = api.nvim_get_current_buf()
  if kind == "complete" and not vim.bo[buf].modifiable then
    return
  end
  local root = root_for(buf)
  local release = lock(root)
  local ok, err = pcall(function()
    local link = project.prepare(root)
    local provider = link and link.provider or opts.provider
    require_cli(provider)
    local prompt = opts.prompts[kind][provider]
    local context, tick
    if kind == "complete" then
      ghost.clear(buf)
      context = ghost.context(buf, opts.context_lines)
      context.file = api.nvim_buf_get_name(buf)
      if vim.startswith(context.file, root .. "/") then
        context.file = context.file:sub(#root + 2)
      end
      tick = api.nvim_buf_get_changedtick(buf)
      prompt = prompt .. "\n\nReturn JSON with an edits array. Each edit has start_line and end_line "
        .. "(absolute 1-based inclusive lines) and text (replacement for those whole lines). "
        .. "Restrict edits to the supplied context, keep spans disjoint, and preserve unchanged text "
        .. "on edited lines. Use an empty array if you have no suggestion. "
        .. "cursor_byte_column is zero-based. Buffer context follows as JSON data.\n"
        .. vim.json.encode(context)
    end

    busy(root, { provider = provider })
    local link_error
    providers.turn[provider](root, link, kind, prompt, context and ghost.schema, opts, function(window, percent, reset)
      update_usage(provider, window, percent, reset)
    end, function(id)
      if not link then
        local wrote, write_err = pcall(project.write, root, provider, id)
        if wrote then
          link = { provider = provider, id = id }
          link_error = nil
        else
          link_error = tostring(write_err)
        end
      end
    end, function(turn_error, answer)
      release()
      busy(root, nil)
      guarded(function()
        if link_error then
          notify(link_error, vim.log.levels.ERROR)
        end
        if turn_error then
          notify(turn_error, vim.log.levels.ERROR)
        elseif kind == "review" then
          if opts.open_on_review and link and root == project.root(api.nvim_get_current_buf())
              and vim.fn.mode() == "n" then
            open_chat(root)
          else
            notify("Review finished. Open the native chat with :SlimChatOpen")
          end
        elseif api.nvim_buf_is_loaded(buf) and tick == api.nvim_buf_get_changedtick(buf) then
          local shown, edit_error = ghost.show(buf, context, answer)
          if not shown then
            notify(edit_error, vim.log.levels.WARN)
          elseif shown == 0 then
            notify("No completion suggested")
          end
        end
      end)()
    end)
  end)
  if not ok then
    release()
    busy(root, nil)
    error(err, 0)
  end
end

local function status_buf()
  local win = tonumber(vim.g.statusline_winid)
  return win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) or api.nvim_get_current_buf()
end

function M.status()
  if not opts then
    return ""
  end
  local buf = status_buf()
  local root = vim.b[buf].slimchat_root
  if not root then
    return ""
  end
  local provider = (active[root] and active[root].provider) or vim.b[buf].slimchat_provider or opts.provider
  local function used(window)
    local value = usage[provider][window]
    return value and (not value.resets or value.resets > os.time()) and ("%g%%"):format(value.percent) or "–"
  end
  local spinner = active[root] and (opts.spinner[frame] .. " ") or ""
  return ("%s%s 5h %s  7d %s"):format(spinner, provider == "codex" and "Codex" or "Claude", used("5h"), used("7d"))
end

local function statusline()
  local base = original_statusline
  if base:sub(1, 2) == "%!" then
    local ok, result = pcall(api.nvim_eval, base:sub(3))
    base = ok and type(result) == "string" and result or ""
  end
  if base == "" then
    base = "%f %h%m%r%=%-14.(%l,%c%V%) %P"
  end
  if M.status() == "" then
    return base
  end
  local align = base:find("%=", 1, true) and "" or "%="
  return base .. align .. "  %{v:lua.require'slimchat'.status()} "
end

M.statusline = statusline

local function index_buffer(buf)
  local root = project.root(buf)
  vim.b[buf].slimchat_root = root
  if root then
    local ok, link = pcall(project.read, root)
    vim.b[buf].slimchat_provider = ok and link and link.provider or nil
  end
end

function M.setup(config)
  if opts then
    error("Call slimchat.setup() only once", 0)
  end
  local settings = vim.tbl_deep_extend("force", vim.deepcopy(defaults), config or {})
  assert(settings.provider == "codex" or settings.provider == "claude", "Invalid SlimChat provider")
  assert(vim.islist(settings.spinner) and #settings.spinner > 0, "SlimChat needs at least one spinner frame")
  opts = settings
  local group = api.nvim_create_augroup("SlimChat", { clear = true })
  api.nvim_set_hl(0, "SlimChatGhost", { default = true, link = "Comment" })
  api.nvim_set_hl(0, "SlimChatDelete", { default = true, strikethrough = true })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "InsertLeave" }, {
    group = group,
    callback = function(event) ghost.refresh(event.buf) end,
  })
  api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(event) ghost.forget(event.buf) end,
  })
  api.nvim_create_autocmd({ "BufEnter", "BufFilePost", "FocusGained", "DirChanged" }, {
    group = group,
    callback = guarded(function(event)
      local buf = event.buf > 0 and event.buf or api.nvim_get_current_buf()
      index_buffer(buf)
      visit(buf)
    end),
  })
  api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for _, release in pairs(locks) do
        release()
      end
      locks = {}
    end,
  })
  for action, callback in pairs({
    complete = function() request("complete") end,
    accept = function() ghost.choose(true) end,
    dismiss = function() ghost.choose(false) end,
    review = function() request("review") end,
  }) do
    if opts.keys[action] then
      vim.keymap.set({ "n", "i" }, opts.keys[action], guarded(callback), { desc = "SlimChat " .. action })
    end
  end
  api.nvim_create_user_command("SlimChatLogin", guarded(function(command)
    local root = project.root(api.nvim_get_current_buf())
    local link = root and project.read(root)
    local provider = command.args ~= "" and command.args or (link and link.provider or opts.provider)
    assert(provider == "codex" or provider == "claude", "Use codex or claude")
    require_cli(provider)
    terminal(providers.login(provider, opts), root or vim.uv.cwd(), provider, function()
      usage[provider] = {}
      last_usage = nil
    end)
  end), { nargs = "?", complete = function() return { "codex", "claude" } end })
  api.nvim_create_user_command("SlimChatLink", guarded(function(command)
    local provider, id = unpack(command.fargs)
    assert(#command.fargs == 2 and project.valid(provider, id), "Use :SlimChatLink codex|claude SESSION_ID")
    local buf = api.nvim_get_current_buf()
    local root = root_for(buf)
    local release = lock(root)
    local ok, err = pcall(function()
      if project.prepare(root) then
        error("This project already has a chat pointer", 0)
      end
      project.write(root, provider, id)
    end)
    release()
    if not ok then
      error(err, 0)
    end
    index_buffer(buf)
    refresh_usage(root, provider)
  end), { nargs = "+" })
  api.nvim_create_user_command("SlimChatOpen", guarded(function()
    open_chat(root_for(api.nvim_get_current_buf()))
  end), {})
  api.nvim_create_user_command("SlimChatUsage", guarded(function()
    visit(api.nvim_get_current_buf(), true)
  end), {})
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) then
      index_buffer(buf)
    end
  end
  if opts.statusline then
    original_statusline = vim.go.statusline
    vim.go.statusline = "%!v:lua.require'slimchat'.statusline()"
  end
  visit(api.nvim_get_current_buf())
end

return M
