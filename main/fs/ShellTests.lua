local Regression = {}
function Regression.run(Terminal, Shell)
	local fixture = Instance.new("Folder")
	fixture.Name = "ShellTests"
	fixture.Parent = game:GetService("ServerStorage")
	local ok, result = pcall(function()
		local term = Terminal.new(fixture)
		local root = term:pwd()
		local count = 0
		local function check(line, expected)
			local actual = term:shell(line)
			assert(actual == expected, string.format("%s\nexpected %q\nactual   %q", line, expected, actual))
			count += 1
		end
		local function file(name, text, parent)
			local item = Instance.new("ModuleScript"); item.Name, item.Source, item.Parent = name, text, parent or fixture; return item
		end
		local function contains(line, pattern)
			local actual = term:shell(line)
			assert(actual:find(pattern, 1, true), line .. " expected " .. pattern .. ", got " .. actual)
			count += 1
		end

		-- Source capture and the review renderer, in their own fixture so the
		-- scripts these create cannot turn up in another test's `ls`. First in the
		-- file deliberately: this is the path the console's diff is built from, and
		-- a failure anywhere later must not stop it being checked.
		local captureRoot = Instance.new("Folder")
		captureRoot.Name, captureRoot.Parent = "capture", fixture
		local cterm = Terminal.new(captureRoot)
		-- Source capture: what one tool call changed, for the console's diff.
		-- The rules worth pinning are that a scope collects only the writes made
		-- inside it, that several edits to one script within one call are ONE
		-- record rather than a replay of intermediate states, and that a write
		-- changing nothing records nothing.
		assert(#cterm:endCapture() == 0, "endCapture invented records with no scope open")
		cterm:write("cap.luau", "return 1\n")
		assert(#cterm:endCapture() == 0, "a write outside any capture scope was recorded")
		cterm:beginCapture()
		assert(cterm:write("made.luau", "return 1\n"), "capture fixture write failed")
		cterm:write("made.luau", "return 2\n")
		cterm:edit("made.luau", "return 2", "return 3")
		cterm:write("cap.luau", "return 1\n")
		local records = cterm:endCapture()
		assert(#records == 1, string.format("expected one merged record, got %d", #records))
		assert(records[1].kind == "created", "a script the call created was not marked as created")
		assert(records[1].before == "" and records[1].after == "return 3\n",
			string.format("merge kept %q -> %q", records[1].before, records[1].after))
		assert(#cterm:endCapture() == 0, "a closed scope kept collecting")

		-- A shell write is captured by the same hook, with nothing added for it:
		-- redirection, `sed -i`, curl-to-script and git materialization all route
		-- through Terminal:write. This is the check that says so.
		cterm:beginCapture()
		cterm:shell("echo one > redirected.luau")
		cterm:shell("sed -i 's/one/two/' redirected.luau")
		local shellRecords = cterm:endCapture()
		assert(#shellRecords == 1, string.format("shell writes: expected one record, got %d", #shellRecords))
		assert(shellRecords[1].kind == "created" and shellRecords[1].after == "two\n",
			string.format("shell write recorded %q, kind=%s",
				shellRecords[1].after, shellRecords[1].kind))

		-- The review renderer. Pure text, so what the console will draw is
		-- checked here rather than by looking at the widget.
		local SourceDiff = require(script.Parent.Parent:WaitForChild("ui"):WaitForChild("SourceDiff"))
		cterm:beginCapture()
		cterm:write("review.luau", "local a = 1\nlocal b = 2\nlocal c = 3\n")
		local made = SourceDiff.files(cterm:endCapture())
		assert(#made == 1 and made[1].kind == "created", "a created script did not reach the renderer as created")
		assert(SourceDiff.summary(made):find("(new)", 1, true), "a created script is not marked in the summary")
		assert(made[1].added == 3 and made[1].removed == 0,
			string.format("created script counted +%d -%d", made[1].added, made[1].removed))

		cterm:beginCapture()
		cterm:edit("review.luau", "local b = 2", "local b = 22")
		local edited = SourceDiff.files(cterm:endCapture())
		assert(edited[1].added == 1 and edited[1].removed == 1,
			string.format("a one-line edit counted +%d -%d", edited[1].added, edited[1].removed))
		local patch = SourceDiff.body(edited)
		assert(patch:find("@@", 1, true), "the patch carries no hunk header")
		assert(patch:find("\n-local b = 2\n", 1, true) and patch:find("\n+local b = 22", 1, true),
			"the patch does not show the replaced line both ways:\n" .. patch)
		assert(patch:find("\n local a = 1\n", 1, true), "the patch dropped its context lines")

		-- The cap says what it withheld rather than truncating in silence.
		local short, hidden = SourceDiff.body(edited, 2)
		assert(hidden == 4 and select(2, short:gsub("\n", "")) == 1,
			string.format("cap withheld %d lines and kept %q", hidden, short))

		cterm:beginCapture()
		cterm:write("m1.luau", "return 1\n")
		cterm:write("m2.luau", "return 2\n")
		local several = SourceDiff.files(cterm:endCapture())
		assert(#several == 2, "two changed scripts did not produce two files")
		assert(SourceDiff.summary(several):find("2 scripts changed", 1, true),
			"a multi-script call does not say so: " .. SourceDiff.summary(several))
		assert(SourceDiff.body(several):find("m2", 1, true),
			"a multi-script patch does not name each script")

		-- rm records what it took, read while the scripts were still in the tree
		-- and still had a path. A ModuleScript with children is ordinary here, so
		-- a deleted package reports every module in it, not only its root.
		cterm:shell("mkdir -p pkg")
		cterm:write("pkg/init.luau", "return 1\n")
		cterm:write("pkg/helper.luau", "return 2\n")
		cterm:beginCapture()
		cterm:remove("pkg")
		local removed = cterm:endCapture()
		assert(#removed == 2, string.format("rm of a package recorded %d scripts", #removed))
		for _, entry in ipairs(removed) do
			assert(entry.kind == "deleted" and entry.after == "" and entry.before ~= "",
				"rm did not record the source it removed")
			assert(entry.path:find("pkg", 1, true),
				"rm recorded a path from after the detach: " .. entry.path)
		end

		-- mv moves one Instance, so its source did not change. Reporting a delete
		-- plus a create there would invent two edits out of none.
		cterm:write("mover.luau", "return 1\n")
		cterm:beginCapture()
		cterm:move("mover.luau", "moved.luau")
		assert(#cterm:endCapture() == 0, "mv reported a source change")

		-- reload swaps in a fresh clone carrying the same text: same reasoning.
		cterm:beginCapture()
		cterm:reload({ "moved.luau" })
		assert(#cterm:endCapture() == 0, "reload reported a source change")

		-- mv ONTO an existing script is a real loss: the destination is
		-- unparented and its text is gone with nothing else recording it. The
		-- moved script itself is still not a change.
		cterm:write("keep.luau", "return 'kept'\n")
		cterm:write("victim.luau", "return 'doomed'\n")
		cterm:beginCapture()
		cterm:move("keep.luau", "victim.luau")
		local clobbered = cterm:endCapture()
		assert(#clobbered == 1, string.format("mv over a script recorded %d changes", #clobbered))
		assert(clobbered[1].kind == "deleted" and clobbered[1].before == "return 'doomed'\n",
			"mv did not record the script it replaced")
		assert(clobbered[1].path:find("victim", 1, true),
			"mv recorded a path from after the detach: " .. clobbered[1].path)

		-- cp records what landed. An overwrite is paired with what it replaced,
		-- so it reads as an edit rather than as a file appearing from nowhere.
		cterm:write("origin.luau", "return 'a'\n")
		cterm:beginCapture()
		cterm:copy("origin.luau", "fresh.luau")
		local copied = cterm:endCapture()
		assert(#copied == 1 and copied[1].kind == "created" and copied[1].after == "return 'a'\n",
			"cp did not record the script it created")
		cterm:write("target.luau", "return 'old'\n")
		cterm:beginCapture()
		cterm:copy("origin.luau", "target.luau")
		local over = cterm:endCapture()
		assert(#over == 1 and over[1].kind == "modified"
			and over[1].before == "return 'old'\n" and over[1].after == "return 'a'\n",
			"cp over an existing script did not pair with what it replaced")

		-- cp -r of a package records every module the clone landed, not just its
		-- root: a copied package that reported one file would be lying about the
		-- rest by omission.
		cterm:shell("mkdir -p tree")
		cterm:write("tree/one.luau", "return 1\n")
		cterm:write("tree/two.luau", "return 2\n")
		cterm:beginCapture()
		cterm:copy("tree", "treecopy", { recursive = true })
		local cloned = cterm:endCapture()
		assert(#cloned == 2, string.format("cp -r of a package recorded %d scripts", #cloned))
		for _, entry in ipairs(cloned) do
			assert(entry.kind == "created" and entry.path:find("treecopy", 1, true),
				"cp -r recorded the source rather than the copy: " .. entry.path)
		end

		-- The whole path the console draws from: dispatch opens the scope, the
		-- tool writes, dispatch hands the changes back BESIDE the model's result.
		--
		-- Tested here because a stale or unwired Tools.lua fails silently — no
		-- scope, so no changes, so no diff and no error — which looks exactly
		-- like the feature being switched off.
		local Tools = require(script.Parent.Parent:WaitForChild("agent"):WaitForChild("Tools"))
		cterm:write("dispatched.luau", "local a = 1\nprint(a)\nreturn a\n")
		local dispatched, dispatchedChanges = Tools.dispatch(term, "edit", {
			path = cterm:pwd() .. "/dispatched.luau",
			old_string = "print(a)",
			new_string = "print(a + 1)",
		})
		assert(dispatched:find("edited", 1, true),
			"dispatch did not run the edit tool: " .. tostring(dispatched))
		assert(dispatchedChanges and #dispatchedChanges == 1,
			"dispatch returned no source changes for an edit that changed source")
		assert(dispatchedChanges[1].after:find("print(a + 1)", 1, true),
			"dispatch returned a change that does not carry the new source")
		-- And a read-only call returns nothing, or every tool row would grow a diff.
		local _, readOnlyChanges = Tools.dispatch(term, "bash", { command = "ls" })
		assert(readOnlyChanges == nil, "a read-only call reported source changes")
		captureRoot:Destroy()

		check("true; echo $?; false; echo $?", "0\n1")
		check("false || true; echo $?", "0")
		check("printf '%s:%04d\\n' answer 7", "answer:0007")
		check("printf '%s' 'a\0b'", "a\0b")
		local quoted = term:shell("printf %.2q 'a b'")
		check("printf %s " .. quoted, "a ")
		check("printf '%s' a; printf '%s' b", "ab")
		check("printf '<%s>\\n' a b", "<a>\n<b>")
		check("printf '%s' 'x y' | wc -c", "3")
		check("echo -n a; echo b", "ab")
		check("NAME=world; echo \"hello $NAME\"", "hello world")
		check("echo '$NAME' \\$NAME", "$NAME $NAME")
		check("NAME='a; echo injected'; printf '%s' \"$NAME\"", "a; echo injected")
		check("NAME='a b'; printf '<%s>' $NAME", "<a><b>")
		check("printf '<%s>' \"$NAME\"", "<a b>")
		check("export KEY='a b'; echo \"$KEY\"", "a b")
		check("KEY=temporary true; echo \"$KEY\"", "a b")
		contains("KEY=temporary BAD=$((1/0)) true", "division by zero")
		check("echo \"$KEY\"", "a b")
		check("echo $HOME; echo $((1 + 2 * 3))", "/\n7")
		check("echo $((~0)) $((-8 >> 2)) $((1 << 40)) $((1099511627776 | 3)) $((-1 & 1099511627776))", "-1 -2 1099511627776 1099511627779 1099511627776")
		check("echo $((0 && 1/0)) $((1 ? 7 : 1/0)) $((-7 / 2)) $((-7 % 2))", "0 7 -3 -1")
		check("i=0; while [ $i -lt 3 ]; do printf %s $i; i=$((i+1)); done", "012")
		check("if false; then echo wrong; elif true; then echo right; else echo wrong; fi", "right")
		check("if true; then printf a; if false; then echo wrong; else printf b; fi; fi", "ab")
		check("false && echo $(cat missing); true || echo $(cat missing)", "")
		check("case foo.lua in *.txt) echo wrong;; *.lua|*.luau) echo right;; *) echo wrong;; esac", "right")
		check("case '*' in \"*\") echo literal;; *) echo wildcard;; esac", "literal")
		check("{ printf a; printf b; } | wc -c", "2")
		check("greet() { printf '%s:%s' \"$1\" \"$2\"; }; greet hi there", "hi:there")
		check("command -v greet; command -V greet", "greet\ngreet is a shell function")
		check("echo() { printf function; }; echo; command echo builtin; unset -f echo", "functionbuiltin")
		check("function first { local KEY=local; echo $KEY; return 7; echo wrong; }; first; echo $?; echo \"$KEY\"", "local\n7\na b")
		check("for f in a b; do echo \"$(echo \"$f\")\"; done", "a\nb")
		check("printf '%s' \"$(printf 'a; b')\"", "a; b")
		check("echo `echo nested`", "nested")
		check("echo {probe,verify}.luau", "probe.luau verify.luau")
		check("echo a{1,2}{x,y}", "a1x a1y a2x a2y")
		check("echo {03..01}", "03 02 01")
		check("echo '{a,b}'", "{a,b}")
		file("alpha", "return 1"); file("beta", "return 2")
		check("echo *.luau", "alpha.luau beta.luau")
		check("echo '*.luau'", "*.luau")
		check("echo [ab]*.luau", "alpha.luau beta.luau")
		check("echo [!b]*.luau", "alpha.luau")
		check("grep -l return *.luau | wc -l", "2")
		check("cat *.luau", "return 1return 2")
		file("literal*", "return 3")
		check("cat 'literal*.luau'", "return 3")
		check("case ']' in []]) echo yes;; *) echo no;; esac", "yes")
		check("printf 'a\\nb\\n' | while IFS= read -r line; do printf '[%s]' \"$line\"; done", "[a][b]")
		check("printf 'a\\nb' | while IFS= read -r line || [ -n \"$line\" ]; do printf '[%s]' \"$line\"; done", "[a][b]")
		check("for a in 1 2; do for b in x y; do printf '%s%s' $a $b; break; done; done", "1x2x")
		check("for a in 1 2 3; do [ $a -eq 2 ] && continue; printf %s $a; done", "13")
		check("printf %s data > plain.txt", "")
		assert(term:resolve("plain.txt").Source == "data", "printf redirection added a newline")
		check("cat plain.txt", "data")
		check("printf %s more >> plain.txt; cat plain.txt", "datamore")
		check("cat missing 2>/dev/null; echo $?", "2")
		check("cat missing 2>/dev/null | wc -c", "0")
		check("cat <<'EOF'\n$NAME arbitrary text\nEOF", "$NAME arbitrary text\n")
		check("NAME=ok; cat <<EOF\nhello $NAME\nEOF", "hello ok\n")
		check("cat <<EOF\n'$NAME' \"$NAME\" \\$NAME \\x\nEOF", "'ok' \"ok\" $NAME \\x\n")
		check("NAME=outer; echo $(NAME=inner; echo $NAME); echo $NAME", "inner\nouter")
		check("NAME=outer; (NAME=inner; echo $NAME); echo $NAME", "inner\nouter")
		check("printf -v MESSAGE 'hello %s' world; echo \"$MESSAGE\"", "hello world")
		check("printf -v MESSAGE %d invalid 2>/dev/null; echo \"$?:$MESSAGE\"", "1:0")
		contains("echo $((1/0))", "division by zero")
		contains("while true; do :; done", "execution budget exceeded")
		contains("echo should-not-run > forbidden.txt; if true; then echo x", "missing `fi`")
		assert(not term:resolve("forbidden.txt"), "malformed compound command caused a write")
		local src, dst = file("src", "return 123"), file("dst", "return 456")
		check("cp -n src dst", "")
		assert(dst.Source == "return 456" and #dst:GetChildren() == 0, "cp -n mutated an existing file")
		contains("cp src dst", "copied to")
		assert(term:resolve("dst") == dst and dst.Source == "return 123", "cp did not preserve destination identity while overwriting")
		local executable = Instance.new("Script"); executable.Name, executable.Source, executable.Parent = "executable", "return 789", fixture
		contains("cp executable dst", "copied to")
		assert(term:resolve("dst") == dst and dst.ClassName == "ModuleScript" and dst.Source == "return 789", "cp changed the destination script class")
		local duplicates = 0; for _, child in ipairs(fixture:GetChildren()) do if child.Name == "dst" then duplicates += 1 end end
		assert(duplicates == 1, "cp created duplicate siblings")
		local dir = Instance.new("Folder"); dir.Name, dir.Parent = "dest", fixture
		contains("cp -T src dest", "directory with a file")
		assert(term:resolve("dest") == dir and #dir:GetChildren() == 0, "cp -T mutated a mismatched destination")
		local sourceDir = Instance.new("Folder"); sourceDir.Name, sourceDir.Parent = "sourceDir", fixture
		file("new", "return 1", sourceDir); file("kept", "return 2", dir)
		contains("cp -rT sourceDir dest", "copied to")
		assert(dir:FindFirstChild("new") and dir:FindFirstChild("kept"), "cp -rT failed to merge")
		file("kept", "return 999", sourceDir)
		check("cp -rnT sourceDir dest", "")
		assert(dir:FindFirstChild("kept").Source == "return 2", "cp -rn overwrote an existing child")
		local conflict = Instance.new("Folder"); conflict.Name, conflict.Parent = "conflict", dir
		file("conflict", "return 1", sourceDir); file("pending", "return 1", sourceDir)
		contains("cp -rT sourceDir dest", "directory with a file")
		assert(not dir:FindFirstChild("pending") and dir:FindFirstChild("kept").Source == "return 2", "a rejected copy partially changed the destination")
		local hidden = file("uncloneable", "return 1"); hidden.Archivable = false
		contains("cp uncloneable newCopy", "not Archivable")
		assert(not term:resolve("newCopy"), "copy silently accepted a non-Archivable script")
		file("child", "return 1", dst)
		contains("rm -rf dst", "removed")
		assert(not term:resolve("dst"), "rm -rf left a script root behind")
		contains("rm -rf dest", "removed")
		assert(not term:resolve("dest"), "rm -rf left its root behind")
		contains("rm -rf /", "refusing")
		for _, name in ipairs({ "notes.txt", "config.json", "README.md", "file.custom-ext" }) do
			local message = assert(term:write(name, "arbitrary text that is not Luau"))
			assert(not message:find("syntax error", 1, true), name .. " was parsed as Luau")
			check("cat " .. name, "arbitrary text that is not Luau")
		end
		-- Diagnostics reach the console where they were written, not in a block at
		-- the end. Read stream by stream, an error from the middle of a line looked
		-- like it came from the last command that ran.
		check("echo start; cat missing 2>&1; echo end",
			"start\ncat: no child named \"missing\" in " .. root .. "\nend")
		check("for f in 1 2; do echo line$f; cat missing 2>&1; done",
			"line1\ncat: no child named \"missing\" in " .. root .. "\n" ..
			"line2\ncat: no child named \"missing\" in " .. root)
		check("echo x; cat missing 2>&1 | cat; echo y",
			"x\ncat: no child named \"missing\" in " .. root .. "\ny")
		check("echo one; cat missing 2>/dev/null; echo two", "one\ntwo")

		-- cd is silent, and PWD/OLDPWD are the variables that say where it went.
		local nook = Instance.new("Folder"); nook.Name, nook.Parent = "nook", fixture
		check("cd nook", "")
		check("echo $PWD", root .. "/nook")
		check("cd ..; echo $PWD; echo $OLDPWD", root .. "\n" .. root .. "/nook")
		check("cd -", root .. "/nook")
		check("cd ..", "")
		-- A pipeline stage is its own shell, so its cd does not move the caller.
		check("cd nook | wc -l", "0")
		check("echo $PWD", root)
		check("PWD=/fake; echo $PWD", "/fake")
		check("cd nook; echo $PWD", root .. "/nook")
		check("cd ..", "")

		-- -delete unlinks a directory, it does not empty one: a matched folder must
		-- not take children the expression never named.
		local shed = Instance.new("Folder"); shed.Name, shed.Parent = "shed", fixture
		file("tool", "return 1", shed)
		contains("find . -name shed -delete", "Directory not empty")
		assert(term:resolve("shed/tool"), "-delete destroyed an unmatched child")
		-- An action belongs to the `-o` branch it was written in.
		check("find shed -name tool -o -name zzz -delete", "")
		assert(term:resolve("shed/tool"), "-delete fired for another branch's match")
		contains("find shed -name zzz -o -name tool -delete", "removed")
		check("find . -name shed -delete", "removed " .. root .. "/shed")

		-- diff -r descends. Comparing one level and stopping reported two trees that
		-- differ below the top as identical, which is the one answer diff cannot give.
		local left = Instance.new("Folder"); left.Name, left.Parent = "left", fixture
		local right = Instance.new("Folder"); right.Name, right.Parent = "right", fixture
		local leftDeep = Instance.new("Folder"); leftDeep.Name, leftDeep.Parent = "deep", left
		local rightDeep = Instance.new("Folder"); rightDeep.Name, rightDeep.Parent = "deep", right
		file("same", "return 1", leftDeep); file("same", "return 2", rightDeep)
		contains("diff -r left right", "-return 1")
		contains("diff -r left right", "+return 2")
		file("rightOnly", "return 1", rightDeep)
		-- Named distinctly: a top-level-only diff can never reach inside `deep`, so
		-- seeing this at all is the proof that -r descended.
		contains("diff -r left right", "Only in " .. root .. "/right/deep: rightOnly")
		local clash = Instance.new("Folder"); clash.Name, clash.Parent = "clash", leftDeep
		file("clash", "return 1", rightDeep)
		contains("diff -r left right", "is a directory while file")

		-- Scripts can own Instances too: -R must reach nested modules both when
		-- the script is the operand and when the walk enters it from a folder.
		for _, className in ipairs({ "ModuleScript", "Script", "LocalScript" }) do
			local parent = Instance.new(className)
			parent.Name, parent.Parent = className .. "Package", fixture
			local child = file("Child", "return {}", parent)
			file("Grandchild", "return {}", child)
			local expected = "Child.luau\n\n" .. root .. "/" .. parent.Name .. "/Child:\nGrandchild.luau"
			check("ls -R " .. parent.Name, expected)
			check("ls --recursive " .. parent.Name .. ".luau", expected)
			check("ls -R " .. root .. "/" .. parent.Name .. " | head -20", expected)
			contains("ls -R .", root .. "/" .. parent.Name .. ":\n" .. expected)
			assert(Terminal.new(parent):shell("ls -R") == expected,
				"ls -R from a script cwd missed its descendants")
			check("ls " .. parent.Name, parent.Name)
			check("ls -dR " .. parent.Name, parent.Name)
			check("ls -R " .. parent.Name .. "/Child/Grandchild", parent.Name .. "/Child/Grandchild")
			parent:Destroy()
		end

		-- A DataModel allows siblings to share a name, so a path is not always a
		-- unique handle: `find` could match one and `rm` destroy the other, which is
		-- data loss under a correct-looking transcript. MUTATION refuses; reading
		-- follows the first match, because a read cannot corrupt anything and
		-- refusing there made a quarter of a real place unreachable.
		local twinScript = Instance.new("ModuleScript")
		twinScript.Name, twinScript.Source, twinScript.Parent = "twin.luau", "return 1", fixture
		file("scriptHeld", "return 3", twinScript)
		local twinFolder = Instance.new("Folder")
		twinFolder.Name, twinFolder.Parent = "twin.luau", fixture
		file("held", "return 2", twinFolder)
		contains("rm -r twin.luau", "ambiguous")
		contains("find . -type d -name twin.luau -exec rm -r {} ';'", "ambiguous")
		-- Reading is unaffected: navigation still works over duplicate names.
		check("cat twin.luau", "return 1")
		check("ls twin.luau", "twin.luau")
		contains("ls -R .", "held")
		contains("ls -R .", "scriptHeld")
		assert(twinScript.Parent == fixture and twinFolder.Parent == fixture,
			"an ambiguous path destroyed an instance")
		assert(twinFolder:FindFirstChild("held"), "an ambiguous path destroyed a child")
		twinFolder:Destroy()
		-- With the duplicate gone the same path resolves again, and the `.luau`
		-- alias still prefers an exact name over a script's rendered one.
		check("cat twin.luau", "return 1")
		twinScript:Destroy()

		-- A substitution's stderr is not fatal, and does not eat what came before.
		check("printf 'B\\n'; V=\"$(cat missing)\"; printf 'A\\n'; printf '[%s]' \"$V\"",
			"B\ncat: no child named \"missing\" in " .. root .. "\nA\n[]")
		check("i=5; printf '%s %s' \"$((++i))\" \"$i\"", "6 6")
		check("i=5; printf '%s %s' \"$((i++))\" \"$i\"", "5 6")

		-- diff's status is the whole reason it is scriptable.
		local same1 = Instance.new("Folder"); same1.Name, same1.Parent = "same1", fixture
		local same2 = Instance.new("Folder"); same2.Name, same2.Parent = "same2", fixture
		check("diff -r same1 same2; echo $?", "0")
		check("if diff -r same1 same2; then echo identical; fi", "identical")
		file("odd", "return 1", same1)
		check("diff -r same1 same2 > /dev/null; echo $?", "1")
		file("odd", "return 2", same2)
		check("diff same1/odd same2/odd > /dev/null; echo $?", "1")
		check("diff same1/odd same1/odd; echo $?", "0")

		-- rmdir -p removes the components it was given and stops there.
		check("mkdir -p nest/b/c; rmdir -p nest/b/c 2>/dev/null; echo $?", "0")
		assert(not term:resolve("nest"), "rmdir -p left a named component behind")
		term:shell("mkdir -p nest/b/c")
		term:shell("touch nest/keep.luau")
		contains("rmdir -p nest/b/c", "Directory not empty")
		check("rmdir -p nest/b/c 2>/dev/null; echo $?", "2")
		assert(term:resolve("nest/keep.luau"), "rmdir -p removed an unnamed sibling")
		term:shell("rm -r nest")

		-- A mutation announces on stderr, so a capture gets the value and not the
		-- announcement. `$(touch f)` used to evaluate to "created /path [Class]".
		check("printf '[%s]' \"$(touch captured.luau)\" 2>/dev/null", "[]")
		check("printf '[%s]' \"$(rm captured.luau)\" 2>/dev/null", "[]")
		check("printf '[%s]' \"$(mkdir capdir)\" 2>/dev/null", "[]")
		check("printf '[%s]' \"$(rmdir capdir)\" 2>/dev/null", "[]")
		file("edited", "return 1")
		check("printf '[%s]' \"$(sed -i 's/1/2/' edited.luau)\" 2>/dev/null", "[]")
		check("cat edited.luau", "return 2\n")

		-- One named file is grep's bare form: no path, no line number without -n.
		file("hay", "alpha one\nbeta two")
		check("grep alpha hay.luau", "alpha one")
		check("printf '[%s]' \"$(grep alpha hay.luau)\"", "[alpha one]")
		check("grep -n beta hay.luau", "2: beta two")
		check("grep -H alpha hay.luau", root .. "/hay\n  alpha one")

		-- A prefix assignment in front of a special builtin persists; in front of
		-- an ordinary command it is restored.
		check("C=outer; C=temp export C=operand; echo $C", "operand")
		check("C=outer; C=temp true; echo $C", "outer")

		-- Tilde expands at the head of an assignment value and after each colon.
		check("A=~/x; printf '%s' \"$A\"", "//x")
		check("export B=~/x; printf '%s' \"$B\"", "//x")
		check("D=x:~/z; printf '%s' \"$D\"", "x://z")
		check("g() { local E=~/x; printf '%s' \"$E\"; }; g", "//x")

		-- tree descends the whole way; two levels was a silent, unmarked cut.
		term:shell("mkdir -p deep/a/b/c")
		term:shell("touch deep/a/b/c/leaf.luau")
		contains("tree deep", "leaf.luau")
		check("tree -L 2 deep | wc -l", "3")
		term:shell("rm -r deep")

		-- mkdir refuses an existing name, and -p is still the "already fine" form.
		term:shell("mkdir once")
		contains("mkdir once", "File exists")
		check("mkdir once 2>/dev/null; echo $?", "2")
		check("mkdir -p once; echo $?", "0")
		term:shell("rm -r once")

		for _, name in ipairs({ "NoExtension", "Script.lua", "Other.luau" }) do
			local message = assert(term:write(name, "local ="))
			assert(message:find("syntax error", 1, true), name .. " lost Luau diagnostics")
		end

		return count
	end)
	fixture:Destroy()
	if not ok then error(result, 0) end
	return result
end
return Regression
