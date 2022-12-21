local io_open   = io.open
local ngx_re    = require "ngx.re"


local _M = {version = 0.1}


local function split_proc_stat(content)
    local name_start = string.find(content, '(')
	local name_end = string.find(content, ')')
    if name_start < 3 then
        return nil, "invalid proc stat file content"
    end

    local name = string.sub(content, name_start + 1, name_end)
    local pid = string.sub(content, 0, name_start - 1)
    local rest_content = string.sub(content, name_end)
	local rest_fields = ngx_re.split(rest_content, [[\s*]], "jo")

    local res = {}
    res[1] = pid
    res[2] = name
    for i = 1, #rest_fields do
        res[i+2] = rest_fields[i]
    end

    return res
end


local function worker_cpu_times(pid)
    local filepath = "/proc/" .. pid .. "/stat"
    local fp, err = io_open(filepath, "r")
    if not fp then
        return 0, "failed to open file: " .. filepath .. ", error info:" .. err
    end

    local content = fp:read("*all")
    fp:close()

    local res, err = split_proc_stat(content)
    if err then
        return 0, err
    end

    if #res < 15 then
        return 0, "invalid proc stat file(" .. filepath .. ") content"
    end

    local utime = res[14]
    local stime = res[15]

    return utime + stime
end


local function cpu_times()
    local fp, err = io_open("/proc/stat","r")
    if not fp then
        return 0, "failed to open file: /proc/stat, error info: " .. err
    end

    -- skip the total cpu line
    local _ = fp:read()
    local cpu_line = fp:read()
    fp:close()

    local fields = ngx_re.split(cpu_line, [[\s*]], "jo")

    local cpu_total = 0
    for i = 2, #fields do
        cpu_total = cpu_total + fields[i]
    end

    return cpu_total
end


function _M.cpu_percent(worker_pid, duration)
    local worker_cpu_total, err = worker_cpu_times(worker_pid)
    if not worker_cpu_total then
        return 0, "failed to get cpu times for worker " .. worker_pid .. " " .. err
    end

    local cpu_total, err = cpu_times()
    if not cpu_total then
        return 0, "failed to get cpu times" .. err
    end

    ngx.sleep(duration)

    local worker_cpu_total2, err = worker_cpu_times(worker_pid)
    if not worker_cpu_total2 then
        return 0, "failed to get cpu times for worker " .. worker_pid .. " " .. err
    end

    local cpu_total2, err = cpu_times()
    if not cpu_total2 then
        return 0, "failed to get cpu times" .. err
    end

    return (worker_cpu_total2 - worker_cpu_total) / (cpu_total2 - cpu_total)
end


return _M
