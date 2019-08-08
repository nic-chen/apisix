-- Copyright (C) Yuansheng Wang

local base_prometheus = require("apisix.plugins.prometheus.base_prometheus")
local prometheus
local core = require("apisix.core")
local ipairs = ipairs
local ngx_capture = ngx.location.capture
local re_gmatch = ngx.re.gmatch


local metrics = {}
local tmp_tab = {}


local _M = {version = 0.1}


function _M.init()
end


function _M.get_config()
    return 200, 'get config'
end


function _M.set_config()
    return 200, 'set config'
end


return _M
