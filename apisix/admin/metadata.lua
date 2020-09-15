--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local core    = require("apisix.core")
local plugins = require("apisix.admin.plugins")
local plugin  = require("apisix.plugin")
local pairs   = pairs

local _M = {
    version = 0.1,
}


local function check_conf(key, conf)
    -- core.log.error(core.json.encode(conf))
    if not conf then
        return nil, {error_msg = "missing configurations"}
    end

    if not key then
        return nil, {error_msg = "missing metadata key"}
    end

    core.log.info("schema: ", core.json.delay_encode(core.schema.metadata))
    core.log.info("conf  : ", core.json.delay_encode(conf))
    local ok, err = core.schema.check(core.schema.metadata, conf)
    if not ok then
        return nil, {error_msg = "invalid configuration: " .. err}
    end

    return key
end


function _M.put(key, conf)
    local key, err = check_conf(key, conf)
    if not key then
        return 400, err
    end

    local key = "/metadata/" .. key
    core.log.info("key: ", key)
    local res, err = core.etcd.set(key, conf)
    if not res then
        core.log.error("failed to put metadata[", key, "]: ", err)
        return 500, {error_msg = err}
    end

    return res.status, res.body
end


function _M.get(key)
    local path = "/metadata"
    if key then
        path = path .. "/" .. key
    end

    local res, err = core.etcd.get(path)
    if not res then
        core.log.error("failed to get metadata[", key, "]: ", err)
        return 500, {error_msg = err}
    end

    return res.status, res.body
end


function _M.post(key, conf)
    return 400, {error_msg = "not support `POST` method for metadata"}
end


function _M.delete(key)
    if not key then
        return 400, {error_msg = "missing metadata key"}
    end

    local key = "/metadata/" .. key
    local res, err = core.etcd.delete(key)
    if not res then
        core.log.error("failed to delete metadata[", key, "]: ", err)
        return 500, {error_msg = err}
    end

    return res.status, res.body
end


return _M
