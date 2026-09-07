--!optimize 2
-- Shell printf owns its format grammar, escapes, C-style numeric arguments and
-- integer rendering. Only f/e/g digit conversion uses Luau's C-format backend;
-- field width, signs, alternate form, precision and padding are handled here.
local Builtins = {}
local ESCAPES = { a = "\a", b = "\b", e = string.char(27), E = string.char(27),
	f = "\f", n = "\n", r = "\r", t = "\t", v = "\v", ["\\"] = "\\" }
local MAX_FIELD, MAX_OUTPUT = 100000, 1000000
local DIGITS, BASE = "0123456789abcdef", 4294967296

local function digit(c: string): number?
	local at = DIGITS:find(c:lower(), 1, true)
	return c ~= "" and at and at - 1 or nil
end

-- One escape at a time: the caller knows whether it is format text or %b data.
-- \c terminates only %b; in a format it is an unknown escape and stays literal.
local function escape(text: string, at: number, percentB: boolean?): (string, number, boolean, string?, number?)
	local c = text:sub(at + 1, at + 1)
	if c == "c" and percentB then return "", at + 2, true end
	if ESCAPES[c] then return ESCAPES[c], at + 2, false end
	local base, limit, start = nil, 0, at + 2
	if c == "x" then base, limit = 16, 2
	elseif c == "u" then base, limit = 16, 4
	elseif c == "U" then base, limit = 16, 8
	elseif c:match("[0-7]") then
		base, limit, start = 8, 3, at + 1
		if percentB and c == "0" then start = at + 2 end
	end
	if not base then return "\\" .. c, at + 1 + #c, false end
	local value, used = 0, 0
	while used < limit do
		local d = digit(text:sub(start + used, start + used))
		if not d or d >= base then break end
		value = value * base + d; used += 1
	end
	if used == 0 then
		if base == 8 then return "\0", start, false end
		return "\\" .. c, at + 2, false, "printf: missing hexadecimal digits after \\" .. c
	end
	if c == "u" or c == "U" then
		if value > 0x10ffff or value >= 0xd800 and value <= 0xdfff then
			return "", start + used, false, "printf: invalid Unicode code point", 1
		end
		return utf8.char(value), start + used, false
	end
	return string.char(value % 256), start + used, false
end

