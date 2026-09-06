--!strict
-- Retry.luau: when to come back, and how long to wait.
--
-- Extracted from Anthropic.luau unchanged when a second provider arrived. The
-- schedule follows Claude Code's withRetry.ts rather than inventing one, and the
-- reasoning for every number below is kept with it — a second copy of this in
-- another provider is exactly the drift the Anthropic header warns about.
--
-- What is NOT here is anything that reads a vendor's own header or error type:
-- `needsTokenRefresh` and the quota-window reset stay with the provider that
-- knows the spelling. Only the parts that are the same for anyone speaking HTTP.

local Retry = {}

-- Theirs: BASE_DELAY_MS = 500, `min(500 * 2^(attempt-1), 32000)` plus up to 25%
-- jitter, and a `retry-after` taken literally — it deliberately bypasses the cap
-- there, being a server directive.
local BASE_DELAY = 0.5
local MAX_DELAY = 32

-- NOT from the source. Upstream retries 10 times; four is a judgement call for a
-- docked widget, where the whole schedule has to stay inside the patience of
-- someone watching a spinner. Four attempts is at most ~8s of backoff.
-- Attempts, not retries: the first try counts, so 4 here is one request and
-- three more. Named for what the code compares against, because "MAX_RETRIES = 4"
-- next to `attempts < MAX_RETRIES` reads as one more try than it performs.
Retry.MAX_ATTEMPTS = 4
-- Their MAX_529_RETRIES is also 3, but theirs counts RETRIES and this counts
-- ATTEMPTS, so this is the tighter of the two despite the matching number.
-- Deliberate: an overloaded fleet is the one case where coming back less is
-- strictly better for everyone.
Retry.MAX_OVERLOAD_ATTEMPTS = 3
-- NOT from the source, and there is no upstream equivalent — they sleep through
-- a quota window in unattended mode instead. Past a minute, waiting is no longer
-- something to do behind a spinner without saying so, and the reset time is more
-- useful to a person than four doomed attempts.
Retry.WINDOW_LIMIT_SECONDS = 60

function Retry.delay(attempt: number, retryAfter: number?): number
	local base = math.min(BASE_DELAY * 2 ^ (attempt - 1), MAX_DELAY)
	-- Jitter so several Studio windows that failed together do not come back in
	-- lockstep and rebuild the pileup they were caught in.
	local delay = base + math.random() * 0.25 * base
	-- The LARGER of the two, which is what ships: `Math.max(A*1000, Y)`. The
	-- leaked tree returns retry-after bare, and that is the older behaviour —
	-- worth knowing, because a server answering `retry-after: 1` would then pin
	-- every attempt at one second while the backoff never got to grow.
	if retryAfter then return math.max(retryAfter, delay) end
	return delay
end

-- InactivityTimeout is ours. Roblox closes a stream that goes quiet, which
-- happens when the server is still reading an uncached prefix and has sent
-- nothing yet. Retrying is the right move precisely because the failed attempt
-- still warmed that prefix, so the second one starts talking sooner.
--
-- It was also the ONLY transport failure matched here, and the rest arrive the
-- same way: no HTTP status at all (the Error signal reports -1) and the
-- HttpError name in the message. So `HttpError: NetFail` before the first byte
-- — the same stall one layer lower — fell straight through as fatal and ended
-- the turn without a single retry. The names left out are the ones a second
-- attempt cannot fix: InvalidUrl, TooManyRedirects, InvalidRedirect,
-- SslVerificationFail and OutOfMemory answer the same way every time, and
-- Aborted is what a stream someone closed reports.
local RETRYABLE_TRANSPORT = {
	"InactivityTimeout", "NetFail", "ConnectFail", "DnsResolve", "TimedOut",
	"SslConnectFail",
}

