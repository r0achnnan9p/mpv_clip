-- Simple clip exporter for mpv
-- Features:
--  - Toggle clip mode with Shift+C (use uppercase C)
--  - Press 1 to set start time, 2 to set end time
--  - Press e to export clip using libx264 + aac to the input file's directory

local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local active = false
local start_time = nil
local end_time = nil
local input_path = nil

-- available output formats / encoders
local formats = {
  { id = "libx264", label = "libx264 (x264)", ovcopts = {} },
  { id = "h264_nvenc", label = "h264_nvenc (NVENC)", ovcopts = { "rc=vbr_hq", "cq=18", "preset=p4" } },
  { id = "h264_videotoolbox", label = "h264_videotoolbox (VideoToolbox - Apple)", ovcopts = { "profile=high" } }
}
local format_index = 1

local function osd(text, dur)
  mp.osd_message(text, dur or 3)
end

-- filename-friendly timestamp (HH-MM-SS)
local function fmt_seconds(sec)
  local s = math.floor(sec + 0.5)
  local h = math.floor(s / 3600)
  local m = math.floor((s % 3600) / 60)
  local ss = s % 60
  return string.format("%02d-%02d-%02d", h, m, ss)
end

-- display-friendly timestamp (HH:MM:SS)
local function fmt_hms(sec)
  local s = math.floor(sec + 0.5)
  local h = math.floor(s / 3600)
  local m = math.floor((s % 3600) / 60)
  local ss = s % 60
  return string.format("%02d:%02d:%02d", h, m, ss)
end

local function update_osd()
  if not active then return end
  local s = start_time and fmt_hms(start_time) or "--:--:--"
  local e = end_time and fmt_hms(end_time) or "--:--:--"
  local fmt_label = formats[format_index] and formats[format_index].label or "unknown"
  local text = string.format(
    "%s\nstart: %s\nend: %s\n←/→ = encoder  E = export\nShift+C to toggle off",
    fmt_label, s, e
  )
  -- Large duration to approximate persistent until toggled off
  mp.osd_message(text, 99999)
end

local function select_prev_format()
  format_index = format_index - 1
  if format_index < 1 then format_index = #formats end
  update_osd()
  msg.info("Selected encoder: " .. formats[format_index].id)
end

local function select_next_format()
  format_index = format_index + 1
  if format_index > #formats then format_index = 1 end
  update_osd()
  msg.info("Selected encoder: " .. formats[format_index].id)
end

local function set_start()
  if not active then return end
  start_time = mp.get_property_number("time-pos", 0)
  update_osd()
  msg.info("Clip start set: " .. tostring(start_time))
end

local function set_end()
  if not active then return end
  end_time = mp.get_property_number("time-pos", 0)
  update_osd()
  msg.info("Clip end set: " .. tostring(end_time))
end

local function valid_times()
  if not start_time then osd("Start time not set"); return false end
  if not end_time then osd("End time not set"); return false end
  if end_time <= start_time then osd("End must be after start"); return false end
  return true
end

local function make_output_name(path, s, e)
  local dir, file = utils.split_path(path)
  local base = file:match("(.+)%.[^%.]+$") or file
  local outname = base .. "_clip_" .. fmt_seconds(s) .. "-" .. fmt_seconds(e) .. ".mp4"
  if utils.join_path then
    return utils.join_path(dir, outname)
  else
    -- fallback join
    local sep = package.config:sub(1,1)
    if dir:sub(-1) ~= sep then dir = dir .. sep end
    return dir .. outname
  end
end

local function export_clip()
  if not active then return end
  input_path = input_path or mp.get_property("path")
  if not input_path then osd("No input file to export"); return end
  if not valid_times() then return end

  local out = make_output_name(input_path, start_time, end_time)
  osd("Exporting: " .. out, 4)
  msg.info("Starting clip export: " .. tostring(out))

  local args = {
    "mpv",
    input_path,
    "--start=" .. tostring(start_time),
    "--end=" .. tostring(end_time),
    -- video codec chosen by user
    "--ovc=" .. formats[format_index].id,
    "--oac=aac",
    "--o=" .. out,
    "--no-terminal"
  }
  -- append ovc options if present
  if formats[format_index].ovcopts then
    for _, opt in ipairs(formats[format_index].ovcopts) do
      table.insert(args, "--ovcopts-add=" .. opt)
    end
  end

  mp.command_native_async({name = "subprocess", args = args}, function(success, result)
    if result and (result.status == 0 or result.exit_code == 0) then
      osd("Export finished:\n" .. out, 5)
      msg.info("Export finished: " .. tostring(out))
    else
      osd("Export failed (see console)", 5)
      msg.error("Export failed: " .. tostring(result and (result.status or result.exit_code) or "unknown"))
    end
    -- restore the persistent OSD if still active
    if active then
      update_osd()
    end
  end)
end

local function toggle()
  active = not active
  if active then
    input_path = mp.get_property("path")
    -- add forced bindings for LEFT/RIGHT so they override seek while in clip mode
    local ok, err = pcall(function()
      mp.add_forced_key_binding("LEFT", "clip-prev-encoder", select_prev_format)
      mp.add_forced_key_binding("RIGHT", "clip-next-encoder", select_next_format)
      -- add forced bindings for 1/2/E while in clip mode
      mp.add_forced_key_binding("1", "clip-set-start", set_start)
      mp.add_forced_key_binding("2", "clip-set-end", set_end)
      mp.add_forced_key_binding("e", "clip-export", export_clip)
    end)
    if not ok then
      msg.warn("Could not add forced key bindings: " .. tostring(err))
    end
    msg.info("Clip mode enabled for: " .. tostring(input_path))
    update_osd()
  else
    -- clear OSD
    -- remove forced bindings so LEFT/RIGHT and 1/2/E go back to default behavior
    mp.remove_key_binding("clip-prev-encoder")
    mp.remove_key_binding("clip-next-encoder")
    mp.remove_key_binding("clip-set-start")
    mp.remove_key_binding("clip-set-end")
    mp.remove_key_binding("clip-export")
    mp.osd_message("", 1)
    msg.info("Clip mode disabled")
  end
end

-- Key bindings
-- Uppercase C corresponds to Shift+C in most mpv setups
mp.add_key_binding("C", "clip-toggle", toggle)
-- The 1/2/E bindings are only active while clip mode is enabled to avoid
-- overriding any default mpv behavior when not in clip mode.
-- LEFT / RIGHT should only override default seeking while clip mode is active.
-- We add forced bindings when entering clip mode and remove them when leaving.

-- Help on load
osd("Clip script loaded: Shift+C toggle (C). 1=start 2=end ←/→=encoder E=export", 4)
