local M = {}
local api = vim.api
local anchors = api.nvim_create_namespace("slimchat-anchors")
local display = api.nvim_create_namespace("slimchat-ghost")
local suggestions = {}

M.schema = {
  type = "object",
  additionalProperties = false,
  required = { "edits" },
  properties = {
    edits = {
      type = "array",
      items = {
        type = "object",
        additionalProperties = false,
        required = { "start_line", "end_line", "text" },
        properties = { start_line = { type = "integer" }, end_line = { type = "integer" }, text = { type = "string" } },
      },
    },
  },
}

function M.context(buf, radius)
  local cursor = api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local first = math.max(1, row - radius)
  local last = math.min(api.nvim_buf_line_count(buf), row + radius)
  local lines = api.nvim_buf_get_lines(buf, first - 1, last, false)
  local size = 0
  for _, line in ipairs(lines) do
    size = size + #line + 1
  end
  while size > 24000 and first < last do
    if row - first > last - row then
      size = size - #table.remove(lines, 1) - 1
      first = first + 1
    else
      size = size - #table.remove(lines) - 1
      last = last - 1
    end
  end
  if size > 24000 then
    error("The cursor line is too large for inline completion", 0)
  end
  return {
    first_line = first, lines = lines, filetype = vim.bo[buf].filetype,
    cursor_line = row, cursor_byte_column = cursor[2],
  }
end

function M.clear(buf)
  suggestions[buf] = nil
  api.nvim_buf_clear_namespace(buf, anchors, 0, -1)
  api.nvim_buf_clear_namespace(buf, display, 0, -1)
end

function M.forget(buf)
  suggestions[buf] = nil
end

local function continuation(byte)
  return byte and byte >= 128 and byte < 192
end

