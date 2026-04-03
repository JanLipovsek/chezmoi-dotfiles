local M = {}

local uv = vim.uv or vim.loop

M.state = {
  current = nil,
}

M.config = {
  base_dir = '/tmp/' .. (vim.env.USER or 'nvim'),
  sshfs_bin = 'sshfs',
  unmount_cmd = { 'fusermount', '-u' },
  open_on_connect = true,
  auto_unmount_on_exit = false,
  set_global_cwd = true,
  lsp = {
    enabled = true,
    restart_active_clients = true,
    servers = {
      lua_ls = function(cfg, mount)
        cfg.settings = cfg.settings or {}
        cfg.settings.Lua = cfg.settings.Lua or {}
        cfg.settings.Lua.workspace = cfg.settings.Lua.workspace or {}

        local lib = cfg.settings.Lua.workspace.library or {}
        local add = {
          mount .. '/usr/share/lua',
          mount .. '/usr/local/share/lua',
          mount .. '/usr/lib/lua',
          mount .. '/usr/local/lib/lua',
        }

        for _, path in ipairs(add) do
          if vim.fn.isdirectory(path) == 1 then
            table.insert(lib, path)
          end
        end

        cfg.settings.Lua.workspace.library = lib
      end,

      pyright = function(cfg, mount)
        cfg.settings = cfg.settings or {}
        cfg.settings.python = cfg.settings.python or {}
        cfg.settings.python.analysis = cfg.settings.python.analysis or {}

        local extra = cfg.settings.python.analysis.extraPaths or {}
        for _, path in ipairs(M.get_python_paths(mount)) do
          table.insert(extra, path)
        end
        cfg.settings.python.analysis.extraPaths = M.uniq_paths(extra)
      end,

      basedpyright = function(cfg, mount)
        cfg.settings = cfg.settings or {}
        cfg.settings.python = cfg.settings.python or {}
        cfg.settings.python.analysis = cfg.settings.python.analysis or {}

        local extra = cfg.settings.python.analysis.extraPaths or {}
        for _, path in ipairs(M.get_python_paths(mount)) do
          table.insert(extra, path)
        end
        cfg.settings.python.analysis.extraPaths = M.uniq_paths(extra)
      end,

      pylyzer = function(cfg, mount)
        local source_cmd = M.build_ros_source_command(mount)
        local pylyzer_cmd = 'pylyzer --server'

        if source_cmd ~= '' then
          cfg.cmd = {
            'bash',
            '-lc',
            source_cmd .. ' && ' .. pylyzer_cmd,
          }
        else
          cfg.cmd = { 'bash', '-lc', pylyzer_cmd }
        end

        cfg.cmd_env = vim.tbl_extend('force', cfg.cmd_env or {}, {
          REMOTE_CONNECT_MOUNT = mount,
          ERG_PATH = vim.env.ERG_PATH,
          PYTHONPATH = M.join_env_paths(vim.list_extend(M.get_python_paths(mount), {
            vim.env.PYTHONPATH or '',
          })),
        })
      end,

      clangd = function(cfg, mount)
        cfg.cmd = cfg.cmd or { 'clangd' }

        local extras = {
          '--query-driver=' .. mount .. '/usr/bin/*,' .. mount .. '/bin/*',
        }

        for _, arg in ipairs(extras) do
          local found = false
          for _, existing in ipairs(cfg.cmd) do
            if existing == arg then
              found = true
              break
            end
          end
          if not found then
            table.insert(cfg.cmd, arg)
          end
        end
      end,
    },
  },
}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'remote-connect.nvim' })
end

local function shellescape(path)
  return vim.fn.fnameescape(path)
end

local function is_dir(path)
  local stat = uv.fs_stat(path)
  return stat and stat.type == 'directory'
end

local function is_file(path)
  local stat = uv.fs_stat(path)
  return stat and stat.type == 'file'
end

local function path_exists(path)
  return uv.fs_stat(path) ~= nil
end

local function ensure_dir(path)
  if is_dir(path) then
    return true
  end
  vim.fn.mkdir(path, 'p')
  return is_dir(path)
end

