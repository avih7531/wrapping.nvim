local M = {}

local utils = require("wrapping.utils")
local treesitter = require("wrapping.treesitter")

local OPTION_DEFAULTS = {
    -- Existing options
    set_nvim_opt_defaults = true,
    softener = {
        default = 1.0,
        gitcommit = false,
    },
    create_commands = true,
    create_keymaps = true,
    auto_set_mode_heuristically = true,
    auto_set_mode_filetype_allowlist = {
        "asciidoc",
        "gitcommit",
        "help",
        "latex",
        "mail",
        "markdown",
        "rst",
        "tex",
        "text",
        "typst",
    },
    auto_set_mode_filetype_denylist = {},
    excluded_treesitter_queries = {
        markdown = {
            "(fenced_code_block) @markdown1",
            "(atx_heading) @markdown2",
            "(pipe_table_header) @markdown3",
            "(pipe_table_delimiter_row) @markdown4",
            "(pipe_table_row) @markdown5",
        },
    },
    notify_on_switch = true,
    log_path = utils.get_log_path(),
    -- New configuration options for indicators
    indicator_icon = "󱞩",
    indicator_color = "cyan",
    indicator_position = "beginning",
}

local VERY_LONG_TEXTWIDTH_FOR_SOFT = 999999
local opts

local function log(str)
    if opts.log_path ~= nil then
        local bufname = vim.fn.bufname()
        local datetime = os.date("%FT%H:%m:%S%z")

        if bufname == nil or bufname == "" then
            bufname = "Unknown of filetype "
                .. vim.api.nvim_get_option_value("filetype", { buf = 0 })
        end

        local fp = assert(io.open(opts.log_path, "a"))
        fp:write("[" .. datetime .. "] " .. bufname .. ": " .. str .. "\n")
        fp:close()
    end
end

local function soft_wrap_mode_quiet()
    if vim.b.wrapmode == "soft" then
        return false
    end

    vim.b.hard_textwidth =
        vim.api.nvim_get_option_value("textwidth", { buf = 0 })

    vim.api.nvim_set_option_value(
        "textwidth",
        VERY_LONG_TEXTWIDTH_FOR_SOFT,
        { buf = 0 }
    )

    vim.api.nvim_set_option_value("wrap", true, { win = 0 })

    vim.keymap.set(
        "n",
        "<Up>",
        "g<Up>",
        { buffer = 0, desc = "Move up one display line" }
    )
    vim.keymap.set(
        "n",
        "<Down>",
        "g<Down>",
        { buffer = 0, desc = "Move down one display line" }
    )

    vim.b.wrap_mappings_initialized = true
    vim.b.wrapmode = "soft"

    return true
end

local function hard_wrap_mode_quiet()
    if vim.b.wrapmode == "hard" then
        return false
    end

    if vim.b.hard_textwidth then
        vim.api.nvim_set_option_value(
            "textwidth",
            vim.b.hard_textwidth,
            { buf = 0 }
        )
        vim.b.hard_textwidth = nil
    end

    vim.api.nvim_set_option_value("wrap", false, { win = 0 })

    if vim.b.wrap_mappings_initialized == true then
        vim.keymap.del("n", "<Up>", { buffer = 0 })
        vim.keymap.del("n", "<Down>", { buffer = 0 })
    end

    vim.b.wrap_mappings_initialized = false
    vim.b.wrapmode = "hard"

    return true
end

M.soft_wrap_mode = function()
    if soft_wrap_mode_quiet() and opts.notify_on_switch then
        vim.notify("Soft wrap mode.")
    end
end

M.hard_wrap_mode = function()
    if hard_wrap_mode_quiet() and opts.notify_on_switch then
        vim.notify("Hard wrap mode.")
    end
end

M.toggle_wrap_mode = function()
    if M.get_current_mode() == "hard" then
        M.soft_wrap_mode()
    else
        M.hard_wrap_mode()
    end
end

local function get_softener()
    local filetype = vim.api.nvim_get_option_value("filetype", { buf = 0 })
    local value = vim.tbl_get(opts.softener, filetype)

    if value ~= nil then
        return value
    else
        return opts.softener.default
    end
end

