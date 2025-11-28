-- ffmpeg_clip.lua
-- mpv Lua script: select clip range and export via ffmpeg with simplified codec options

local mp = require 'mp'
local utils = require 'mp.utils'

-- ffmpeg/ffprobe (use full paths here if needed)
local ffmpeg = "ffmpeg"
local ffprobe = "ffprobe"

local codec_options = {
    {id = "copy", label = "copy"},
    {id = "libx264", label = "libx264"},
    {id = "h264_nvenc", label = "h264_nvenc (cq18)"},
    {id = "videotoolbox", label = "videotoolbox (profile high)"},
}

local state = { active = false, start = nil, stop = nil, codec_index = 1 }
local osd_timer = nil

local function osd()
    -- use ASS overlay so the multi-line OSD stays until we clear it
    if not state.active then
        mp.set_osd_ass(0, 0, "")
        return
    end
    local s = state.start and string.format("%.3f", state.start) or "-"
    local e = state.stop and string.format("%.3f", state.stop) or "-"
    local codec = codec_options[state.codec_index].label
    -- 五行提示：编码 / 开始 / 结束 / 导出 / 退出
    local lines = {}
    table.insert(lines, string.format("编码: %s", codec))
    table.insert(lines, string.format("开始: %s (按 Ctrl+1 设置)", s))
    table.insert(lines, string.format("结束: %s (按 Ctrl+2 设置)", e))
    table.insert(lines, "按 Ctrl+O 导出（仅在本模式生效）")
    table.insert(lines, "再次按 Ctrl+C 退出（恢复默认快捷键）")
    local msg = table.concat(lines, "\n")
    -- convert to ASS (\N for newline) and place at top-left (alignment 7)
    local msg = "\\N\\N\\N" .. table.concat(lines, "\n")
    local ass = string.format('{\\an7}{\\fs10}%s', msg:gsub('\n','\\N'))
    mp.set_osd_ass(0, 0, ass)
end

local function stop_osd_timer()
    if osd_timer then
        osd_timer:kill()
        osd_timer = nil
    end
end

local function toggle_mode()
    state.active = not state.active

    if not state.active then
        stop_osd_timer()
        mp.set_osd_ass(0, 0, "")   -- ⭐立刻清除 OSD
        mp.osd_message("ffmpeg-clip: 已退出（按 Ctrl+C 进入）", 3)
    else
        state.start = nil
        state.stop = nil
        state.codec_index = 1
        if not osd_timer then
            osd_timer = mp.add_periodic_timer(1.0, function()
                if state.active then
                    osd()
                else
                    stop_osd_timer()
                end
            end)
        end
        osd()
    end
end


local function set_start()
    if not state.active then return end
    state.start = mp.get_property_number("time-pos", 0)
    osd()
end

local function set_stop()
    if not state.active then return end
    state.stop = mp.get_property_number("time-pos", 0)
    osd()
end

local function codec_left()
    if not state.active then return end
    state.codec_index = state.codec_index - 1
    if state.codec_index < 1 then state.codec_index = #codec_options end
    osd()
end

local function codec_right()
    if not state.active then return end
    state.codec_index = state.codec_index + 1
    if state.codec_index > #codec_options then state.codec_index = 1 end
    osd()
end

local function codec_cycle()
    if not state.active then return end
    state.codec_index = state.codec_index + 1
    if state.codec_index > #codec_options then
        state.codec_index = 1
    end
    osd()
end