function Builtins.escapes(text: string, percentB: boolean?): (string, boolean, string?, number)
	local out, at, diagnostic, status = {}, 1, nil, 0
	while at <= #text do
		if text:sub(at, at) == "\\" then
			local value, after, stop, err, code = escape(text, at, percentB)
			out[#out + 1] = value; at = after; diagnostic = diagnostic or err
			status = math.max(status, code or 0)
			if stop then return table.concat(out), true, diagnostic, status end
		else out[#out + 1] = text:sub(at, at); at += 1 end
	end
	return table.concat(out), false, diagnostic, status
end

function Builtins.quote(value: string): string
	if value ~= "" and not value:find("[^%w_./%-]") then return value end
	return "'" .. value:gsub("'", "'\\''") .. "'"
end

-- Parse into two 32-bit limbs so integers above 2^53 never pass through a Luau
-- number and lose low digits. Each multiply is <= 2^36 and therefore exact.
local function integer(value: string, unsigned: boolean): (number, number, boolean, string?, boolean?)
	if value == "" then return 0, 0, false end
	local first = value:sub(1, 1)
	if first == "'" or first == '"' then return 0, value:byte(2) or 0, false end
	local at = 1
	while value:sub(at, at):match("%s") do at += 1 end
	local negative = value:sub(at, at) == "-"
	if negative or value:sub(at, at) == "+" then at += 1 end
	local radix = 10
	if value:sub(at, at + 1):lower() == "0x" and digit(value:sub(at + 2, at + 2)) then radix = 16; at += 2
	elseif value:sub(at, at) == "0" then radix = 8 end
	local hi, lo, count, overflow = 0, 0, 0, false
	while at <= #value do
		local d = digit(value:sub(at, at))
		if not d or d >= radix then break end
		local low = lo * radix + d
		local high = hi * radix + math.floor(low / BASE)
		if high >= BASE then overflow = true end
		hi, lo = high % BASE, low % BASE
		count += 1; at += 1
	end
	local diagnostic = (count == 0 or at <= #value) and ("printf: invalid number " .. Builtins.quote(value)) or nil
	local invalid = diagnostic ~= nil
	if unsigned then
		if overflow then hi, lo = BASE - 1, BASE - 1; diagnostic = "printf: number out of range " .. value
		elseif negative then lo = (BASE - lo) % BASE; hi = (BASE - 1 - hi + (lo == 0 and 1 or 0)) % BASE end
		return hi, lo, false, diagnostic, invalid
	end
	local limitHi, limitLo = 2147483647, BASE - 1
	if negative then limitHi, limitLo = 2147483648, 0 end
	if overflow or hi > limitHi or hi == limitHi and lo > limitLo then
		hi, lo = limitHi, limitLo; diagnostic = "printf: number out of range " .. value
	end
	return hi, lo, negative and (hi ~= 0 or lo ~= 0), diagnostic, invalid
end

local function digits(hi: number, lo: number, radix: number): string
	if hi == 0 and lo == 0 then return "0" end
	local out = ""
	while hi ~= 0 or lo ~= 0 do
		local high = math.floor(hi / radix)
		local combined = (hi % radix) * BASE + lo
		local low = math.floor(combined / radix)
		local remainder = combined % radix
		out = DIGITS:sub(remainder + 1, remainder + 1) .. out
		hi, lo = high, low
	end
	return out
end

local function field(format: string, start: number): (any?, number, string?)
	local spec = { flags = {}, width = 0, precision = nil }
	local at = start
	while at <= #format and ("#0 +-"):find(format:sub(at, at), 1, true) do
		spec.flags[format:sub(at, at)] = true; at += 1
	end
	local function decimal(): number?
		local begin = at
		while format:sub(at, at):match("%d") do at += 1 end
		if begin == at then return nil end
		return tonumber(format:sub(begin, at - 1))
	end
	if format:sub(at, at) == "*" then spec.width = "*"; at += 1
	else spec.width = decimal() or 0 end
	if format:sub(at, at) == "." then
		at += 1
		if format:sub(at, at) == "*" then spec.precision = "*"; at += 1
		else spec.precision = decimal() or 0 end
	end
	spec.conversion = format:sub(at, at)
	if spec.conversion == "" or not ("sbcqdiuoxXfFeEgG"):find(spec.conversion, 1, true) then
		return nil, at, "printf: unsupported format directive near " .. format:sub(start - 1, at)
	end
	return spec, at + 1, nil
end

local function pad(body: string, prefix: string, spec: any, numeric: boolean): string
	local amount = math.max(0, spec.width - #prefix - #body)
	if spec.flags["-"] then return prefix .. body .. string.rep(" ", amount) end
	if numeric and spec.flags["0"] and spec.precision == nil then
		return prefix .. string.rep("0", amount) .. body
	end
	return string.rep(" ", amount) .. prefix .. body
end

function Builtins.printf(args: { string }): (string, string?, number?)
	local at = 2
	if args[at] == "--" then at += 1 end
	local format = args[at]
	if not format then return "", "printf requires a format", 1 end
	at += 1
	local out, bytes, diagnostic, status = {}, 0, nil, 0
	local function append(text: string)
		bytes += #text
		if bytes > MAX_OUTPUT then error("printf output exceeds 1000000 bytes", 0) end
		out[#out + 1] = text
	end
	local function take(): string local value = args[at] or ""; at += 1; return value end
	local function size(value: string): number
		local hi, lo, negative, err, invalid = integer(value, false)
		diagnostic = diagnostic or err
		if invalid then status = 1 end
		if hi > 0 or lo > MAX_FIELD then error("printf: field width or precision exceeds 100000", 0) end
		return negative and -lo or lo
	end
	repeat
		local before, i = at, 1
		while i <= #format do
			local c = format:sub(i, i)
			if c == "\\" then
				local text, after, _, err, code = escape(format, i, false)
				append(text); diagnostic = diagnostic or err; i = after
				status = math.max(status, code or 0)
			elseif c == "%" then
				if format:sub(i + 1, i + 1) == "%" then append("%"); i += 2; continue end
				local spec, after, parseErr = field(format, i + 1)
				if not spec then return table.concat(out), parseErr, 1 end
				if spec.width == "*" then spec.width = size(take()) end
				if spec.precision == "*" then spec.precision = size(take()); if spec.precision < 0 then spec.precision = nil end end
				if spec.width < 0 then spec.flags["-"] = true; spec.width = -spec.width end
				if spec.width > MAX_FIELD or spec.precision and spec.precision > MAX_FIELD then
					return table.concat(out), "printf: field width or precision exceeds 100000", 1
				end
				local conversion, value = spec.conversion, take()
				local body, prefix, stop = "", "", false
				local numeric = not ("sbcq"):find(conversion, 1, true)
				if conversion == "s" or conversion == "b" or conversion == "q" then
					body = value
					if conversion == "b" then
						local err, code; body, stop, err, code = Builtins.escapes(value, true); diagnostic = diagnostic or err
						status = math.max(status, code)
					end
					if spec.precision then body = body:sub(1, spec.precision) end
					if conversion == "q" then body = Builtins.quote(body) end
				elseif conversion == "c" then body = value == "" and "\0" or value:sub(1, 1)
				elseif ("diuoxX"):find(conversion, 1, true) then
					local unsigned = conversion ~= "d" and conversion ~= "i"
					local hi, lo, negative, err, invalid = integer(value, unsigned)
					diagnostic = diagnostic or err
					if invalid then status = 1 end
					local radix = conversion == "o" and 8 or (conversion == "x" or conversion == "X") and 16 or 10
					body = digits(hi, lo, radix)
					if spec.precision == 0 and hi == 0 and lo == 0 then body = "" end
					if spec.precision then body = string.rep("0", math.max(0, spec.precision - #body)) .. body end
					if conversion == "X" then body = body:upper() end
					if not unsigned then prefix = negative and "-" or spec.flags["+"] and "+" or spec.flags[" "] and " " or "" end
					if spec.flags["#"] then
						if conversion == "o" and body:sub(1, 1) ~= "0" then body = "0" .. body
						elseif radix == 16 and (hi ~= 0 or lo ~= 0) then prefix = conversion == "X" and "0X" or "0x" end
					end
				else
					-- f/e/g use the same C conversion syntax as Luau's formatter.
					-- Send only a validated precision and conversion; shell flags,
					-- signs, dynamic fields and width are handled explicitly above.
					-- Values use Luau's IEEE-754 double precision (not long double).
					local n
					if value == "" then n = 0
					elseif value:sub(1, 1) == "'" or value:sub(1, 1) == '"' then n = value:byte(2) or 0
					else n = tonumber(value) end
					if not n or n ~= n or math.abs(n) == math.huge then
						return table.concat(out), "printf: requires a finite floating-point number, got " .. Builtins.quote(value), 1
					end
					local negative = n < 0 or n == 0 and 1 / n < 0
					local precision = spec.precision or 6
					-- Luau's format parser limits decimal field lengths. The
					-- supported backend range is checked explicitly, not guessed.
					if precision > 99 then return table.concat(out), "printf: floating-point precision exceeds 99", 1 end
					local conversionFormat = "%" .. (spec.flags["#"] and "#" or "") .. "." .. tostring(precision) .. conversion:lower()
					local ok, formatted = pcall(string.format, conversionFormat, math.abs(n))
					if not ok then return table.concat(out), "printf: floating-point conversion failed: " .. tostring(formatted), 1 end
					body = conversion:match("%u") and formatted:upper() or formatted
					prefix = negative and "-" or spec.flags["+"] and "+" or spec.flags[" "] and " " or ""
					-- Unlike integer precision, floating precision does not disable
					-- zero padding; it was already consumed by digit conversion.
					spec.precision = nil
				end
				append(pad(body, prefix, spec, numeric))
				if stop then return table.concat(out), diagnostic, status end
				i = after
			else append(c); i += 1 end
		end
		if at == before then break end
	until at > #args
	return table.concat(out), diagnostic, status
end

return Builtins
