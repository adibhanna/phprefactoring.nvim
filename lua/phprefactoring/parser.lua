-- Parser module for phprefactoring.nvim
-- Integrates with Treesitter for accurate PHP code analysis

local config = require('phprefactoring.config')

local M = {}

-- Cache for parsed data
local cache = {
    current_node = nil,
    current_scope = nil,
    symbols = {},
    references = {},
}

-- Initialize the parser
function M.setup()
    -- `vim.treesitter.language.add('php')` signals availability differently
    -- across Neovim versions:
    --   0.9/0.10 return nothing on success and raise on a missing parser.
    --   0.11+    return `true` on success and `nil, err` on a missing parser.
    -- pcall absorbs the old-style raise; checking the error slot (always nil on
    -- success, non-nil on failure) works for both shapes.
    local ok, _, err = pcall(vim.treesitter.language.add, 'php')
    M.has_treesitter = ok and err == nil
end

-- Get current treesitter node at cursor
function M.get_current_node()
    if not M.has_treesitter then
        return nil
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local row, col = cursor[1] - 1, cursor[2] -- Convert to 0-based indexing

    local parser = vim.treesitter.get_parser(0, 'php')
    if not parser then
        return nil
    end

    local tree = parser:parse()[1]
    if not tree then
        return nil
    end

    local root = tree:root()
    local node = root:descendant_for_range(row, col, row, col)

    cache.current_node = node
    return node
end

-- Get the scope (function, class, etc.) containing the cursor
function M.get_current_scope()
    local node = M.get_current_node()
    if not node then
        return nil
    end

    local current = node
    while current do
        local type = current:type()
        if vim.tbl_contains({
                'function_definition',
                'method_declaration',
                'class_declaration',
                'interface_declaration',
                'trait_declaration'
            }, type) then
            cache.current_scope = current
            return current
        end
        current = current:parent()
    end

    return nil
end

-- Check if cursor is in a function signature
function M.is_in_function_signature()
    local node = M.get_current_node()
    if not node then
        return false
    end

    local current = node
    while current do
        local type = current:type()
        if vim.tbl_contains({
                'formal_parameters',
                'function_definition',
                'method_declaration'
            }, type) then
            return true
        end
        if vim.tbl_contains({
                'compound_statement',
                'expression_statement'
            }, type) then
            return false
        end
        current = current:parent()
    end

    return false
end

-- Check if cursor is in a class
function M.is_in_class()
    local node = M.get_current_node()
    if not node then
        return false
    end

    local current = node
    while current do
        if current:type() == 'class_declaration' then
            return true
        end
        current = current:parent()
    end

    return false
end

-- Check if cursor is in a function/method
function M.is_in_function()
    local node = M.get_current_node()
    if not node then
        return false
    end

    local current = node
    while current do
        local type = current:type()
        if vim.tbl_contains({ 'function_definition', 'method_declaration' }, type) then
            return true
        end
        current = current:parent()
    end

    return false
end

-- Check if current expression can be extracted
function M.is_extractable_expression()
    local node = M.get_current_node()
    if not node then
        return false
    end

    local extractable_types = {
        'variable_name',
        'member_access_expression',
        'scoped_call_expression',
        'function_call_expression',
        'binary_expression',
        'unary_expression',
        'conditional_expression',
        'string',
        'integer',
        'float',
        'array_creation_expression',
        'object_creation_expression'
    }

    return vim.tbl_contains(extractable_types, node:type())
end

-- Check if current value can be extracted to constant
function M.is_extractable_value()
    local node = M.get_current_node()
    if not node then
        return false
    end

    local value_types = {
        'string',
        'integer',
        'float',
        'true',
        'false',
        'null'
    }

    return vim.tbl_contains(value_types, node:type())
end

-- Check if class has parent class
function M.has_parent_class()
    if not M.is_in_class() then
        return false
    end

    -- Use regex-based approach for reliability
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1

    -- Find the class declaration containing the cursor
    local class_found = false
    for i, line in ipairs(lines) do
        local line_idx = i - 1
        if line:match('^%s*class%s+') then
            -- Check if this class contains the cursor
            if line_idx <= cursor_line then
                -- Find the end of this class to see if cursor is within it
                local brace_count = 0
                local found_opening = false
                local class_end = nil

                for j = i, #lines do
                    local check_line = lines[j]
                    for char in check_line:gmatch('.') do
                        if char == '{' then
                            brace_count = brace_count + 1
                            found_opening = true
                        elseif char == '}' then
                            brace_count = brace_count - 1
                            if brace_count == 0 and found_opening then
                                class_end = j - 1
                                break
                            end
                        end
                    end
                    if class_end then break end
                end

                if class_end and cursor_line <= class_end then
                    -- This class contains the cursor, check if it extends another class
                    return line:match('extends%s+[%w_\\]+') ~= nil
                end
            end
        end
    end

    return false
end

-- Get selected text range
function M.get_visual_selection()
    -- Check if we're actually in visual mode or have a recent visual selection
    local mode = vim.fn.mode()
    local has_visual = mode:match('[vV]') or vim.fn.getpos("'<")[2] ~= vim.fn.getpos("'>")[2] or
        vim.fn.getpos("'<")[3] ~= vim.fn.getpos("'>")[3]

    if not has_visual then
        return nil, nil, nil
    end

    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")

    local start_row = start_pos[2] - 1
    local start_col = start_pos[3] - 1
    local end_row = end_pos[2] - 1
    local end_col = end_pos[3] - 1 -- Make this consistent - convert to 0-based too

    -- Validate positions
    if start_row < 0 or end_row < 0 or start_col < 0 or end_col < 0 then
        return nil, nil, nil
    end

    local lines = vim.api.nvim_buf_get_lines(0, start_row, end_row + 1, false)

    if #lines == 0 then
        return nil, nil, nil
    end

    -- Handle single line selection
    if #lines == 1 then
        lines[1] = lines[1]:sub(start_col + 1, end_col + 1) -- Adjust for 0-based end_col
    else
        -- Handle multi-line selection
        lines[1] = lines[1]:sub(start_col + 1)
        lines[#lines] = lines[#lines]:sub(1, end_col + 1) -- Adjust for 0-based end_col
    end

    return lines, { start_row, start_col }, { end_row, end_col }
end

-- Get text of a treesitter node
function M.get_node_text(node)
    if not node then
        return ""
    end

    local start_row, start_col, end_row, end_col = node:range()
    local lines = vim.api.nvim_buf_get_lines(0, start_row, end_row + 1, false)

    if #lines == 0 then
        return ""
    end

    if #lines == 1 then
        return lines[1]:sub(start_col + 1, end_col)
    else
        lines[1] = lines[1]:sub(start_col + 1)
        lines[#lines] = lines[#lines]:sub(1, end_col)
        return table.concat(lines, '\n')
    end
end

-- Find variable declarations in scope
function M.find_variables_in_scope()
    local scope = M.get_current_scope()
    if not scope then
        return {}
    end

    local variables = {}

    -- Traverse the scope looking for variable declarations
    local function traverse(node)
        if node:type() == 'assignment_expression' then
            local left = node:child(0)
            if left and left:type() == 'variable_name' then
                local var_name = M.get_node_text(left)
                variables[var_name] = {
                    node = left,
                    declaration = node
                }
            end
        end

        for child in node:iter_children() do
            traverse(child)
        end
    end

    traverse(scope)
    return variables
end

-- Clear cache
function M.clear_cache()
    cache = {
        current_node = nil,
        current_scope = nil,
        symbols = {},
        references = {},
    }
end

return M
