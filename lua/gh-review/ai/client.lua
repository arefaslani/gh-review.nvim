local M = {}

-- ---------------------------------------------------------------------------
-- Streaming request (SSE) — uses vim.fn.jobstart + curl
-- vim.system() does NOT stream; only jobstart() with stdout_buffered=false does.
-- ---------------------------------------------------------------------------

--- Resolve and validate the API key from opts.
--- Priority: opts.api_key (direct) > env var named by opts.api_key_env.
--- Trims whitespace to prevent "invalid x-api-key" errors from stray newlines.
--- @param opts table
--- @return string|nil key, string|nil err
local function resolve_key(opts)
  local key = opts.api_key
    or vim.env[opts.api_key_env or "ANTHROPIC_API_KEY"]
  if not key or key == "" then
    return nil, "API key not set. Export it in your shell or add `api_key = '...'` to opts.ai"
  end
  -- Trim all leading/trailing whitespace (env vars can have a trailing newline)
  key = key:gsub("^%s+", ""):gsub("%s+$", "")
  if key == "" then
    return nil, "API key is blank after trimming whitespace"
  end
  return key, nil
end

--- Build curl args and request body for the given opts and mode.
--- Supports three formats:
---   "anthropic" (default): POST to base_url, x-api-key auth, anthropic-version header
---   "bedrock": POST to {base_url}/model/{model}/invoke[-with-response-stream],
---              Authorization: Bearer auth, anthropic_version in body
---   "openai": POST to base_url, Authorization: Bearer auth, system as first message,
---             tools converted to OpenAI function-calling schema
--- @param opts table
--- @param api_key string
--- @param streaming boolean
--- @param tmpfile string  path to the JSON body temp file
--- @return string[] curl_args, string url
local function build_curl_args(opts, api_key, streaming, tmpfile)
  local model = opts.model or "claude-haiku-4-5-20251001"
  local format = opts.format or "anthropic"

  local body = {
    max_tokens = opts.max_tokens or 4096,
    messages   = opts.messages,
  }
  -- system and tools are format-specific; set Anthropic defaults here,
  -- overridden below for other formats.
  if opts.system then
    -- Prompt caching: for the Anthropic format, wrap system in a content-block
    -- array with cache_control so repeated calls within 5 min pay ~90 % less.
    if format == "anthropic" then
      local sys_text = opts.system
      if type(sys_text) == "string" then
        body.system = {
          { type = "text", text = sys_text, cache_control = { type = "ephemeral" } },
        }
      else
        -- Already an array (caller built it manually) — pass through
        body.system = sys_text
      end
    else
      body.system = opts.system
    end
  end
  if opts.tools and format ~= "openai" then
    body.tools       = opts.tools
    body.tool_choice = opts.tool_choice or { type = "any" }
  end

  local url
  local headers = { "-H", "Content-Type: application/json" }

  if format == "bedrock" then
    -- Bedrock format: model in URL, anthropic_version in body, Bearer auth
    local suffix = streaming and "/invoke-with-response-stream" or "/invoke"
    local base = (opts.base_url or "https://bedrock-runtime.us-east-1.amazonaws.com")
    url = base .. "/model/" .. model .. suffix
    body.anthropic_version = "bedrock-2023-05-31"
    vim.list_extend(headers, { "-H", "Authorization: Bearer " .. api_key })
  elseif format == "openai" then
    -- OpenAI-compatible format: model in body, Bearer auth, system as first message
    url = opts.base_url or "https://api.openai.com/v1/chat/completions"
    -- System prompt must live inside the messages array, not as a separate field
    local messages = {}
    if opts.system then
      table.insert(messages, { role = "system", content = opts.system })
    end
    for _, m in ipairs(opts.messages or {}) do
      table.insert(messages, m)
    end
    body.system   = nil
    body.messages = messages
    body.model    = model
    if streaming then body.stream = true end
    -- Convert tools from Anthropic input_schema format to OpenAI function-calling format
    if opts.tools then
      local oai_tools = {}
      for _, t in ipairs(opts.tools) do
        table.insert(oai_tools, {
          type = "function",
          ["function"] = {
            name        = t.name,
            description = t.description,
            parameters  = t.input_schema,
          },
        })
      end
      body.tools       = oai_tools
      body.tool_choice = opts.tool_choice or "required"
    end
    vim.list_extend(headers, { "-H", "Authorization: Bearer " .. api_key })
  else
    -- Standard Anthropic format: model + stream in body, x-api-key header
    url = opts.base_url or "https://api.anthropic.com/v1/messages"
    body.model  = model
    body.stream = streaming
    vim.list_extend(headers, {
      "-H", "x-api-key: " .. api_key,
      "-H", "anthropic-version: 2023-06-01",
    })
  end

  local f = io.open(tmpfile, "w")
  if not f then return nil, nil end
  f:write(vim.json.encode(body))
  f:close()

  local args = { "curl", "--silent" }
  if streaming then
    vim.list_extend(args, { "--no-buffer", "-N" })
  end
  vim.list_extend(args, { "-X", "POST" })
  vim.list_extend(args, headers)
  vim.list_extend(args, { "--data", "@" .. tmpfile, url })

  return args, url
