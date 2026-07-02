local dfpwm = require("cc.audio.dfpwm")

-- =========================================================
-- Peripherals
-- =========================================================

local speaker = peripheral.find("speaker")
if not speaker then
	error("No speaker attached.", 0)
end

local speakerName = peripheral.getName(speaker)
local monitors = { peripheral.find("monitor") }

-- =========================================================
-- Configuration
-- =========================================================

local CHUNK_SIZE = 16 * 1024
local SAMPLE_RATE = 48000
local SECONDS_PER_CHUNK = (CHUNK_SIZE * 8) / SAMPLE_RATE

local radioConfigs = {
	stationName = "ULTRAKILL",
	EAS = false,

	-- 0 = mute, 1 = normal, 3 = practical max.
	volume = 3,

	youtubeApi = "https://cc.specifix.dev/ipod",
	youtubeVersion = "2.1",
}

-- =========================================================
-- Playback state
-- =========================================================

local songName = "None"
local songDurationSeconds = 0
local numChunks = 0
local currentChunk = 0

local playbackQueue = {}
local currentTrack = nil
local isPlaying = false
local lastPlaybackError = nil

local running = true
local stopRequested = false
local skipRequested = false

-- Incrementing this invalidates old playback loops.
local playbackGeneration = 0

local QUEUE_EVENT = "radio_queue_changed"
local INTERRUPT_EVENT = "radio_playback_interrupt"

-- =========================================================
-- Rednet
-- =========================================================

local rednetEnabled = false
local modems = { peripheral.find("modem") }

for _, modem in ipairs(modems) do
	if modem.isWireless() then
		local modemName = peripheral.getName(modem)

		if not rednet.isOpen(modemName) then
			rednet.open(modemName)
		end

		rednetEnabled = true
		break
	end
end

-- =========================================================
-- Utilities
-- =========================================================

local function trim(text)
	return (text:gsub("^%s*(.-)%s*$", "%1"))
end

local function clamp(value, minimum, maximum)
	return math.max(minimum, math.min(maximum, value))
end

local function to_mss(totalSeconds)
	local minutes = math.floor(totalSeconds / 60)
	local seconds = math.floor(totalSeconds % 60)

	return string.format("%d:%02d", minutes, seconds)
end

local function getLength(chunks)
	return to_mss(chunks * SECONDS_PER_CHUNK)
end

local function truncate(text, maxLength)
	text = tostring(text or "")

	if #text <= maxLength then
		return text
	end

	if maxLength <= 3 then
		return text:sub(1, maxLength)
	end

	return text:sub(1, maxLength - 3) .. "..."
end

local function getFileDisplayName(path)
	local name = path:match("([^/]+)$") or path
	return name:gsub("%.dfpwm$", "")
end

local function getTotalChunks(file)
	local size = fs.getSize(file)

	if not size then
		return 0
	end

	return math.ceil(size / CHUNK_SIZE)
end

local function getResponseHeader(handle, wantedHeader)
	if not handle.getResponseHeaders then
		return nil
	end

	for header, value in pairs(handle.getResponseHeaders() or {}) do
		if string.lower(header) == string.lower(wantedHeader) then
			return value
		end
	end

	return nil
end

local function getTrackName(track)
	return tostring(track.name or track.title or "Unknown track")
end

local function getTrackArtist(track)
	return tostring(track.artist or track.channel or "")
end

local function getTrackDuration(track)
	local artist = getTrackArtist(track)
	local hours, minutes, seconds = artist:match("^(%d+):(%d%d):(%d%d)")

	if hours then
		return tonumber(hours) * 3600 + tonumber(minutes) * 60 + tonumber(seconds)
	end

	minutes, seconds = artist:match("^(%d+):(%d%d)")

	if minutes then
		return tonumber(minutes) * 60 + tonumber(seconds)
	end

	return nil
end

local function trackLabel(track)
	if not track then
		return "None"
	end

	local artist = getTrackArtist(track)

	if artist ~= "" then
		return getTrackName(track) .. " - " .. artist
	end

	return getTrackName(track)
end

local function makeYoutubeUrl(params)
	local base = tostring(radioConfigs.youtubeApi)
	local separator = base:find("?", 1, true) and "&" or "?"

	local query = {
		"v=" .. textutils.urlEncode(tostring(radioConfigs.youtubeVersion)),
	}

	for key, value in pairs(params) do
		table.insert(query, key .. "=" .. textutils.urlEncode(tostring(value)))
	end

	return base .. separator .. table.concat(query, "&")
