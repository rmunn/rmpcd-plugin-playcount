---@class PlayCountPluginArgs
---@field enabled? boolean
---@field padding_factor_milliseconds? integer
---@field padding_factor_seconds? integer
---@field sticker_name? string
---@field from? "start" | "end"
---@field target_fraction? number
---@field target_percent? number

---@class PlayCountPlugin : RmpcdPlugin<PlayCountPluginArgs>
---@field enabled boolean
---@field timeout_handle table|nil
---@field last_incremented_song_id integer|nil
---@field padding_factor_ms integer
---@field from? "start" | "end"
---@field target_fraction number|nil
---@field sticker_name string

local DEFAULT_PADDING_FACTOR_MS = 15000 -- 15 seconds
local SAFETY_FACTOR_MS = 2000 -- 2 seconds
local DEFAULT_STICKER_NAME = "playCount";

---@class PlayCountPlugin
local M = {
    enabled = true;
    timeout_handle = nil;
    last_incremented_song_id = nil;
    padding_factor_ms = DEFAULT_PADDING_FACTOR_MS;
    from = "end";
    target_fraction = nil;
    sticker_name = DEFAULT_STICKER_NAME;
}

-- Sometimes MPD has sond durations in ms, others in a { secs, nanos } structure. Here we handle both.
local function duration_in_ms(song_duration)
    if type(song_duration) == "number" then return song_duration end
    return song_duration.secs * 1000 + song_duration.nanos / 1000000
end