-- What is worth trying again. Deliberately a short list: anything not named here
-- fails the turn, because a retry that cannot succeed just spends the user's
-- time twice.
--
-- Anthropic publishes which statuses are worth retrying, and the table ships
-- inside Claude Code's own bundle: 400, 401, 403, 404 and 413 are No; 429
-- (rate_limit_error), 500 (api_error) and 529 (overloaded_error) are Yes. The
-- 5xx range is included rather than 500 alone because 502 and 503 come from
-- infrastructure in front of the API and mean the same thing to a client.
--
-- The two error-type strings are Anthropic's spelling, and they are matched for
-- every provider on purpose: OpenRouter forwards an upstream provider's error
-- body through largely intact, so an Anthropic model reached that way reports
-- an overload in exactly these words.
function Retry.isRetryable(status: number?, body: string?): boolean
	if status == 429 then return true end
	if status and status >= 500 and status < 600 then return true end
	if not body then return false end
	-- Body matching as well as status for the same reason upstream does it: the
	-- status is not always the thing that arrives. rate_limit_error is included
	-- alongside overloaded_error because both can reach us through a path that
	-- carried no usable status at all.
	if string.find(body, '"type":"rate_limit_error"', 1, true) then return true end
	-- An overload is retryable by definition, so there is one copy of that test
	-- and it lives in isOverload below.
	if Retry.isOverload(nil, body) then return true end
	-- The 429 wording, for the one case left after Stream has already tried to
	-- recover a status from the body: a mid-stream error whose object carries no
	-- code at all. Nothing else is matched on prose — an error that merely reads
	-- badly is still fatal, because a retry that cannot succeed spends the user's
	-- time twice.
	if string.find(string.lower(body), "too many requests", 1, true) then return true end
	for _, name in ipairs(RETRYABLE_TRANSPORT) do
		if string.find(body, name, 1, true) then
			return true
		end
	end
	return false
end

-- 529 is matched on the BODY as well as the status. Upstream does the same, and
-- says why: "the SDK sometimes fails to properly pass the 529 status code during
-- streaming". That applies doubly here, where an overloaded_error arrives as an
-- SSE `event: error` inside a response whose HTTP status was already 200.
function Retry.isOverload(status: number?, body: string?): boolean
	-- 529 ONLY, and not 503. A 503 is retryable as an ordinary 5xx and the note
	-- above says why: it comes from infrastructure in front of the API and means
	-- the same to a client as a 500. Counting it as an overload was a change made
	-- here for NVIDIA's benefit, and it quietly cut Anthropic's retry budget on
	-- that status from MAX_ATTEMPTS to the tighter MAX_OVERLOAD_ATTEMPTS.
	-- Anthropic's own table names 529 as the overload code; leave it at that.
	if status == 529 then return true end
	-- One test for every spelling, because they all contain the word: Anthropic's
	-- `"type":"overloaded_error"` and NVIDIA's "Service temporarily overloaded".
	-- Matching the word rather than either literal is what puts a NIM overload
	-- under the TIGHTER attempt cap, which is the point — a fleet that is already
	-- saturated is not helped by us coming back four times.
	return body ~= nil and string.find(string.lower(body), "overload", 1, true) ~= nil
end

-- `retry-after` out of the raw header blob WebStreamClient hands to Opened. A
-- server directive beats our own schedule, so this is preferred over the
-- backoff when present — upstream lets it bypass the delay cap for the same
-- reason. Seconds only: the HTTP-date form is legal but neither provider sends
-- it, and guessing wrong on a date is worse than falling back.
function Retry.retryAfterSeconds(headers: string?): number?
	if not headers then return nil end
	-- Lowercased first because Lua patterns have no case-insensitivity flag and
	-- header names are case-insensitive per HTTP. The alternative is spelling out
	-- a bracket class per letter, which is what this was and which nobody should
	-- have to read. A header blob is a few hundred bytes and this runs once per
	-- failed attempt, so the copy costs nothing worth measuring.
	local value = string.match(headers:lower(), "retry%-after:%s*(%d+)")
	return if value then tonumber(value) else nil
end

-- Seconds until a named unix-timestamp header comes due, or nil if it is absent
-- or already past. Providers that report a quota window this way differ only in
-- the header name, so the name is the argument.
function Retry.resetSeconds(headers: string?, header: string): number?
	if not headers then return nil end
	local pattern = header:lower():gsub("%-", "%%-") .. ":%s*(%d+)"
	local value = string.match(headers:lower(), pattern)
	local reset = if value then tonumber(value) else nil
	if not reset then return nil end
	local delay = reset - os.time()
	return if delay > 0 then delay else nil
end

