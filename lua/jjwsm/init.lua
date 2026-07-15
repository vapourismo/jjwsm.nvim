local M = {}

local uv = vim.uv or vim.loop
local TITLE = "jjwsm.nvim"
local MIN_JJ_MINOR = 40
local WORKSPACE_TEMPLATE = [[self.name().escape_json() ++ "\0" ++ self.root().escape_json() ++ "\0"]]

local function notify(message, level)
  vim.notify(message, level, { title = TITLE })
end

local function error_message(message)
  notify(message, vim.log.levels.ERROR)
end

local function warning(message)
  notify(message, vim.log.levels.WARN)
end

local function trim(value)
  return vim.trim(value or "")
end

local function result_message(result)
  local message = trim(result and result.stderr)
  if message == "" then
    message = trim(result and result.stdout)
  end
  if message == "" then
    message = ("jj exited with status %s"):format(result and result.code or "unknown")
  end
  return message
end

local function run_process(args, opts, callback)
  local ok, spawn_error = pcall(vim.system, args, {
    cwd = opts.cwd,
    text = true,
  }, function(result)
    vim.schedule(function()
      callback(result)
    end)
  end)

  if not ok then
    vim.schedule(function()
      callback(nil, tostring(spawn_error))
    end)
  end
end

local function jj_args(args)
  local command = { "jj", "--no-pager", "--color=never" }
  vim.list_extend(command, args)
  return command
end

local function run_jj(cwd, args, callback)
  run_process(jj_args(args), { cwd = cwd }, callback)
end

local function check_dependencies(cwd, callback)
  if vim.fn.has("nvim-0.10") ~= 1 or type(vim.system) ~= "function" then
    error_message("Neovim 0.10 or newer is required")
    return
  end

  run_process({ "jj", "--version" }, { cwd = cwd }, function(result, spawn_error)
    if spawn_error then
      error_message("Jujutsu (jj) is required: " .. spawn_error)
      return
    end
    if not result or result.code ~= 0 then
      error_message("Jujutsu (jj) is required: " .. result_message(result))
      return
    end

    local major, minor = (result.stdout or ""):match("jj%s+(%d+)%.(%d+)")
    major, minor = tonumber(major), tonumber(minor)
    if not major then
      error_message("Could not determine the Jujutsu version from: " .. trim(result.stdout))
      return
    end
    if major == 0 and minor < MIN_JJ_MINOR then
      error_message(("Jujutsu 0.%d or newer is required (found %d.%d)"):format(MIN_JJ_MINOR, major, minor))
      return
    end

    callback()
  end)
end

