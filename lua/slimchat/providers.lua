local M = {}

local function decode(line)
  local ok, value = pcall(vim.json.decode, line)
  if ok and type(value) == "table" then
    return value
  end
end

local function codex(root, opts, timeout, ready, event, done)
  local id, pending = 0, {}
  local tail, stderr = "", ""
  local job, timer, stopped
  local function finish(err)
    if stopped then
      return
    end
    stopped = true
    if timer then
      timer:stop()
      timer:close()
    end
    if job and job > 0 then
      pcall(vim.fn.chanclose, job, "stdin")
      if err then
        pcall(vim.fn.jobstop, job)
      end
    end
    done(err)
  end
  local function send(message)
    local ok, sent = pcall(vim.fn.chansend, job, vim.json.encode(message) .. "\n")
    if not ok or sent == 0 then
      finish("Lost connection to Codex")
    end
  end
  local function request(method, params, callback)
    id = id + 1
    pending[id] = callback
    send({ id = id, method = method, params = params })
  end
  local function message(line)
    local msg = decode(line)
    if stopped or not msg then
      return
    end
    if msg.id and msg.method then
      send({ id = msg.id, error = { code = -32601, message = "No interactive response available" } })
    elseif msg.id and pending[msg.id] then
      local callback = pending[msg.id]
      pending[msg.id] = nil
      if msg.error then
        finish(msg.error.message or "Codex request failed")
      else
        callback(msg.result)
      end
    elseif msg.method then
      event(msg.method, msg.params or {}, finish)
    end
  end
  job = vim.fn.jobstart({ opts.command.codex, "app-server" }, {
    cwd = root,
    env = next(opts.env.codex) and opts.env.codex or nil,
    on_stdout = function(_, data)
      data[1] = tail .. data[1]
      tail = table.remove(data)
      for _, line in ipairs(data) do
        local ok, err = pcall(message, line)
        if not ok then
          finish(tostring(err))
        end
      end
    end,
    on_stderr = function(_, data)
      stderr = (stderr .. table.concat(data, "\n")):sub(-2000)
    end,
    on_exit = function(_, code)
      finish(vim.trim(stderr) ~= "" and vim.trim(stderr) or ("Codex exited (" .. code .. ")"))
    end,
  })
  if job <= 0 then
    finish("Could not start " .. opts.command.codex)
    return
  end
  timer = vim.uv.new_timer()
  timer:start(timeout, 0, vim.schedule_wrap(function()
    finish("Codex request timed out")
  end))
  request("initialize", { clientInfo = { name = "slimchat", version = "0.1.0" } }, function()
    send({ method = "initialized" })
    if not stopped then
      ready(request, finish)
    end
  end)
end

local function codex_usage(data, report)
  local buckets = data.rateLimitsByLimitId
  local limits = (type(buckets) == "table" and buckets.codex) or data.rateLimits
  if type(limits) ~= "table" then
    return
  end
  local windows = { [300] = "5h", [10080] = "7d" }
  for _, key in ipairs({ "primary", "secondary" }) do
    local window = limits[key]
    if type(window) == "table" and windows[window.windowDurationMins] then
      report(windows[window.windowDurationMins], window.usedPercent, window.resetsAt)
    end
  end
end

function M.usage(root, opts, report, done)
  codex(root, opts, 15000, function(request, finish)
    request("account/rateLimits/read", { excludeResetCreditDetails = true }, function(data)
      codex_usage(data, report)
      finish()
    end)
  end, function() end, done)
end

