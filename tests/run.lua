local uv = vim.uv
local project_root = vim.fn.getcwd()
local original_system = vim.system
local original_notify = vim.notify
local original_input = vim.ui.input
local original_tmpdir = uv.os_tmpdir

local tests = {}
local cleanups = {}
local failures = 0
local skipped = 0

local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

local function cleanup(fn)
  cleanups[#cleanups + 1] = fn
end

local function fail(message)
  error(message, 2)
end

local function assert_true(value, message)
  if not value then
    fail(message or "expected value to be truthy")
  end
end

local function assert_equal(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    fail((message and (message .. ": ") or "") .. "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
  end
end

local function assert_match(pattern, value, message)
  if not tostring(value):match(pattern) then
    fail((message and (message .. ": ") or "") .. ("expected %q to match %q"):format(tostring(value), pattern))
  end
end

local function canonical(path)
  return uv.fs_realpath(path) or vim.fs.normalize(path)
end

local function assert_path_equal(expected, actual, message)
  assert_equal(canonical(expected), canonical(actual), message)
end

local function eventually(predicate, message, timeout)
  if not vim.wait(timeout or 3000, predicate, 10) then
    fail(message or "timed out waiting for asynchronous operation")
  end
end

local function command(name)
  vim.api.nvim_cmd({ cmd = "Jjwsm", args = { name } }, {})
end

local function tab_cwd(tabpage)
  return vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(tabpage))
end

local function set_tab_cwd(tabpage, path)
  local window = vim.api.nvim_tabpage_list_wins(tabpage)[1]
  vim.api.nvim_win_call(window, function()
    vim.api.nvim_cmd({ cmd = "tcd", args = { path } }, {})
  end)
end

local function workspace_output(workspaces)
  local fields = {}
  for _, workspace in ipairs(workspaces) do
    fields[#fields + 1] = vim.json.encode(workspace.name)
    fields[#fields + 1] = "\0"
    fields[#fields + 1] = vim.json.encode(workspace.root)
    fields[#fields + 1] = "\0"
  end
  return table.concat(fields)
end

local function result(code, stdout, stderr)
  return { code = code or 0, signal = 0, stdout = stdout or "", stderr = stderr or "" }
end

local function mock_system(handler)
  local calls = {}
  vim.system = function(args, opts, callback)
    calls[#calls + 1] = { args = vim.deepcopy(args), opts = vim.deepcopy(opts) }
    local response = handler(args, opts, #calls)
    if callback then
      callback(response)
    end
    return {
      wait = function()
        return response
      end,
    }
  end
  cleanup(function()
    vim.system = original_system
  end)
  return calls
end

local function standard_mock(workspaces, extra)
  return mock_system(function(args, opts, call_index)
    if args[2] == "--version" then
      return result(0, "jj 0.43.0\n")
    end
    if args[4] == "workspace" and args[5] == "list" then
      return result(0, workspace_output(type(workspaces) == "function" and workspaces() or workspaces))
    end
    if extra then
      local response = extra(args, opts, call_index)
      if response then
        return response
      end
    end
    return result(0)
  end)
end

local function deferred_standard_mock(workspaces, extra)
  local pending_list
  local calls = mock_system(function(args, opts, call_index)
    if args[2] == "--version" then
      return result(0, "jj 0.43.0\n")
    end
    if args[4] == "workspace" and args[5] == "list" then
      return result(0, workspace_output(type(workspaces) == "function" and workspaces() or workspaces))
    end
    if extra then
      local response = extra(args, opts, call_index)
      if response then
        return response
      end
    end
    return result(0)
  end)

  local system = vim.system
  vim.system = function(args, opts, callback)
    if args[4] == "workspace" and args[5] == "list" then
      local response = result(0, workspace_output(type(workspaces) == "function" and workspaces() or workspaces))
      calls[#calls + 1] = { args = vim.deepcopy(args), opts = vim.deepcopy(opts) }
      pending_list = { callback = callback, response = response }
      return {
        wait = function()
          return response
        end,
      }
    end
    return system(args, opts, callback)
  end

  return calls, function()
    assert_true(pending_list, "workspace list was not pending")
    local pending = pending_list
    pending_list = nil
    pending.callback(pending.response)
  end, function()
    return pending_list ~= nil
  end
end

local function capture_notifications()
  local notifications = {}
  vim.notify = function(message, level, opts)
    notifications[#notifications + 1] = { message = message, level = level, opts = opts }
  end
  cleanup(function()
    vim.notify = original_notify
  end)
  return notifications
end

local function has_notification(notifications, pattern)
  for _, notification in ipairs(notifications) do
    if notification.message:match(pattern) then
      return true
    end
  end
  return false
end

local function install_input(response)
  local calls = {}
  vim.ui.input = function(opts, on_confirm)
    calls[#calls + 1] = vim.deepcopy(opts)
    on_confirm(response)
  end
  cleanup(function()
    vim.ui.input = original_input
  end)
  return calls
end

local function install_picker()
  local captured
  package.loaded.snacks = {
    picker = {
      pick = function(opts)
        captured = opts
        return {}
      end,
    },
  }
  cleanup(function()
    package.loaded.snacks = nil
    _G.Snacks = nil
  end)
  return function()
    return captured
  end
end

local function install_tabby(callback)
  local calls = {}
  vim.api.nvim_create_user_command("Tabby", function(opts)
    calls[#calls + 1] = {
      args = opts.args,
      fargs = vim.deepcopy(opts.fargs),
      tabpage = vim.api.nvim_get_current_tabpage(),
    }
    if callback then
      callback(opts)
    end
  end, { nargs = "*", force = true })
  cleanup(function()
    pcall(vim.api.nvim_del_user_command, "Tabby")
  end)
  return calls
end

local function temp_dir(label)
  local path = vim.fn.tempname() .. "-" .. label
  assert_true(uv.fs_mkdir(path, 448), "could not create test directory " .. path)
  cleanup(function()
    pcall(uv.fs_chmod, path, 448)
    vim.fn.delete(path, "rf")
  end)
  return path
end

local function mkdir(path)
  local ok, err = uv.fs_mkdir(path, 448)
  assert_true(ok, "could not create directory " .. path .. ": " .. tostring(err))
end

local function with_tmpdir(path)
  uv.os_tmpdir = function()
    return path
  end
  cleanup(function()
    uv.os_tmpdir = original_tmpdir
  end)
end

local function reset_editor()
  vim.system = original_system
  vim.notify = original_notify
  vim.ui.input = original_input
  uv.os_tmpdir = original_tmpdir
  package.loaded.snacks = nil
  _G.Snacks = nil

  local tabs = vim.api.nvim_list_tabpages()
  if #tabs > 0 then
    vim.api.nvim_set_current_tabpage(tabs[1])
  end
  if #tabs > 1 then
    pcall(vim.api.nvim_cmd, { cmd = "tabonly", bang = true }, {})
  end
  vim.api.nvim_cmd({ cmd = "cd", args = { project_root } }, {})
  vim.api.nvim_cmd({ cmd = "tcd", args = { project_root } }, {})
end

local function run_cleanups()
  reset_editor()
  for index = #cleanups, 1, -1 do
    pcall(cleanups[index])
  end
  cleanups = {}
  reset_editor()
end

local function run_sync(args, cwd)
  local response = original_system(args, { cwd = cwd, text = true }):wait()
  assert_equal(0, response.code, table.concat(args, " ") .. " failed: " .. (response.stderr or ""))
  return response
end

local function real_workspace_list(cwd)
  local module = require("jjwsm")
  local response = run_sync({
    "jj",
    "--no-pager",
    "--color=never",
    "workspace",
    "list",
    "--template",
    module._test.workspace_template,
  }, cwd)
  local workspaces, parse_error = module._test.parse_workspaces(response.stdout)
  assert_true(workspaces, parse_error)
  return workspaces
end

test("registers command, completes arguments, and rejects invalid dispatch", function()
  local notifications = capture_notifications()
  local calls = mock_system(function()
    return result(0)
  end)
  local module = require("jjwsm")

  assert_equal(2, vim.fn.exists(":Jjwsm"))
  assert_equal({ "switch", "new", "delete" }, module._complete("", "Jjwsm ", #"Jjwsm "))
  assert_equal({ "switch" }, module._complete("s", "Jjwsm s", #"Jjwsm s"))
  assert_equal({ "delete" }, module._complete("d", "Jjwsm d", #"Jjwsm d"))
  assert_equal({}, module._complete("", "Jjwsm switch ", #"Jjwsm switch "))

  vim.api.nvim_cmd({ cmd = "Jjwsm", args = { "bogus", "extra" } }, {})
  assert_true(has_notification(notifications, "Usage: :Jjwsm {switch|new|delete}"))
  assert_equal(0, #calls, "invalid commands must not start processes")
end)

test("parses NUL-delimited JSON without treating names or roots as commands", function()
  local module = require("jjwsm")
  local expected = {
    { name = "quoted-name", root = "/tmp/a path/with | bars" },
    { name = "unicode-λ", root = "/tmp/line\nfeed" },
  }
  local parsed = assert(module._test.parse_workspaces(workspace_output(expected)))
  assert_equal(expected, parsed)
  local invalid, parse_error = module._test.parse_workspaces('"name"\0"unterminated')
  assert_equal(nil, invalid)
  assert_match("NUL delimiter", parse_error)
  assert_match("escape_json", module._test.workspace_template)
  assert_match("\\0", module._test.workspace_template)
end)

test("reports a cwd outside a Jujutsu repository", function()
  local notifications = capture_notifications()
  mock_system(function(args)
    if args[2] == "--version" then
      return result(0, "jj 0.43.0\n")
    end
    return result(1, "", "Error: No Jujutsu repository here")
  end)

  command("switch")
  eventually(function()
    return has_notification(notifications, "No Jujutsu repository")
  end)
end)

test("deletes the most-specific workspace after closing only the captured tab", function()
  local sandbox = temp_dir("delete")
  local default = vim.fs.joinpath(sandbox, "repo")
  local workspace = vim.fs.joinpath(default, "workspace with spaces | safe")
  local subdir = vim.fs.joinpath(workspace, "nested")
  local stale = vim.fs.joinpath(sandbox, "missing-stale-workspace")
  mkdir(default)
  mkdir(workspace)
  mkdir(subdir)
  local marker = vim.fs.joinpath(workspace, "do-not-delete")
  vim.fn.writefile({ "safe" }, marker)

  local default_tab = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(default_tab, default)
  vim.api.nvim_cmd({ cmd = "tabnew" }, {})
  local shared_workspace_tab = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(shared_workspace_tab, workspace)
  vim.api.nvim_cmd({ cmd = "tabnew" }, {})
  local invocation_tab = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(invocation_tab, subdir)

  local calls = standard_mock({
    { name = "default", root = default },
    { name = "feature | --safe", root = workspace },
    { name = "stale", root = stale },
  })

  command("delete")
  eventually(function()
    return not vim.api.nvim_tabpage_is_valid(invocation_tab)
  end, "captured tabpage was not closed")

  local forget_calls = {}
  for _, call in ipairs(calls) do
    if call.args[5] == "forget" then
      forget_calls[#forget_calls + 1] = call
    end
  end
  assert_equal(1, #forget_calls, "delete must not clean unrelated stale records")
  assert_equal(
    { "jj", "--no-pager", "--color=never", "workspace", "forget", "--", "feature | --safe" },
    forget_calls[1].args
  )
  assert_path_equal(subdir, forget_calls[1].opts.cwd)
  assert_true(vim.api.nvim_tabpage_is_valid(default_tab))
  assert_true(vim.api.nvim_tabpage_is_valid(shared_workspace_tab))
  assert_path_equal(workspace, tab_cwd(shared_workspace_tab))
  assert_equal({ "safe" }, vim.fn.readfile(marker))
  assert_equal(1, vim.fn.isdirectory(workspace))
end)

test("refuses to delete the default workspace", function()
  local sandbox = temp_dir("delete-default")
  local default = vim.fs.joinpath(sandbox, "default")
  local other = vim.fs.joinpath(sandbox, "other")
  mkdir(default)
  mkdir(other)

  local invocation_tab = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(invocation_tab, default)
  vim.api.nvim_cmd({ cmd = "tabnew" }, {})
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), other)
  vim.api.nvim_set_current_tabpage(invocation_tab)

  local notifications = capture_notifications()
  local calls = standard_mock({
    { name = "default", root = default },
    { name = "other", root = other },
  })
  command("delete")
  eventually(function()
    return has_notification(notifications, "default workspace cannot be deleted")
  end)

  assert_true(vim.api.nvim_tabpage_is_valid(invocation_tab))
  for _, call in ipairs(calls) do
    assert_true(call.args[5] ~= "forget", "default workspace must not be forgotten")
  end
end)

test("refuses deletion from the sole tab before starting a process", function()
  local notifications = capture_notifications()
  local calls = mock_system(function()
    return result(0)
  end)

  command("delete")

  assert_true(has_notification(notifications, "only one tabpage exists"))
  assert_equal(0, #calls)
  assert_equal(1, #vim.api.nvim_list_tabpages())
end)

test("leaves the tab and workspace registered when a modified buffer blocks tabclose", function()
  local sandbox = temp_dir("delete-modified")
  local default = vim.fs.joinpath(sandbox, "default")
  local workspace = vim.fs.joinpath(sandbox, "workspace")
  mkdir(default)
  mkdir(workspace)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), default)
  vim.api.nvim_cmd({ cmd = "tabnew" }, {})
  local invocation_tab = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(invocation_tab, workspace)
  vim.api.nvim_cmd({ cmd = "enew" }, {})
  local modified_buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved change" })
  vim.bo.modified = true
  local original_hidden = vim.o.hidden
  vim.o.hidden = false
  cleanup(function()
    vim.o.hidden = original_hidden
  end)
  cleanup(function()
    if vim.api.nvim_buf_is_valid(modified_buffer) then
      vim.api.nvim_buf_delete(modified_buffer, { force = true })
    end
  end)

  local notifications = capture_notifications()
  local calls = standard_mock({
    { name = "default", root = default },
    { name = "feature", root = workspace },
  })
  command("delete")
  eventually(function()
    return has_notification(notifications, "Could not close the invoking tabpage")
  end)

  assert_true(vim.api.nvim_tabpage_is_valid(invocation_tab))
  assert_true(vim.bo.modified)
  for _, call in ipairs(calls) do
    assert_true(call.args[5] ~= "forget", "workspace must remain registered after a refused close")
  end
end)

test("does not forget when the captured tab disappears during workspace listing", function()
  local sandbox = temp_dir("delete-disappeared")
  local default = vim.fs.joinpath(sandbox, "default")
  local workspace = vim.fs.joinpath(sandbox, "workspace")
  mkdir(default)
  mkdir(workspace)
  local default_tab = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(default_tab, default)
  vim.api.nvim_cmd({ cmd = "tabnew" }, {})
  local invocation_tab = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(invocation_tab, workspace)

  local notifications = capture_notifications()
  local calls, release_list, list_pending = deferred_standard_mock({
    { name = "default", root = default },
    { name = "feature", root = workspace },
  })
  command("delete")
  eventually(list_pending, "workspace list did not start")
  vim.api.nvim_cmd({ cmd = "tabclose", bang = true }, {})
  release_list()
  eventually(function()
    return has_notification(notifications, "invoking tabpage no longer exists")
  end)

  assert_true(vim.api.nvim_tabpage_is_valid(default_tab))
  for _, call in ipairs(calls) do
    assert_true(call.args[5] ~= "forget")
  end
end)

test("does not forget when the captured tab changes workspaces during listing", function()
  local sandbox = temp_dir("delete-changed")
  local default = vim.fs.joinpath(sandbox, "default")
  local workspace = vim.fs.joinpath(sandbox, "workspace")
  local other = vim.fs.joinpath(sandbox, "other")
  mkdir(default)
  mkdir(workspace)
  mkdir(other)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), default)
  vim.api.nvim_cmd({ cmd = "tabnew" }, {})
  local invocation_tab = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(invocation_tab, workspace)

  local notifications = capture_notifications()
  local calls, release_list, list_pending = deferred_standard_mock({
    { name = "default", root = default },
    { name = "feature", root = workspace },
    { name = "other", root = other },
  })
  command("delete")
  eventually(list_pending, "workspace list did not start")
  set_tab_cwd(invocation_tab, other)
  release_list()
  eventually(function()
    return has_notification(notifications, "invoking tabpage changed workspaces")
  end)

  assert_true(vim.api.nvim_tabpage_is_valid(invocation_tab))
  assert_path_equal(other, tab_cwd(invocation_tab))
  for _, call in ipairs(calls) do
    assert_true(call.args[5] ~= "forget")
  end
end)

test("rechecks the sole-tab restriction immediately before closing", function()
  local sandbox = temp_dir("delete-sole-race")
  local default = vim.fs.joinpath(sandbox, "default")
  local workspace = vim.fs.joinpath(sandbox, "workspace")
  mkdir(default)
  mkdir(workspace)
  local default_tab = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(default_tab, default)
  vim.api.nvim_cmd({ cmd = "tabnew" }, {})
  local invocation_tab = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(invocation_tab, workspace)

  local notifications = capture_notifications()
  local calls, release_list, list_pending = deferred_standard_mock({
    { name = "default", root = default },
    { name = "feature", root = workspace },
  })
  command("delete")
  eventually(list_pending, "workspace list did not start")
  vim.api.nvim_cmd({ cmd = "tabclose", args = { tostring(vim.api.nvim_tabpage_get_number(default_tab)) }, bang = true }, {})
  release_list()
  eventually(function()
    return has_notification(notifications, "only one tabpage remains")
  end)

  assert_true(vim.api.nvim_tabpage_is_valid(invocation_tab))
  assert_equal(1, #vim.api.nvim_list_tabpages())
  for _, call in ipairs(calls) do
    assert_true(call.args[5] ~= "forget")
  end
end)

test("reports forget failure after closing the workspace tab", function()
  local sandbox = temp_dir("delete-forget-failure")
  local default = vim.fs.joinpath(sandbox, "default")
  local workspace = vim.fs.joinpath(sandbox, "workspace")
  mkdir(default)
  mkdir(workspace)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), default)
  vim.api.nvim_cmd({ cmd = "tabnew" }, {})
  local invocation_tab = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(invocation_tab, workspace)

  local notifications = capture_notifications()
  standard_mock({
    { name = "default", root = default },
    { name = "feature", root = workspace },
  }, function(args)
    if args[5] == "forget" then
      return result(1, "", "simulated forget failure")
    end
  end)
  command("delete")
  eventually(function()
    return has_notification(notifications, "Jujutsu could not forget workspace.*simulated forget failure")
  end)

  assert_true(not vim.api.nvim_tabpage_is_valid(invocation_tab))
  assert_equal(1, #vim.api.nvim_list_tabpages())
end)

test("reports an error when no workspace contains the captured cwd", function()
  local sandbox = temp_dir("delete-unresolved")
  local default = vim.fs.joinpath(sandbox, "default")
  local workspace = vim.fs.joinpath(sandbox, "workspace")
  local unrelated = vim.fs.joinpath(sandbox, "unrelated")
  mkdir(default)
  mkdir(workspace)
  mkdir(unrelated)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), default)
  vim.api.nvim_cmd({ cmd = "tabnew" }, {})
  local invocation_tab = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(invocation_tab, unrelated)

  local notifications = capture_notifications()
  local calls = standard_mock({
    { name = "default", root = default },
    { name = "feature", root = workspace },
  })
  command("delete")
  eventually(function()
    return has_notification(notifications, "Could not resolve a Jujutsu workspace")
  end)

  assert_true(vim.api.nvim_tabpage_is_valid(invocation_tab))
  for _, call in ipairs(calls) do
    assert_true(call.args[5] ~= "forget")
  end
end)

test("forgets stale records and switches only the captured tabpage", function()
  local sandbox = temp_dir("switch")
  local current = vim.fs.joinpath(sandbox, "current")
  local target = vim.fs.joinpath(sandbox, "target with spaces | safe")
  local other = vim.fs.joinpath(sandbox, "other")
  mkdir(current)
  mkdir(target)
  mkdir(other)
  local missing = vim.fs.joinpath(sandbox, "missing")

  local invocation_tab = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(invocation_tab, current)
  local picker = install_picker()
  local tabby_calls = install_tabby()
  local calls = standard_mock({
    { name = "default", root = current },
    { name = "target", root = target },
    { name = "--stale-name", root = missing },
  })

  command("switch")
  eventually(function()
    return picker() ~= nil
  end, "picker did not open")

  assert_equal(1, #picker().items)
  assert_equal("target", picker().items[1].name)
  assert_match("target with spaces", picker().items[1].text)

  local forget_call
  for _, call in ipairs(calls) do
    if call.args[5] == "forget" then
      forget_call = call
    end
  end
  assert_true(forget_call, "stale workspace was not forgotten")
  assert_equal("--", forget_call.args[6])
  assert_equal("--stale-name", forget_call.args[7])
  assert_path_equal(current, forget_call.opts.cwd)

  vim.api.nvim_cmd({ cmd = "tabnew" }, {})
  local other_tab = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(other_tab, other)
  picker().confirm({ close = function() end }, picker().items[1])

  assert_path_equal(target, tab_cwd(invocation_tab))
  assert_path_equal(other, tab_cwd(other_tab))
  assert_equal(1, #tabby_calls)
  assert_equal(invocation_tab, tabby_calls[1].tabpage)
  assert_equal({ "rename_tab", "current[target]" }, tabby_calls[1].fargs)
end)

test("unsets the tab name when switching to the default workspace", function()
  local sandbox = temp_dir("switch-default")
  local default = vim.fs.joinpath(sandbox, "default")
  local current = vim.fs.joinpath(sandbox, "current")
  mkdir(default)
  mkdir(current)

  local tabpage = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(tabpage, current)
  local notifications = capture_notifications()
  local picker = install_picker()
  local tabby_calls = install_tabby()
  standard_mock({
    { name = "default", root = default },
    { name = "current", root = current },
  })

  command("switch")
  eventually(function()
    return picker() ~= nil
  end)
  assert_equal("default", picker().items[1].name)
  picker().confirm({ close = function() end }, picker().items[1])

  assert_path_equal(default, tab_cwd(tabpage))
  assert_equal(1, #tabby_calls)
  assert_equal(tabpage, tabby_calls[1].tabpage)
  assert_equal({ "rename_tab" }, tabby_calls[1].fargs)
  assert_true(not has_notification(notifications, "tab could not be named"))
end)

test("switches successfully when the default basename is unavailable", function()
  local sandbox = temp_dir("switch-no-default")
  local current = vim.fs.joinpath(sandbox, "current")
  local target = vim.fs.joinpath(sandbox, "target")
  mkdir(current)
  mkdir(target)
  local tabpage = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(tabpage, current)

  local notifications = capture_notifications()
  local picker = install_picker()
  local tabby_calls = install_tabby()
  standard_mock({
    { name = "active", root = current },
    { name = "target", root = target },
  })

  command("switch")
  eventually(function()
    return picker() ~= nil
  end)
  picker().confirm({ close = function() end }, picker().items[1])

  assert_path_equal(target, tab_cwd(tabpage))
  assert_equal(0, #tabby_calls)
  assert_true(has_notification(notifications, "tab could not be named.*default workspace root"))
end)

test("switches successfully when Tabby is unavailable", function()
  local sandbox = temp_dir("switch-no-tabby")
  local current = vim.fs.joinpath(sandbox, "current")
  local target = vim.fs.joinpath(sandbox, "target")
  mkdir(current)
  mkdir(target)
  local tabpage = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(tabpage, current)

  local notifications = capture_notifications()
  local picker = install_picker()
  standard_mock({
    { name = "default", root = current },
    { name = "target", root = target },
  })

  command("switch")
  eventually(function()
    return picker() ~= nil
  end)
  picker().confirm({ close = function() end }, picker().items[1])

  assert_path_equal(target, tab_cwd(tabpage))
  assert_true(has_notification(notifications, "tab could not be named.*Tabby.*unavailable"))
end)

test("keeps a successful switch when Tabby renaming fails", function()
  local sandbox = temp_dir("switch-tabby-failure")
  local current = vim.fs.joinpath(sandbox, "current")
  local target = vim.fs.joinpath(sandbox, "target")
  mkdir(current)
  mkdir(target)
  local tabpage = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(tabpage, current)

  local notifications = capture_notifications()
  local picker = install_picker()
  local tabby_calls = install_tabby(function()
    error("simulated Tabby failure")
  end)
  standard_mock({
    { name = "default", root = current },
    { name = "target", root = target },
  })

  command("switch")
  eventually(function()
    return picker() ~= nil
  end)
  picker().confirm({ close = function() end }, picker().items[1])

  assert_path_equal(target, tab_cwd(tabpage))
  assert_equal(1, #tabby_calls)
  assert_true(has_notification(notifications, "tab could not be named.*simulated Tabby failure"))
end)

test("does not rename when the invoking tabpage disappears before confirmation", function()
  local sandbox = temp_dir("switch-closed-tab")
  local current = vim.fs.joinpath(sandbox, "current")
  local target = vim.fs.joinpath(sandbox, "target")
  local other = vim.fs.joinpath(sandbox, "other")
  mkdir(current)
  mkdir(target)
  mkdir(other)
  local invocation_tab = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(invocation_tab, current)

  local notifications = capture_notifications()
  local picker = install_picker()
  local tabby_calls = install_tabby()
  standard_mock({
    { name = "default", root = current },
    { name = "target", root = target },
  })

  command("switch")
  eventually(function()
    return picker() ~= nil
  end)
  vim.api.nvim_cmd({ cmd = "tabnew" }, {})
  local other_tab = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(other_tab, other)
  vim.api.nvim_set_current_tabpage(invocation_tab)
  vim.api.nvim_cmd({ cmd = "tabclose", bang = true }, {})
  picker().confirm({ close = function() end }, picker().items[1])

  assert_path_equal(other, tab_cwd(other_tab))
  assert_equal(0, #tabby_calls)
  assert_true(has_notification(notifications, "Could not switch workspace.*no longer exists"))
end)

test("forgets a workspace that disappears before picker confirmation", function()
  local sandbox = temp_dir("disappeared")
  local current = vim.fs.joinpath(sandbox, "current")
  local target = vim.fs.joinpath(sandbox, "target")
  mkdir(current)
  mkdir(target)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), current)

  local notifications = capture_notifications()
  local picker = install_picker()
  local tabby_calls = install_tabby()
  local calls = standard_mock({
    { name = "default", root = current },
    { name = "gone", root = target },
  })

  command("switch")
  eventually(function()
    return picker() ~= nil
  end)
  assert_equal(0, vim.fn.delete(target, "d"))
  picker().confirm({ close = function() end }, picker().items[1])
  eventually(function()
    return has_notification(notifications, "No switch occurred")
  end)

  assert_path_equal(current, tab_cwd(vim.api.nvim_get_current_tabpage()))
  assert_equal(0, #tabby_calls)
  local forgot = false
  for _, call in ipairs(calls) do
    forgot = forgot or (call.args[5] == "forget" and call.args[6] == "--" and call.args[7] == "gone")
  end
  assert_true(forgot, "disappeared workspace record was not forgotten")
end)

test("retains roots that cannot be inspected", function()
  local sandbox = temp_dir("permission")
  local current = vim.fs.joinpath(sandbox, "current")
  local locked = vim.fs.joinpath(sandbox, "locked")
  local hidden = vim.fs.joinpath(locked, "workspace")
  mkdir(current)
  mkdir(locked)
  mkdir(hidden)
  assert_true(uv.fs_chmod(locked, 0))
  cleanup(function()
    pcall(uv.fs_chmod, locked, 448)
  end)

  local state = require("jjwsm")._test.classify_directory(hidden)
  if state ~= "unknown" then
    skipped = skipped + 1
    return
  end

  set_tab_cwd(vim.api.nvim_get_current_tabpage(), current)
  local notifications = capture_notifications()
  local picker = install_picker()
  local calls = standard_mock({
    { name = "default", root = current },
    { name = "unreadable", root = hidden },
  })
  command("switch")
  eventually(function()
    return picker() ~= nil
  end)
  assert_true(has_notification(notifications, "retaining its record"))
  for _, call in ipairs(calls) do
    assert_true(call.args[5] ~= "forget", "permission failure must not forget a workspace")
  end
end)

test("reports a missing Snacks picker after workspace inspection", function()
  local sandbox = temp_dir("no-snacks")
  local current = vim.fs.joinpath(sandbox, "current")
  local target = vim.fs.joinpath(sandbox, "target")
  mkdir(current)
  mkdir(target)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), current)
  package.loaded.snacks = nil
  _G.Snacks = nil

  local notifications = capture_notifications()
  standard_mock({
    { name = "default", root = current },
    { name = "target", root = target },
  })
  command("switch")
  eventually(function()
    return has_notification(notifications, "Snacks picker is required")
  end)
end)

test("aborts when Jujutsu cannot forget stale records", function()
  local sandbox = temp_dir("forget-failure")
  local current = vim.fs.joinpath(sandbox, "current")
  mkdir(current)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), current)
  local notifications = capture_notifications()
  local picker = install_picker()
  standard_mock({
    { name = "default", root = current },
    { name = "stale", root = vim.fs.joinpath(sandbox, "gone") },
  }, function(args)
    if args[5] == "forget" then
      return result(1, "", "Error: operation conflict")
    end
  end)

  command("switch")
  eventually(function()
    return has_notification(notifications, "operation conflict")
  end)
  assert_equal(nil, picker(), "picker must not open after cleanup failure")
end)

test("allocates the lowest repository-specific counter absent from paths", function()
  local parent = temp_dir("allocation")
  local prefix = "jjwsm-Repo.Name-"
  mkdir(vim.fs.joinpath(parent, "jjwsm-Repo.Name-1"))
  mkdir(vim.fs.joinpath(parent, "jjwsm-Repo.Name-3"))
  mkdir(vim.fs.joinpath(parent, "jjwsm-2"))
  local module = require("jjwsm")
  assert_equal("$Repo With [Punctuation].v1!", module._test.default_workspace_basename({
    { name = "default", root = "/work/$Repo With [Punctuation].v1!" },
  }))
  assert_equal("jjwsm-$Repo With [Punctuation].v1!-", module._test.workspace_prefix({
    { name = "default", root = "/work/$Repo With [Punctuation].v1!" },
  }))

  local candidate = assert(module._test.allocate_candidate(parent, prefix, 1))
  assert_equal(vim.fs.joinpath(parent, "jjwsm-Repo.Name-2"), candidate.root)

  mkdir(candidate.root)
  local next_candidate = assert(module._test.allocate_candidate(parent, prefix, 1))
  assert_equal(vim.fs.joinpath(parent, "jjwsm-Repo.Name-4"), next_candidate.root)
end)

test("passes a prompted name verbatim while generating the repository-aware path", function()
  local sandbox = temp_dir("new")
  local current = vim.fs.joinpath(sandbox, "Repo With Spaces.v1+Draft")
  local temp_root = vim.fs.joinpath(sandbox, "os-temp")
  mkdir(current)
  mkdir(temp_root)
  with_tmpdir(temp_root)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), current)
  local prompted_name = "  Feature: spaces + punctuation!?  "
  local input_calls = install_input(prompted_name)

  local tabby_calls = install_tabby()
  local add_call
  standard_mock({ { name = "default", root = current } }, function(args, opts)
    if args[5] == "add" then
      add_call = { args = vim.deepcopy(args), opts = vim.deepcopy(opts) }
      assert_true(uv.fs_mkdir(args[8], 448))
      return result(0)
    end
  end)

  command("new")
  eventually(function()
    return #vim.api.nvim_list_tabpages() == 2
  end, "new workspace tab did not open")

  local expected_parent = vim.fs.joinpath(temp_root, "jjwsm.nvim")
  local expected_root = vim.fs.joinpath(expected_parent, "jjwsm-Repo With Spaces.v1+Draft-1")
  assert_true(add_call, "workspace add was not called")
  assert_equal({ "Workspace name: " }, { input_calls[1].prompt })
  assert_equal(nil, input_calls[1].default, "the prompt must not have a generated default")
  assert_equal(
    { "jj", "--no-pager", "--color=never", "workspace", "add", "--name", prompted_name, expected_root },
    add_call.args
  )
  assert_path_equal(current, add_call.opts.cwd)
  assert_equal("rwx------", vim.fn.getfperm(expected_parent))
  assert_path_equal(expected_root, tab_cwd(vim.api.nvim_get_current_tabpage()))
  assert_equal("", vim.api.nvim_buf_get_name(0), "new tab should contain a blank buffer")
  assert_equal(1, #tabby_calls)
  assert_equal(vim.api.nvim_get_current_tabpage(), tabby_calls[1].tabpage)
  assert_equal({
    "rename_tab",
    "Repo With Spaces.v1+Draft[  Feature: spaces + punctuation!?  ]",
  }, tabby_calls[1].fargs)
end)

test("cancels workspace creation without creating a parent or tab", function()
  local sandbox = temp_dir("cancel-new")
  local current = vim.fs.joinpath(sandbox, "current")
  local temp_root = vim.fs.joinpath(sandbox, "os-temp")
  local parent = vim.fs.joinpath(temp_root, "jjwsm.nvim")
  mkdir(current)
  mkdir(temp_root)
  with_tmpdir(temp_root)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), current)

  local notifications = capture_notifications()
  local input_calls = install_input(nil)
  local calls = standard_mock({ { name = "default", root = current } })

  command("new")
  eventually(function()
    return has_notification(notifications, "creation cancelled")
  end)

  assert_equal({ prompt = "Workspace name: " }, input_calls[1])
  assert_equal(vim.log.levels.INFO, notifications[#notifications].level)
  for _, call in ipairs(calls) do
    assert_true(call.args[5] ~= "add", "cancellation must not attempt workspace creation")
  end
  assert_equal(0, vim.fn.isdirectory(parent))
  assert_equal(1, #vim.api.nvim_list_tabpages())
end)

test("rejects a blank workspace name without creating a parent", function()
  local sandbox = temp_dir("blank-name")
  local current = vim.fs.joinpath(sandbox, "current")
  local temp_root = vim.fs.joinpath(sandbox, "os-temp")
  local parent = vim.fs.joinpath(temp_root, "jjwsm.nvim")
  mkdir(current)
  mkdir(temp_root)
  with_tmpdir(temp_root)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), current)

  local notifications = capture_notifications()
  install_input(" \t ")
  local calls = standard_mock({ { name = "default", root = current } })

  command("new")
  eventually(function()
    return has_notification(notifications, "cannot be blank")
  end)

  assert_equal(vim.log.levels.ERROR, notifications[#notifications].level)
  for _, call in ipairs(calls) do
    assert_true(call.args[5] ~= "add", "blank input must not attempt workspace creation")
  end
  assert_equal(0, vim.fn.isdirectory(parent))
  assert_equal(1, #vim.api.nvim_list_tabpages())
end)

test("rejects an already-registered workspace name without creating a parent", function()
  local sandbox = temp_dir("duplicate-name")
  local current = vim.fs.joinpath(sandbox, "current")
  local existing = vim.fs.joinpath(sandbox, "existing")
  local temp_root = vim.fs.joinpath(sandbox, "os-temp")
  local parent = vim.fs.joinpath(temp_root, "jjwsm.nvim")
  mkdir(current)
  mkdir(existing)
  mkdir(temp_root)
  with_tmpdir(temp_root)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), current)

  local notifications = capture_notifications()
  install_input("taken name")
  local calls = standard_mock({
    { name = "default", root = current },
    { name = "taken name", root = existing },
  })

  command("new")
  eventually(function()
    return has_notification(notifications, "already registered")
  end)

  for _, call in ipairs(calls) do
    assert_true(call.args[5] ~= "add", "duplicate input must not attempt workspace creation")
  end
  assert_equal(0, vim.fn.isdirectory(parent))
  assert_equal(1, #vim.api.nvim_list_tabpages())
end)

test("aborts before creating a parent when the default workspace is missing", function()
  local sandbox = temp_dir("missing-default")
  local current = vim.fs.joinpath(sandbox, "current")
  local temp_root = vim.fs.joinpath(sandbox, "os-temp")
  local parent = vim.fs.joinpath(temp_root, "jjwsm.nvim")
  mkdir(current)
  mkdir(temp_root)
  with_tmpdir(temp_root)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), current)

  local notifications = capture_notifications()
  local input_calls = install_input("must not be requested")
  local add_called = false
  standard_mock({ { name = "other", root = current } }, function(args)
    if args[5] == "add" then
      add_called = true
    end
  end)

  command("new")
  eventually(function()
    return has_notification(notifications, "default workspace root")
  end)
  assert_true(not add_called)
  assert_equal(0, #input_calls)
  assert_equal(0, vim.fn.isdirectory(parent))
  assert_equal(1, #vim.api.nvim_list_tabpages())
end)

test("aborts before creating a parent when the default root basename is empty", function()
  local sandbox = temp_dir("empty-basename")
  local current = vim.fs.joinpath(sandbox, "current")
  local temp_root = vim.fs.joinpath(sandbox, "os-temp")
  local parent = vim.fs.joinpath(temp_root, "jjwsm.nvim")
  mkdir(current)
  mkdir(temp_root)
  with_tmpdir(temp_root)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), current)

  local notifications = capture_notifications()
  local input_calls = install_input("must not be requested")
  local add_called = false
  standard_mock({ { name = "default", root = "/" } }, function(args)
    if args[5] == "add" then
      add_called = true
    end
  end)

  command("new")
  eventually(function()
    return has_notification(notifications, "non%-empty basename")
  end)
  assert_true(not add_called)
  assert_equal(0, #input_calls)
  assert_equal(0, vim.fn.isdirectory(parent))
  assert_equal(1, #vim.api.nvim_list_tabpages())
end)

test("rejects a non-directory temporary parent without touching it", function()
  local sandbox = temp_dir("invalid-parent")
  local current = vim.fs.joinpath(sandbox, "current")
  local temp_root = vim.fs.joinpath(sandbox, "os-temp")
  mkdir(current)
  mkdir(temp_root)
  local parent = vim.fs.joinpath(temp_root, "jjwsm.nvim")
  vim.fn.writefile({ "keep" }, parent)
  with_tmpdir(temp_root)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), current)

  local notifications = capture_notifications()
  install_input("new workspace")
  local add_called = false
  standard_mock({ { name = "default", root = current } }, function(args)
    if args[5] == "add" then
      add_called = true
    end
  end)
  command("new")
  eventually(function()
    return has_notification(notifications, "not a real directory")
  end)
  assert_true(not add_called)
  assert_equal({ "keep" }, vim.fn.readfile(parent))
  assert_equal(1, #vim.api.nvim_list_tabpages())
end)

test("rescans from the next counter after a concurrent collision", function()
  local sandbox = temp_dir("collision")
  local current = vim.fs.joinpath(sandbox, "Collision Repo")
  local temp_root = vim.fs.joinpath(sandbox, "os-temp")
  mkdir(current)
  mkdir(temp_root)
  with_tmpdir(temp_root)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), current)
  install_input("collision workspace")

  local tabby_calls = install_tabby()
  local parent = vim.fs.joinpath(temp_root, "jjwsm.nvim")
  local list_count = 0
  local add_names = {}
  local add_roots = {}
  mock_system(function(args)
    if args[2] == "--version" then
      return result(0, "jj 0.43.0\n")
    end
    if args[5] == "list" then
      list_count = list_count + 1
      local listed = { { name = "default", root = current } }
      if list_count > 1 then
        listed[1].root = vim.fs.joinpath(sandbox, "changed-default-root")
        listed[#listed + 1] = {
          name = "jjwsm-Collision Repo-1",
          root = vim.fs.joinpath(parent, "jjwsm-Collision Repo-1"),
        }
      end
      return result(0, workspace_output(listed))
    end
    if args[5] == "add" then
      add_names[#add_names + 1] = args[7]
      add_roots[#add_roots + 1] = args[8]
      assert_true(uv.fs_mkdir(args[8], 448))
      if #add_names == 1 then
        return result(1, "", "Error: File exists (os error 17)")
      end
      return result(0)
    end
    return result(0)
  end)

  command("new")
  eventually(function()
    return #vim.api.nvim_list_tabpages() == 2
  end)
  assert_equal({ "collision workspace", "collision workspace" }, add_names)
  assert_equal({
    vim.fs.joinpath(parent, "jjwsm-Collision Repo-1"),
    vim.fs.joinpath(parent, "jjwsm-Collision Repo-2"),
  }, add_roots)
  assert_path_equal(
    vim.fs.joinpath(parent, "jjwsm-Collision Repo-2"),
    tab_cwd(vim.api.nvim_get_current_tabpage())
  )
  assert_equal(
    "directory",
    require("jjwsm")._test.classify_directory(vim.fs.joinpath(parent, "jjwsm-Collision Repo-1"))
  )
  assert_equal({ "rename_tab", "Collision Repo[collision workspace]" }, tabby_calls[1].fargs)
end)

test("stops retrying when a collision rescan finds the prompted name", function()
  local sandbox = temp_dir("concurrent-name")
  local current = vim.fs.joinpath(sandbox, "Concurrent Repo")
  local existing = vim.fs.joinpath(sandbox, "concurrent-winner")
  local temp_root = vim.fs.joinpath(sandbox, "os-temp")
  mkdir(current)
  mkdir(existing)
  mkdir(temp_root)
  with_tmpdir(temp_root)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), current)
  install_input("contended name")

  local notifications = capture_notifications()
  local parent = vim.fs.joinpath(temp_root, "jjwsm.nvim")
  local list_count = 0
  local add_count = 0
  mock_system(function(args)
    if args[2] == "--version" then
      return result(0, "jj 0.43.0\n")
    end
    if args[5] == "list" then
      list_count = list_count + 1
      local listed = { { name = "default", root = current } }
      if list_count > 1 then
        listed[#listed + 1] = { name = "contended name", root = existing }
      end
      return result(0, workspace_output(listed))
    end
    if args[5] == "add" then
      add_count = add_count + 1
      assert_equal("contended name", args[7])
      assert_true(uv.fs_mkdir(args[8], 448))
      return result(1, "", "Error: already exists")
    end
    return result(0)
  end)

  command("new")
  eventually(function()
    return has_notification(notifications, "already registered")
  end)

  assert_equal(1, add_count)
  assert_equal(2, list_count)
  assert_equal(1, vim.fn.isdirectory(vim.fs.joinpath(parent, "jjwsm-Concurrent Repo-1")))
  assert_equal(1, #vim.api.nvim_list_tabpages())
end)

test("surfaces unrelated add failures without tabs or deletion", function()
  local sandbox = temp_dir("add-failure")
  local current = vim.fs.joinpath(sandbox, "current")
  local temp_root = vim.fs.joinpath(sandbox, "os-temp")
  local parent = vim.fs.joinpath(temp_root, "jjwsm.nvim")
  local occupied = vim.fs.joinpath(parent, "jjwsm-current-1")
  mkdir(current)
  mkdir(temp_root)
  mkdir(parent)
  mkdir(occupied)
  local marker = vim.fs.joinpath(occupied, "do-not-delete")
  vim.fn.writefile({ "safe" }, marker)
  with_tmpdir(temp_root)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), current)
  install_input("requested name")

  local notifications = capture_notifications()
  standard_mock({ { name = "default", root = current } }, function(args)
    if args[5] == "add" then
      assert_equal("requested name", args[7])
      assert_equal(vim.fs.joinpath(parent, "jjwsm-current-2"), args[8])
      return result(1, "", "Error: backend refused the operation")
    end
  end)

  command("new")
  eventually(function()
    return has_notification(notifications, "backend refused")
  end)
  assert_equal(1, #vim.api.nvim_list_tabpages())
  assert_equal({ "safe" }, vim.fn.readfile(marker))
  assert_equal(0, vim.fn.isdirectory(vim.fs.joinpath(parent, "jjwsm-current-2")))
end)

test("real Jujutsu cleanup retains live workspaces and forgets missing ones", function()
  local sandbox = temp_dir("real-cleanup")
  local repo = vim.fs.joinpath(sandbox, "repo")
  local live = vim.fs.joinpath(sandbox, "live workspace")
  local stale = vim.fs.joinpath(sandbox, "stale workspace")
  run_sync({ "jj", "git", "init", repo }, sandbox)
  run_sync({ "jj", "workspace", "add", "--name", "live", live }, repo)
  run_sync({ "jj", "workspace", "add", "--name", "stale", stale }, repo)
  assert_equal(0, vim.fn.delete(stale, "rf"))
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), repo)

  local picker = install_picker()
  command("switch")
  eventually(function()
    return picker() ~= nil
  end, "real cleanup did not reach picker", 10000)

  local names = {}
  for _, workspace in ipairs(real_workspace_list(repo)) do
    names[workspace.name] = true
  end
  assert_true(names.default)
  assert_true(names.live)
  assert_true(not names.stale)
  assert_equal("live", picker().items[1].name)
end)

test("real Jujutsu creation uses the exact repository-aware temporary layout", function()
  local sandbox = temp_dir("real-new")
  local repo = vim.fs.joinpath(sandbox, "repo")
  local temp_root = vim.fs.joinpath(sandbox, "os-temp")
  mkdir(temp_root)
  run_sync({ "jj", "git", "init", repo }, sandbox)
  with_tmpdir(temp_root)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), repo)
  install_input("prompted real workspace")

  local tabby_calls = install_tabby()
  command("new")
  eventually(function()
    return #vim.api.nvim_list_tabpages() == 2
  end, "real workspace creation did not open a tab", 10000)

  local expected = vim.fs.joinpath(temp_root, "jjwsm.nvim", "jjwsm-repo-1")
  assert_path_equal(expected, tab_cwd(vim.api.nvim_get_current_tabpage()))
  assert_equal(1, vim.fn.isdirectory(expected))
  local names = {}
  for _, workspace in ipairs(real_workspace_list(repo)) do
    names[workspace.name] = workspace.root
  end
  assert_path_equal(expected, names["prompted real workspace"])
  assert_equal({ "rename_tab", "repo[prompted real workspace]" }, tabby_calls[1].fargs)
end)

test("real Jujutsu deletion forgets the record and preserves its directory", function()
  local sandbox = temp_dir("real-delete")
  local repo = vim.fs.joinpath(sandbox, "repo")
  local workspace = vim.fs.joinpath(sandbox, "workspace to forget")
  run_sync({ "jj", "git", "init", repo }, sandbox)
  run_sync({ "jj", "workspace", "add", "--name", "delete me", workspace }, repo)
  local marker = vim.fs.joinpath(workspace, "keep-me")
  vim.fn.writefile({ "safe" }, marker)

  set_tab_cwd(vim.api.nvim_get_current_tabpage(), repo)
  vim.api.nvim_cmd({ cmd = "tabnew" }, {})
  local invocation_tab = vim.api.nvim_get_current_tabpage()
  set_tab_cwd(invocation_tab, workspace)

  command("delete")
  eventually(function()
    return not vim.api.nvim_tabpage_is_valid(invocation_tab)
  end, "real deletion did not close the workspace tab", 10000)
  eventually(function()
    local listed_ok, workspaces = pcall(real_workspace_list, repo)
    if not listed_ok then
      return false
    end
    for _, listed in ipairs(workspaces) do
      if listed.name == "delete me" then
        return false
      end
    end
    return true
  end, "real deletion did not forget the workspace record", 10000)

  assert_equal(1, vim.fn.isdirectory(workspace))
  assert_equal({ "safe" }, vim.fn.readfile(marker))
end)

for _, item in ipairs(tests) do
  reset_editor()
  local ok, err = xpcall(item.fn, debug.traceback)
  run_cleanups()
  if ok then
    io.stdout:write("ok - " .. item.name .. "\n")
  else
    failures = failures + 1
    io.stderr:write("not ok - " .. item.name .. "\n" .. err .. "\n")
  end
end

io.stdout:write(("\n%d tests, %d failures, %d platform skips\n"):format(#tests, failures, skipped))
if failures > 0 then
  vim.cmd.cquit(failures)
else
  vim.cmd.quitall()
end
