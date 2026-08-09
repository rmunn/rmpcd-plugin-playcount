---@class PlayCountPluginArgs
---@field enabled? boolean
---@field padding_factor_milliseconds? integer
---@field padding_factor_seconds? integer
---@field sticker_name? string
---@field from? "start" | "end"
---@field target_fraction? number
---@field target_percent? number
---@field loop? boolean -- Enable looping playcount

---@class PlayCountPlugin : RmpcdPlugin<PlayCountPluginArgs>
---@field enabled boolean
---@field timeout_handle table|nil
---@field last_incremented_song_id integer|nil
---@field padding_factor_ms integer
---@field from? "start" | "end"
---@field target_fraction number|nil
---@field sticker_name string
---@field loop boolean -- Enable looping playcount
---@field is_loop_active boolean -- Tracks if loop timer is currently running
---@field paused_remaining_ms integer|nil -- Stores remaining time when paused

local DEFAULT_PADDING_FACTOR_MS = 15000 -- 15 seconds
local SAFETY_FACTOR_MS = 2000 -- 2 seconds
local DEFAULT_STICKER_NAME = "playCount";
local LOOP_BUFFER_MS = 5000 -- 5 seconds buffer for loop timer

---@class PlayCountPlugin
local M = {
    enabled = true;
    timeout_handle = nil;
    last_incremented_song_id = nil;
    padding_factor_ms = DEFAULT_PADDING_FACTOR_MS;
    from = "end";
    target_fraction = nil;
    sticker_name = DEFAULT_STICKER_NAME;
    loop = false; -- Default to false
    is_loop_active = false; -- Initialize loop state
    paused_remaining_ms = nil; -- Initialize paused time storage
}

-- Sometimes MPD has song durations in ms, others in a { secs, nanos } structure. Here we handle both.
local function duration_in_ms(song_duration)
    if type(song_duration) == "number" then return song_duration end
    return song_duration.secs * 1000 + song_duration.nanos / 1000000
end