local function parse_target(target)
  local user, host = target:match '^([^@]+)@(.+)$'
  if not user or not host then
    return nil, 'target must look like user@host'
  end

  local safe_host = host:gsub('[^%w%.%-_]', '_')
  local safe_user = user:gsub('[^%w%.%-_]', '_')

  return {
    target = target,
    user = user,
    host = host,
    mount_name = string.format('%s_%s', safe_user, safe_host),
  }
end

local function run_system(cmd, input)
  local opts = { text = true }
  if input then
    opts.stdin = input
  end
  local result = vim.system(cmd, opts):wait()
  return result.code == 0, result
end

local function mount_for(target_info)
  return M.config.base_dir .. '/' .. target_info.mount_name
end

local function remote_home_for(target_info)
  return mount_for(target_info) .. '/home/' .. target_info.user
end

local function lspconfig_available()
  local ok = pcall(require, 'lspconfig')
  return ok
end

function M.uniq_paths(paths)
  local seen = {}
  local out = {}

  for _, path in ipairs(paths) do
    if path and path ~= '' and not seen[path] then
      seen[path] = true
      table.insert(out, path)
    end
  end

  return out
end

function M.join_env_paths(paths)
  return table.concat(M.uniq_paths(paths), ':')
end

local function glob_dirs(pattern)
  local matches = vim.fn.glob(pattern, false, true)
  local out = {}

  for _, path in ipairs(matches) do
    if is_dir(path) then
      table.insert(out, path)
    end
  end

  return M.uniq_paths(out)
end

local function glob_files(pattern)
  local matches = vim.fn.glob(pattern, false, true)
  local out = {}

  for _, path in ipairs(matches) do
    if is_file(path) then
      table.insert(out, path)
    end
  end

  return M.uniq_paths(out)
end

function M.get_ros_setup_scripts(mount)
  local scripts = {}

  for _, path in ipairs(glob_files(mount .. '/opt/ros/*/setup.bash')) do
    table.insert(scripts, path)
  end

  return M.uniq_paths(scripts)
end

function M.get_workspace_setup_scripts(mount)
  local scripts = {}

  local workspace_patterns = {
    mount .. '/home/*/*/install/local_setup.bash',
    mount .. '/home/*/*/install/setup.bash',
    mount .. '/workspace/*/install/local_setup.bash',
    mount .. '/workspace/*/install/setup.bash',
    mount .. '/workspaces/*/install/local_setup.bash',
    mount .. '/workspaces/*/install/setup.bash',
  }

  for _, pattern in ipairs(workspace_patterns) do
    for _, path in ipairs(glob_files(pattern)) do
      table.insert(scripts, path)
    end
  end

  return M.uniq_paths(scripts)
end

function M.build_ros_source_command(mount)
  local cmds = {}

  for _, script in ipairs(M.get_ros_setup_scripts(mount)) do
    table.insert(cmds, 'source ' .. vim.fn.shellescape(script))
  end

  for _, script in ipairs(M.get_workspace_setup_scripts(mount)) do
    table.insert(cmds, 'source ' .. vim.fn.shellescape(script))
  end

  return table.concat(cmds, ' && ')
end

function M.get_python_paths(mount)
  local paths = {}

  local patterns = {
    -- ROS 2
    mount .. '/opt/ros/*/lib/python*/site-packages',
    mount .. '/opt/ros/*/local/lib/python*/dist-packages',
    mount .. '/opt/ros/*/local/lib/python*/site-packages',

    -- system Python
    mount .. '/usr/lib/python*/dist-packages',
    mount .. '/usr/lib/python*/site-packages',
    mount .. '/usr/local/lib/python*/dist-packages',
    mount .. '/usr/local/lib/python*/site-packages',
    mount .. '/lib/python*/site-packages',

    -- user-local installs
    mount .. '/home/*/.local/lib/python*/site-packages',

    -- common venv names
    mount .. '/home/*/.venv/lib/python*/site-packages',
    mount .. '/home/*/venv/lib/python*/site-packages',
    mount .. '/home/*/.virtualenvs/*/lib/python*/site-packages',

    -- project-local venvs
    mount .. '/home/*/*/.venv/lib/python*/site-packages',
    mount .. '/home/*/*/venv/lib/python*/site-packages',

    -- ROS 2 workspaces
    mount .. '/home/*/*/install/*/lib/python*/site-packages',
    mount .. '/home/*/*/install/lib/python*/site-packages',
    mount .. '/home/*/*/install/local/lib/python*/dist-packages',
    mount .. '/home/*/*/install/local/lib/python*/site-packages',
    mount .. '/workspace/*/install/*/lib/python*/site-packages',
    mount .. '/workspace/*/install/lib/python*/site-packages',
    mount .. '/workspaces/*/install/*/lib/python*/site-packages',
    mount .. '/workspaces/*/install/lib/python*/site-packages',
  }

  for _, pattern in ipairs(patterns) do
    for _, path in ipairs(glob_dirs(pattern)) do
      table.insert(paths, path)
    end
  end

  return M.uniq_paths(paths)