local function likely_nontextual_language()
    for _, client in pairs(vim.lsp.buf_get_clients(0)) do
        if client.definitionProvider or client.signatureHelpProvider then
            return true
        end
    end

    return false
end

local function likely_textwidth_set_deliberately()
    local textwidth_global = vim.api.nvim_get_option("textwidth")
    local textwidth_buffer =
        vim.api.nvim_get_option_value("textwidth", { buf = 0 })

    log(
        "Textwidths: global="
            .. textwidth_global
            .. ", buffer="
            .. textwidth_buffer
    )

    if
        textwidth_global ~= textwidth_buffer
        and textwidth_buffer ~= VERY_LONG_TEXTWIDTH_FOR_SOFT
    then
        return true
    end

    return false
end

local function get_excluded_treesitter()
    local filetype = vim.api.nvim_get_option_value("filetype", { buf = 0 })
    local exclusions = opts.excluded_treesitter_queries[filetype]

    local tree_lines = 0
    local tree_chars = 0

    if exclusions then
        for _, exclusion in pairs(exclusions) do
            local lines, chars =
                treesitter.count_lines_of_query(filetype, exclusion)
            tree_lines = tree_lines + lines
            tree_chars = tree_chars + chars
        end
    end

    return tree_lines, tree_chars
end

local function auto_heuristic()
    log("Testing for auto heuristic...")

    if vim.b.wrapmode ~= nil then
        log("wrapmode already set for this buffer")
        return
    end

    local filetype = vim.api.nvim_get_option_value("filetype", { buf = 0 })
    log("Filetype: " .. filetype)

    if vim.tbl_contains(opts.auto_set_mode_filetype_denylist, filetype) then
        log("File in denylist")
        return
    elseif
        vim.tbl_count(opts.auto_set_mode_filetype_denylist) > 0
        or vim.tbl_contains(opts.auto_set_mode_filetype_allowlist, filetype)
    then
        log("About to set mode heuristically")
        M.set_mode_heuristically()
    else
        log("Skipping heuristic mode because of allow/denylist")
    end
end

M.set_mode_heuristically = function()
    local buftype = vim.api.nvim_get_option_value("buftype", { buf = 0 })

    if buftype ~= "" then
        log("Buftype is " .. buftype .. ", ignoring")
        return
    end

    local softener = get_softener()
    log("Softener is " .. vim.inspect(softener))

    if type(softener) == "function" then
        softener = softener()
    end

    if softener == true then
        log("Softener function forcing soft mode")
        M.soft_wrap_mode()
        return
    elseif softener == false then
        log("Softener function forcing hard mode")
        M.hard_wrap_mode()
        return
    end

    if likely_nontextual_language() then
        log("Likely this is a nontextual language, ignoring")
        return
    end

    if likely_textwidth_set_deliberately() then
        log("Likely that textwidth was set deliberately, forcing hard mode")
        M.hard_wrap_mode()
        return
    end

    local hard_textwidth_for_comparison

    if vim.b.hard_textwidth then
        hard_textwidth_for_comparison = vim.b.hard_textwidth
        log("Previous hard textwidth=" .. hard_textwidth_for_comparison)
    else
        hard_textwidth_for_comparison =
            vim.api.nvim_get_option_value("textwidth", { buf = 0 })
        log("Option textwidth=" .. hard_textwidth_for_comparison)
    end

    if hard_textwidth_for_comparison == 0 then
        hard_textwidth_for_comparison = VERY_LONG_TEXTWIDTH_FOR_SOFT
        log("Forcing very long textwidth")
    end

    local tree_lines, tree_chars = get_excluded_treesitter()
    local blank_lines = utils.count_blank_lines()

    log(
        "Exclusions: "
            .. tree_lines
            .. " TS lines; "
            .. tree_chars
            .. " TS chars; "
            .. blank_lines
            .. " blank lines"
    )

    local file_size = utils.get_buf_size() - tree_chars
    local average_line_length = file_size
        / (vim.fn.line("$") - blank_lines - tree_lines)

    log("Average line length: " .. vim.inspect(average_line_length))

    if (average_line_length * softener) < hard_textwidth_for_comparison then
        log("Selecting hard wrap mode")
        M.hard_wrap_mode()
    else
        log("Selecting soft wrap mode")
        M.soft_wrap_mode()
    end