local function detect_video_codec(path)
    if not ffprobe or ffprobe == "" then
        mp.msg.warn("ffmpeg-clip: ffprobe not set; cannot detect video codec")
        return nil
    end
    local args = {ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name", "-of", "default=nw=1:nk=1", path}
    local res = utils.subprocess({ args = args, cancellable = false })
    if res then
        mp.msg.debug("ffmpeg-clip: ffprobe stdout='" .. tostring(res.stdout) .. "' status=" .. tostring(res.status))
    end
    if res and res.status == 0 and res.stdout then
        return (res.stdout:gsub("\n", ""))
    end
    return nil
end

local function build_ffmpeg_args(input, outpath, start, stop, codec_id)
    local args = {ffmpeg, "-y"}
    local duration = nil
    if start and stop then
        if stop <= start then return nil, "end time must be greater than start time" end
        duration = stop - start
        table.insert(args, "-ss"); table.insert(args, string.format("%.6f", start))
    end
    table.insert(args, "-i"); table.insert(args, input)
    if duration then table.insert(args, "-t"); table.insert(args, string.format("%.6f", duration)) end

    local extra = {}
    if codec_id == "copy" then
        table.insert(args, "-c:v"); table.insert(args, "copy")
        local vcodec = detect_video_codec(input)
        if vcodec then
            local v = string.lower(vcodec)
            if v:find("hevc") or v:find("h265") then
                mp.msg.info("ffmpeg-clip: input codec detected as '"..tostring(vcodec).."', adding -tag:v hvc1")
                table.insert(args, "-tag:v"); table.insert(args, "hvc1")
            end
        end
    elseif codec_id == "libx264" then
        table.insert(args, "-c:v"); table.insert(args, "libx264")
    elseif codec_id == "h264_nvenc" then
        table.insert(args, "-c:v"); table.insert(args, "h264_nvenc")
        table.insert(args, "-cq"); table.insert(args, "18")
    elseif codec_id == "videotoolbox" then
        table.insert(args, "-c:v"); table.insert(args, "h264_videotoolbox")
        table.insert(args, "-profile:v"); table.insert(args, "high")
    else
        return nil, "unsupported codec"
    end

    if codec_id == "copy" then
        table.insert(args, "-c:a"); table.insert(args, "copy")
    else
        table.insert(args, "-c:a"); table.insert(args, "aac")
        table.insert(args, "-b:a"); table.insert(args, "192k")
    end

    for _, v in ipairs(extra) do table.insert(args, v) end
    table.insert(args, outpath)
    return args
end

local function find_ffmpeg()
    -- Try current ffmpeg variable first, then common locations
    local candidates = {ffmpeg, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"}
    for _, cmd in ipairs(candidates) do
        if not cmd or cmd == "" then goto continue end
        local res = utils.subprocess({ args = {cmd, "-version"}, cancellable = false })
        if res and res.status == 0 then
            if cmd ~= ffmpeg then
                mp.msg.info("ffmpeg-clip: using ffmpeg at: " .. cmd)
            end
            ffmpeg = cmd
            -- try to locate ffprobe alongside ffmpeg
            local probe_path = cmd:gsub("ffmpeg$", "ffprobe")
            local pres = utils.subprocess({ args = {probe_path, "-version"}, cancellable = false })
            if pres and pres.status == 0 then
                ffprobe = probe_path
                mp.msg.info("ffmpeg-clip: using ffprobe at: " .. probe_path)
            else
                -- fall back to common locations for ffprobe
                local common_probes = {"/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe", "ffprobe"}
                for _, p in ipairs(common_probes) do
                    local pres2 = utils.subprocess({ args = {p, "-version"}, cancellable = false })
                    if pres2 and pres2.status == 0 then
                        ffprobe = p
                        mp.msg.info("ffmpeg-clip: using ffprobe at: " .. p)
                        break
                    end
                end
            end
            return true
        end
        ::continue::
    end
    return false
end

local function safe_filename(name)
    return (string.gsub(name, '[/\\:*?"<>|]', "_"))
end

local function export_clip()
    if not state.active then return end
    if not state.start or not state.stop then mp.osd_message("ffmpeg-clip: 请先按 Ctrl+1 / Ctrl+2 设置开始和结束时间"); return end
    local path = mp.get_property("path")
    if not path then mp.osd_message("ffmpeg-clip: 无法获取当前播放路径"); return end
    local dir, filename = utils.split_path(path)
    -- 如果 utils.split_path 未能返回文件名（例如某些流/特殊路径），尝试其它属性或回退到默认名
    if not filename or filename == "" then
        filename = mp.get_property("filename")
    end
    if not filename or filename == "" then
        filename = "mpv_clip"
    end
    if not filename or filename == "" then
        filename = "mpv_clip"
    end
    local base = filename:gsub("%.[^.]+$", "")
    local codec_id = codec_options[state.codec_index].id
    -- always use .mp4 for outputs, even when copying streams
    local ext = ".mp4"
    local outname = string.format("%s_clip_%.0f-%.0f_%s%s", base, state.start, state.stop, codec_id, ext)
    outname = safe_filename(outname)
    -- `dir` was obtained above from utils.split_path
    local outpath = dir and (dir .. "/" .. outname) or outname
    -- ensure ffmpeg available before building args so the executable path is correct
    if not find_ffmpeg() then
        mp.osd_message("ffmpeg-clip: 未找到 ffmpeg，请安装或在脚本顶部配置路径", 5)
        mp.msg.error("ffmpeg-clip: ffmpeg not found")
        return
    end
    local args, err = build_ffmpeg_args(path, outpath, state.start, state.stop, codec_id)
    if not args then mp.osd_message("ffmpeg-clip error: " .. (err or "unknown")); return end

    mp.osd_message("ffmpeg-clip: 开始导出 -> " .. outpath .. " (后台执行)")
    mp.msg.info("ffmpeg-clip: running ffmpeg with args: " .. utils.to_string(args))

    mp.command_native_async({ name = "subprocess", args = args, playback_only = false }, function(success, result, reason)
        if not success then
            mp.osd_message("ffmpeg-clip: 无法启动导出进程", 5)
            mp.msg.error("ffmpeg-clip: failed to start subprocess:", utils.to_string(result))
            return
        end

        -- Some mpv/os variants return 'exit_status', others return 'status'.
        -- Treat either 0 as success.
        local exit_code = nil
        if result then exit_code = result.exit_status or result.status or result.code end

        if exit_code == 0 then
            mp.osd_message("ffmpeg-clip: 导出完成 -> " .. outpath, 5)
            mp.msg.info("ffmpeg-clip: export finished successfully: " .. outpath)
        else
            mp.osd_message("ffmpeg-clip: 导出失败 (查看终端输出)", 8)
            mp.msg.error("ffmpeg-clip: ffmpeg exit:", utils.to_string(result))

            -- write debug info to a cross-platform temp path for easier inspection
            local tmp = os.getenv("TMP") or os.getenv("TEMP") or "/tmp"
            local logpath = tmp .. "/ffmpeg_clip_last.log"
            local ok, ferr = pcall(function()
                local f = io.open(logpath, "w")
                if not f then error("cannot open " .. tostring(logpath)) end
                f:write("FFMPEG ARGS:\n")
                f:write(utils.to_string(args) .. "\n\n")
                f:write("RESULT:\n")
                f:write(utils.to_string(result) .. "\n")
                f:close()
            end)
            if not ok then mp.msg.warn("ffmpeg-clip: failed to write debug log: " .. tostring(ferr)) end
            mp.msg.warn("ffmpeg-clip: wrote debug to " .. logpath)
        end
    end)
end

-- key bindings: Ctrl+C to toggle the mode (tips off by default)
mp.add_key_binding("Ctrl+c", "ffmpeg_clip_toggle", toggle_mode)
mp.add_key_binding("Ctrl+1", "ffmpeg_clip_set_start", set_start)
mp.add_key_binding("Ctrl+2", "ffmpeg_clip_set_stop", set_stop)
mp.add_key_binding("Ctrl+e", "ffmpeg_clip_cycle_codec", codec_cycle)
mp.add_key_binding("Ctrl+o", "ffmpeg_clip_export", export_clip)

mp.register_event("file-loaded", function() if state.active then osd() end end)
-- Do not show a startup OSD tip; the tips are off by default and can be toggled with C t r l+C

-- End