end

local function apply_env(mount)
  local python_paths = M.get_python_paths(mount)

  vim.g.remote_connect_mount = mount
  vim.env.REMOTE_CONNECT_MOUNT = mount
  vim.env.REMOTE_CONNECT_ROOT = mount

  vim.env.CPATH = M.join_env_paths {
    mount .. '/usr/include',
    mount .. '/usr/local/include',
    vim.env.CPATH or '',
  }

  vim.env.LIBRARY_PATH = M.join_env_paths {
    mount .. '/lib',
    mount .. '/usr/lib',
    mount .. '/usr/local/lib',
    vim.env.LIBRARY_PATH or '',
  }

  vim.env.PKG_CONFIG_PATH = M.join_env_paths {
    mount .. '/usr/lib/pkgconfig',
    mount .. '/usr/share/pkgconfig',
    mount .. '/usr/local/lib/pkgconfig',
    vim.env.PKG_CONFIG_PATH or '',
  }

  vim.env.PYTHONPATH = M.join_env_paths(vim.list_extend(python_paths, {
    vim.env.PYTHONPATH or '',
  }))
end

local function patch_server_defaults(server_name, mount)
  local ok_configs, configs = pcall(require, 'lspconfig.configs')
  if not ok_configs then
    return
  end

  local server = configs[server_name]
  if not server or not server.document_config or not server.document_config.default_config then
    return
  end

  local cfg = server.document_config.default_config
  cfg.cmd_env = vim.tbl_extend('force', cfg.cmd_env or {}, {
    REMOTE_CONNECT_MOUNT = mount,
    CPATH = vim.env.CPATH,
    LIBRARY_PATH = vim.env.LIBRARY_PATH,
    PKG_CONFIG_PATH = vim.env.PKG_CONFIG_PATH,
    PYTHONPATH = vim.env.PYTHONPATH,
  })

  local extra = M.config.lsp.servers[server_name]
  if extra then
    extra(cfg, mount)
  end
end

local function restart_active_clients(mount)
  if not M.config.lsp.restart_active_clients then
    return
  end

  local clients = vim.lsp.get_clients()
  local seen = {}

  for _, client in ipairs(clients) do
    if not seen[client.name] then
      seen[client.name] = true
      patch_server_defaults(client.name, mount)
    end

    vim.schedule(function()
      pcall(vim.cmd, 'LspRestart ' .. client.name)
    end)
  end
end

local function patch_all_known_servers(mount)
  if not lspconfig_available() then
    return
  end

  for server_name, _ in pairs(M.config.lsp.servers) do
    patch_server_defaults(server_name, mount)
  end

  local ok_configs, configs = pcall(require, 'lspconfig.configs')
  if ok_configs then
    for server_name, _ in pairs(configs) do
      patch_server_defaults(server_name, mount)
    end
  end
end

local function apply_lsp_defaults(mount)
  if not M.config.lsp.enabled then
    return
  end

  apply_env(mount)
  patch_all_known_servers(mount)
  restart_active_clients(mount)
end

local function is_mounted(mount)
  if vim.fn.executable 'mountpoint' == 1 then
    local result = vim.system({ 'mountpoint', '-q', mount }):wait()
    return result.code == 0
  end

  local result = vim.system({ 'sh', '-c', 'mount | grep -F -- ' .. vim.fn.shellescape(mount) }, { text = true }):wait()
  return result.code == 0
