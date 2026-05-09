A plugin for [rmpcd](https://rmpc.mierak.dev/rmpcd/) to increment `playCount` when a song finishes playing.

### Why?

The [rmpcd documentation](https://rmpc.mierak.dev/rmpcd/) includes a plugin to increment a `playCount` sticker on songs when they start playing. I prefer incrementing `playCount` when a song finishes playing, so I wrote a plugin to do that.

However, since it's not 100% reliable to be notified the moment a song finishes playing (the notification might well arrive after the *next* song has started), there's a built-in padding factor (defaulting to 15 seconds). A song will have its `playCount` incremented about 15 seconds before the end of the song.

### Instructions

To use this plugin:

1. Make sure you have `sticker_file` configured in your MPD settings. This plugin will not work if you don't have an MPD sticker file.
2. Install [rmpcd](https://rmpc.mierak.dev/rmpcd/) and run `rmpcd init` to get an `init.lua` file.
3. Go to the place where `init.lua` was saved (probably `$HOME/.config/rmpcd/`) and create a `plugins` folder if it doesn't already exist.
4. Clone this repository and copy the `playcount.lua` file into your `$HOME/.config/rmpcd/plugins/` folder.
5. Add the line `rmpcd.install("plugins.playcount")` to your `init.lua` file.
6. (Optional) If you want to change the defaults, for example to allow just 10 seconds of padding instead of the default of 15 seconds, then change that `rmpcd.install` line to:
    ```lua
    rmpcd.install('plugins.playcount'):setup({
      padding_factor_seconds = 10,
    })
    ```
    You can also use `padding_factor_milliseconds` instead of `padding_factor_seconds` if you like, e.g. `padding_factor_milliseconds=2500` for 2.5 seconds of padding. (I recommend at least 5 seconds of padding, but I haven't tested it). Another option you can change is the `sticker_name`, though you should use the sticker name `playCount` (the default) if you want to be able to interoperate with other MPD clients. (See https://github.com/jcorporation/mpd-stickers for a useful list of what stickers are used by what MPD clients).

### License

BSD 3-Clause open-source license; see [LICENSE](LICENSE) for complete copyright and license statement.

### How it works

The way this plugin works is that whenever a new song starts playing, it sets a timer for (length of song - padding factor), i.e. 15 seconds before the end of the song if you use the default settings. When you pause or stop playback, the timer is stopped. (If you unpause playback, the timer will resume, still aimed at 15 seconds before the end of the song). When the timer expires, it will increment the playCount sticker for the current song. Any songs that are shorter than the padding factor (by default, 15 seconds) will instead have their playCount incremented when they start playing.

The plugin ensures that only one timer will run at once. So if the song changes before the timer has expired (i.e., you skipped to the next song in the queue without letting the current one play to the end, or you used seeking to skip parts of the current song that added up to more than 15 seconds, so that a new song starts before the (song duration - 15 seconds) timer has elapsed), then the old song's timer will be canceled and its playCount will not be incremented.

### Weirdness

There are two corner cases where the plugin's behavior might not be what you expect:

1. If you skip over parts of a song by seeking, but then pause playback, when you unpause, the fact that you skipped over parts of the song will be "forgotten", and the plugin will behave as if you had played through the entirety of the song so far. That's because when MPD reports the "time elapsed in current song" value, it's reporting the *current position* in the song, which is usually the same as "how long has this song been playing?". But if you skipped through the song with seek features, the "elapsed" time will not be the same as "how long has this song been playing?". When you unpause playback, this plugin uses the time elapsed reported by MPD in order to calculate how long to set the timer for.
    * There's not much I can do about this one. There's no way to tell, when MPD playback is unpaused, whether it had previously been "seeked".
2. If you set MPD to "repeat" mode AND "single" mode (which causes it to repeat one single song on loop, over and over), the plugin will only increment playCount **ONCE**, no matter how often the song is looped. This is because the `song_change` event, which the plugin depends on, only triggers when a *new* song is played, and not when the current song is repeated.
    * If you have the same song queued up multiple times in a row, the playCount *WILL* increment for each of them. It's only when you loop a single song over and over that it will increment only once. This is because MPD stores an internal `song_id` value for each instance of a queued song, and the plugin uses that to keep track. If you just played song ID 233 and song ID 234 is the same file ("My Favorite Song.flac"), then the playCount sticker for My Favorite Song.flac will be incremented twice, once for ID 233 and once for ID 234. But if you loop the song, then the plugin will see ID 233 looping over and over and will say "I already incremented the playCount for ID 233 once, I won't do it again".
    * The reason the plugin works that way is because if you pause and unpause playback, it looks at the time elapsed of the current song to decide how to set the timer. And if the current song has less than 15 seconds (or whatever you configured) left, it will check whether the song's playCount has already been incremented, and if it hasn't been incremented yet, it will assume that something malfunctioned earlier and increment the playCount. (This can happen, for example, if you start the plugin while a song is currently playing: if the first time the plugin finds out about the 4-minute song currently playing is at the 3:52 time marker, it will say "Hey, that song has been playing for long enough to qualify, and I haven't added to its playCount yet; let me fix that right now".
    * If you actually WANT to increment the playCount sticker by 50 for your favorite song that you looped 50 times, you can do that manually by opening up your sticker database with SQLite (e.g., `sqlite3 ~/.cache/mpd/sticker.sql`) and running `update sticker set value = value + 50 where uri = 'My Favorite Song.mp3' and name = 'playCount' ;`
    * In theory, I could do something about this one: after incrementing the playCount, I could set a timer for (remaining song length + 5 seconds) and see if the same song_id is still playing. In practice, I will probably leave the logic as-is, because that's a complicated bit of logic for a not-much-in-demand corner case. But if you actually want this feature (and actually read that far), open an issue in this repo and let me know, and I'll see what I can do.