-- Will be called when new song starts playing, and in other situations where the existing timeout
-- should be canceled (usually because it's being replaced by a new one)
M.cancel_timeout = function(self)
    if self.timeout_handle then
        self.timeout_handle.cancel()
        self.timeout_handle = nil
    end
end

--- @param file string
--- @param song_id number
M.increment_playcount = function(self, file, song_id)
    -- Do this first to ensure we won't be called again and possibly double-increment
    self.cancel_timeout(self)
    if song_id == self.last_incremented_song_id then
        -- This can happen if you pause and resume a song repeatedly within its last 15 seconds
        -- If that happens, we still only want to count a single play of the song
        return
    end
    self.last_incremented_song_id = song_id
    local oldsticker, err = mpd.get_song_sticker(file, self.sticker_name)
    if err then
        log.error("Could not increment play count for " .. file .. " because of an error while trying to look up the " .. self.sticker_name .. " sticker: " .. err)
    else
        local oldcount = tonumber(oldsticker) or 0
        mpd.set_song_sticker(file, self.sticker_name, tostring(oldcount + 1))
        log.info(file .. " has now been played " .. (oldcount + 1) .. " times.")
    end
end

-- Calculate the target position in the song. Returns a negative value if target position would be past end of song.
-- Calling code will interpret negative values as "already reached, increment immediately if we haven't already"
---@param song_duration_ms number
function M.calculate_target_position(self, song_duration_ms)
    -- Short songs get play count incremented right away, no waiting
    if self.padding_factor_ms >= song_duration_ms then return -1 end
    if self.from == "start" then
        if self.target_fraction ~= nil then
            -- Target desired fraction of song, but ensure at least padding_factor remaining
            local target = song_duration_ms * self.target_fraction
            return math.min(target, song_duration_ms - math.max(self.padding_factor_ms, SAFETY_FACTOR_MS))
        else
            -- No fraction specified, so just return the requested distance from start of song
            -- (Though leave at least 2 seconds before end of song, just for safety's sake)
            local target = self.padding_factor_ms
            return math.min(target, song_duration_ms - SAFETY_FACTOR_MS)
        end
    else
        if self.target_fraction ~= nil then
            -- Target desired fraction of song (calculating from END), but ensure at least padding_factor remaining
            local target = song_duration_ms * (1 - self.target_fraction)
            return math.min(target, song_duration_ms - math.max(self.padding_factor_ms, SAFETY_FACTOR_MS))
        else
            -- No fraction specified, so just return the requested distance from end of song
            -- (Though leave at least 2 seconds before end of song, just for safety's sake)
            return song_duration_ms - math.max(self.padding_factor_ms, SAFETY_FACTOR_MS)
        end
    end
end

---@param song_duration_ms number
---@param already_elapsed_ms number
function M.calculate_time_to_wait(self, song_duration_ms, already_elapsed_ms)
    local target = self.calculate_target_position(self, song_duration_ms)
    return target - already_elapsed_ms
end

-- Set up the timeout for N (configurable, default 15) seconds before the end of the song
-- Once the timeout fires, we will increment the song's playCount sticker
-- We use the song's id (a unique value assigned by MPD) to ensure we never double-increment for a single play
-- If we used the song's file for this, we might only add a single play count when the song gets played repeatedly
-- We also need to know how much time has elapsed in the song so far (which can happen when unpausing), since that
-- will change the calculation for how long the tieout needs to be so that it triggers N seconds before the song ends
---@param song QueuedSong
---@param already_elapsed_ms number
M.setup_timeout = function(self, song, already_elapsed_ms)
    self.cancel_timeout(self)
    already_elapsed_ms = already_elapsed_ms or 0
    local time_to_wait_ms = self.calculate_time_to_wait(self, duration_in_ms(song.duration), already_elapsed_ms)
    if time_to_wait_ms <= 0 then
        -- Already past target time: either it was a short song, or we were paused and unpaused.
        -- Either way, increment now without waiting
        self.increment_playcount(self, song.file, song.id)
    else
        -- Wait until chosen target time (by default, when song has 15 seconds (or less) to go), then increment play count
        self.timeout_handle = sync.set_timeout(time_to_wait_ms, function ()
            self.increment_playcount(self, song.file, song.id)
        end)
    end
end

-- Will be called when we unpause *or* when plugin starts up
-- In both cases, we want to check whether a song is already playing,
-- because the song's elapsed time needs to be taken into account when setting up the timeout
M.resume_after_pause = function(self)
    local status = mpd.get_status()
    if status and status.state == "play" then
        local song = mpd.get_current_song()
        if song then
            self.setup_timeout(self, song, status.elapsed)
        end
    end
end

--- @param _old_song QueuedSong
--- @param new_song QueuedSong
-- Will be called when a song changes.
-- Interestingly, in repeat+single mode (where one song loops repeatedly) this will only get called once,
-- when the song is first played. Repeating the same song isn't a "change" so this event doesn't get called.
-- I prefer that behavior, so I'm not going to try to add extra complexity to detect whether a song is
-- being looped forever. If you want your playCount sticker to be incremented by 50 when a song loops 50 times,
-- you can do `rmpc sticker get MySong.mp3 playCount` and then `rmpc sticker set mySong.mp3 playCount N`
-- (where N = old value + 50) yourself, in a bash script or something.
M.song_change = function(self, _old_song, new_song)
    if not self.enabled or new_song == nil or not new_song.file then
        self.cancel_timeout(self)
        return
    end

    self.setup_timeout(self, new_song, 0)
end

-- Will be called when playback is started, stopped or paused. A few cases need to be handled:
-- Stopping playback = cancel the timeout if it hasn't fired yet, because the song didn't play for long enough
-- Pausing playback = ditto, but when playback resumes the song's time elapsed so far will be counted
-- Unpausing playback = the timeout (which was canceled when playback was paused) can should be restarted now
-- Starting playback = 
M.state_change = function(self, old, new)
    if not self.enabled then
        self.cancel_timeout(self)
        return
    end

    if new == "pause" or new == "stop" then self.cancel_timeout(self) end
    if new == "play" then self.resume_after_pause(self) end
end

--- @param value number
--- @param warning string
M.clamp_between_0_and_1 = function(self, value, warning)
    if value < 0 then
        log.warn(warning)
        return 0
    elseif value > 1 then
        log.warn(warning)
        return 1
    end
    return value
end

M.setup = function(self, args)
    self.enabled = (args.enabled ~= nil) and args.enabled or true
    if args.padding_factor_milliseconds ~= nil and args.padding_factor_seconds ~= nil then
        log.warn("Both milliseconds and seconds were set for padding_factor. Using milliseconds and *IGNORING* seconds. Padding factor will be set to " .. args.padding_factor_milliseconds .. " ms, which is " .. args.padding_factor_milliseconds / 1000 .. " seconds.")
    end
    if args.padding_factor_seconds ~= nil then
        self.padding_factor_ms = args.padding_factor_seconds * 1000
    end
    if args.padding_factor_milliseconds ~= nil then
        self.padding_factor_ms = args.padding_factor_milliseconds
    end
    if args.target_fraction ~= nil then
        if args.target_percent ~= nil then
            log.warn("Both target_percent and target_fraction were set. Using target_fraction and *IGNORING* target_percent.")
        end
        self.target_fraction = self.clamp_between_0_and_1(self, args.target_fraction, "The target_fraction parameter should be between 0 and 1.")
    elseif args.target_percent ~= nil then
        self.target_fraction = self.clamp_between_0_and_1(self, args.target_percent / 100, "The target_percent parameter should be between 0 and 100.")
    end
    if args.padding_factor_seconds ~= nil then
        self.padding_factor_ms = args.padding_factor_seconds * 1000
    end
    if args.padding_factor_milliseconds ~= nil then
        self.padding_factor_ms = args.padding_factor_milliseconds
    end
    if args.sticker_name then
        self.sticker_name = args.sticker_name
    end
    if args.from then
        if args.from == "start" or args.from == "end" then
            self.from = args.from
        else
            log.warn("\"from\" parameter should be either \"start\" or \"end\" (default \"end\"). Ignoring unknown value \"" .. args.from .. "\"")
        end
    end

    -- Same logic for resiming after pause (check times elapsed, etc) works here too, so just reuse it
    -- However, resume_after_pause needs to call mpd.get_status(), and during plugin setup, rmpcd isn't running yet
    -- But by setting a timeout of 0, we ensure we get queued up to run immediately after rmpcd setup completes
    -- This neatly solves the chicken-and-egg problem
    sync.set_timeout(0, function ()
      self.resume_after_pause(self)
    end)
end

-- We subscribe to both playCount and playcount channels in case someone mistypes the name
M.subscribed_channels = { "rmpcd.playcount", "rmpcd.playCount" }

-- We can ignore the channel here because we're only subscribed to our own comm channels
M.message = function(self, _channel, message)
    -- Turning plugin on/off
    if message == "enable" then
        log.info("Enabling playcount plugin")
        self.enabled = true
    elseif message == "disable" then
        log.info("Disabling playcount plugin")
        self.enabled = false
    elseif message == "toggle" then
        local newstate = not self.enabled
        local first_word = newstate and "Enabling" or "Disabling"
        log.info(first_word .. " playcount plugin")
        self.enabled = newstate

    -- Changing parameters on-the-fly: padding factor
    -- Syntax: send either "padding_factor_seconds:15" or "padding_factor_milliseconds:15000"
    elseif string.find(message, "padding_factor_seconds:") == 1 then
        local len = string.len("padding_factor_seconds:")
        local seconds = tonumber(string.sub(message, len))
        if seconds ~= nil then
            self.padding_factor_ms = seconds * 1000
        end
    elseif string.find(message, "padding_factor_milliseconds:") == 1 then
        local len = string.len("padding_factor_milliseconds:")
        local ms = tonumber(string.sub(message, len))
        if ms ~= nil then
            self.padding_factor_ms = ms
        end

    -- Changing parameters on-the-fly: sticker name
    -- CAUTION: No attempt is made to validate the new name. Make sure you spelled it the way you want it to be spelled!
    -- Note also that no attempt is made to search the sticker database and rename anything from the old name to the new name
    -- So changing this while the plugin is running is almost never useful, but we include the option for completeness' sake
    elseif string.find(message, "sticker_name:") == 1 then
        local len = string.len("sticker_name:")
        local new_name = string.sub(message, len)
        if new_name ~= nil then
            self.sticker_name = new_name
        end
    elseif string.find(message, "from:") == 1 then
        local len = string.len("from:")
        local new_from = string.sub(message, len)
        if new_from ~= nil and (new_from == "start" or new_from == "end") then
            self.from = new_from
        end
    end
end

return M

-- TODO: Message for target_fraction and target_percent
