return {
  {
    'rose-pine/neovim',
    name = 'rose-pine',
    priority = 1000,
    config = function()
      require('rose-pine').setup {
        variant = 'moon', -- 'main' | 'moon' | 'dawn'
        styles = {
          italic = false,
        },
      }
      vim.cmd.colorscheme 'rose-pine'
    end,
  },
}