end

--- Stream a Claude messages request, calling on_chunk for each text delta.
--- For the "bedrock" format, if the gateway does not support /invoke-with-response-stream,
--- set streaming=false to fall back to /invoke (buffered) and deliver the full
--- text to on_chunk in one call.
--- @param opts {model?: string, format?: string, system?: string, messages: table[], tools?: table[], max_tokens?: integer, api_key_env?: string, api_key?: string, base_url?: string}
--- @param on_chunk fun(text: string)      called for each streamed text token
--- @param on_done  fun()                  called when stream is complete
--- @param on_error fun(err: string)       called on error
--- @return {cancel: fun()}
function M.stream(opts, on_chunk, on_done, on_error)
  local api_key, key_err = resolve_key(opts)
  if key_err then
    on_error(key_err)
    return { cancel = function() end }
  end

  -- Some gateways (e.g. AWS Bedrock proxies) do not support the streaming endpoint.
  -- Setting streaming = false falls back to a single buffered request for all AI features.
  if opts.streaming == false then
    return M._stream_via_invoke(opts, api_key, on_chunk, on_done, on_error)
  end

  -- Write to temp file to avoid shell argument length limits on large diffs
  local tmpfile = vim.fn.tempname() .. ".json"
  local curl_args, _ = build_curl_args(opts, api_key, true, tmpfile)
  if not curl_args then
    on_error("Failed to create temp file for request body")
    return { cancel = function() end }
  end

  -- Line buffer: on_stdout receives string[] split on \n, chunks may be partial
  local line_buf = ""
  local done_called = false

  local job_id = vim.fn.jobstart(curl_args, {
    stdout_buffered = false,  -- CRITICAL: must be false for real-time streaming

    on_stdout = function(_, data)
      if not data then return end
      vim.schedule(function()
        -- data is string[] — join chunks into line buffer
        for _, chunk in ipairs(data) do
          line_buf = line_buf .. chunk
          -- Consume all complete lines
          local pos = line_buf:find("\n")
          while pos do
            local line = line_buf:sub(1, pos - 1):gsub("\r$", "")
            line_buf = line_buf:sub(pos + 1)
            -- SSE data lines look like: "data: {...json...}"
            if line:match("^data: ") then
              local json_str = line:sub(7)  -- skip "data: "
              if json_str ~= "[DONE]" then
                local ok, event = pcall(vim.json.decode, json_str)
                if ok then
                  local fmt = opts.format or "anthropic"
                  if fmt == "openai" then
                    -- OpenAI SSE: choices[0].delta.content
                    local choice  = event.choices and event.choices[1]
                    local content = choice and choice.delta and choice.delta.content
                    if content and content ~= vim.NIL then
                      on_chunk(content)
                    end
                  else
                    -- Anthropic SSE: content_block_delta with text_delta
                    if event.type == "content_block_delta"
                      and event.delta
                      and event.delta.type == "text_delta"
                      and event.delta.text
                    then
                      on_chunk(event.delta.text)
                    elseif event.type == "error" then
                      local msg = (event.error and event.error.message) or "API error"
                      if not done_called then
                        done_called = true
                        on_error(msg)
                      end
                    end
                  end
                end
              end
            end
            pos = line_buf:find("\n")
          end
        end
      end)
    end,

    on_stderr = function(_, data)
      if not data then return end
      local msg = table.concat(data, ""):gsub("^%s+", ""):gsub("%s+$", "")
      if msg ~= "" then
        vim.schedule(function()
          if not done_called then
            done_called = true
            on_error("curl error: " .. msg)
          end
        end)
      end
    end,

    on_exit = function(_, exit_code)
      vim.schedule(function()
        os.remove(tmpfile)
        if not done_called then
          done_called = true
          if exit_code ~= 0 then
            on_error("curl exited with code " .. exit_code)
          else
            on_done()
          end
        end
      end)
    end,
  })

  if job_id == 0 or job_id == -1 then
    os.remove(tmpfile)
    on_error("Failed to start curl (is curl installed?)")
    return { cancel = function() end }
  end

  return {
    cancel = function()
      vim.fn.jobstop(job_id)
      pcall(os.remove, tmpfile)
    end,
  }
