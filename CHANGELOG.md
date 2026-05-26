# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.2] - 2026-05-26

### Added
- Can now increment playCount from start of song as well as from end
- Can choose start/end at setup time, or while plugin is running via messages
- New parameter `target_fraction` to let increment point be based on song length
  - Example: `setup({target_fraction = 2/3})` to increment playCount when
    a song has played for two-thirds of its total duration
  - Value should be between 0 and 1
- New parameter `target_percent` similar to target_fraction
  - Value should be between 0 and 100
- target_fraction and target_percent configurable after plugin starts
  - Format: `target_fraction:3/4` or `target_fraction:0.75`
  - Or for percent: `target_percent:66.67` or `target_percent:75`

## [0.0.1] - 2026-05-09

### Added
- Initial release
- playCount sticker updated when song is nearly finished
- Padding (time between update moment and end of song) configurable at setup time
- Padding configurable after plugin starts by passing messages
- Padding can be set in either seconds or milliseconds
- Sticker name configurable at setup time
- Sticker name configurable by passing messages

[Unreleased]: https://github.com/username/repo/compare/v0.0.2...HEAD
[0.0.2]: https://github.com/username/repo/releases/tag/v0.0.2
[0.0.1]: https://github.com/username/repo/releases/tag/v0.0.1