local function codex_turn(root, link, kind, prompt, schema, opts, report, remember, done)
  local thread, turn, answer, turn_error
  codex(root, opts, opts.timeout, function(request)
    local review = kind == "review"
    local params = {
      cwd = root,
      sandbox = review and opts.codex.review_sandbox or "read-only",
      approvalPolicy = "never",
    }
    if link then
      params.threadId = link.id
      params.excludeTurns = true
    end
    request(link and "thread/resume" or "thread/start", params, function(result)
      thread = result.thread.id
      local method, input
      if review then
        method = "review/start"
        input = { delivery = "inline", target = { type = "custom", instructions = prompt } }
      else
        method = "turn/start"
        input = { input = { { type = "text", text = prompt } }, outputSchema = schema }
      end
      input.threadId = thread
      request(method, input, function(response)
        turn = response.turn.id
        remember(thread)
      end)
    end)
  end, function(method, params, finish)
    if method == "account/rateLimits/updated" then
      codex_usage(params, report)
    elseif thread and params.threadId == thread then
      if method == "item/completed" and params.item.type == "agentMessage" then
        if params.item.phase ~= "commentary" then
          answer = params.item.text
        end
      elseif method == "error" and not params.willRetry then
        turn_error = params.error and params.error.message
      elseif method == "turn/completed" and (not turn or params.turn.id == turn) then
        local result = params.turn
        remember(thread)
        if result.status == "completed" then
          finish()
        else
          finish((type(result.error) == "table" and result.error.message) or turn_error
            or ("Codex turn " .. result.status))
        end
      end
    end
  end, function(err)
    done(err, answer)
  end)
end

local function claude_usage(info, report)
  if type(info) ~= "table" then
    return
  end
  local names = { five_hour = "5h", seven_day = "7d" }
  if type(info.unifiedWindows) == "table" then
    for key, name in pairs(names) do
      local window = info.unifiedWindows[key]
      if type(window) == "table" and type(window.utilization) == "number" then
        report(name, 100 * window.utilization, window.resetsAt)
      end
    end
  end
  if names[info.rateLimitType] and type(info.utilization) == "number" then
    report(names[info.rateLimitType], 100 * info.utilization, info.resetsAt)
  end
end

local function claude_turn(root, link, kind, prompt, schema, opts, report, remember, done)
  local args = { opts.command.claude, "-p", "--output-format", "stream-json", "--verbose" }
  if link then
    vim.list_extend(args, { "--resume", link.id })
  end
  if kind == "complete" then
    vim.list_extend(args, {
      "--tools", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
      "--json-schema", vim.json.encode(schema),
    })
  else
    vim.list_extend(args, {
      "--system-prompt-snapshot", "off", "--append-system-prompt",
      "For this code review, apply the following project instructions:\n" .. prompt,
    })
    vim.list_extend(args, opts.claude.review_args)
    prompt = "/code-review"
  end
  vim.system(args, {
    cwd = root, env = opts.env.claude, stdin = prompt, text = true, timeout = opts.timeout,
  }, vim.schedule_wrap(function(process)
    local result
    for line in (process.stdout or ""):gmatch("[^\n]+") do
      local event = decode(line)
      if event and event.type == "rate_limit_event" then
        claude_usage(event.rate_limit_info, report)
      elseif event and event.type == "result" then
        result = event
      end
    end
    if process.code == 0 and result and not result.is_error then
      remember(result.session_id)
      done(nil, type(result.structured_output) == "table" and result.structured_output or result.result)
    else
      local err = result and (result.result or table.concat(result.errors or {}, "\n"))
      if type(err) ~= "string" or err == "" then
        err = vim.trim(process.stderr or "")
      end
      done(err ~= "" and err or ("Claude Code exited (" .. process.code .. ")"))
    end
  end))
end

M.turn = { codex = codex_turn, claude = claude_turn }

function M.login(provider, opts)
  local args = { opts.command[provider] }
  vim.list_extend(args, provider == "codex" and { "login" } or { "auth", "login" })
  return vim.list_extend(args, opts.auth[provider])
end

function M.resume(link, opts)
  if not link then
    return
  end
  local command = opts.command[link.provider]
  return link.provider == "codex" and { command, "resume", link.id }
    or { command, "--resume", link.id }
end

return M
