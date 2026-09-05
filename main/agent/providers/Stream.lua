--!strict
-- Stream.luau: one streaming HTTP request, retried, cancellable.
--
-- Everything here is transport. It knows about sockets, attempts, latches and
-- SSE framing; it knows nothing about what a frame MEANS. A provider supplies
-- the request and reads the frames, and gets the retry machinery for free.
--
-- Extracted from Anthropic.luau when OpenRouter arrived, and extracted rather
-- than copied deliberately: this is ~200 lines of latching whose failure modes
-- are all silent — a late event from an abandoned socket killing a live retry,
-- a second attempt re-rendering text the first one already emitted, a stream
-- closed before its own completion callback ran. Anthropic.luau's own header
-- records what happened the last time one protocol had two implementations
-- here. There must only ever be one copy of this.
--
-- Usage:
--   Stream.open(config, callbacks) -> handle
--
-- config:
--   request()  -> ({ url, headers, body }?, error?)   built per ATTEMPT, so a
--                 retry after a 401 picks up a refreshed credential
--   reset()    -> ()          clear the provider's per-attempt accumulators
--   frame(text, ctrl) -> ()   one complete SSE frame, "\n\n"-delimited
--   partial()  -> string?     text already accumulated, for the error handover
--   explain?(status, body) -> string?   a sentence ADDED under the error line,
--                 for a failure this provider can say something more useful
--                 about. It never replaces what the server said: the raw line
--                 keeps the status and the vendor's own wording, which is what
--                 is left to go on when the explanation guesses wrong. Called on
--                 EVERY failure route, in-band SSE errors included.
--   closed?(ctrl) -> ()       the socket ended without the provider finishing.
--                 A clean close raises no Error, so a protocol whose terminator
--                 can go missing would otherwise leave the turn spinning until
--                 somebody pressed Stop.
--   refresh?() -> ()          force a credential refresh (yields; omit if none)
--   needsRefresh?(status, body) -> boolean
--   windowReset?(headers) -> number?   seconds until a quota window resets
--
-- ctrl, handed to `frame` so a provider can drive the state machine from inside
-- its own parser:
--   ctrl.emitted()                 latch: the caller has been told something,
--                                  so no retry can be offered from here on
--   ctrl.finish(emit)              latch dead, run emit(), close the socket
--   ctrl.fail(status, body, msg)   an in-band error; routes to the same
--                                  decision point a transport failure does

local HttpService = game:GetService("HttpService")
local warn = warn

local Retry = require(script.Parent:WaitForChild("Retry"))

local Stream = {}

export type Handle = { cancelled: boolean, cancel: () -> () }

export type Ctrl = {
	emitted: () -> (),
	finish: ((() -> ())?) -> (),
	fail: (number?, string?, string) -> (),
}