local function narrow(before, after)
  local prefix, suffix = 0, 0
  local size = math.min(#before, #after)
  while prefix < size and before:byte(prefix + 1) == after:byte(prefix + 1) do
    prefix = prefix + 1
  end
  while continuation(before:byte(prefix + 1)) or continuation(after:byte(prefix + 1)) do
    prefix = prefix - 1
  end
  while suffix < size - prefix and before:byte(#before - suffix) == after:byte(#after - suffix) do
    suffix = suffix + 1
  end
  while suffix > 0 and (continuation(before:byte(#before - suffix + 1))
      or continuation(after:byte(#after - suffix + 1))) do
    suffix = suffix - 1
  end
  return prefix, suffix
end

local function advance(row, col, text)
  local lines = vim.split(text, "\n", { plain = true })
  if #lines == 1 then
    return row, col + #text
  end
  return row + #lines - 1, #lines[#lines]
end

local function tracked(buf, edit)
  local mark = api.nvim_buf_get_extmark_by_id(buf, anchors, edit.id, { details = true })
  if #mark == 0 or mark[3].invalid then
    return
  end
  local row, col, details = unpack(mark)
  local end_row, end_col = details.end_row, details.end_col
  local ok, pieces = pcall(api.nvim_buf_get_text, buf, row, col, end_row, end_col, {})
  if not ok then
    return
  end
  local current = table.concat(pieces, "\n")
  local typed, old = "", edit.before
  if current ~= old then
    if #old > 0 and #current >= #old and vim.endswith(current, old) then
      typed = current:sub(1, #current - #old)
    else
      typed, old = current, ""
    end
    if not vim.startswith(edit.after, typed) then
      return
    end
  end
  local remaining = edit.after:sub(#typed + 1)
  if remaining == "" and old == "" then
    return
  end
  row, col = advance(row, col, typed)
  return { row = row, col = col, end_row = end_row, end_col = end_col, remaining = remaining, old = old }
end

function M.refresh(buf)
  local edits = suggestions[buf]
  if not edits then
    return
  end
  api.nvim_buf_clear_namespace(buf, display, 0, -1)
  for index = #edits, 1, -1 do
    local edit = edits[index]
    local pos = tracked(buf, edit)
    if not pos then
      api.nvim_buf_del_extmark(buf, anchors, edit.id)
      table.remove(edits, index)
    else
      local lines = vim.split(pos.remaining, "\n", { plain = true })
      local virt_lines = {}
      for i = 2, #lines do
        virt_lines[#virt_lines + 1] = { { lines[i], "SlimChatGhost" } }
      end
      api.nvim_buf_set_extmark(buf, display, pos.row, pos.col, {
        virt_text = { { lines[1], "SlimChatGhost" } },
        virt_text_pos = "inline",
        virt_lines = virt_lines,
        end_row = pos.end_row,
        end_col = pos.end_col,
        hl_group = pos.old ~= "" and "SlimChatDelete" or nil,
      })
    end
  end
  if #edits == 0 then
    suggestions[buf] = nil
  end
end

function M.show(buf, context, answer)
  if type(answer) == "string" then
    local payload = vim.trim(answer)
    payload = payload:match("^```[%w]*%s*([%s%S]-)%s*```$") or payload
    local ok, value = pcall(vim.json.decode, payload)
    answer = ok and value or nil
  end
  if type(answer) ~= "table" or type(answer.edits) ~= "table" or not vim.islist(answer.edits) then
    return nil, "Provider did not return completion edits"
  end
  local first = context.first_line
  local last = first + #context.lines - 1
  local ranges = {}
  for _, edit in ipairs(answer.edits) do
    local start = type(edit) == "table" and edit.start_line
    local stop = type(edit) == "table" and edit.end_line
    if type(start) ~= "number" or type(stop) ~= "number"
        or start % 1 ~= 0 or stop % 1 ~= 0 or start < first or stop > last or stop < start
        or type(edit.text) ~= "string" or #edit.text > 24000 or edit.text:find("%z") then
      return nil, "Provider returned an invalid edit range"
    end
    ranges[#ranges + 1] = edit
  end
  table.sort(ranges, function(a, b) return a.start_line < b.start_line end)
  local previous = first - 1
  for _, edit in ipairs(ranges) do
    if edit.start_line <= previous then
      return nil, "Provider returned overlapping edits"
    end
    previous = edit.end_line
  end

  local edits = {}
  suggestions[buf] = edits
  for _, edit in ipairs(ranges) do
    local before = table.concat(context.lines, "\n", edit.start_line - first + 1, edit.end_line - first + 1)
    local after = edit.text
    if before ~= after then
      local prefix, suffix = narrow(before, after)
      local row, col = advance(edit.start_line - 1, 0, before:sub(1, prefix))
      local end_row, end_col = advance(row, col, before:sub(prefix + 1, #before - suffix))
      local id = api.nvim_buf_set_extmark(buf, anchors, row, col, {
        end_row = end_row, end_col = end_col, right_gravity = false, end_right_gravity = true,
        undo_restore = false,
      })
      edits[#edits + 1] = {
        id = id,
        before = before:sub(prefix + 1, #before - suffix),
        after = after:sub(prefix + 1, #after - suffix),
      }
    end
  end
  M.refresh(buf)
  return #edits
end

function M.choose(accept)
  local buf = api.nvim_get_current_buf()
  M.refresh(buf)
  local row, col = unpack(api.nvim_win_get_cursor(0))
  row = row - 1
  local selected, position, distance
  for i, edit in ipairs(suggestions[buf] or {}) do
    local pos = tracked(buf, edit)
    local rows = math.max(pos.row - row, row - pos.end_row, 0)
    local cols = row == pos.row and math.abs(col - pos.col) or 0
    local score = rows == 0 and cols or math.huge
    if rows <= 1 and (not selected or score < distance) then
      selected, position, distance = i, pos, score
    end
  end
  if not selected or (accept and not vim.bo[buf].modifiable) then
    return
  end
  local edit = table.remove(suggestions[buf], selected)
  api.nvim_buf_del_extmark(buf, anchors, edit.id)
  if accept then
    api.nvim_buf_set_text(buf, position.row, position.col, position.end_row, position.end_col,
      vim.split(position.remaining, "\n", { plain = true }))
    if vim.fn.mode():sub(1, 1) == "i" then
      local end_row, end_col = advance(position.row, position.col, position.remaining)
      api.nvim_win_set_cursor(0, { end_row + 1, end_col })
    end
  end
  M.refresh(buf)
end

return M