-- Self-test
-- Moved here with the functions, from Anthropic.selfTest. Each of these has a
-- way of being wrong that costs something real: refusing a 529 wastes the turn,
-- retrying a 400 wastes the user's time twice, and missing the body-matched
-- overload means the one error that arrives inside a 200 response is never
-- caught. Chained from every provider's own selfTest, so it runs at startup.
function Retry.selfTest(): (boolean, string?)
	if not Retry.isRetryable(429, nil) then return false, "429 is not being retried" end
	if not Retry.isRetryable(529, nil) then return false, "529 is not being retried" end
	if not Retry.isRetryable(nil, '{"type":"error","error":{"type":"overloaded_error"}}') then
		return false, "overloaded_error in a 200 stream is not being retried"
	end
	if not Retry.isRetryable(200, "HttpError: InactivityTimeout") then
		return false, "InactivityTimeout is not being retried"
	end
	-- A transport failure carries no status at all, so the -1 is the whole test:
	-- NetFail before the first byte used to fall through as fatal and end the
	-- turn without one retry, because InactivityTimeout was the only name matched.
	if not Retry.isRetryable(-1, "HttpError: NetFail") then
		return false, "a transport failure with no status is not being retried"
	end
	if Retry.isRetryable(-1, "HttpError: SslVerificationFail") then
		return false, "a certificate failure is being retried; it cannot succeed"
	end
	if Retry.isRetryable(400, "invalid_request_error") then
		return false, "a 400 is being retried; it cannot succeed"
	end
	if Retry.isRetryable(401, nil) then return false, "an auth failure is being retried" end
	if not Retry.isRetryable(500, nil) then return false, "500 api_error is not being retried" end
	if not Retry.isRetryable(503, nil) then return false, "503 is not being retried" end
	if Retry.isRetryable(404, nil) then return false, "404 is being retried" end
	if Retry.isRetryable(413, nil) then return false, "413 request_too_large is being retried" end

	if not Retry.isOverload(nil, '{"type":"overloaded_error"}') then
		return false, "overload not detected from the body, so it gets the wrong budget"
	end
	if Retry.isOverload(429, nil) then return false, "a 429 is being counted against the 529 budget" end

	-- retry-after wins when it is the longer wait, and does NOT shorten a backoff
	-- that has already grown past it — the second half is the part the leaked
	-- tree gets wrong, so it is worth pinning.
	if Retry.delay(1, 7) ~= 7 then return false, "retry-after was not honoured" end
	if Retry.delay(8, 1) <= 1 then
		return false, "a short retry-after shortened a long backoff"
	end
	-- Doubling, and the jitter only ever adds.
	for attempt = 1, 8 do
		local base = math.min(BASE_DELAY * 2 ^ (attempt - 1), MAX_DELAY)
		local delay = Retry.delay(attempt, nil)
		if delay < base or delay > base * 1.25 then
			return false, string.format("Retry.delay(%d) = %.3f, outside [%.3f, %.3f]",
				attempt, delay, base, base * 1.25)
		end
	end
	if Retry.delay(99, nil) > MAX_DELAY * 1.25 then
		return false, "backoff is not capped"
	end

	if Retry.retryAfterSeconds("content-type: application/json\r\nretry-after: 12\r\n") ~= 12 then
		return false, "retry-after header not parsed"
	end
	if Retry.retryAfterSeconds("Retry-After: 3") ~= 3 then
		return false, "retry-after header is case-sensitive"
	end
	if Retry.retryAfterSeconds("content-type: application/json") ~= nil then
		return false, "retry-after invented from headers that carry none"
	end

	-- A window reset in the future is reported; one in the past is not a limit
	-- at all and must not be mistaken for one. The hyphens in the header name
	-- are the trap: unescaped they are Lua pattern ranges, so a name that looks
	-- right matches nothing.
	local name = "anthropic-ratelimit-unified-reset"
	local ahead = Retry.resetSeconds(string.format("%s: %d", name, os.time() + 600), name)
	if not ahead or ahead < 500 or ahead > 700 then
		return false, string.format("reset parsed as %s, expected ~600", tostring(ahead))
	end
	if Retry.resetSeconds(string.format("%s: %d", name, os.time() - 600), name) ~= nil then
		return false, "an already-elapsed reset is being reported as a wait"
	end
	if Retry.resetSeconds("content-type: application/json", name) ~= nil then
		return false, "reset invented from headers that carry none"
	end

	return true
end

return Retry
