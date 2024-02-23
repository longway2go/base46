local M = {}
local g = vim.g
local config = require("core.utils").load_config()

-- 获取当前正在执行的Lua代码所在的目录路径
-- 如：当前代码位于：~/.local/share/nvim/lazy/base46/lua/base46/init.lua
-- 则：base46_path="~/.local/share/nvim/lazy/base46/lua"
local base46_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

-- [[
-- M.get_theme_tb()，用于获取指定主题类型的配置表格。
-- 优先返回默认主题
-- 如果默认主题不存在，则使用用户自定义主题
-- 否则，报错："No such theme!"
-- 还需要实际运行、调试下才好
-- ]]
M.get_theme_tb = function(type)
  -- default_path: 默认主题文件路径。具体数值是多少，不知道？
  local default_path = "base46.themes." .. g.nvchad_theme

  -- user_path: 用户自定义主题文件路径
  local user_path = "custom.themes." .. g.nvchad_theme

  -- pcall()以受保护的方式执行代码
  -- 使用pcall()尝试加载默认主题文件
  local present1, default_theme = pcall(require, default_path)
  -- 使用pcall()尝试加载用户自定义主题文件
  local present2, user_theme = pcall(require, user_path)

  -- 优先返回默认主题
  -- 如果默认主题不存在，则使用用户自定义主题
  -- 否则，报错："No such theme!"
  if present1 then
    return default_theme[type]
  elseif present2 then
    return user_theme[type]
  else
    error "No such theme!"
  end
end

M.merge_tb = function(...)
  return vim.tbl_deep_extend("force", ...)
end

local change_hex_lightness = require("base46.colors").change_hex_lightness

-- turns color var names in hl_override/hl_add to actual colors
-- hl_add = { abc = { bg = "one_bg" }} -> bg = colors.one_bg
M.turn_str_to_color = function(tb)
  local colors = M.get_theme_tb "base_30"
  local copy = vim.deepcopy(tb)

  for _, hlgroups in pairs(copy) do
    for opt, val in pairs(hlgroups) do
      if opt == "fg" or opt == "bg" or opt == "sp" then
        if not (type(val) == "string" and val:sub(1, 1) == "#" or val == "none" or val == "NONE") then
          hlgroups[opt] = type(val) == "table" and change_hex_lightness(colors[val[1]], val[2]) or colors[val]
        end
      end
    end
  end

  return copy
end

M.extend_default_hl = function(highlights)
  local polish_hl = M.get_theme_tb "polish_hl"
  local add_hl = M.get_theme_tb "add_hl"

  -- polish themes
  if polish_hl then
    for key, value in pairs(polish_hl) do
      if highlights[key] then
        highlights[key] = M.merge_tb(highlights[key], value)
      end
    end
  end

  -- add new hl
  if add_hl then
    for key, value in pairs(add_hl) do
      if not highlights[key] and type(value) == "table" then
        highlights[key] = value
      end
    end
  end

  -- transparency
  if vim.g.transparency then
    local glassy = require "base46.glassy"

    for key, value in pairs(glassy) do
      if highlights[key] then
        highlights[key] = M.merge_tb(highlights[key], value)
      end
    end
  end

  if config.ui.hl_override then
    local overriden_hl = M.turn_str_to_color(config.ui.hl_override)

    for key, value in pairs(overriden_hl) do
      if highlights[key] then
        highlights[key] = M.merge_tb(highlights[key], value)
      end
    end
  end
end

-- 根据给定的主题名，返回对应的高亮配置方案，以表的形式
M.load_highlight = function(group, is_extended)
  local str = is_extended and "extended_" or ""

  -- 拼装并加载特定lua模块
  group = require("base46." .. str .. "integrations." .. group)

  -- 返回对应主题表
  M.extend_default_hl(group)
  return group
end

-- convert table into string
M.table_to_str = function(tb)
  local result = ""

  for hlgroupName, hlgroup_vals in pairs(tb) do
    local hlname = "'" .. hlgroupName .. "',"
    local opts = ""

    for optName, optVal in pairs(hlgroup_vals) do
      local valueInStr = ((type(optVal)) == "boolean" or type(optVal) == "number") and tostring(optVal)
        or '"' .. optVal .. '"'
      opts = opts .. optName .. "=" .. valueInStr .. ","
    end

    result = result .. "vim.api.nvim_set_hl(0," .. hlname .. "{" .. opts .. "})"
  end

  return result
end

