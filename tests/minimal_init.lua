vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
vim.o.writebackup = false
vim.o.backup = false
vim.o.shadafile = "NONE"

vim.cmd.runtime("plugin/jjwsm.lua")
