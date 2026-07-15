local uv = vim.uv
local project_root = vim.fn.getcwd()
local original_system = vim.system
local original_notify = vim.notify
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
  assert_equal({ "switch", "new" }, module._complete("", "Jjwsm ", #"Jjwsm "))
  assert_equal({ "switch" }, module._complete("s", "Jjwsm s", #"Jjwsm s"))
  assert_equal({}, module._complete("", "Jjwsm switch ", #"Jjwsm switch "))

  vim.api.nvim_cmd({ cmd = "Jjwsm", args = { "bogus", "extra" } }, {})
  assert_true(has_notification(notifications, "Usage: :Jjwsm"))
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

test("allocates the lowest counter absent from names and paths", function()
  local parent = temp_dir("allocation")
  mkdir(vim.fs.joinpath(parent, "jjwsm-1"))
  mkdir(vim.fs.joinpath(parent, "jjwsm-3"))
  local module = require("jjwsm")

  local candidate = assert(module._test.allocate_candidate(parent, {
    { name = "jjwsm-4", root = "/somewhere/else" },
  }, 1))
  assert_equal("jjwsm-2", candidate.name)
  assert_equal(vim.fs.joinpath(parent, "jjwsm-2"), candidate.root)

  mkdir(candidate.root)
  local next_candidate = assert(module._test.allocate_candidate(parent, {
    { name = "jjwsm-4", root = "/somewhere/else" },
  }, 1))
  assert_equal("jjwsm-5", next_candidate.name)
end)

test("creates an exact jjwsm-1 workspace, restricted parent, and one blank tab", function()
  local sandbox = temp_dir("new")
  local current = vim.fs.joinpath(sandbox, "current")
  local temp_root = vim.fs.joinpath(sandbox, "os-temp")
  mkdir(current)
  mkdir(temp_root)
  with_tmpdir(temp_root)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), current)

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
  local expected_root = vim.fs.joinpath(expected_parent, "jjwsm-1")
  assert_true(add_call, "workspace add was not called")
  assert_equal({ "jj", "--no-pager", "--color=never", "workspace", "add", "--name", "jjwsm-1", expected_root }, add_call.args)
  assert_path_equal(current, add_call.opts.cwd)
  assert_equal("rwx------", vim.fn.getfperm(expected_parent))
  assert_path_equal(expected_root, tab_cwd(vim.api.nvim_get_current_tabpage()))
  assert_equal("", vim.api.nvim_buf_get_name(0), "new tab should contain a blank buffer")
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
  local current = vim.fs.joinpath(sandbox, "current")
  local temp_root = vim.fs.joinpath(sandbox, "os-temp")
  mkdir(current)
  mkdir(temp_root)
  with_tmpdir(temp_root)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), current)

  local parent = vim.fs.joinpath(temp_root, "jjwsm.nvim")
  local list_count = 0
  local add_names = {}
  mock_system(function(args)
    if args[2] == "--version" then
      return result(0, "jj 0.43.0\n")
    end
    if args[5] == "list" then
      list_count = list_count + 1
      local listed = { { name = "default", root = current } }
      if list_count > 1 then
        listed[#listed + 1] = { name = "jjwsm-1", root = vim.fs.joinpath(parent, "jjwsm-1") }
      end
      return result(0, workspace_output(listed))
    end
    if args[5] == "add" then
      add_names[#add_names + 1] = args[7]
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
  assert_equal({ "jjwsm-1", "jjwsm-2" }, add_names)
  assert_path_equal(vim.fs.joinpath(parent, "jjwsm-2"), tab_cwd(vim.api.nvim_get_current_tabpage()))
  assert_equal("directory", require("jjwsm")._test.classify_directory(vim.fs.joinpath(parent, "jjwsm-1")))
end)

test("surfaces unrelated add failures without tabs or deletion", function()
  local sandbox = temp_dir("add-failure")
  local current = vim.fs.joinpath(sandbox, "current")
  local temp_root = vim.fs.joinpath(sandbox, "os-temp")
  local parent = vim.fs.joinpath(temp_root, "jjwsm.nvim")
  local occupied = vim.fs.joinpath(parent, "jjwsm-1")
  mkdir(current)
  mkdir(temp_root)
  mkdir(parent)
  mkdir(occupied)
  local marker = vim.fs.joinpath(occupied, "do-not-delete")
  vim.fn.writefile({ "safe" }, marker)
  with_tmpdir(temp_root)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), current)

  local notifications = capture_notifications()
  standard_mock({ { name = "default", root = current } }, function(args)
    if args[5] == "add" then
      assert_equal("jjwsm-2", args[7])
      return result(1, "", "Error: backend refused the operation")
    end
  end)

  command("new")
  eventually(function()
    return has_notification(notifications, "backend refused")
  end)
  assert_equal(1, #vim.api.nvim_list_tabpages())
  assert_equal({ "safe" }, vim.fn.readfile(marker))
  assert_equal(0, vim.fn.isdirectory(vim.fs.joinpath(parent, "jjwsm-2")))
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

test("real Jujutsu creation uses the exact shared temporary layout", function()
  local sandbox = temp_dir("real-new")
  local repo = vim.fs.joinpath(sandbox, "repo")
  local temp_root = vim.fs.joinpath(sandbox, "os-temp")
  mkdir(temp_root)
  run_sync({ "jj", "git", "init", repo }, sandbox)
  with_tmpdir(temp_root)
  set_tab_cwd(vim.api.nvim_get_current_tabpage(), repo)

  command("new")
  eventually(function()
    return #vim.api.nvim_list_tabpages() == 2
  end, "real workspace creation did not open a tab", 10000)

  local expected = vim.fs.joinpath(temp_root, "jjwsm.nvim", "jjwsm-1")
  assert_path_equal(expected, tab_cwd(vim.api.nvim_get_current_tabpage()))
  assert_equal(1, vim.fn.isdirectory(expected))
  local names = {}
  for _, workspace in ipairs(real_workspace_list(repo)) do
    names[workspace.name] = workspace.root
  end
  assert_path_equal(expected, names["jjwsm-1"])
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