-- 将tb转为字符串，写入到`vim.g.base46_cache .. filename`所对应的文件中
M.saveStr_to_cache = function(filename, tb)
  -- Thanks to https://github.com/nullchilly and https://github.com/EdenEast/nightfox.nvim
  -- It helped me understand string.dump stuff

  local bg_opt = "vim.opt.bg='" .. M.get_theme_tb "type" .. "'"
  local defaults_cond = filename == "defaults" and bg_opt or ""

  local lines = "return string.dump(function()" .. defaults_cond .. M.table_to_str(tb) .. "end, true)"
  local file = io.open(vim.g.base46_cache .. filename, "wb")

  if file then
    file:write(loadstring(lines)())
    file:close()
  end
end

M.compile = function()
  -- vim.g.base46_cache缓存了最近使用的Base46编码/解码结果，以便提高性能。
  -- vim.g.base46_cache是一个文件夹,位于~/.config/nvim/plugins/base46目录下
  if not vim.loop.fs_stat(vim.g.base46_cache) then
    -- 若vim.g.base46_cache缓存目录不存在，则创建
    vim.fn.mkdir(vim.g.base46_cache, "p")
  end

  -- All integration modules, each file returns a table
  -- hl_files="~/.local/share/nvim/lazy/base46/lua/integrations" --> 好像不对的
  -- hl_files="~/.local/share/nvim/lazy/base46/lua/base46/integrations" --> 猜测是这个，有待确定
  -- hl_files目录下包含多个文件，每个文件负责定义特定语言或主题的高亮配置
  local hl_files = base46_path .. "/integrations"

  -- 遍历文件
  -- vim.fn.readdir()用于读取给定目录中的所有文件名
  for _, file in ipairs(vim.fn.readdir(hl_files)) do
    -- skip caching some files
    if file ~= "statusline" or file ~= "treesitter" then
      -- 跳过statusline.lua和treesitter.lua文件

      -- 获取文件名
      -- 从file的完整路径中只提取到文件名，去除路径部分
      local filename = vim.fn.fnamemodify(file, ":r")

      -- 加载并缓存高亮配置
      -- M.load_highlight(filename)：加载指定文件中的高亮配置，返回一个包含高亮定义的表。
      -- M.saveStr_to_cache(filename, ...)：将加载的配置存储到缓存中，以便后续快速访问。
      M.saveStr_to_cache(filename, M.load_highlight(filename))
    end
  end

  -- 获取自定义配置列表
  -- 从NvChad配置中获取名为extended_integrations的值
  -- look for custom cached highlight files
  local extended_integrations = config.ui.extended_integrations

  if extended_integrations then
    -- 遍历并缓存自定义配置
    for _, filename in ipairs(extended_integrations) do

      M.saveStr_to_cache(filename, M.load_highlight(filename, true))
    end
  end
end

M.load_all_highlights = function()
  require("plenary.reload").reload_module "base46"
  M.compile()

  for _, file in ipairs(vim.fn.readdir(vim.g.base46_cache)) do
    dofile(vim.g.base46_cache .. file)
  end
end

M.override_theme = function(default_theme, theme_name)
  local changed_themes = config.ui.changed_themes
  return M.merge_tb(default_theme, changed_themes.all or {}, changed_themes[theme_name] or {})
end

M.toggle_theme = function()
  local themes = config.ui.theme_toggle
  local theme1 = themes[1]
  local theme2 = themes[2]

  if g.nvchad_theme ~= theme1 and g.nvchad_theme ~= theme2 then
    vim.notify "Set your current theme to one of those mentioned in the theme_toggle table (chadrc)"
    return
  end

  if g.nvchad_theme == theme1 then
    g.toggle_theme_icon = "   "
    vim.g.nvchad_theme = theme2
    require("nvchad.utils").replace_word('theme = "' .. theme1, 'theme = "' .. theme2)
  else
    vim.g.nvchad_theme = theme1
    g.toggle_theme_icon = "   "
    require("nvchad.utils").replace_word('theme = "' .. theme2, 'theme = "' .. theme1)
  end

  M.load_all_highlights()
end

M.toggle_transparency = function()
  g.transparency = not g.transparency
  M.load_all_highlights()

  -- write transparency value to chadrc
  local old_data = "transparency = " .. tostring(config.ui.transparency)
  local new_data = "transparency = " .. tostring(g.transparency)

  require("nvchad.utils").replace_word(old_data, new_data)
end

return M