local function parse_workspaces(output)
  local fields = {}
  local start = 1

  while true do
    local boundary = output:find("\0", start, true)
    if not boundary then
      break
    end
    fields[#fields + 1] = output:sub(start, boundary - 1)
    start = boundary + 1
  end

  if start <= #output then
    return nil, "workspace output ended without a NUL delimiter"
  end
  if #fields % 2 ~= 0 then
    return nil, "workspace output contained an incomplete record"
  end

  local workspaces = {}
  for index = 1, #fields, 2 do
    local name_ok, name = pcall(vim.json.decode, fields[index])
    local root_ok, root = pcall(vim.json.decode, fields[index + 1])
    if not name_ok or type(name) ~= "string" then
      return nil, ("workspace output contained invalid JSON in record %d"):format((index + 1) / 2)
    end
    if root_ok and type(root) == "string" then
      workspaces[#workspaces + 1] = { name = name, root = root }
    elseif fields[index + 1]:match("^<Error: Failed to resolve workspace root:") then
      -- Jujutsu renders template evaluation failures as an error fragment even
      -- inside escape_json(). Keep it framed by NUL and classify it explicitly.
      local prefix = "<Error: Failed to resolve workspace root: " .. name .. ": "
      local body = fields[index + 1]:sub(1, -2)
      if body:sub(1, #prefix) == prefix then
        body = body:sub(#prefix + 1)
      end
      local unresolved_root = body:match("^(.*): .- %(os error %d+%)$")
      workspaces[#workspaces + 1] = {
        name = name,
        root = unresolved_root,
        root_error = fields[index + 1],
      }
    else
      return nil, ("workspace output contained invalid JSON in record %d"):format((index + 1) / 2)
    end
  end

  return workspaces
end

local function list_workspaces(cwd, callback)
  run_jj(cwd, { "workspace", "list", "--template", WORKSPACE_TEMPLATE }, function(result, spawn_error)
    if spawn_error then
      callback(nil, "Could not run jj: " .. spawn_error)
      return
    end
    if not result or result.code ~= 0 then
      callback(nil, "Jujutsu could not list workspaces: " .. result_message(result))
      return
    end

    local workspaces, parse_error = parse_workspaces(result.stdout or "")
    if not workspaces then
      callback(nil, "Could not parse Jujutsu workspace output: " .. parse_error)
      return
    end
    callback(workspaces)
  end)
end

local function missing_error(err, code)
  code = tostring(code or "")
  err = tostring(err or "")
  return code == "ENOENT"
    or code == "ENOTDIR"
    or err:match("^ENOENT") ~= nil
    or err:match("^ENOTDIR") ~= nil
end

local function classify_directory(path)
  local stat, err, code = uv.fs_stat(path)
  if stat then
    if stat.type == "directory" then
      return "directory"
    end
    return "stale", ("path is a %s, not a directory"):format(stat.type or "non-directory")
  end
  if missing_error(err, code) then
    return "stale", err or code or "path does not exist"
  end
  return "unknown", err or code or "unknown filesystem error"
end

local function classify_workspace(workspace)
  if not workspace.root_error then
    return classify_directory(workspace.root)
  end

  local message = workspace.root_error:lower()
  if message:find("no such file or directory", 1, true)
    or message:find("not a directory", 1, true)
    or message:find("the system cannot find the path", 1, true)
    or message:find("os error 2", 1, true)
    or message:find("os error 3", 1, true)
    or message:find("os error 20", 1, true)
  then
    return "stale", workspace.root_error
  end
  return "unknown", workspace.root_error
end

local function clean_workspaces(cwd, workspaces, callback)
  local stale_names = {}
  local retained = {}

  for _, workspace in ipairs(workspaces) do
    local state, detail = classify_workspace(workspace)
    if state == "stale" then
      stale_names[#stale_names + 1] = workspace.name
    else
      retained[#retained + 1] = workspace
      if state == "unknown" then
        warning(
          ("Could not inspect workspace %q at %s; retaining its record: %s"):format(
            workspace.name,
            workspace.root or "(unresolved root)",
            detail
          )
        )
      end
    end
  end

  if #stale_names == 0 then
    callback(retained)
    return
  end

  local args = { "workspace", "forget", "--" }
  vim.list_extend(args, stale_names)
  run_jj(cwd, args, function(result, spawn_error)
    if spawn_error then
      callback(nil, "Could not run jj while forgetting stale workspaces: " .. spawn_error)
      return
    end
    if not result or result.code ~= 0 then
      callback(nil, "Jujutsu could not forget stale workspaces: " .. result_message(result))
      return
    end
    callback(retained)
  end)
end

local function prepare(cwd, callback)
  list_workspaces(cwd, function(workspaces, list_error)
    if not workspaces then
      error_message(list_error)
      return
    end
    clean_workspaces(cwd, workspaces, function(retained, clean_error)
      if not retained then
        error_message(clean_error)
        return
      end
      callback(retained)
    end)
  end)
end

local function normalize(path)
  local normalized = vim.fs.normalize(path)
  if #normalized > 1 and not normalized:match("^%a:[/\\]$") then
    normalized = normalized:gsub("[/\\]+$", "")
  end
  return normalized
end

local function contains_path(root, path)
  root, path = normalize(root), normalize(path)
  if root == path then
    return true
  end
  local separator = root:find("\\", 1, true) and "\\" or "/"
  local prefix = root
  if root:sub(-1) ~= "/" and root:sub(-1) ~= "\\" then
    prefix = root .. separator
  end
  return path:sub(1, #prefix) == prefix
end

local function workspace_contains(workspace, cwd)
  if not workspace.root then
    return false
  end
  if contains_path(workspace.root, cwd) then
    return true
  end

  local root_ok, real_root = pcall(uv.fs_realpath, workspace.root)
  local cwd_ok, real_cwd = pcall(uv.fs_realpath, cwd)
  return root_ok and cwd_ok and real_root and real_cwd and contains_path(real_root, real_cwd) or false
end

local function tabpage_cwd(tabpage)
  local tabnr = vim.api.nvim_tabpage_get_number(tabpage)
  return vim.fn.getcwd(-1, tabnr)
end

local function set_tabpage_cwd(tabpage, root)
  if not vim.api.nvim_tabpage_is_valid(tabpage) then
    return false, "the invoking tabpage no longer exists"
  end

  local windows = vim.api.nvim_tabpage_list_wins(tabpage)
  if #windows == 0 or not vim.api.nvim_win_is_valid(windows[1]) then
    return false, "the tabpage has no valid window"
  end

  local ok, command_error = pcall(vim.api.nvim_win_call, windows[1], function()
    vim.api.nvim_cmd({ cmd = "tcd", args = { root } }, {})
  end)
  if not ok then
    return false, tostring(command_error)
  end
  return true
end

local function default_workspace_basename(workspaces)
  local default_workspace
  for _, workspace in ipairs(workspaces) do
    if workspace.name == "default" then
      default_workspace = workspace
      break
    end
  end

  if not default_workspace or type(default_workspace.root) ~= "string" or default_workspace.root == "" then
    return nil, "Could not determine the default workspace root"
  end

  local basename = vim.fs.basename(default_workspace.root)
  if type(basename) ~= "string" or basename == "" then
    return nil, "Could not determine a non-empty basename for the default workspace root"
  end
  return basename
end

local function rename_tabpage(tabpage, basename, workspace_name, basename_error)
  local failure_prefix = "Workspace activated, but its tab could not be named: "
  local reset_name = workspace_name == "default"
  if not reset_name and not basename then
    warning(failure_prefix .. basename_error)
    return
  end
  if vim.fn.exists(":Tabby") ~= 2 then
    warning(failure_prefix .. "the :Tabby command is unavailable")
    return
  end
  if not vim.api.nvim_tabpage_is_valid(tabpage) then
    warning(failure_prefix .. "the activated tabpage no longer exists")
    return
  end

  local windows = vim.api.nvim_tabpage_list_wins(tabpage)
  if #windows == 0 or not vim.api.nvim_win_is_valid(windows[1]) then
    warning(failure_prefix .. "the activated tabpage has no valid window")
    return
  end

  local args = { "rename_tab" }
  if not reset_name then
    args[#args + 1] = basename .. "[" .. workspace_name .. "]"
  end
  local renamed, rename_error = pcall(vim.api.nvim_win_call, windows[1], function()
    vim.api.nvim_cmd({ cmd = "Tabby", args = args }, {})
  end)
  if not renamed then
    warning(failure_prefix .. tostring(rename_error))
  end
end

local function forget_disappeared(context, workspace)
  run_jj(context.cwd, { "workspace", "forget", "--", workspace.name }, function(result, spawn_error)
    if spawn_error then
      error_message(
        ("Workspace %q disappeared, but its record could not be forgotten: %s. No switch occurred."):format(
          workspace.name,
          spawn_error
        )
      )
      return
    end
    if not result or result.code ~= 0 then
      error_message(
        ("Workspace %q disappeared, but its record could not be forgotten: %s. No switch occurred."):format(
          workspace.name,
          result_message(result)
        )
      )
      return
    end
    warning(("Workspace %q disappeared and was forgotten. No switch occurred."):format(workspace.name))
  end)
end

local function confirm_switch(context, workspace, basename, basename_error)
  local state, detail = classify_workspace(workspace)
  if state == "stale" then
    forget_disappeared(context, workspace)
    return
  end
  if state == "unknown" then
    warning(
      ("Could not revalidate workspace %q at %s: %s. No switch occurred."):format(
        workspace.name,
        workspace.root,
        detail
      )
    )
    return
  end

  local changed, change_error = set_tabpage_cwd(context.tabpage, workspace.root)
  if not changed then
    error_message("Could not switch workspace: " .. change_error)
    return
  end
  rename_tabpage(context.tabpage, basename, workspace.name, basename_error)
end

local function open_picker(context, workspaces, basename, basename_error)
  local items = {}
  for _, workspace in ipairs(workspaces) do
    if not workspace_contains(workspace, context.cwd) then
      local root = workspace.root or "(unresolved root)"
      items[#items + 1] = {
        text = workspace.name .. " " .. root,
        name = workspace.name,
        root = root,
        root_error = workspace.root_error,
      }
    end
  end

  local snacks_ok, snacks = pcall(require, "snacks")
  if not snacks_ok then
    snacks = rawget(_G, "Snacks")
  end
  if type(snacks) ~= "table" or type(snacks.picker) ~= "table" or type(snacks.picker.pick) ~= "function" then
    error_message("Snacks picker is required for :Jjwsm switch")
    return
  end

  if #items == 0 then
    notify("No other workspaces are available", vim.log.levels.INFO)
    return
  end

  local picker_ok, picker_error = pcall(snacks.picker.pick, {
    title = "Jujutsu workspaces",
    items = items,
    auto_confirm = false,
    format = function(item)
      return {
        { item.name, "Identifier" },
        { "  " },
        { item.root, "Comment" },
      }
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        confirm_switch(context, item, basename, basename_error)
      end
    end,
  })
  if not picker_ok then
    error_message("Could not open the Snacks picker: " .. tostring(picker_error))
  end
end

local function switch_workspace(context)
  prepare(context.cwd, function(workspaces)
    local basename, basename_error = default_workspace_basename(workspaces)
    open_picker(context, workspaces, basename, basename_error)
  end)
end

local function path_join(...)
  if vim.fs.joinpath then
    return vim.fs.joinpath(...)
  end
  return table.concat({ ... }, "/"):gsub("/+", "/")
end

local function lstat_path(path)
  local stat, err, code = uv.fs_lstat(path)
  if stat then
    return "exists", stat
  end
  if missing_error(err, code) then
    return "missing"
  end
  return "unknown", err or code or "unknown filesystem error"
end

local function ensure_workspace_parent()
  local temp_root = uv.os_tmpdir()
  if not temp_root or temp_root == "" then
    return nil, "Could not determine the operating system temporary directory"
  end

  local parent = path_join(temp_root, "jjwsm.nvim")
  local state, detail = lstat_path(parent)
  if state == "exists" then
    if detail.type ~= "directory" then
      return nil, ("Temporary workspace parent %s is not a real directory"):format(parent)
    end
    return parent
  end
  if state == "unknown" then
    return nil, ("Could not inspect temporary workspace parent %s: %s"):format(parent, detail)
  end

  local created, mkdir_error, mkdir_code = uv.fs_mkdir(parent, 448)
  if created then
    return parent
  end

  -- A second process may have created the shared parent after the lstat.
  if tostring(mkdir_code or "") == "EEXIST" or tostring(mkdir_error or ""):match("^EEXIST") then
    local raced_state, raced_detail = lstat_path(parent)
    if raced_state == "exists" and raced_detail.type == "directory" then
      return parent
    end
  end
  return nil, ("Could not create temporary workspace parent %s: %s"):format(
    parent,
    mkdir_error or mkdir_code or "unknown filesystem error"
  )
end

local function registered_names(workspaces)
  local names = {}
  for _, workspace in ipairs(workspaces) do
    names[workspace.name] = true
  end
  return names
end

local function workspace_prefix(workspaces)
  local basename, basename_error = default_workspace_basename(workspaces)
  if not basename then
    return nil, basename_error
  end
  return "jjwsm-" .. basename .. "-"
end

local function allocate_candidate(parent, prefix, first_counter)
  local counter = math.max(1, first_counter or 1)

  while true do
    local root = path_join(parent, prefix .. counter)
    local state, detail = lstat_path(root)
    if state == "unknown" then
      return nil, ("Could not inspect workspace candidate %s: %s"):format(root, detail)
    end
    if state == "missing" then
      return { root = root, counter = counter }
    end
    counter = counter + 1
  end
end

local function collision_failure(result)
  local message = (result_message(result)):lower()
  return message:find("already exists", 1, true) ~= nil
    or message:find("file exists", 1, true) ~= nil
    or message:find("os error 17", 1, true) ~= nil
    or message:find("already tracked", 1, true) ~= nil
end

local function open_new_workspace(root, basename, workspace_name)
  local opened, open_error = pcall(vim.api.nvim_cmd, { cmd = "tabnew" }, {})
  if not opened then
    error_message("Workspace was created, but a new tabpage could not be opened: " .. tostring(open_error))
    return
  end

  local tabpage = vim.api.nvim_get_current_tabpage()
  local changed, change_error = set_tabpage_cwd(tabpage, root)
  if not changed then
    if vim.api.nvim_tabpage_is_valid(tabpage) and #vim.api.nvim_list_tabpages() > 1 then
      pcall(vim.api.nvim_set_current_tabpage, tabpage)
      pcall(vim.api.nvim_cmd, { cmd = "tabclose", bang = true }, {})
    end
    error_message("Workspace was created, but its tabpage cwd could not be set: " .. change_error)
    return
  end
  rename_tabpage(tabpage, basename, workspace_name)
end

local function attempt_new_workspace(context, parent, prefix, basename, workspace_name, first_counter)
  local candidate, allocation_error = allocate_candidate(parent, prefix, first_counter)
  if not candidate then
    error_message(allocation_error)
    return
  end

  run_jj(context.cwd, { "workspace", "add", "--name", workspace_name, candidate.root }, function(result, spawn_error)
    if spawn_error then
      error_message("Could not run jj while creating a workspace: " .. spawn_error)
      return
    end
    if not result or result.code ~= 0 then
      if result and collision_failure(result) then
        list_workspaces(context.cwd, function(updated, list_error)
          if not updated then
            error_message(
              ("Jujutsu reported a workspace collision, but workspaces could not be rescanned: %s"):format(list_error)
            )
            return
          end
          if registered_names(updated)[workspace_name] then
            error_message(("Workspace %q is already registered in this repository"):format(workspace_name))
            return
          end
          attempt_new_workspace(context, parent, prefix, basename, workspace_name, candidate.counter + 1)
        end)
      else
        error_message("Jujutsu could not create workspace: " .. result_message(result))
      end
      return
    end

    local state, detail = classify_directory(candidate.root)
    if state ~= "directory" then
      error_message(
        ("Jujutsu reported success, but workspace %s is not an accessible directory: %s"):format(
          candidate.root,
          detail or state
        )
      )
      return
    end
    open_new_workspace(candidate.root, basename, workspace_name)
  end)
end

local function new_workspace(context)
  prepare(context.cwd, function(workspaces)
    local basename, basename_error = default_workspace_basename(workspaces)
    if not basename then
      error_message(basename_error)
      return
    end
    local prefix = "jjwsm-" .. basename .. "-"

    local prompted, prompt_error = pcall(vim.ui.input, { prompt = "Workspace name: " }, function(workspace_name)
      if workspace_name == nil then
        notify("Workspace creation cancelled", vim.log.levels.INFO)
        return
      end
      if trim(workspace_name) == "" then
        error_message("Workspace name cannot be blank")
        return
      end
      if registered_names(workspaces)[workspace_name] then
        error_message(("Workspace %q is already registered in this repository"):format(workspace_name))
        return
      end

      local parent, parent_error = ensure_workspace_parent()
      if not parent then
        error_message(parent_error)
        return
      end
      attempt_new_workspace(context, parent, prefix, basename, workspace_name, 1)
    end)
    if not prompted then
      error_message("Could not prompt for a workspace name: " .. tostring(prompt_error))
    end
  end)
end

local commands = {
  switch = switch_workspace,
  new = new_workspace,
}

function M._dispatch(args)
  if #args ~= 1 or not commands[args[1]] then
    error_message("Usage: :Jjwsm {switch|new}")
    return
  end

  local tabpage = vim.api.nvim_get_current_tabpage()
  local cwd_ok, cwd = pcall(tabpage_cwd, tabpage)
  if not cwd_ok or cwd == "" then
    error_message("Could not determine the invoking tabpage's working directory")
    return
  end

  local context = { tabpage = tabpage, cwd = cwd }
  check_dependencies(cwd, function()
    commands[args[1]](context)
  end)
end

function M._complete(arglead, cmdline, cursorpos)
  local before_cursor = cmdline:sub(1, cursorpos)
  local arguments = before_cursor:match("^%s*Jjwsm%s+(.*)$")
  if arguments == nil or not arguments:match("^%S*$") then
    return {}
  end

  local matches = {}
  for _, command in ipairs({ "switch", "new" }) do
    if command:sub(1, #arglead) == arglead then
      matches[#matches + 1] = command
    end
  end
  return matches
end

M._test = {
  allocate_candidate = allocate_candidate,
  classify_directory = classify_directory,
  default_workspace_basename = default_workspace_basename,
  parse_workspaces = parse_workspaces,
  workspace_prefix = workspace_prefix,
  workspace_template = WORKSPACE_TEMPLATE,
}

return M
