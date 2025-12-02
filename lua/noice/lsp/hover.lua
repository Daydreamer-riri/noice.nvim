local require = require("noice.util.lazy")

local Config = require("noice.config")
local Docs = require("noice.lsp.docs")
local Format = require("noice.lsp.format")
local Util = require("noice.util")

local M = {}

---@type lsp.MultiHandler
function M.on_hover(results, ctx)
  local bufnr = assert(ctx.bufnr)
  if vim.api.nvim_get_current_buf() ~= bufnr then
    -- Ignore result since buffer changed. This happens for slow language servers.
    return
  end

  -- Filter errors from results
  local results1 = {} --- @type table<integer,lsp.Hover>
  local can_increase_verbosity = false
  local can_decrease_verbosity = false
  local verbosity_client = nil

  for client_id, resp in pairs(results) do
    local err, result = resp.err, resp.result
    if err then
      vim.lsp.log.error(err.code, err.message)
    elseif result and result.contents then
      if result.canIncreaseVerbosity then
        can_increase_verbosity = true
      end
      if result.canDecreaseVerbosity then
        can_decrease_verbosity = true
      end
      if (result.canIncreaseVerbosity or result.canDecreaseVerbosity) and not verbosity_client then
        verbosity_client = vim.lsp.get_client_by_id(client_id)
      end
      -- Make sure the response is not empty
      -- Five response shapes:
      -- - MarkupContent: { kind="markdown", value="doc" }
      -- - MarkedString-string: "doc"
      -- - MarkedString-pair: { language="c", value="doc" }
      -- - MarkedString[]-string: { "doc1", ... }
      -- - MarkedString[]-pair: { { language="c", value="doc1" }, ... }
      if
        (
          type(result.contents) == "table"
          and #(
              vim.tbl_get(result.contents, "value") -- MarkupContent or MarkedString-pair
              or vim.tbl_get(result.contents, 1, "value") -- MarkedString[]-pair
              or result.contents[1] -- MarkedString[]-string
              or ""
            )
            > 0
        )
        or (
          type(result.contents) == "string" and #result.contents > 0 -- MarkedString-string
        )
      then
        results1[client_id] = result
      end
    end
  end

  if vim.tbl_isempty(results1) then
    if Config.options.lsp.hover.silent ~= true then
      vim.notify("No information available")
    end
    return
  end

  local contents = {} --- @type MarkupContents[]

  -- local nresults = #vim.tbl_keys(results1)

  for _client_id, result in pairs(results1) do
    contents[#contents + 1] = result.contents
    contents[#contents + 1] = "---"
  end

  -- Remove last linebreak ('---')
  contents[#contents] = nil

  if can_increase_verbosity or can_decrease_verbosity then
    contents[#contents + 1] = "---"

    if can_increase_verbosity then
      contents[#contents + 1] = "_Press_ `+` _to increase verbosity._"
    end
    if can_decrease_verbosity then
      contents[#contents + 1] = "_Press_ `-` _to decrease verbosity._"
    end
  end

  local message = Docs.get("hover")

  if not message:focus() then
    Format.format(message, contents, { ft = vim.bo[ctx.bufnr].filetype })
    if message:is_empty() then
      if Config.options.lsp.hover.silent ~= true then
        vim.notify("No information available")
      end
      return
    end
    Docs.show(message)
  end

  if (can_increase_verbosity or can_decrease_verbosity) and verbosity_client then
    local params = require("noice.lsp").make_position_params()(verbosity_client)
    vim.schedule(function()
      local function set_keymap(key, delta, desc)
        local original_keymap = vim.fn.maparg(key, "n", false, true).rhs
        vim.keymap.set("n", key, function()
          Docs.hide(message)
          ---@diagnostic disable-next-line: inject-field
          params.context = {
            verbosityRequest = {
              verbosityDelta = delta,
            },
          }
          vim.lsp.buf_request_all(0, "textDocument/hover", params, M.on_hover)
        end, { silent = true, desc = desc })

        local function clean()
          if original_keymap then
            vim.keymap.set("n", key, original_keymap, { silent = true, desc = desc })
          else
            pcall(vim.keymap.del, "n", key)
          end
        end

        message:add_remove_listener(clean)
      end
      if can_increase_verbosity then
        set_keymap("+", 1, "Increase Verbosity")
      end
      if can_decrease_verbosity then
        set_keymap("-", -1, "Decrease Verbosity")
      end
    end)
  end
end

M.on_hover = Util.protect(M.on_hover)

return M
