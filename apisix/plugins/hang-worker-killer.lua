local ngx              = ngx
local ngx_time         = ngx.time
local ngx_worker_pid   = ngx.worker.pid
local ngx_update_time  = ngx.update_time
local counter          = require("resty.counter")
local signal           = require("resty.signal")
local core             = require("apisix.core")
local timers           = require("apisix.timers")
local plugin           = require("apisix.plugin")
local cpu              = require("apisix.plugins.hang-worker-killer.cpu")


local plugin_name     = "hang-worker-killer"
local INTERVAL        = 60         -- The monitor interval (unit: second)
local SYNC_INTERVAL   = 0.1        -- The interval for sync local state to shared dict
local MIN_QPS         = 100        -- At least how many QPS is possible to achieve such CPU usage
local MAX_CPU_PERCENT = 0.80       -- The max CPU usage percent on which the worker should be killed
local CONTINUOUS      = 10         -- How many consecutive checks on CPU for each monitor
local DURATION        = 1          -- The duration to count CPU usage
local ENABLED         = false
local next_time                    -- The next time to monitor(unix timestamp)


local shared_worker_map = ngx.shared["worker-pid-map"]
local shared_worker_qps_count = ngx.shared["worker-qps-count"]
if not shared_worker_map or not shared_worker_qps_count then
    error("failed to get ngx.shared dict when load plugin " .. plugin_name)
end


local worker_qps_counter = counter.new("worker-qps-count", SYNC_INTERVAL)


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
        duration = {
            type = "integer",
            default = 1
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
    local now_time = ngx_time()
    local exceed_cpu_limit = 0
    for i = 0, continuous - 1 do
        local cpu_percent, err = cpu.cpu_percent(worker_pid, duration)
        core.log.info("get cpu percent for worker:", worker_pid, " percent:", cpu_percent)
        if err then
            return false, err
        end

        if cpu_percent >= max_cpu_percent then
            exceed_cpu_limit = exceed_cpu_limit + 1
        end
    end

    if exceed_cpu_limit < continuous / 2 then
        core.log.info("count of workers that exceed cpu limit:",
            exceed_cpu_limit, " continuous:", continuous)
        return false
    end

    for i = 0, continuous - 1 do
        local key = "worker-qps-" .. worker_pid .. "-" .. now_time + i
        local qps = worker_qps_counter:get(key)
        core.log.info("get qps for worker:",
            worker_pid, " shared dict key:", key, " qps:", qps)
        if qps and qps > min_qps then
            return false
        end
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
        duration = metadata.value.duration or duration
        continuous = metadata.value.continuous or continuous
        min_qps = metadata.value.min_qps or min_qps
        max_cpu_percent = metadata.value.max_cpu_percent or max_cpu_percent
    end


    if not enabled then
        core.log.info("monitor disabled")
        return
    end

    ngx_update_time()
    local now_time = ngx_time()
    if not next_time then
        -- first init rotate time
        next_time = now_time + interval
        core.log.info("first init monitor time is: ", next_time)
        return
    end

    if now_time < next_time then
        -- did not reach the next monitor time
        core.log.info("monitor time: ", next_time, " now time: ", now_time)
        return
    end

    next_time = now_time + interval

    local worker_map_keys = shared_worker_map:get_keys()
    for _, key in ipairs(worker_map_keys) do
        local worker_pid = string.sub(key, 12)
        local hung, err = check_hang(worker_pid, max_cpu_percent, min_qps, continuous, duration)
        core.log.info("check worker hang, workder pid:", worker_pid, " hung:", hung, " error:", err)
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
    ngx_update_time()

    local pid = ngx_worker_pid()
    local now_time = ngx_time()
    worker_qps_counter:incr("worker-qps-" .. pid .. "-" .. now_time)
end


function _M.init()
    -- register timer on privileged process
    timers.register_timer("plugin#" .. plugin_name, monitor, true)

    -- store pid of the worker to shared dict
    -- ngx.workder.id return nil at some version of openresty
    -- so we aviod to use it
    local worker_pid = ngx_worker_pid()
    shared_worker_map:set("worker-pid-" .. worker_pid, worker_pid)
end


function _M.destroy()
    timers.unregister_timer("plugin#" .. plugin_name, true)
    -- remove pid of the worker from shared dict
    local worker_pid = ngx_worker_pid()
    shared_worker_map:delete("worker-pid-" .. worker_pid)
end


return _M
