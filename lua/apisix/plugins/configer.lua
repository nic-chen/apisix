local core = require("apisix.core")
local exporter = require("apisix.plugins.configer.exporter")
local plugin_name = "configer"


local _M = {
    version = 0.1,
    priority = 500,
    name = plugin_name,
    init = exporter.init,
}


function _M.api()
    return {
        {
            methods = {"GET"},
            uri = "/apisix/config",
            handler = exporter.get_config
        },
        {
            methods = {"PUT"},
            uri = "/apisix/config",
            handler = exporter.set_config
        }
    }
end



return _M