end

--- Bedrock fallback: use buffered /invoke and deliver text to on_chunk all at once.
function M._stream_via_invoke(opts, api_key, on_chunk, on_done, on_error)
  local tmpfile = vim.fn.tempname() .. ".json"
  local curl_args, _ = build_curl_args(opts, api_key, false, tmpfile)
  if not curl_args then
    on_error("Failed to create temp file for request body")
    return { cancel = function() end }
  end

  local output_chunks = {}

  local job_id = vim.fn.jobstart(curl_args, {
    stdout_buffered = true,

    on_stdout = function(_, data)
      if data then
        for _, chunk in ipairs(data) do
          table.insert(output_chunks, chunk)
        end
      end
    end,

    on_exit = function(_, exit_code)
      vim.schedule(function()
        os.remove(tmpfile)

        if exit_code ~= 0 then
          on_error("curl exited with code " .. exit_code)
          return
        end

        local raw = table.concat(output_chunks, "")
        if raw == "" then
          on_error("Empty response from gateway (check auth token and base_url)")
          return
        end

        local ok, data = pcall(vim.json.decode, raw)
        if not ok then
          on_error("JSON parse error: " .. raw:sub(1, 200))
          return
        end

        local fmt = opts.format or "anthropic"
        if fmt == "openai" then
          -- OpenAI non-streaming: choices[0].message.content
          local choice  = data.choices and data.choices[1]
          local content = choice and choice.message and choice.message.content
          if content and content ~= "" then
            on_chunk(content)
            on_done()
          else
            on_error((data.error and data.error.message) or "No content in response")
          end
          return
        end

        if data.message and not data.content then
          on_error(data.message)
          return
        end
        if data.type == "error" then
          on_error((data.error and data.error.message) or "API error")
          return
        end

        for _, block in ipairs(data.content or {}) do
          if block.type == "text" and block.text and block.text ~= "" then
            on_chunk(block.text)
            on_done()
            return
          end
        end

        on_error("No text content in response")
      end)
    end,
  })

  if job_id == 0 or job_id == -1 then
    os.remove(tmpfile)
    on_error("Failed to start curl (is curl installed?)")
    return { cancel = function() end }
  end

  return {
    cancel = function()
      vim.fn.jobstop(job_id)
      pcall(os.remove, tmpfile)
    end,
  }
end

-- ---------------------------------------------------------------------------
-- Non-streaming request — for tool use (structured JSON output)
-- ---------------------------------------------------------------------------

