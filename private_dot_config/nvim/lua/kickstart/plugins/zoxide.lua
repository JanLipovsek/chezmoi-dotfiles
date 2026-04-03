return {
  {
    "alfaix/nvim-zoxide",
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = {
      -- will define Z[!], Zt[!], Zw[!] for :cd, :tcd, :lcd respectively 
      define_commands = true,
      -- path to zoxide executable; by default must be in $PATH
      path = "zoxide",
    }
  },
  {
    "nvim-telescope/telescope.nvim",
    opts = function(_, opts)
      opts.extensions = opts.extensions or {}
      opts.extensions.zoxide = {}
      return opts
    end,
    config = function(_, opts)
      require("telescope").setup(opts)
      require("telescope").load_extension("zoxide")
    end
  }
}