function Stream.open(config: {
	request: () -> ({ url: string, headers: { [string]: string }, body: string }?, string?),
	reset: () -> (),
	frame: (string, Ctrl) -> (),
	partial: () -> string?,
	closed: ((Ctrl) -> ())?,
	explain: ((number?, string?) -> string?)?,
	refresh: (() -> ())?,
	needsRefresh: ((number?, string?) -> boolean)?,
	windowReset: ((string?) -> number?)?,
	}, callbacks: {
		onError: ((string, string?) -> ())?,
		onRetry: ((string, number, number, number) -> ())?,
	}): Handle

	-- Set the moment anything reaches the caller, and it is what makes retrying
	-- safe: onText has already been appended to a bubble and onToolUseStart has
	-- already put a block on screen, so a second attempt would render both twice
	-- and there is no callback for "forget what I just told you". A retry is
	-- therefore only ever offered before the first content block. That is not
	-- much of a restriction in practice, because the failures worth retrying —
	-- 429, 529, a stream that went quiet waiting on an uncached prefix — all
	-- happen before the model has said anything.
	local emitted = false
	-- Per-attempt latch. Distinct from handle.cancelled, which means the USER
	-- stopped this and must never be undone; this one only means the current
	-- socket is finished, and a retry clears it.
	local dead = false
	-- Bumped by every attempt, and captured by that attempt's handlers. Closing a
	-- WebStreamClient does not disconnect what is bound to it, so without this a
	-- late event from the socket we just abandoned arrives after `dead` has been
	-- cleared for the retry, and gets processed as though it belonged to the new
	-- attempt — an old Error would kill a request that is working.
	local generation = 0
	-- Attempts made including the one in flight, and the subset of them that were
	-- overloads. Two counters because they cap differently, the way upstream
	-- tracks `attempt` and `consecutive529Errors` separately.
	local attempts = 1
	local overloadAttempts = 0
	-- Latched, so a credential refresh is tried once per request and never becomes
	-- a loop against an endpoint that keeps saying no.
	local refreshed = false

	-- Forward-declared so the frame loop can reference it as an upvalue. Without
	-- this it would capture the GLOBAL `stream` (nil), causing "attempt to index
	-- nil with 'Close'" when we try to close the stream.
	local stream: any = nil

	-- Returned to the caller so a Stop button has something to call. Cancelling
	-- closes the socket and latches, so no late SSE chunk can fire a callback
	-- after the UI has already been finalised.
	local handle: Handle = { cancelled = false, cancel = function() end }
	handle.cancel = function()
		if handle.cancelled then return end
		handle.cancelled = true
		pcall(function()
			if stream then stream:Close() end
		end)
	end

	-- Timing lives outside `start` so a retry can report the whole wait rather
	-- than only its own attempt, and is reset per attempt below.
	local startedAt = os.time()
	local firstByteAt: number? = nil

	-- Forward-declared so `fail` can re-enter it.
	local start: (() -> ())
	-- The raw header blob from Opened, kept so a 429 can be answered on the
	-- server's own schedule rather than ours.
	local responseHeaders: string? = nil
	-- The HTTP status from Opened. Load-bearing, and easy to lose: with
	-- RawStream a 401 or 429 arrives as a normal response whose JSON body comes
	-- through MessageReceived, so the status is ONLY ever seen here. Passing nil
	-- from that path silently disabled auth refresh, window-limit reporting and
	-- rate-limit retries all at once, since each of them keys off the number.
	local responseStatus: number? = nil

	-- One decision point for every way an attempt can die: a transport Error, an
	-- in-band SSE error event, and a JSON error body all route here rather than
	-- each calling onError with its own idea of what is fatal.
	-- An in-band SSE error arrives inside a response whose HTTP status was 200, so
	-- the provider that parsed it has no status to pass and hands over nil. The
	-- status is very often right there in the body it DID hand over —
	-- {"error":{"code":429}} on an OpenAI-shaped stream, Gemini's error.code, and
	-- {"status":503} in NVIDIA's problem+json — so it is read here, once, rather
	-- than in each of the three parsers, and rather than being guessed at from the
	-- wording of the message further down.
	local function statusFromBody(body: string?): number?
		if not body then return nil end
		local parsed
		if not pcall(function() parsed = HttpService:JSONDecode(body) end) then return nil end
		if type(parsed) ~= "table" then return nil end
		local obj = parsed :: any
		local err = if type(obj.error) == "table" then obj.error else nil
		local code = (err and (tonumber(err.code) or tonumber(err.status))) or tonumber(obj.status)
		-- Only something that is actually an HTTP status. An OpenAI `code` is
		-- frequently a string like "rate_limit_exceeded", which tonumber rejects,
		-- and some other stray integer would classify worse than nil does.
		if code and code >= 100 and code < 600 then return code end
		return nil
	end

	local function fail(status: number?, body: string?, message: string)
		if handle.cancelled or dead then return end
		dead = true  -- latch first: a late MessageReceived must not race this

		-- Recovered before anything classifies on it, so retry, overload and
		-- explain all see the real number on an in-band failure too.
		if status == nil then status = statusFromBody(body) end

		pcall(function()
			if stream then stream:Close() end
		end)

		-- A quota window, not a burst. Backing off 32 seconds against a limit that
		-- resets in three hours only spends the attempts and arrives at the same
		-- refusal, so this reports the wait instead of pretending to ride it out.
		-- Upstream can afford to sleep through one because it has an unattended
		-- mode; a docked widget has a person in front of it.
		--
		-- Rewrites the message and falls through rather than answering here, so
		-- the partial-text handover at the bottom stays the single exit. An
		-- earlier version returned early and silently dropped whatever the model
		-- had already written.
		local resetIn = if status == 429 and config.windowReset
			then config.windowReset(responseHeaders) else nil
		local windowed = resetIn ~= nil and resetIn > Retry.WINDOW_LIMIT_SECONDS
		if windowed then
			message = string.format("%s — usage limit reached, resets in %d min",
				message, math.ceil((resetIn :: number) / 60))
		end

		-- One forced refresh, then the retry carries a new credential. Bounded to
		-- once because a second 401 on a freshly minted one is a real auth failure,
		-- and looping on it would just relogin-spam the token endpoint.
		if config.refresh and config.needsRefresh and config.needsRefresh(status, body)
			and not refreshed and not emitted
			and not windowed and attempts < Retry.MAX_ATTEMPTS then
			refreshed = true
			attempts += 1
			warn(string.format("[agent] %s — refreshing credential and retrying", message))
			task.spawn(function()
				if handle.cancelled then return end
				-- Yields on an HTTP round trip, which is why this is not inline:
				-- `fail` runs inside a stream event handler.
				(config.refresh :: any)()
				if handle.cancelled then return end
				start()
			end)
			return
		end

		local overload = Retry.isOverload(status, body)
		if overload then overloadAttempts += 1 end
		-- Both caps apply. The overall one bounds how long a user waits; the
		-- overload one is tighter because a fleet that is already saturated is
		-- not helped by us coming back four times.
		local allowed = attempts < Retry.MAX_ATTEMPTS
			and not windowed
			and (not overload or overloadAttempts < Retry.MAX_OVERLOAD_ATTEMPTS)
		if not emitted and allowed and Retry.isRetryable(status, body) then
			local wait = Retry.delay(attempts, Retry.retryAfterSeconds(responseHeaders))
			attempts += 1
			warn(string.format("[agent] %s — retrying in %.1fs (attempt %d/%d)",
				message, wait, attempts, Retry.MAX_ATTEMPTS))
			-- Said out loud, because a silent backoff is indistinguishable from
			-- the hang this whole mechanism exists to survive: same spinner, same
			-- nothing, for up to eight seconds. The caller decides how to show it;
			-- this file does not reach into the UI.
			if callbacks.onRetry then
				callbacks.onRetry(message, wait, attempts, Retry.MAX_ATTEMPTS)
			end
			task.delay(wait, function()
				-- Re-checked after the wait: Stop during a backoff must not be
				-- answered by opening another socket.
				if handle.cancelled then return end
				start()
			end)
			return
		end

		-- The provider's word on what went wrong, and only now that the attempt is
		-- genuinely over.
		--
		-- It used to live in the MessageReceived handler, which meant it only ever
		-- saw an error carried by an HTTP status. An SSE stream reports a
		-- mid-flight failure as a chunk inside a 200 response, and those arrive
		-- here from the provider's own parser: the whole in-band path was exempt,
		-- so the vendor advice never appeared for the errors most likely to need
		-- it — a NIM overload said "Service temporarily overloaded" and no more.
		--
		-- Down HERE rather than at the top of `fail`, because every retry path
		-- above returns before it. An explanation is a paragraph, and appending
		-- one to each of three retry lines buries the one thing those lines are
		-- for: how long the wait is. A retry says what happened; only the failure
		-- that ends the turn says why.
		--
		-- ADDED to the error, never substituted for it. An explanation is a guess
		-- about a cause; the line above it is what the server actually said, and
		-- that is the half worth having when the guess is wrong. Replacing it also
		-- throws away the status and the vendor's own wording, which are the first
		-- two things anyone needs to look a failure up.
		if config.explain then
			local because = config.explain(status or responseStatus, body)
			if because and because ~= "" then
				message = message .. "\n" .. because
			end
		end

		if callbacks.onError then
			-- Second argument is the text the model had already written, so a
			-- caller can keep a mostly-finished answer instead of discarding it on
			-- what is usually a transient stall rather than a real failure. The
			-- provider owns the accumulator, so it owns the question.
			callbacks.onError(message, config.partial())
		end
	end

	local ctrl: Ctrl = {
		emitted = function()
			emitted = true
		end,
		-- Latch, emit, close — in that order, and the order is load-bearing. The
		-- latch has to precede the callback so a late Error on the socket is not
		-- mistaken for a failure worth retrying on top of a delivered answer, and
		-- the close has to follow it so a completion handler is never running
		-- against a socket that has already gone.
		finish = function(emit: (() -> ())?)
			dead = true
			if emit then emit() end
			pcall(function()
				if stream then stream:Close() end
			end)
		end,
		fail = fail,
	}

	-- We buffer received chunks and split on a blank line to get complete SSE
	-- events, since RawStream doesn't guarantee message boundaries.
	--
	-- All THREE separators, not just "\n\n". The spec allows a line to end LF,
	-- CRLF or CR, so a blank line is any of "\n\n", "\r\n\r\n" or "\r\r" — and a
	-- CRLF server is not hypothetical. Matching only "\n\n" against "\r\n\r\n"
	-- finds nothing, because the two newlines in it are not adjacent: the bytes
	-- are CR LF CR LF. Every chunk then lands in a buffer that never drains, so
	-- the socket stays busy, the inactivity timeout never fires, and the turn
	-- spins forever with no error and no output.
	local SEPARATORS = { "\r\n\r\n", "\n\n", "\r\r" }
	local sseBuffer = ""
	-- Whether this attempt ever cut a frame ON A BOUNDARY, and whether it received
	-- anything at all. The pair is what tells a stream that ended cleanly apart
	-- from one whose framing we never understood — see the Closed handler. The
	-- tail flush there deliberately does NOT count, or a mismatch would hide
	-- behind the one frame that flush produces.
	local realFrames = 0
	local bytesSeen = 0
	-- The head of the response, kept for that diagnostic. A couple of hundred
	-- bytes is enough to see whether it was JSON, HTML from a proxy, or SSE with
	-- separators we did not cut on.
	local preview = ""

	local function nextBoundary(s: string): (number?, number?)
		local at: number?, len: number? = nil, nil
		for _, sep in ipairs(SEPARATORS) do
			local found = s:find(sep, 1, true)
			-- Earliest wins, so a CRLF blank line is consumed whole rather than
			-- leaving a stray CR at the head of the next frame.
			if found and (at == nil or found < at) then
				at, len = found, #sep
			end
		end
		return at, len
	end

	local function processFrames(data: string)
		if handle.cancelled or dead then return end
		sseBuffer = sseBuffer .. data
		bytesSeen += #data
		if #preview < 200 then preview = string.sub(preview .. data, 1, 200) end
		while true do
			local eventEnd, sepLen = nextBoundary(sseBuffer)
			if not eventEnd then break end
			local eventStr = sseBuffer:sub(1, eventEnd - 1)
			sseBuffer = sseBuffer:sub(eventEnd + (sepLen :: number))
			realFrames += 1
			config.frame(eventStr, ctrl)
			-- A frame can finish or fail the stream. Anything buffered after that
			-- belongs to a socket that is now closed.
			if handle.cancelled or dead then return end
		end
	end

	start = function()
		dead = false
		sseBuffer = ""
		realFrames = 0
		bytesSeen = 0
		preview = ""
		responseHeaders = nil
		responseStatus = nil
		config.reset()
		generation += 1
		-- Captured, not read live: every handler below belongs to THIS socket and
		-- must go silent the moment a later attempt supersedes it.
		local myGeneration = generation

		-- InactivityTimeout is raised by Roblox, not by the API, and it says nothing
		-- about WHERE the silence was. The two cases have different causes and
		-- different fixes: before the first byte is the server reprocessing an
		-- uncached prefix, which is a caching problem; after it is a stall mid-answer,
		-- which is not. Wall clock, because the thing being measured is a network
		-- wait, and seconds are enough against a window Roblox puts near 20.
		startedAt = os.time()
		firstByteAt = nil

		-- Built per attempt rather than once, so a refreshed credential is picked
		-- up by the retry that forced the refresh.
		local req, reqErr = config.request()
		if not req then
			if callbacks.onError then callbacks.onError(tostring(reqErr)) end
			return
		end

		local client
		-- Created with RawStream (not SSE) because:
		-- - The SSE client type validates that the RESPONSE Content-Type is
		--   text/event-stream. When an API returns an error (400/429/etc.), the
		--   response body is application/json, and Roblox's SSE client rejects it
		--   with "Invalid Content-Type header for SSE client", hiding the actual
		--   error message from us.
		-- - RawStream doesn't validate Content-Type, so we can read error bodies.
		-- - Successful streams are still SSE-formatted, so the framing above works
		--   the same.
		local ok, err = pcall(function()
			client = HttpService:CreateWebStreamClient(Enum.WebStreamClientType.RawStream, {
				Url = req.url,
				Method = "POST",
				Headers = req.headers,
				Body = req.body,
			})
		end)

		if not ok or not client then
			-- Not routed through `fail`: there is no stream to close and no status to
			-- classify. Six clients may exist at once, so this is also what a leak
			-- from an earlier turn eventually looks like.
			if callbacks.onError then callbacks.onError("Failed to create stream client: " .. tostring(err)) end
			return
		end

		stream = client

		stream.Opened:Connect(function(statusCode: number, headers: string)
			if myGeneration ~= generation then return end
			-- Kept whatever the status: a 429 carries retry-after here, and the body
			-- explaining it arrives separately through MessageReceived.
			responseHeaders = headers
			responseStatus = statusCode
		end)

		stream.MessageReceived:Connect(function(message: string)
			if handle.cancelled or dead or myGeneration ~= generation then return end
			if firstByteAt == nil then firstByteAt = os.time() end
			-- A JSON error body is tried FIRST, and this used to be the other way
			-- around: the old code looked for an "event:" line and only reached for
			-- JSON when it found none. That heuristic is Anthropic-shaped — an
			-- OpenAI-style stream has no `event:` lines at all, so every good frame
			-- would have taken the error path. Ordering it this way needs no
			-- heuristic: an SSE chunk begins "data:" or "event:" and cannot parse as
			-- JSON, so it falls through to the buffer on its own.
			local parsed
			local parseOk = pcall(function()
				parsed = HttpService:JSONDecode(message)
			end)
			local body = if parseOk and type(parsed) == "table" then parsed :: any else nil
			local e = if body then body.error else nil
			-- An error body in whatever shape this vendor uses, and the status is
			-- half the test rather than the envelope alone. Anthropic and OpenRouter
			-- send {error:{type|code, message}}; NVIDIA sends RFC-7807
			-- {status, title, detail}, and a 401 there is not JSON at all. Matching
			-- only on `.error` sent both of those to processFrames, where they sat in
			-- a buffer that never sees a "\n\n" — and when the socket then closed
			-- cleanly, nothing spoke for the attempt and the turn span forever with
			-- no error on screen.
			local httpFailed = responseStatus ~= nil and (responseStatus :: number) >= 400
			if e or httpFailed then
				-- `type` is Anthropic's spelling, `code` is OpenAI's and
				-- OpenRouter's, `title` is NVIDIA's. Reading only the first left
				-- every OpenRouter failure reading "HTTP error:  — ...", blank
				-- where the useful half goes.
				local kind = (if e then e.type or e.code else nil) or (if body then body.title else nil)
				-- The raw message is the last resort, and it is what carries a
				-- non-JSON body: NVIDIA answers a missing Authorization header with
				-- one line of plain text.
				local text = (if e then e.message else nil) or (if body then body.detail else nil) or message
				-- responseStatus, not `status`: `status` is only ever `fail`'s
				-- parameter, a different scope, so this fallback was reading a nil
				-- global and never once fired.
				-- Not explained here: `fail` does it for every route, this one
				-- included, so doing it twice would just apply it to its own output.
				local msg = "HTTP error: " .. tostring(kind or responseStatus or "") .. " — " .. tostring(text)
				warn("[agent] " .. msg)
				warn("[agent] Response body: " .. message)
				-- The body is passed on so an overloaded_error is recognised even
				-- when the status never made it through.
				-- responseStatus, not nil: this is the 401/429 path, and every
				-- decision fail makes about those keys off the number.
				fail(responseStatus, message, msg)
				return
			end
			processFrames(message)
		end)

		stream.Error:Connect(function(statusCode: number, errorMessage: string)
			-- An abandoned socket erroring on its way out must not be allowed to
			-- fail the attempt that replaced it.
			if myGeneration ~= generation then return end
			-- Which side of the first byte this died on, and how long it took to get
			-- there. Spelled out in the message itself rather than logged separately,
			-- because the person who sees this is the one who has to decide whether
			-- the history is too big or the connection is bad.
			local now = os.time()
			local where: string
			if firstByteAt == nil then
				where = string.format(
					"silent for %ds, no first byte — the prefix was almost certainly uncached and the server was still reading it",
					now - startedAt)
			else
				where = string.format(
					"first byte after %ds, then stalled %ds mid-answer",
					(firstByteAt :: number) - startedAt, now - (firstByteAt :: number))
			end
			-- errorMessage carries the HttpError name, which is what Retry.isRetryable
			-- matches InactivityTimeout on; the status here is 200 for a stream that
			-- opened cleanly and then went quiet.
			fail(statusCode, errorMessage,
				string.format("Stream error (HTTP %s): %s — %s",
					tostring(statusCode), tostring(errorMessage), where))
		end)

		stream.Closed:Connect(function()
			if handle.cancelled or dead or myGeneration ~= generation then return end

			-- A last event with no blank line after it. The spec says to discard an
			-- incomplete one, but a server that simply stops after its final event
			-- is common, and on this wire that final event is the one carrying the
			-- stop reason and the usage. Handed over as a frame: if it really is a
			-- fragment the provider's JSON parse rejects it and nothing is lost.
			if sseBuffer ~= "" then
				local tail = sseBuffer
				sseBuffer = ""
				config.frame(tail, ctrl)
				if handle.cancelled or dead then return end
			end

			-- The socket ended without the provider finishing, and without an
			-- Error — so nothing else is going to speak for this attempt. A
			-- provider whose terminator can go missing gets one chance to deliver
			-- what it has; one that says nothing leaves the turn to the Error
			-- path, which is where a genuinely broken stream belongs.
			if config.closed then config.closed(ctrl) end
			if handle.cancelled or dead then return end

			-- Still nothing, after the tail and after the provider's own last
			-- chance. If bytes arrived and none of them ever cut a frame, this is a
			-- framing mismatch rather than an empty answer — and it is the failure
			-- mode with no symptom at all: the socket stays busy so no inactivity
			-- timeout fires, nothing reaches the caller, and the turn spins until
			-- somebody presses Stop. Checked LAST so a stream the tail flush
			-- rescued is never accused, and reported with what actually arrived,
			-- because otherwise it is indistinguishable from a hang.
			if realFrames == 0 and bytesSeen > 0 then
				fail(responseStatus, nil, string.format(
					"Stream ended after %d bytes without a readable event — the response "
					.. "was not the SSE this expects. It began: %s",
					bytesSeen, string.format("%q", preview)))
			end
		end)
	end

	start()
	return handle
end

return Stream