--- Send a non-streaming Claude messages request and call callback with result.
--- @param opts {model?: string, format?: string, system?: string, messages: table[], tools?: table[], max_tokens?: integer, api_key_env?: string, api_key?: string, base_url?: string}
--- @param callback fun(err: string|nil, result: {type: "tool_use"|"text", name?: string, input?: table, text?: string}|nil)
--- @return {cancel: fun()}
function M.request(opts, callback)
  local api_key, key_err = resolve_key(opts)
  if key_err then
    callback(key_err, nil)
    return { cancel = function() end }
  end

  local tmpfile = vim.fn.tempname() .. ".json"
  local curl_args, _ = build_curl_args(opts, api_key, false, tmpfile)
  if not curl_args then
    callback("Failed to create temp file", nil)
    return { cancel = function() end }
  end

  local output_chunks = {}

  local job_id = vim.fn.jobstart(curl_args, {
    stdout_buffered = true,  -- collect full response for JSON parsing

    on_stdout = function(_, data)
      if data then
        for _, chunk in ipairs(data) do
          table.insert(output_chunks, chunk)
        end
      end
    end,

    on_exit = function(_, exit_code)
      vim.schedule(function()
        os.remove(tmpfile)

        if exit_code ~= 0 then
          callback("curl exited with code " .. exit_code, nil)
          return
        end

        local raw = table.concat(output_chunks, "")

        if raw == "" then
          callback("Empty response from gateway (check auth token and base_url)", nil)
          return
        end

        local ok, data = pcall(vim.json.decode, raw)
        if not ok then
          callback("JSON parse error: " .. raw:sub(1, 300), nil)
          return
        end

        local fmt = opts.format or "anthropic"
        if fmt == "openai" then
          -- OpenAI response: tool_calls take priority over plain text content
          local choice = data.choices and data.choices[1]
          if not choice then
            callback((data.error and data.error.message) or "No choices in response", nil)
            return
          end
          local msg = choice.message or {}
          if msg.tool_calls and msg.tool_calls[1] then
            local tc       = msg.tool_calls[1]
            local name     = tc["function"] and tc["function"].name
            local args_str = (tc["function"] and tc["function"].arguments) or "{}"
            local ok2, input = pcall(vim.json.decode, args_str)
            if not ok2 then
              callback("Failed to parse tool arguments: " .. args_str:sub(1, 200), nil)
              return
            end
            callback(nil, { type = "tool_use", name = name, input = input, id = tc.id })
            return
          end
          local content = msg.content
          if content and content ~= "" then
            callback(nil, { type = "text", text = content })
            return
          end
          callback((data.error and data.error.message) or "No content in response", nil)
          return
        end

        -- Bedrock/gateway error format: {"message": "..."}
        if data.message and not data.content and not data.type then
          callback(data.message, nil)
          return
        end

        -- Anthropic API-level error: {"type": "error", "error": {...}}
        if data.type == "error" then
          local msg = (data.error and data.error.message) or "API error"
          callback(msg, nil)
          return
        end

        -- Scan all content blocks, preferring tool_use over text.
        -- Claude sometimes emits a preamble text block before the tool_use block.
        local text_result = nil
        for _, block in ipairs(data.content or {}) do
          if block.type == "tool_use" then
            callback(nil, { type = "tool_use", name = block.name, input = block.input, id = block.id })
            return
          elseif block.type == "text" and not text_result then
            text_result = { type = "text", text = block.text }
          end
        end

        if text_result then
          callback(nil, text_result)
          return
        end

        callback("No content blocks in response", nil)
      end)
    end,
  })

  if job_id == 0 or job_id == -1 then
    os.remove(tmpfile)
    callback("Failed to start curl (is curl installed?)", nil)
    return { cancel = function() end }
  end

  return {
    cancel = function()
      vim.fn.jobstop(job_id)
      pcall(os.remove, tmpfile)
    end,
  }
end

return M
