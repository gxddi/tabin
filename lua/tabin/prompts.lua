local M = {}
local uv = vim.uv
local template_dir = vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "prompts")

function M.seed(dir)
  vim.fn.mkdir(dir, "p")
  for _, kind in ipairs({ "complete", "review" }) do
    local name = kind .. ".md"
    local path = vim.fs.joinpath(dir, name)
    if not uv.fs_lstat(path) then
      local text = table.concat(vim.fn.readfile(vim.fs.joinpath(template_dir, name)), "\n") .. "\n"
      local fd, err, code = uv.fs_open(path, "wx", 384)
      if fd then
        local bytes, write_err = uv.fs_write(fd, text, 0)
        local closed, close_err = uv.fs_close(fd)
        if bytes ~= #text or not closed then
          uv.fs_unlink(path)
          error(write_err or close_err or ("Incomplete prompt write: " .. path), 0)
        end
      elseif code ~= "EEXIST" then
        error(err, 0)
      end
    end
  end
end

function M.read(dir, kind)
  local path = vim.fs.joinpath(dir, kind .. ".md")
  local text = table.concat(vim.fn.readfile(path), "\n")
  if vim.trim(text) == "" then
    error("Prompt is empty: " .. path, 0)
  end
  return text
end

return M
