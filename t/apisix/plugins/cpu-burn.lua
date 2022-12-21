local ngx_time        = ngx.time
local ngx_update_time = ngx.update_time
local core            = require("apisix.core")


local schema = {
    type = "object",
    properties = {},
    required = {},
}

local plugin_name = "cpu-burn"

local _M = {
    version = 0.1,
    priority = 12,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


local function cal()
    local sum = 0

    for i = 1, 10000000 do
        sum = sum + i * 2 - 8
    end

    return sum
end


function _M.access(conf, ctx)
    local uri_args = core.request.get_uri_args(ctx) or {}
    local burn_sec = uri_args["burn_sec"] and tonumber(uri_args["burn_sec"]) or 1

    ngx_update_time()
    local start_time = ngx_time()
    local sum = 0
    while true do
        ngx_update_time()
        local now_time = ngx_time()
        if now_time - start_time > burn_sec then
            break
        end

        sum = sum + cal()
    end

    return 200, sum
end


return _M