end

local function normaliseConfig()
	radioConfigs.volume = clamp(tonumber(radioConfigs.volume) or 3, 0, 3)

	if type(radioConfigs.EAS) == "string" then
		local value = radioConfigs.EAS:lower()

		radioConfigs.EAS = value == "true" or value == "1" or value == "yes" or value == "on"
	end
end

-- =========================================================
-- radio.env
-- =========================================================

local function readEnvOverride()
	if not fs.exists("/radio.env") then
		return
	end

	local handle = fs.open("/radio.env", "r")
	if not handle then
		return
	end

	local success = 0
	local lineNumber = 0

	while true do
		local line = handle.readLine()

		if not line then
			break
		end

		lineNumber = lineNumber + 1
		line = trim(line)

		if line ~= "" and not line:match("^#") then
			local key, value = line:match("^([^=]+)=(.*)$")

			if not key then
				printError("Malformed /radio.env line " .. lineNumber)
			else
				radioConfigs[trim(key)] = trim(value)
				success = success + 1
			end
		end
	end

	handle.close()
	normaliseConfig()

	if success > 0 then
		print("/radio.env loaded: " .. success .. " override(s).")
	end
end

-- =========================================================
-- Rednet + monitor
-- =========================================================

local broadcastFailed = false

local function broadcast(audioChunk)
	if not rednetEnabled then
		return
	end

	local ok, err = pcall(rednet.broadcast, {
		songName = songName,
		stationName = radioConfigs.stationName,
		currentChunk = currentChunk,
		numChunks = numChunks,
		audio_chunk = audioChunk,
		EAS = radioConfigs.EAS,
	}, "RADIO")

	if not ok and not broadcastFailed then
		broadcastFailed = true
		printError("Rednet broadcast failed: " .. tostring(err))
	end
end

