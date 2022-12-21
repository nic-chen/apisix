local core = require("apisix.core")


local schema = {
    type = "object",
    properties = {},
    required = {"body"},
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
    local sum = cal()
    return 200, sum
end


return _M
