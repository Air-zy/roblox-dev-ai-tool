-- Boundary checks requiring simulated editor buffers/failures. The production
-- ShellTests suite covers ordinary copy/remove behavior in Studio as well.
return function(Terminal, shim)
	local fixture = shim.Instance.new("Folder")
	local function make(class, name, parent, text)
		local item = shim.Instance.new(class); item.Name, item.Parent = name, parent
		if text then item.Source = text end
		return item
	end
	local ok, err = pcall(function()
		local terminal = Terminal.new(fixture)
		local src = make("ModuleScript", "source", fixture, "return 'stale'")
		local child = make("ModuleScript", "child", src, "return 'stale child'")
		shim.documents[src] = { text = "return 'editor'" }
		shim.documents[child] = { text = "return 'editor child'" }
		assert(terminal:copy("source", "fresh"))
		local fresh = assert(terminal:resolve("fresh"))
		assert(fresh.Source == shim.documents[src].text, "copy lost the root editor buffer")
		assert(fresh:FindFirstChild("child").Source == shim.documents[child].text, "copy lost a descendant editor buffer")
		local old = make("ModuleScript", "old", fixture, "return 'old'")
		local unrelated = make("Folder", "unrelated", old)
		shim.documents[old] = { text = "return 'unsaved destination'" }
		assert(terminal:copy("source", "old"))
		assert(terminal:resolve("old") == old and unrelated.Parent == old, "copy replaced an existing file or deleted its unrelated children")
		assert(shim.documents[old].text == shim.documents[src].text, "copy did not update the open destination document")

		local srcDir = make("Folder", "srcDir", fixture)
		local dstDir = make("Folder", "dstDir", fixture)
		make("ModuleScript", "a", srcDir, "return 'new a'")
		make("ModuleScript", "b", srcDir, "return 'new b'")
		make("ModuleScript", "newChild", srcDir, "return 'new child'")
		local a = make("ModuleScript", "a", dstDir, "return 'old a'")
		local b = make("ModuleScript", "b", dstDir, "return 'old b'")
		shim.documents[a] = { text = "return 'unsaved a'" }
		shim.documents[b] = { text = "return 'unsaved b'", failWrites = 1 }
		local message, failure = terminal:copy("srcDir", "dstDir", { recursive = true, noTargetDirectory = true })
		assert(not message and failure:find("injected editor write failure", 1, true), "copy swallowed an editor write failure")
		assert(shim.documents[a].text == "return 'unsaved a'" and shim.documents[b].text == "return 'unsaved b'", "copy failed to restore the pre-copy buffers")
		assert(not dstDir:FindFirstChild("newChild"), "failed copy leaked a prepared clone")
		assert(dstDir:FindFirstChild("a") == a and dstDir:FindFirstChild("b") == b, "failed copy replaced destination identities")
	end)
	for _, item in ipairs(fixture:GetDescendants()) do shim.documents[item] = nil end
	fixture:Destroy()
	assert(ok, err)
end
