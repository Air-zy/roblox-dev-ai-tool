-- Test doubles for the Studio-only boundary. Production Fs/Terminal/Shell,
-- Regex, Sed, and the Luau syntax parser run unchanged in the CLI.
local shim = {}
local methods, serial = {}, 0
local classes = { Folder = true, Model = true, Part = true, MeshPart = true, ModuleScript = true,
	Script = true, LocalScript = true, ObjectValue = true, Workspace = true, DataModel = true }
local scriptClasses = { ModuleScript = true, Script = true, LocalScript = true }
local function signal() return { Connect = function() return { Disconnect = function() end } end } end
local instanceMT = {
	__index = function(self, key)
		if methods[key] then return methods[key] end
		if key == "Source" and not scriptClasses[self._props.ClassName] then error("Source is not a member", 0) end
		return self._props[key]
	end,
	__newindex = function(self, key, value)
		if key == "Parent" then
			if self._destroyed then error("Parent property is locked", 0) end
			if value == self or value and value:IsDescendantOf(self) then error("cyclic Parent", 0) end
			local old = self._props.Parent
			if old then local at = table.find(old._children, self); if at then table.remove(old._children, at) end end
			self._props.Parent = value
			if value then value._children[#value._children + 1] = self end
		else self._props[key] = value end
	end,
}
local Instance = {}
function Instance.new(class)
	assert(classes[class], "unknown class " .. class)
	serial += 1
	return setmetatable({ _props = { ClassName = class, Name = class, Archivable = true,
		Source = scriptClasses[class] and "" or nil, Disabled = false, Locked = false },
		_children = {}, _attributes = {}, _tags = {}, _id = serial }, instanceMT)
end
function methods:IsA(class)
	return class == "Instance" or class == self.ClassName or class == "LuaSourceContainer" and scriptClasses[self.ClassName] == true
		or class == "BasePart" and (self.ClassName == "Part" or self.ClassName == "MeshPart")
end
function methods:GetChildren() return table.clone(self._children) end
function methods:GetDescendants()
	local out = {}
	for _, child in ipairs(self._children) do out[#out + 1] = child; for _, item in ipairs(child:GetDescendants()) do out[#out + 1] = item end end
	return out
end
function methods:FindFirstChild(name)
	for _, child in ipairs(self._children) do if child.Name == name then return child end end
	return nil
end
methods.WaitForChild = methods.FindFirstChild
function methods:IsDescendantOf(other)
	local parent = self.Parent
	while parent do if parent == other then return true end; parent = parent.Parent end
	return false
end
function methods:Destroy()
	if self._destroyed then return end
	for _, child in ipairs(self:GetChildren()) do child:Destroy() end
	self.Parent = nil; rawset(self, "_destroyed", true)
end
function methods:Clone()
	if not self.Archivable then return nil end
	local clone = Instance.new(self.ClassName)
	for key, value in pairs(self._props) do if key ~= "Parent" then clone[key] = value end end
	rawset(clone, "_attributes", table.clone(self._attributes)); rawset(clone, "_tags", table.clone(self._tags))
	for _, child in ipairs(self:GetChildren()) do local copy = child:Clone(); if copy then copy.Parent = clone end end
	return clone
end
function methods:GetFullName() return self.Parent and self.Parent:GetFullName() .. "." .. self.Name or self.Name end
function methods:GetDebugId() return tostring(self._id) end
function methods:GetAttributes() return table.clone(self._attributes) end
function methods:SetAttribute(name, value) self._attributes[name] = value end
function methods:GetAttribute(name) return self._attributes[name] end
function methods:GetTags() local tags = {}; for tag in pairs(self._tags) do tags[#tags + 1] = tag end; return tags end
function methods:HasTag(tag) return self._tags[tag] == true end
function methods:GetPropertyChangedSignal() return signal() end

local game = Instance.new("DataModel")
game.Name, game.PlaceId, game.GameId = "game", 0, 0
local services, documents = {}, {}
local changes = { recordings = 0 }
function changes:TryBeginRecording() self.recordings += 1; return tostring(self.recordings) end
function changes:FinishRecording() end -- real undo/redo requires Studio
services.ChangeHistoryService = changes
services.CollectionService = {
	AddTag = function(_, inst, tag) inst._tags[tag] = true end,
	HasTag = function(_, inst, tag) return inst:HasTag(tag) end,
	GetTags = function(_, inst) return inst:GetTags() end,
}
services.ScriptEditorService = {
	FindScriptDocument = function(_, inst) return documents[inst] end,
	GetEditorSource = function(_, inst) return documents[inst] and documents[inst].text or inst.Source end,
	UpdateSourceAsync = function(_, inst, callback)
		if documents[inst] and (documents[inst].failWrites or 0) > 0 then
			documents[inst].failWrites -= 1; error("injected editor write failure", 0)
		end
		local content = callback(documents[inst] and documents[inst].text or inst.Source)
		inst.Source = content; if documents[inst] then documents[inst].text = content end
	end,
}
services.StudioService = { GetUserId = function() return 1 end }
services.HttpService = {
	RequestAsync = function() error("network requests are disabled in tests", 0) end,
	GetAsync = function(_, url)
		assert(url:find("Mini-API-Dump.json", 1, true), "network requests are disabled in tests")
		return "__API_DUMP_FIXTURE__"
	end,
	JSONDecode = function(_, text)
		assert(text == "__API_DUMP_FIXTURE__", "JSON fixture not implemented")
		local entries = { { Name = "Instance", Superclass = "<<<ROOT>>>", Members = {} },
			{ Name = "LuaSourceContainer", Superclass = "Instance", Members = {} } }
		for name in pairs(classes) do entries[#entries + 1] = {
			Name = name, Superclass = scriptClasses[name] and "LuaSourceContainer" or "Instance", Members = {},
		} end
		return { Classes = entries }
	end,
	UrlEncode = function(_, text) return (text:gsub("([^%w%-_%.~])", function(c) return string.format("%%%02X", c:byte()) end)) end,
}
for _, name in ipairs({ "Workspace", "ServerStorage", "ReplicatedStorage" }) do
	local service = Instance.new(name == "Workspace" and "Workspace" or "Folder")
	service.Name, service.Parent = name, game; services[name] = service
end
function methods:GetService(name)
	assert(services[name], "service not implemented in CLI: " .. name)
	return services[name]
end
shim.game, shim.Instance = game, Instance
shim.Enum = { FinishRecordingOperation = { Commit = "commit", Cancel = "cancel" }, HashAlgorithm = { Sha1 = "sha1" } }
shim.task = { wait = function() end, spawn = function() end, defer = function() end }
shim.typeof = function(value) return getmetatable(value) == instanceMT and "Instance" or typeof(value) end
shim.warn = print
shim.documents, shim.changes = documents, changes
return shim
