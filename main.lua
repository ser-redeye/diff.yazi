--- @since 26.1.22

local M = {}

local DEFAULT_TEMPLATE = { "git", "diff", "--no-index", "--", "{left}", "{right}" }

--- Write a structured diagnostic event to Yazi's log.
---@param event string
---@param fields table|nil
local function log_debug(event, fields)
  fields = fields or {}
  fields.plugin = "diff"
  fields.event = event
  ya.dbg(fields)
end

--- Write a structured error event to Yazi's log.
---@param event string
---@param fields table|nil
local function log_error(event, fields)
  fields = fields or {}
  fields.plugin = "diff"
  fields.event = event
  ya.err(fields)
end

--- Show an actionable notification to the user.
---@param level string
---@param message string
local function notify(level, message)
  ya.notify({ title = "diff", content = message, timeout = 5, level = level })
end

--- Report a failure once to both developers and users.
---@param event string
---@param message string
---@param fields table|nil
local function fail(event, message, fields)
  log_error(event, fields)
  notify("error", message)
end

--- Show a warning for an expected user-correction state.
---@param message string
local function notify_warn(message)
  notify("warn", message)
end

-- ============================================================
--  External-command templates
-- ============================================================

--- Parse a command template into argv without invoking a shell.
---
--- Whitespace separates arguments. Single and double quotes group whitespace,
--- and a backslash escapes the following character. Nothing is expanded: shell
--- operators, variables, globs, and substitutions are all literal text.
---@param template string
---@return string[]|nil argv
---@return string|nil err
local function parse_template(template)
  if type(template) ~= "string" or template == "" then
    return nil, "the command template must be a non-empty string"
  end
  if template:find("\0", 1, true) then
    return nil, "the command template must not contain NUL bytes"
  end

  local argv, current = {}, {}
  local quote, escaped, started = nil, false, false

  local function push()
    if started then
      argv[#argv + 1] = table.concat(current)
      current, started = {}, false
    end
  end

  for i = 1, #template do
    local char = template:sub(i, i)
    if escaped then
      current[#current + 1] = char
      escaped, started = false, true
    elseif char == "\\" then
      escaped, started = true, true
    elseif quote then
      if char == quote then
        quote = nil
      else
        current[#current + 1] = char
      end
    elseif char == "'" or char == '"' then
      quote, started = char, true
    elseif char:match("%s") then
      push()
    else
      current[#current + 1], started = char, true
    end
  end

  if escaped then
    return nil, "the command template ends with an unfinished escape"
  end
  if quote then
    return nil, "the command template has an unclosed quote"
  end
  push()

  if #argv == 0 or argv[1] == "" then
    return nil, "the command template must start with an executable"
  end

  local left_count, right_count = 0, 0
  for _, arg in ipairs(argv) do
    if arg == "{left}" then
      left_count = left_count + 1
    elseif arg == "{right}" then
      right_count = right_count + 1
    elseif arg:find("{left}", 1, true) or arg:find("{right}", 1, true) then
      return nil, "{left} and {right} must each be standalone arguments"
    end
  end

  if left_count ~= 1 or right_count ~= 1 then
    return nil, "the command template must contain exactly one {left} and one {right}"
  end

  return argv, nil
end

--- Substitute paths into a parsed template as separate argv entries.
---@param template string[]
---@param left string
---@param right string
---@return string cmd
---@return string[] args
local function expand_template(template, left, right)
  local args = {}
  for i = 2, #template do
    local arg = template[i]
    if arg == "{left}" then
      args[#args + 1] = left
    elseif arg == "{right}" then
      args[#args + 1] = right
    else
      args[#args + 1] = arg
    end
  end
  return template[1], args
end

-- ============================================================
--  Setup
-- ============================================================

--- Configure an optional external command template.
---
--- @param state table
--- @param opts table|nil
function M.setup(state, opts)
  opts = opts or {}
  state.command_template = nil
  state.command_error = nil

  if type(opts) ~= "table" then
    state.command_error = "setup options must be a table"
    log_error("invalid_setup_options", { actual_type = type(opts) })
    return
  end

  if opts.command == nil then
    return
  end

  local template, err = parse_template(opts.command)
  if not template then
    state.command_error = "invalid command: " .. err
    log_error("invalid_configured_command", { reason = err })
    return
  end

  state.command_template = template
  log_debug("configured_template", { template = state.command_template })
end

-- ============================================================
--  Sync helpers
-- ============================================================
-- All ya.sync() blocks must be defined at file top-level.

--- Returns the number of currently selected entries.
local get_selected_count = ya.sync(function()
  return #cx.active.selected
end)

--- Returns the Url of the first selected entry, or nil if none selected.
local get_selected_path = ya.sync(function()
  for _, url in pairs(cx.active.selected) do
    return url
  end
  return nil
end)

--- Returns the Url of the currently hovered entry, or nil if nothing is hovered.
local get_hovered_path = ya.sync(function()
  local hovered = cx.active.current.hovered
  return hovered and hovered.url or nil
end)

--- Returns the configured command template from the persistent state.
local get_command_config = ya.sync(function(state)
  return state.command_template, state.command_error
end)

-- ============================================================
--  Command execution
-- ============================================================

--- Hide Yazi, run `cmd args` with full terminal I/O, then restore Yazi.
--- Notifies on spawn failure (e.g. binary not found in PATH).
---@param cmd string Executable name
---@param args string[] Arguments to pass
local function run_in_terminal(cmd, args)
  local permit = ui.hide()

  log_debug("run_command", { cmd = cmd, args = args })
  local _, spawn_err =
    Command(cmd):arg(args):stdin(Command.INHERIT):stdout(Command.INHERIT):stderr(Command.INHERIT):status()

  -- Restore Yazi unconditionally — must not be skipped on any code path.
  permit:drop()

  if spawn_err then
    local message = "Failed to launch " .. cmd .. ": " .. tostring(spawn_err)
    fail("spawn_failed", message, { executable = cmd, error = tostring(spawn_err) })
  end
end

--- Run a parsed command template.
---@param template string[]
---@param left string
---@param right string
local function show_diff(template, left, right)
  local cmd, args = expand_template(template, left, right)
  run_in_terminal(cmd, args)
end

-- ============================================================
--  Entry point
-- ============================================================

--- Resolve the template to use using invocation, setup, then built-in-default precedence.
---@param args string[]
---@return string[]|nil template
---@return boolean valid
---@return string|nil source
local function resolve_request(args)
  if #args > 0 then
    if #args ~= 1 then
      fail("invalid_invocation", "Pass one quoted command template as the plugin argument", { argument_count = #args })
      return nil, false, nil
    end

    local template, err = parse_template(args[1])
    if not template then
      fail("invalid_invocation_template", "Invalid command template: " .. err, { reason = err })
      return nil, false, nil
    end
    return template, true, "argument"
  end

  local template, err = get_command_config()
  if err then
    notify("error", "Diff setup error: " .. err)
    return nil, false, nil
  end
  return template or DEFAULT_TEMPLATE, true, template and "setup" or "default"
end

--- Main entry point. Diffs the single selected entry against the hovered entry.
---@param job table Plugin job passed by Yazi
function M.entry(_, job)
  job = job or { args = {} }
  local args = job.args or {}

  -- Validate selection.
  local count = get_selected_count()
  if count == 0 then
    return notify_warn("Select exactly one entry to diff against the hovered entry")
  elseif count > 1 then
    return notify_warn("Select exactly one entry for diff (currently " .. count .. " selected)")
  end

  local selected = get_selected_path()
  local hovered = get_hovered_path()
  if not selected then
    return notify_warn("No selected entry found")
  end
  if not hovered then
    return notify_warn("No entry is hovered")
  end

  local template, valid, source = resolve_request(args)
  if not valid then
    return
  end

  local left, right = tostring(selected), tostring(hovered)
  log_debug("command_resolved", { command_source = source, command = template[1] })
  show_diff(template, left, right)
  if left == right then
    notify_warn("Trying to diff between the same entries")
  end
end

return M