end

function M.remote_path(remote_path)
  local mount = vim.g.remote_connect_mount
  if not mount or mount == '' then
    return remote_path
  end

  if not remote_path:match '^/' then
    return remote_path
  end

  return mount .. remote_path
end

function M.disconnect()
  local current = M.state.current
  if not current then
    notify('no active remote mount', vim.log.levels.WARN)
    return
  end

  local ok, result = run_system {
    M.config.unmount_cmd[1],
    M.config.unmount_cmd[2],
    current.mount,
  }

  if not ok then
    local err_msg = result.stderr
    if not err_msg or err_msg == '' then
      err_msg = result.stdout
    end
    if not err_msg or err_msg == '' then
      err_msg = 'unknown error'
    end

    notify('unmount failed: ' .. err_msg, vim.log.levels.ERROR)
    return
  end

  M.state.current = nil
  vim.g.remote_connect_mount = nil
  vim.env.REMOTE_CONNECT_MOUNT = nil
  vim.env.REMOTE_CONNECT_ROOT = nil

  notify('disconnected ' .. current.target)
end

function M.connect(target)
  local info, err = parse_target(target)
  if not info then
    notify(err, vim.log.levels.ERROR)
    return
  end

  if vim.fn.executable(M.config.sshfs_bin) ~= 1 then
    notify('sshfs is not installed or not in PATH', vim.log.levels.ERROR)
    return
  end

  local mount = mount_for(info)
  local home = remote_home_for(info)

  if not ensure_dir(mount) then
    notify('failed to create mount dir: ' .. mount, vim.log.levels.ERROR)
    return
  end

  local already_mounted = is_mounted(mount)

  if not already_mounted then
    local password = vim.fn.inputsecret('SSH password for ' .. info.target .. ': ')
    if not password or password == '' then
      notify('connection cancelled', vim.log.levels.WARN)
      return
    end

    local ok, result = run_system({
      M.config.sshfs_bin,
      info.target .. ':/',
      mount,
      '-o',
      'password_stdin,reconnect,follow_symlinks,cache=yes',
      '-o',
      'ssh_command=ssh -o StrictHostKeyChecking=accept-new',
    }, password .. '\n')

    if not ok then
      local err_msg = result.stderr
      if not err_msg or err_msg == '' then
        err_msg = result.stdout
      end
      if not err_msg or err_msg == '' then
        err_msg = 'unknown error'
      end

      notify('sshfs failed: ' .. err_msg, vim.log.levels.ERROR)
      return
    end
  else
    notify('mount already exists, skipping remount: ' .. mount, vim.log.levels.INFO)
  end

  if not path_exists(home) then
    notify('mounted successfully, but remote home was not found: ' .. home, vim.log.levels.WARN)
    home = mount
  end

  M.state.current = {
    target = info.target,
    user = info.user,
    host = info.host,
    mount = mount,
    home = home,
  }

  if M.config.set_global_cwd then
    vim.cmd('cd ' .. shellescape(home))
  else
    vim.cmd('lcd ' .. shellescape(home))
  end

  if M.config.open_on_connect then
    vim.cmd('edit ' .. shellescape(home))
  end

  apply_lsp_defaults(mount)

  if already_mounted then
    notify('reused existing mount ' .. mount .. ' for ' .. info.target)
  else
    notify('connected ' .. info.target .. ' -> ' .. mount)
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})

  vim.api.nvim_create_user_command('Connect', function(params)
    M.connect(params.args)
  end, {
    nargs = 1,
    complete = 'file',
    desc = 'sshfs mount remote root and enter mounted remote home',
  })

  vim.api.nvim_create_user_command('Disconnect', function()
    M.disconnect()
  end, {
    nargs = 0,
    desc = 'unmount current remote sshfs mount',
  })

  if M.config.auto_unmount_on_exit then
    vim.api.nvim_create_autocmd('VimLeavePre', {
      callback = function()
        if M.state.current then
          pcall(M.disconnect)
        end
      end,
    })
  end
end

return M
