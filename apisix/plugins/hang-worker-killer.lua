local ngx             = ngx
local require         = require
local ngx_time        = ngx.time
local ngx_worker_pid  = ngx.worker.pid
local ngx_update_time = ngx.update_time
local process         = require("ngx.process")
local counter         = require("resty.counter")
local signal          = require("resty.signal")
local core            = require("apisix.core")
local plugin          = require("apisix.plugin")
local timers          = require("apisix.timers")
local cpu             = require("apisix.plugins.hang-worker-killer.cpu")


local plugin_name     = "hang-worker-killer"

-- configurations
-- default values just for test. TODO: upate to 60 by default
local INTERVAL        = 2          -- The monitor interval (unit: second)
local MIN_QPS         = 100        -- At least how many QPS is possible to achieve such CPU usage
local MAX_CPU_PERCENT = 0.8        -- The max CPU usage percent on which the worker should be killed
-- default values just for test. TODO: upate to 10 by default
local CONTINUOUS      = 2          -- How many consecutive checks on CPU for each monitor
local ENABLED         = false      -- The monitor is enabled or not

-- runtime vars
local SYNC_INTERVAL   = 0.1        -- The interval for sync local state to shared dict
local DURATION        = 0.05       -- The duration to count CPU usage(in seconds)
local next_time                    -- The next time to monitor(unix timestamp)

local shared_worker_map = ngx.shared["plugin-hang-worker-killer-pids"]
local shared_worker_qps_count = ngx.shared["plugin-hang-worker-killer-qps"]
if not shared_worker_map or not shared_worker_qps_count then
    error("failed to get ngx.shared dict when load plugin " .. plugin_name)
end

local worker_qps_counter = counter.new("plugin-hang-worker-killer-qps", SYNC_INTERVAL)

local schema = {
    type = "object",
    properties = {},
}

local metadata_schema = {
    type = "object",
    properties = {
        enabled = {
            type = "bool",
            default = false
        },
        interval = {
            type = "integer",
            default = 60
        },
        continuous = {
            type = "integer",
            default = 10
        },
        max_cpu_percent = {
            type = "number",
            default = 0.8
        },
        min_qps = {
            type = "integer",
            default = 100
        }
    }
}

local _M = {
    version = 0.1,
    priority = 100,
    name = plugin_name,
    schema = schema,
    scope = "global",
}


function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end

    return core.schema.check(schema, conf)
end


local function check_hang(worker_pid, max_cpu_percent, min_qps, continuous, duration)
    local exceed_cpu_limit = 0
    local requests_key = "worker-qps-" .. worker_pid
    local reach_min_qps = false

    local current_requests = worker_qps_counter:get(requests_key) or 0

    for i = 0, continuous - 1 do
        local cpu_percent, err = cpu.cpu_percent(worker_pid, duration)
        core.log.info("get cpu percent for worker:",
            worker_pid, " percent:", cpu_percent, " error:", err)
        if err then
            return false, err
        end

        if cpu_percent >= max_cpu_percent then
            exceed_cpu_limit = exceed_cpu_limit + 1
        end

        local temp_requests = worker_qps_counter:get(requests_key) or 0
        -- once the requests collected is greater than the min qps
        -- it can be considered that the min requirement has been met
        local diff = temp_requests - current_requests
        core.log.info("counting diff, temp_requests:", temp_requests, " current_requests:", current_requests)
        if diff > min_qps then
            core.log.info("reached min QPS, diff:", diff, " min_qps:", min_qps)
            reach_min_qps = true
        end

        current_requests = temp_requests
    end

    if reach_min_qps then
        core.log.info("determined non-hang process, because QPS reached the set min_qps")
        return false
    end

    -- consider a worker CPU usage limit exceeded only if
    -- more than half of the continuous checks exceed the limit
    if exceed_cpu_limit < continuous / 2 then
        core.log.info("count of workers that exceed cpu limit:",
            exceed_cpu_limit, " continuous:", continuous)
        return false
    end

    return true
end


local function monitor(premature)
    if premature then
        return
    end

    local metadata = plugin.plugin_metadata(plugin_name)
    if not (metadata and metadata.value and metadata.modifiedIndex) then
        core.log.info("please set the correct plugin_metadata for ", plugin_name)
        return
    end

    local enabled = ENABLED
    local interval = INTERVAL
    local duration = DURATION
    local continuous = CONTINUOUS
    local min_qps = MIN_QPS
    local max_cpu_percent = MAX_CPU_PERCENT
    core.log.info("metadata.value for hang-worker-killer:", core.json.encode(metadata.value, true))
    if metadata.value then
        enabled = metadata.value.enabled or enabled
        interval = metadata.value.interval or interval
        continuous = metadata.value.continuous or continuous
        min_qps = metadata.value.min_qps or min_qps
        max_cpu_percent = metadata.value.max_cpu_percent or max_cpu_percent
    end

    if not enabled then
        core.log.info("hang worker monitor disabled")
        return
    end

    ngx_update_time()
    local now_time = ngx_time()
    if not next_time then
        -- first init monitor time
        next_time = now_time + interval
        core.log.info("first init monitor time is: ", next_time)
        return
    end

    if now_time < next_time then
        -- not reach the next monitor time
        core.log.info("not reach the next monitor time, monitor time: ",
            next_time, " now time: ", now_time)
        return
    end

    next_time = now_time + interval

    local worker_map_keys = shared_worker_map:get_keys()
    for _, key in ipairs(worker_map_keys) do
        local worker_pid = string.sub(key, 12)
        local hung, err = check_hang(worker_pid, max_cpu_percent, min_qps, continuous, duration)
        core.log.info("check worker hang, worker pid:", worker_pid, " hung:", hung, " error:", err)
        if err then
            core.log.error("failed to check worker hang:", err)
        end

        if hung then
            core.log.warn("send TERM signal to worker process [", worker_pid, "] for restarting it")
            local ok, err = signal.kill(tonumber(worker_pid), "TERM")
            if not ok then
                core.log.error("failed to send TERM signal for restarting it: ", err)
            end
        end
    end
end


function _M.log()
    local pid = ngx_worker_pid()
    worker_qps_counter:incr("worker-qps-" .. pid)
end


local function is_privileged()
    return process.type() == "privileged agent"
end


function _M.init()
    -- register timer on privileged process
    timers.register_timer("plugin#" .. plugin_name, monitor, true)

    -- don't monitor privileged process itself
    if is_privileged() then
        return
    end

    -- store pid of the worker to shared dict
    -- ngx.worker.pids is undefined and ngx.worker.id return nil at current versions of openresty
    -- so we aviod to use them
    local worker_pid = ngx_worker_pid()
    shared_worker_map:set("worker-pid-" .. worker_pid, worker_pid)
end


function _M.destroy()
    timers.unregister_timer("plugin#" .. plugin_name, true)

    -- don't monitor privileged process itself
    if is_privileged() then
        return
    end

    -- remove pid of the worker from shared dict
    local worker_pid = ngx_worker_pid()
    shared_worker_map:delete("worker-pid-" .. worker_pid)
end


return _M