end

M.get_current_mode = function()
    if vim.b.wrapmode then
        return vim.b.wrapmode
    else
        return nil
    end
end

M.setup = function(o)
    opts = vim.tbl_deep_extend("force", OPTION_DEFAULTS, o or {})

    log("setup() with o=" .. vim.inspect(o))

    vim.validate({
        set_nvim_opt_defaults = { opts.set_nvim_opt_defaults, "boolean" },
        softener = { opts.softener, "table" },
        create_commands = { opts.create_commands, "boolean" },
        create_keymaps = { opts.create_commands, "boolean" },
        auto_set_mode_heuristically = {
            opts.auto_set_mode_heuristically,
            "boolean",
        },
        auto_set_mode_filetype_allowlist = {
            opts.auto_set_mode_filetype_allowlist,
            "table",
        },
        auto_set_mode_filetype_denylist = {
            opts.auto_set_mode_filetype_denylist,
            "table",
        },
        notify_on_switch = { opts.notify_on_switch, "boolean" },
        log_path = { opts.log_path, "string" },
        indicator_icon = { opts.indicator_icon, "string" },
        indicator_color = { opts.indicator_color, "string" },
        indicator_position = { opts.indicator_position, "string", true }
    })

    if
        vim.tbl_count(opts.auto_set_mode_filetype_allowlist) > 0
        and vim.tbl_count(opts.auto_set_mode_filetype_denylist) > 0
    then
        vim.notify(
            "wrapping.lua: both auto_set_mode_filetype_allowlist and auto_set_mode_filetype_denylist have entries; "
                .. "they are mutually exclusive and only one must be set.",
            vim.log.levels.ERROR
        )
        return
    end

    if opts.set_nvim_opt_defaults then
        vim.api.nvim_set_option_value("linebreak", true, {})
        vim.api.nvim_set_option_value("wrap", false, {})
    end

    if opts.create_commands then
        vim.api.nvim_create_user_command("SoftWrapMode", function()
            M.soft_wrap_mode()
        end, {
            desc = "Set wrap mode to 'soft'",
        })
        vim.api.nvim_create_user_command("HardWrapMode", function()
            M.hard_wrap_mode()
        end, {
            desc = "Set wrap mode to 'hard'",
        })
        vim.api.nvim_create_user_command("ToggleWrapMode", function()
            M.toggle_wrap_mode()
        end, {
            desc = "Toggle wrap mode",
        })
        vim.api.nvim_create_user_command("WrappingOpenLog", function()
            vim.cmd(":split " .. opts.log_path)
            vim.api.nvim_set_option_value("readonly", true, { buf = 0 })
            vim.cmd(":norm G")
        end, {
            desc = "Toggle wrap mode",
        })
    end

    if opts.create_keymaps then
        vim.keymap.set("n", "[ow", function()
            M.soft_wrap_mode()
        end, { desc = "Soft wrap mode", unique = true })
        vim.keymap.set("n", "]ow", function()
            M.hard_wrap_mode()
        end, { desc = "Hard wrap mode", unique = true })
        vim.keymap.set("n", "yow", function()
            M.toggle_wrap_mode()
        end, { desc = "Toggle wrap mode", unique = true })
    end

    if opts.auto_set_mode_heuristically then
        vim.api.nvim_create_autocmd("BufWinEnter", {
            group = vim.api.nvim_create_augroup("wrapping", {}),
            callback = auto_heuristic,
        })
    end

    -- Setup indicator highlighting
    local highlight_cmd = string.format(
        "highlight WrapIndicator guifg=%s",
        opts.indicator_color
    )
    vim.cmd(highlight_cmd)

    -- Insert indicator icon at line wrap positions
    vim.api.nvim_exec([[
        augroup wrapping_nvim_indicator
            autocmd!
            autocmd TextChangedI * lua require('wrapping.indicator').add()
        augroup END
    ]], false)
end

if vim.fn.has("nvim-0.8.0") ~= 1 then
    vim.notify(
        "WARNING: wrapping.nvim is only compatible with NeoVim 0.8+",
        vim.log.levels.WARN
    )

    return
end

return M