-- Will be called when new song starts playing, and in other situations where the existing timeout
-- should be canceled (usually because it's being replaced by a new one)
function M:cancel_timeout()
    if self.timeout_handle then
        self.timeout_handle.cancel()
        self.timeout_handle = nil
    end
end

--- @param file string
--- @param song_id number
--- @param is_loop_check boolean Optional flag to indicate this is a loop check, not a standard increment
function M:increment_playcount(file, song_id, is_loop_check)
    -- Do this first to ensure we won't be called again and possibly double-increment
    self:cancel_timeout()
    
    -- Clear paused state on increment
    self.paused_remaining_ms = nil

    -- If this is a loop check, we verify the song ID hasn't changed
    if is_loop_check then
        local current_status = mpd.get_status()
        local current_song = mpd.get_current_song()
        
        -- If no song is playing or song ID changed, stop the loop
        if not current_song or current_song.id ~= song_id then
            log.info("Loop check failed: Song changed or stopped. Stopping loop.")
            self.is_loop_active = false -- Reset loop state
            return
        end
        
        -- Ensure we are actually playing, not paused
        if current_status.state ~= "play" then
            log.info("Loop check failed: Song is not currently playing (state: " .. tostring(current_status.state) .. "). Stopping loop.")
            self.is_loop_active = false -- Reset loop state
            return
        end
        
        -- If we are still on the same song and playing, proceed to increment
        log.info("Loop check passed: Song ID " .. song_id .. " is still playing. Incrementing.")
    end

    -- Enhanced duplicate prevention that accounts for pause/resume
    if song_id == self.last_incremented_song_id then
        if is_loop_check then
            -- For loop checks, we need to be more careful
            -- Only allow if enough time has passed since last increment
            -- This prevents rapid double-counting during pause/resume cycles
            
            -- We are on the same song (verified above), so reset the ID to allow the next loop iteration
            self.last_incremented_song_id = song_id
        else
            -- Standard playcount: prevent double increment
            return
        end
    else
        self.last_incremented_song_id = song_id
    end

    local oldsticker, err = mpd.get_song_sticker(file, self.sticker_name)
    if err then
        log.error("Could not increment play count for " .. file .. " because of an error while trying to look up the " .. self.sticker_name .. " sticker: " .. err)
    else
        local oldcount = tonumber(oldsticker) or 0
        mpd.set_song_sticker(file, self.sticker_name, tostring(oldcount + 1))
        log.info(file .. " has now been played " .. (oldcount + 1) .. " times.")
        
        -- NEW LOGIC: If loop is enabled, start the loop timer AFTER incrementing
        -- But only if this was a loop-check increment (not initial play) and loop mode is active
        if self.loop and not is_loop_check then
            -- This is the first increment of the song - check if we should start looping
            -- Loop will only work if the song has a valid duration (checked before calling this)
            self.is_loop_active = true -- Mark that we are in a loop
            self:start_loop_timer(file, song_id)
        elseif self.loop and is_loop_check then
            -- Loop check passed, continue the loop cycle
            self.is_loop_active = true
            self:start_loop_timer(file, song_id)
        else
            self.is_loop_active = false -- Ensure loop is off if mode is disabled
        end
    end
end

-- NEW FUNCTION: Start the loop timer
-- Waits for (remaining duration + LOOP_BUFFER_MS) then checks if song is still the same
-- If paused_remaining_ms is set, use that instead of calculating from current state
function M:start_loop_timer(file, song_id)
    self:cancel_timeout()
    
    local status = mpd.get_status()
    local current_song = mpd.get_current_song()
    
    if not current_song or current_song.id ~= song_id then
        log.info("Cannot start loop timer: Song has changed.")
        self.is_loop_active = false
        self.paused_remaining_ms = nil
        return
    end
    
    -- Get the song duration to check if it's valid before starting loop
    local duration_ms = duration_in_ms(current_song.duration)
    if duration_ms <= 0 then
        log.info("Cannot start loop timer: Song has invalid/zero duration. No loop for this song.")
        self.is_loop_active = false
        self.paused_remaining_ms = nil
        return
    end

    local wait_time_ms
    
    -- If we have a stored paused time, use it
    if self.paused_remaining_ms and self.paused_remaining_ms > 0 then
        wait_time_ms = self.paused_remaining_ms
        log.info("Resuming loop timer with stored remaining time: " .. wait_time_ms .. "ms")
        self.paused_remaining_ms = nil -- Clear the stored time
    else
        -- Calculate fresh
        local elapsed_ms = status.elapsed or 0
        local remaining_ms = duration_ms - elapsed_ms
        
        -- Add LOOP_BUFFER_MS buffer
        wait_time_ms = remaining_ms + LOOP_BUFFER_MS
        
        log.info("Starting loop timer for " .. song_id .. ". Calculated wait time: " .. wait_time_ms .. "ms.")
    end
    
    if wait_time_ms <= 0 then
        -- Song already finished or very short, increment immediately
        self:increment_playcount(file, song_id, true)
    else
        self.timeout_handle = sync.set_timeout(wait_time_ms, function ()
            self:increment_playcount(file, song_id, true)
        end)
    end
end

-- Calculate the target position in the song. Returns a negative value if target position would be past end of song.
-- Calling code will interpret negative values as "already reached, increment immediately if we haven't already"
---@param song_duration_ms number
function M:calculate_target_position(song_duration_ms)
    -- Short songs get play count incremented right away, no waiting
    if self.padding_factor_ms >= song_duration_ms then return -1 end
    if self.target_fraction ~= nil then
        -- Target desired fraction of song, but ensure at least padding_factor remaining
        local target = song_duration_ms * self.target_fraction
        return math.min(target, song_duration_ms - math.max(self.padding_factor_ms, SAFETY_FACTOR_MS))
    end
    -- No fraction specified, so just return the requested distance from start/end of song
    -- (Though leave at least 2 seconds before end of song, just for safety's sake)
    if self.from == "start" then
        local target = self.padding_factor_ms
        return math.min(target, song_duration_ms - SAFETY_FACTOR_MS)
    else
        -- Could do it this way:
        -- local target = song_duration_ms - self.padding_factor_ms
        -- return math.min(target, song_duration_ms - SAFETY_FACTOR_MS)
        -- But the below is exactly equivalent to that, and does one fewer subtraction
        return song_duration_ms - math.max(self.padding_factor_ms, SAFETY_FACTOR_MS)
    end
end

---@param song_duration_ms number
---@param already_elapsed_ms number
function M:calculate_time_to_wait(song_duration_ms, already_elapsed_ms)
    local target = self:calculate_target_position(song_duration_ms)
    return target - already_elapsed_ms
end

-- Set up the timeout for N (configurable, default 15) seconds before the end of the song
-- Once the timeout fires, we will increment the song's playCount sticker
-- We use the song's id (a unique value assigned by MPD) to ensure we never double-increment for a single play
-- We also need to know how much time has elapsed in the song so far (which can happen when unpausing), since that
-- will change the calculation for how long the tieout needs to be so that it triggers N seconds before the song ends
---@param song QueuedSong
---@param already_elapsed_ms number
function M:setup_timeout(song, already_elapsed_ms)
    self:cancel_timeout()
    already_elapsed_ms = already_elapsed_ms or 0
    
    -- Check if song duration is valid before proceeding
    local duration_ms = duration_in_ms(song.duration)
    if duration_ms <= 0 then
        log.warn("Song has invalid or zero duration (" .. tostring(song.duration) .. "). Incrementing play count once without loop.")
        self:increment_playcount(song.file, song.id)
        return
    end
    
    local time_to_wait_ms = self:calculate_time_to_wait(duration_ms, already_elapsed_ms)
    
    if time_to_wait_ms <= 0 then
        -- Already past target time: either it was a short song, or we were paused and unpaused.
        -- Either way, increment now without waiting
        self:increment_playcount(song.file, song.id)
    else
        -- Wait until chosen target time (by default, when song has 15 seconds (or less) to go), then increment play count
        self.timeout_handle = sync.set_timeout(time_to_wait_ms, function ()
            self:increment_playcount(song.file, song.id)
        end)
    end
end

-- Will be called when we unpause *or* when plugin starts up
-- In both cases, we want to check whether a song is already playing,
-- because the song's elapsed time needs to be taken into account when setting up the timeout
-- If loop is active, resume the loop timer with stored time. Otherwise, use standard timeout.
function M:resume_after_pause()
    local status = mpd.get_status()
    if status and status.state == "play" then
        local song = mpd.get_current_song()
        if song then
            if self.is_loop_active then
                -- We were in a loop, resume the loop timer immediately
                log.info("Resuming loop timer for song " .. song.id)
                self:start_loop_timer(song.file, song.id)
            else
                -- Standard playcount behavior
                self:setup_timeout(song, status.elapsed)
            end
        end
    end
end

--- @param _old_song QueuedSong
--- @param new_song QueuedSong
-- Will be called when a song changes.
function M:song_change(_old_song, new_song)
    if not self.enabled or new_song == nil or not new_song.file then
        self:cancel_timeout()
        self.is_loop_active = false -- Reset loop state on song change
        self.paused_remaining_ms = nil -- Clear paused time
        return
    end

    -- Reset loop state because a new song breaks the loop
    self.is_loop_active = false
    self.paused_remaining_ms = nil
    
    -- Always use standard timeout for first play of a new song
    self:setup_timeout(new_song, 0)
end

-- Will be called when playback is started, stopped or paused. A few cases need to be handled:
-- Stopping playback = cancel the timeout if it hasn't fired yet, because the song didn't play for long enough
-- Pausing playback = ditto, but when playback resumes the song's time elapsed so far will be counted
-- Unpausing playback = the timeout (which was canceled when playback was paused) can should be restarted now
-- Starting playback = trigger setup
function M:state_change(old, new)
    if not self.enabled then
        self:cancel_timeout()
        return
    end

    if new == "pause" then 
        -- PAUSE HANDLING: Capture remaining time if in loop mode
        if self.is_loop_active and self.timeout_handle then
            -- We need to calculate how much time is left on the current timer
            -- Since we can't easily get the remaining time from the handle, we recalculate based on current state
            local status = mpd.get_status()
            local current_song = mpd.get_current_song()
            
            if current_song then
                local duration_ms = duration_in_ms(current_song.duration)
                local elapsed_ms = status.elapsed or 0
                local remaining_ms = duration_ms - elapsed_ms
                
                -- Add the LOOP_BUFFER_MS back to get the original wait time
                local wait_time_ms = remaining_ms + LOOP_BUFFER_MS
                
                -- Store this time
                self.paused_remaining_ms = wait_time_ms
                log.info("Paused. Stored loop timer remaining time: " .. wait_time_ms .. "ms")
            end
        end
        self:cancel_timeout() 
    elseif new == "stop" then 
        self:cancel_timeout() 
        self.paused_remaining_ms = nil -- Clear paused time on stop
    end
    
    if new == "play" then 
        self:resume_after_pause() 
    end
end

--- @param value number
--- @param warning string
function M:clamp_between_0_and_1(value, warning)
    if value < 0 then
        log.warn(warning)
        return 0
    elseif value > 1 then
        log.warn(warning)
        return 1
    end
    return value
end

function M:parse_fraction(fractionStr)
    local slash = string.find(fractionStr, "/")
    if slash ~= nil then
        local numerator = string.sub(fractionStr, 0, slash-1)
        local denominator = string.sub(fractionStr, slash+1)
        return tonumber(numerator) / tonumber(denominator)
    else
        -- No slash? Maybe it's one number written like 0.75
        return tonumber(fractionStr)
    end
end

function M:setup(args)
    self.enabled = (args.enabled ~= nil) and args.enabled or true
    self.loop = (args.loop ~= nil) and args.loop or false -- Parse loop option
    
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
        self.target_fraction = self:clamp_between_0_and_1(args.target_fraction, "The target_fraction parameter should be between 0 and 1.")
    elseif args.target_percent ~= nil then
        self.target_fraction = self:clamp_between_0_and_1(args.target_percent / 100, "The target_percent parameter should be between 0 and 100.")
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

    -- Same logic for resuming after pause (check times elapsed, etc) works here too, so just reuse it
    -- However, resume_after_pause needs to call mpd.get_status(), and during plugin setup, rmpcd isn't running yet
    -- But by setting a timeout of 0, we ensure we get queued up to run immediately after rmpcd setup completes
    -- This neatly solves the chicken-and-egg problem
    sync.set_timeout(0, function ()
      self:resume_after_pause()
    end)
end

-- We subscribe to both playCount and playcount channels in case someone mistypes the name
M.subscribed_channels = { "rmpcd.playcount", "rmpcd.playCount" }

-- We can ignore the channel here because we're only subscribed to our own comm channels
function M:message(_channel, message)
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
    -- Changing parameters on-the-fly: target fraction
    elseif string.find(message, "target_fraction:") == 1 then
        local len = string.len("target_fraction:")
        local fractionStr = string.sub(message, len) -- Do not call tonumber yet
        local fractionValue = self:parse_fraction(fractionStr)
        if fractionValue ~= nil then
            self.target_fraction = self:clamp_between_0_and_1(fractionValue, "The target_fraction parameter should be between 0 and 1.")
        else
            log.warn("target_fraction message should have payload that is either a fraction like 2/3 (two numbers separated by a slash, with no spaces), or else a single number between 0 and 1 (like 0.75). Instead, found " .. fractionStr)
        end
    -- Changing parameters on-the-fly: target percent
    elseif string.find(message, "target_percent:") == 1 then
        local len = string.len("target_percent:")
        local percent = tonumber(string.sub(message, len))
        if percent ~= nil then
            self.target_fraction = self:clamp_between_0_and_1(percent / 100, "The target_percent parameter should be between 0 and 100.")
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
    -- Loop control messages
    elseif message == "loop_enable" then
        self.loop = true
        log.info("Loop playcount enabled")
        -- If a song is currently playing, start the loop timer immediately
        local status = mpd.get_status()
        local current_song = mpd.get_current_song()
        if status and status.state == "play" and current_song then
            self.is_loop_active = true
            self:start_loop_timer(current_song.file, current_song.id)
        end
    elseif message == "loop_disable" then
        self.loop = false
        self.is_loop_active = false
        self.paused_remaining_ms = nil
        self:cancel_timeout() -- Cancel any active loop timer
        log.info("Loop playcount disabled")
    elseif message == "loop_toggle" then
        self.loop = not self.loop
        if self.loop then
            log.info("Loop playcount enabled")
            -- If a song is currently playing, start the loop timer immediately
            local status = mpd.get_status()
            local current_song = mpd.get_current_song()
            if status and status.state == "play" and current_song then
                self.is_loop_active = true
                self:start_loop_timer(current_song.file, current_song.id)
            end
        else
            self.loop = false
            self.is_loop_active = false
            self.paused_remaining_ms = nil
            self:cancel_timeout()
            log.info("Loop playcount disabled")
        end
    end
end

return M
