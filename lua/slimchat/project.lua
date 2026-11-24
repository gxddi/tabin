local M = {}
local uv = vim.uv
local filename = ".slimchat"

local function git(root, ...)
  return vim.system({ "git", "-C", root, ... }, { text = true }):wait()
end

function M.root(buf)
  if vim.bo[buf].buftype ~= "" or vim.fn.executable("git") ~= 1 then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local root = vim.fs.root(name ~= "" and name or uv.cwd(), ".git")
  return root and (uv.fs_realpath(root) or root)
end

function M.valid(provider, id)
  return (provider == "codex" or provider == "claude")
    and type(id) == "string" and #id <= 128 and id:match("^[%w][%w_%-]*$") ~= nil
end

function M.read(root)
  local path = vim.fs.joinpath(root, filename)
  local stat = uv.fs_lstat(path)
  if not stat then
    return nil
  end
  if stat.type ~= "file" or stat.size > 256 then
    error("Invalid project pointer: " .. path, 0)
  end
  local lines = vim.fn.readfile(path)
  local provider, id = (lines[1] or ""):match("^(%w+):([%w_%-]+)$")
  if #lines ~= 1 or not M.valid(provider, id) then
    error("Expected one line in " .. path .. " in provider:session-id format", 0)
  end
  return { provider = provider, id = id }
end

function M.lock(root)
  local result = git(root, "rev-parse", "--path-format=absolute", "--git-path", "slimchat.lock")
  if result.code ~= 0 then
    error(vim.trim(result.stderr), 0)
  end
  local path = vim.trim(result.stdout)
  local ok, err = uv.fs_mkdir(path, 448)
  if not ok then
    error("Could not lock this project's chat (" .. path .. "): " .. err, 0)
  end
  return function()
    uv.fs_rmdir(path)
  end
end

local function ignore(root)
  local tracked = git(root, "ls-files", "--error-unmatch", "--", filename)
  if tracked.code == 0 then
    error(filename .. " is already tracked by Git", 0)
  end
  local ignored = git(root, "check-ignore", "-q", "--", filename)
  if ignored.code == 0 then
    return
  end
  local result = git(root, "rev-parse", "--path-format=absolute", "--git-path", "info/exclude")
  if result.code ~= 0 then
    error(vim.trim(result.stderr), 0)
  end
  local path = vim.trim(result.stdout)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "a"))
  local written, err = file:write("\n/" .. filename .. "\n")
  local closed, close_err = file:close()
  assert(written, err)
  assert(closed, close_err)
  if git(root, "check-ignore", "-q", "--", filename).code ~= 0 then
    error("Git did not ignore " .. filename .. ". Check this project's ignore rules.", 0)
  end
end

function M.prepare(root)
  ignore(root)
  return M.read(root)
end

function M.write(root, provider, id)
  assert(M.valid(provider, id), "Invalid provider session ID")
  local path = vim.fs.joinpath(root, filename)
  local fd, err = uv.fs_open(path, "wx", 384)
  assert(fd, err)
  local line = provider .. ":" .. id .. "\n"
  local bytes, write_err = uv.fs_write(fd, line, 0)
  local closed, close_err = uv.fs_close(fd)
  if bytes ~= #line or not closed then
    uv.fs_unlink(path)
    error(write_err or close_err or "Incomplete project pointer write", 0)
  end
end

return M
