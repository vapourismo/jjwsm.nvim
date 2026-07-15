if vim.g.loaded_jjwsm == 1 then
  return
end
vim.g.loaded_jjwsm = 1

vim.api.nvim_create_user_command("Jjwsm", function(opts)
  require("jjwsm")._dispatch(opts.fargs)
end, {
  nargs = "*",
  complete = function(arglead, cmdline, cursorpos)
    return require("jjwsm")._complete(arglead, cmdline, cursorpos)
  end,
  desc = "Switch, create, or forget Jujutsu workspaces",
})