local function updateMonitors()
	for _, monitor in ipairs(monitors) do
		local width = select(1, monitor.getSize())

		monitor.setTextScale(0.5)
		monitor.setBackgroundColor(colors.black)
		monitor.clear()

		monitor.setCursorPos(1, 1)
		monitor.setTextColor(colors.yellow)
		monitor.write("MK.II Radio Station ")

		monitor.setTextColor(colors.white)
		monitor.write("| by ")

		monitor.setTextColor(colors.yellow)
		monitor.write("Specifix")

		monitor.setCursorPos(1, 2)
		monitor.setTextColor(colors.white)
		monitor.write("Currently playing: ")

		if songName == "None" then
			monitor.setTextColor(colors.red)
		else
			monitor.setTextColor(colors.yellow)
		end

		monitor.write(truncate(songName, math.max(1, width - #"Currently playing: ")))

		if songName ~= "None" then
			monitor.setCursorPos(1, 4)
			monitor.setTextColor(colors.white)
			monitor.write("Playing ")

			monitor.setTextColor(colors.yellow)

			if numChunks > 0 then
				monitor.write(currentChunk .. "/" .. numChunks .. " chunks")
			else
				monitor.write(currentChunk .. " chunks")
			end

			monitor.setTextColor(colors.white)
			monitor.write(" ")

			monitor.setTextColor(colors.yellow)

			if numChunks > 0 then
				local totalDuration = songDurationSeconds > 0 and to_mss(songDurationSeconds) or getLength(numChunks)
				local elapsedDuration = songDurationSeconds > 0
						and to_mss(math.min(currentChunk * SECONDS_PER_CHUNK, songDurationSeconds))
					or getLength(currentChunk)

				monitor.write("(" .. elapsedDuration .. " / " .. totalDuration .. ")")
			else
				monitor.write("(" .. getLength(currentChunk) .. " / streaming)")
			end
		end

		if radioConfigs.EAS then
			monitor.setCursorPos(1, 5)
			monitor.setTextColor(colors.red)
			monitor.write("! EAS MODE ACTIVE !")
		end

		if rednetEnabled then
			monitor.setCursorPos(1, 6)
			monitor.setTextColor(colors.yellow)
			monitor.write("REDNET ACTIVE, CAN BROADCAST")

			monitor.setCursorPos(1, 7)
			monitor.setTextColor(colors.white)
			monitor.write("Station: ")

			monitor.setTextColor(colors.yellow)
			monitor.write(tostring(radioConfigs.stationName))

			monitor.setCursorPos(1, 8)
			monitor.setTextColor(colors.white)
			monitor.write("Channel: ")

			monitor.setTextColor(colors.yellow)
			monitor.write("#" .. os.getComputerID())
		end

		monitor.setCursorPos(1, 9)
		monitor.setTextColor(colors.white)
		monitor.write("Volume: ")

		monitor.setTextColor(colors.yellow)
		monitor.write(string.format("%.1f / 3", radioConfigs.volume))

		monitor.setCursorPos(1, 10)
		monitor.setTextColor(colors.white)
		monitor.write("Queue: ")

		monitor.setTextColor(colors.yellow)
		monitor.write(#playbackQueue .. " track(s)")

		monitor.setCursorPos(1, 12)
		monitor.setTextColor(colors.gray)
		monitor.write("~ 2024-2026 (C) CURVE Technologies ~")
	end

	term.setTextColor(colors.white)
end

local function setNowPlaying(name, chunks, durationSeconds)
	songName = name or "None"
	songDurationSeconds = durationSeconds or 0
	numChunks = chunks or 0
	currentChunk = 0

	updateMonitors()
	broadcast(nil)
end

local function resetRadio()
	setNowPlaying("None", 0)
end

-- =========================================================
-- Queue controls
-- =========================================================

local function signalPlayer()
	os.queueEvent(QUEUE_EVENT)
end

local function interruptCurrentPlayback()
	local oldGeneration = playbackGeneration

	playbackGeneration = playbackGeneration + 1
	speaker.stop()

	-- Lets a coroutine stuck waiting on speaker audio wake immediately.
	os.queueEvent(INTERRUPT_EVENT, oldGeneration)
end

local function queueTracks(tracks, playNow)
	if #tracks == 0 then
		return false, "No playable tracks found"
	end

	if playNow then
		playbackQueue = {}

		for _, track in ipairs(tracks) do
			table.insert(playbackQueue, track)
		end

		stopRequested = false

		if currentTrack then
			skipRequested = true
			interruptCurrentPlayback()
		end
	else
		for _, track in ipairs(tracks) do
			table.insert(playbackQueue, track)
		end
	end

	updateMonitors()
	signalPlayer()

	return true
end

local function stopPlayback()
	playbackQueue = {}
	stopRequested = true
	skipRequested = false

	interruptCurrentPlayback()
	updateMonitors()
	signalPlayer()
end

local function skipTrack()
	if not currentTrack then
		return false, "Nothing is currently playing"
	end

	skipRequested = true
	interruptCurrentPlayback()

	return true
end

local function clearQueue()
	playbackQueue = {}
	updateMonitors()
	signalPlayer()
end

-- =========================================================
-- Speaker playback helpers
-- =========================================================

local function waitForSpeakerEmptyOrInterrupt(generation)
	local reason = nil

	parallel.waitForAny(function()
		while true do
			local _, side = os.pullEvent("speaker_audio_empty")

			if side == speakerName then
				reason = "speaker_empty"
				return
			end
		end
	end, function()
		while true do
			local _, targetGeneration = os.pullEvent(INTERRUPT_EVENT)

			if targetGeneration == generation then
				reason = "interrupted"
				return
			end
		end
	end)

	return reason == "speaker_empty" and generation == playbackGeneration
end

local function queueAudio(buffer, generation)
	while generation == playbackGeneration and running do
		if speaker.playAudio(buffer, radioConfigs.volume) then
			return true
		end

		if not waitForSpeakerEmptyOrInterrupt(generation) then
			return false
		end
	end

	return false
end

local function playReader(nextChunk, generation)
	local decoder = dfpwm.make_decoder()
	local chunksPlayed = 0

	while running and generation == playbackGeneration do
		local chunk = nextChunk()

		if not chunk or #chunk == 0 then
			break
		end

		chunksPlayed = chunksPlayed + 1
		currentChunk = chunksPlayed

		updateMonitors()
		broadcast(chunk)

		local buffer = decoder(chunk)

		if not queueAudio(buffer, generation) then
			return false, chunksPlayed, "cancelled"
		end
	end

	if generation ~= playbackGeneration or not running then
		return false, chunksPlayed, "cancelled"
	end

	-- Wait for the final queued speaker buffer to actually finish.
	if chunksPlayed > 0 and not waitForSpeakerEmptyOrInterrupt(generation) then
		return false, chunksPlayed, "cancelled"
	end

	return true, chunksPlayed
end

-- =========================================================
-- Local .dfpwm tracks
-- =========================================================

local function normaliseLocalFile(input)
	local file = trim(input)

	if not file:lower():match("%.dfpwm$") then
		file = file .. ".dfpwm"
	end

	return file
end

local function makeLocalTrack(input)
	local file = normaliseLocalFile(input)

	if not fs.exists(file) then
		return nil, "File not found: " .. file
	end

	return {
		type = "local",
		file = file,
		name = getFileDisplayName(file),
		artist = "Local DFPWM",
	}
end

local function playLocalTrack(track, generation)
	if not fs.exists(track.file) then
		return false, "File disappeared: " .. track.file
	end

	local handle = fs.open(track.file, "rb")
	if not handle then
		return false, "Could not open: " .. track.file
	end

	setNowPlaying(trackLabel(track), getTotalChunks(track.file))

	local finished, _, err = playReader(function()
		return handle.read(CHUNK_SIZE)
	end, generation)

	handle.close()

	if not finished then
		return false, err
	end

	return true
end

local function listDfpwmFiles()
	local files = fs.list("/")
	local audioFiles = {}

	for _, file in ipairs(files) do
		if file:lower():match("%.dfpwm$") then
			table.insert(audioFiles, file:gsub("%.dfpwm$", ""))
		end
	end

	table.sort(audioFiles)

	term.setTextColor(colors.yellow)
	print("Available Audio Files (" .. #audioFiles .. "):")
	term.setTextColor(colors.white)

	for index, file in ipairs(audioFiles) do
		print(index .. ". " .. file)
	end
end

-- =========================================================
-- YouTube result resolving
-- =========================================================

local function searchYoutube(query)
	local url = makeYoutubeUrl({
		search = query,
	})

	local handle, err = http.get(url)

	if not handle then
		return nil, err or "Search request failed"
	end

	local raw = handle.readAll()
	handle.close()

	local ok, results = pcall(textutils.unserialiseJSON, raw)

	if not ok or type(results) ~= "table" then
		return nil, "Invalid response from YouTube backend"
	end

	return results
end

local function makeYoutubeTrack(result)
	if type(result) ~= "table" or not result.id then
		return nil
	end

	return {
		type = "youtube",
		id = tostring(result.id),
		name = getTrackName(result),
		artist = getTrackArtist(result),
	}
end

local function expandYoutubeResult(result)
	local tracks = {}

	if result.type == "playlist" then
		for _, item in ipairs(result.playlist_items or {}) do
			local track = makeYoutubeTrack(item)

			if track then
				table.insert(tracks, track)
			end
		end
	else
		local track = makeYoutubeTrack(result)

		if track then
			table.insert(tracks, track)
		end
	end

	return tracks
end

local function chooseYoutubeResult(query)
	local results, err = searchYoutube(query)

	if not results then
		return nil, err
	end

	if #results == 0 then
		return nil, "No results found"
	end

	local isUrl = query:match("^https?://") ~= nil

	if isUrl or #results == 1 then
		return expandYoutubeResult(results[1])
	end

	local maxResults = math.min(#results, 10)

	print("")
	for index = 1, maxResults do
		local result = results[index]

		term.setTextColor(colors.yellow)
		write(index .. ". ")

		term.setTextColor(colors.white)
		write(getTrackName(result))

		local artist = getTrackArtist(result)

		if artist ~= "" then
			term.setTextColor(colors.lightGray)
			print(" - " .. artist)
		else
			print()
		end
	end

	term.setTextColor(colors.yellow)
	write("Select [1-" .. maxResults .. ", blank cancels]> ")
	term.setTextColor(colors.white)

	local selected = trim(read())

	if selected == "" then
		return nil, "Cancelled"
	end

	selected = tonumber(selected)

	if not selected or selected < 1 or selected > maxResults then
		return nil, "Invalid selection"
	end

	return expandYoutubeResult(results[selected])
end

local function playYoutubeTrack(track, generation)
	local duration = getTrackDuration(track)
	local estimatedChunks = duration and math.ceil(duration / SECONDS_PER_CHUNK) or 0

	setNowPlaying(trackLabel(track), estimatedChunks, duration)

	local url = makeYoutubeUrl({
		id = track.id,
	})

	local handle, err = http.get(url, nil, true)

	if not handle then
		return false, err or "Could not open DFPWM stream"
	end

	-- A stop/skip may have happened while http.get was waiting.
	if generation ~= playbackGeneration or not running then
		handle.close()
		return false, "cancelled"
	end

	local contentLength = tonumber(getResponseHeader(handle, "content-length"))
	numChunks = contentLength and math.ceil(contentLength / CHUNK_SIZE) or estimatedChunks
	currentChunk = 0

	updateMonitors()
	broadcast(nil)

	local finished, _, playErr = playReader(function()
		return handle.read(CHUNK_SIZE)
	end, generation)

	handle.close()

	if not finished then
		return false, playErr
	end

	return true
end

local function playTrack(track, generation)
	if track.type == "local" then
		return playLocalTrack(track, generation)
	end

	if track.type == "youtube" then
		return playYoutubeTrack(track, generation)
	end

	return false, "Unknown track type"
end

-- =========================================================
-- Background player
-- =========================================================

local function playerLoop()
	while running do
		if #playbackQueue == 0 then
			isPlaying = false
			currentTrack = nil

			if songName ~= "None" then
				resetRadio()
			end

			stopRequested = false
			os.pullEvent(QUEUE_EVENT)
		else
			currentTrack = table.remove(playbackQueue, 1)
			isPlaying = true
			lastPlaybackError = nil

			local generation = playbackGeneration

			local callOk, finished, err = pcall(playTrack, currentTrack, generation)

			if not callOk then
				lastPlaybackError = tostring(finished)
			elseif not finished and err ~= "cancelled" then
				lastPlaybackError = tostring(err)
			end

			currentTrack = nil
			isPlaying = false

			if stopRequested then
				stopRequested = false
				playbackQueue = {}
				resetRadio()
			elseif skipRequested then
				skipRequested = false
			elseif #playbackQueue == 0 then
				resetRadio()
			end

			updateMonitors()
		end
	end
end

-- =========================================================
-- Terminal commands
-- =========================================================

local function showQueue()
	term.setTextColor(colors.yellow)
	print("Now playing:")

	term.setTextColor(colors.white)

	if currentTrack then
		print("  " .. trackLabel(currentTrack))
	else
		print("  Nothing")
	end

	term.setTextColor(colors.yellow)
	print("Queue (" .. #playbackQueue .. "):")
	term.setTextColor(colors.white)

	if #playbackQueue == 0 then
		print("  Empty")
		return
	end

	for index, track in ipairs(playbackQueue) do
		if index > 15 then
			print("  ... and " .. (#playbackQueue - 15) .. " more")
			break
		end

		print("  " .. index .. ". " .. trackLabel(track))
	end
end

local function showStatus()
	term.setTextColor(colors.yellow)
	print("Radio status")
	term.setTextColor(colors.white)

	print("  Playing: " .. (isPlaying and "yes" or "no"))
	print("  Track: " .. (currentTrack and trackLabel(currentTrack) or "None"))
	print("  Progress: " .. currentChunk .. (numChunks > 0 and ("/" .. numChunks) or " chunks"))
	print("  Volume: " .. string.format("%.1f", radioConfigs.volume) .. " / 3")
	print("  Queue: " .. #playbackQueue .. " track(s)")

	if lastPlaybackError then
		term.setTextColor(colors.red)
		print("  Last error: " .. lastPlaybackError)
		term.setTextColor(colors.white)
	end
end

local function showHelp()
	term.setTextColor(colors.yellow)
	print("Commands:")
	term.setTextColor(colors.white)

	print("  yt <search or YouTube URL>    Replace current track + queue")
	print("  add <search or YouTube URL>   Add video or whole playlist")
	print("  local <file>                  Play local .dfpwm now")
	print("  addlocal <file>               Queue local .dfpwm")
	print("  skip                          Skip current track")
	print("  stop                          Stop playback and clear queue")
	print("  clear                         Clear upcoming queue only")
	print("  queue / q                     Show current queue")
	print("  status                        Show playback status")
	print("  volume <0-3> / vol <0-3>      Set volume")
	print("  files                         List local .dfpwm files")
	print("  help                          Show this list")
	print("  exit                          Stop and quit")
end

local function resolveAndQueueYoutube(query, playNow)
	term.setTextColor(colors.yellow)
	print("Searching YouTube...")
	term.setTextColor(colors.white)

	local tracks, err = chooseYoutubeResult(query)

	if not tracks then
		term.setTextColor(colors.red)
		print("Search failed: " .. tostring(err))
		term.setTextColor(colors.white)
		return
	end

	local ok, queueErr = queueTracks(tracks, playNow)

	if not ok then
		term.setTextColor(colors.red)
		print("Queue error: " .. tostring(queueErr))
		term.setTextColor(colors.white)
		return
	end

	term.setTextColor(colors.yellow)

	if playNow then
		print("Playing now: " .. trackLabel(tracks[1]))

		if #tracks > 1 then
			print("Added " .. (#tracks - 1) .. " additional playlist track(s).")
		end
	else
		print("Added " .. #tracks .. " track(s) to queue.")
	end

	term.setTextColor(colors.white)
end

local function queueLocalFile(input, playNow)
	local track, err = makeLocalTrack(input)

	if not track then
		term.setTextColor(colors.red)
		print(err)
		term.setTextColor(colors.white)
		return
	end

	local ok, queueErr = queueTracks({ track }, playNow)

	if not ok then
		term.setTextColor(colors.red)
		print(queueErr)
		term.setTextColor(colors.white)
		return
	end

	term.setTextColor(colors.yellow)

	if playNow then
		print("Playing now: " .. trackLabel(track))
	else
		print("Added to queue: " .. trackLabel(track))
	end

	term.setTextColor(colors.white)
end

local function commandLoop()
	while running do
		term.setTextColor(colors.yellow)
		write("\nPlayer> ")
		term.setTextColor(colors.white)

		local input = trim(read())

		if input ~= "" then
			local command, argument = input:match("^(%S+)%s*(.-)%s*$")
			command = command and command:lower() or ""

			if command == "exit" or command == "quit" then
				running = false
				stopPlayback()
				signalPlayer()
				break
			elseif command == "help" then
				showHelp()
			elseif command == "files" then
				listDfpwmFiles()
			elseif command == "queue" or command == "q" then
				showQueue()
			elseif command == "status" or command == "now" then
				showStatus()
			elseif command == "clear" then
				clearQueue()

				term.setTextColor(colors.yellow)
				print("Upcoming queue cleared.")
				term.setTextColor(colors.white)
			elseif command == "stop" then
				stopPlayback()

				term.setTextColor(colors.yellow)
				print("Playback stopped and queue cleared.")
				term.setTextColor(colors.white)
			elseif command == "skip" or command == "next" then
				local ok, err = skipTrack()

				if ok then
					term.setTextColor(colors.yellow)
					print("Skipping current track...")
				else
					term.setTextColor(colors.red)
					print(err)
				end

				term.setTextColor(colors.white)
			elseif command == "volume" or command == "vol" then
				if argument == "" then
					term.setTextColor(colors.yellow)
					print("Current volume: " .. radioConfigs.volume .. " / 3")
					print("Use: volume <0-3>")
					term.setTextColor(colors.white)
				else
					local volume = tonumber(argument)

					if not volume then
						term.setTextColor(colors.red)
						print("Volume must be a number from 0 to 3.")
					elseif volume < 0 or volume > 3 then
						term.setTextColor(colors.red)
						print("Volume must be between 0 and 3.")
					else
						radioConfigs.volume = volume
						updateMonitors()

						term.setTextColor(colors.yellow)
						print("Volume set to " .. volume .. " / 3")
					end

					term.setTextColor(colors.white)
				end
			elseif command == "yt" then
				if argument == "" then
					printError("Use: yt <search terms or YouTube URL>")
				else
					resolveAndQueueYoutube(argument, true)
				end
			elseif command == "add" then
				if argument == "" then
					printError("Use: add <search terms or YouTube URL>")
				else
					resolveAndQueueYoutube(argument, false)
				end
			elseif command == "local" then
				if argument == "" then
					printError("Use: local <filename>")
				else
					queueLocalFile(argument, true)
				end
			elseif command == "addlocal" then
				if argument == "" then
					printError("Use: addlocal <filename>")
				else
					queueLocalFile(argument, false)
				end
			else
				-- Preserve old behaviour:
				-- typing a filename plays filename.dfpwm immediately.
				queueLocalFile(input, true)
			end
		end
	end
end

-- =========================================================
-- Startup
-- =========================================================

term.clear()
term.setCursorPos(1, 1)

print("MK.II Radio Station | by Specifix")

readEnvOverride()
normaliseConfig()

if rednetEnabled then
	print("Rednet active. Broadcasting on protocol RADIO.")
else
	print("No wireless modem found. Local speaker mode only.")
end

print("Volume: " .. radioConfigs.volume .. " / 3")
print("")

resetRadio()
showHelp()
print("")
listDfpwmFiles()

-- Both loops run concurrently.
parallel.waitForAll(commandLoop, playerLoop)

resetRadio()
term.setTextColor(colors.white)
print("Radio stopped.")
