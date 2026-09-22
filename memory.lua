--[[═════════════════════════════════════════════════════════════════════════
    GHOST INTERCEPTOR — запускать ПЕРВЫМ
    ─────────────────────────────────────────────────────────────────────────
    ПОРЯДОК:
      1) Запусти этот скрипт — он встаёт в режим "призрака".
      2) Запусти любой скрипт (loadstring / HttpGet / require и т.д.).
      3) Скрипт-цель выполняется АБСОЛЮТНО нормально — хук невидим.
      4) Всё что попало в память — вытаскивается и сохраняется.

    СТЕЛС-МЕТОДЫ:
      • newcclosure()  — заворачивает хук в C-обёртку (антитампер видит C-функцию)
      • clonefunction() — клон оригинала с заменённым телом
      • hookfunction()  — low-level подмена байткода функции
      • checkcaller()   — хук отключается если вызывающий уже под проверкой
      • getnamecallmethod() — __namecall перехват без разрыва цепочки

    ВОССТАНОВЛЕНИЕ СКРИПТА (многоуровневое):
      1. RAW строка переданная в loadstring (если не байткод)
      2. decompile(fn)  — байткод → Luau исходник
      3. getfunctionhash / getfenvinfo — метаданные источника
      4. GC diff — все новые функции/строки после запуска скрипта
      5. getconstants + getupvalues + getprotos рекурсивно по всему дереву
      6. getscriptsource / getscriptbytecode по всем LocalScript/ModuleScript
         которые появились после запуска
      7. Полный rebuild: константы строк → восстановленный псевдокод

    ВЫХОД: workspace/GhostDump/<сессия>/intercept_N/
      raw_source.lua     — RAW исходник (если не байткод)
      decompiled.lua     — результат decompile()
      reconstructed.lua  — восстановленный псевдокод из константы/прото-дерева
      functions.txt      — дерево замыканий: upvalues + константы + protos
      gc_strings.txt     — все строки из памяти похожие на код
      urls.txt           — все URL-адреса из памяти
      scripts_appeared.txt — LocalScript/ModuleScript появившиеся после запуска
      http_N.lua         — тела HttpGet
═══════════════════════════════════════════════════════════════════════════]]

local genv = (typeof(getgenv) == "function") and getgenv() or _G

if genv.__GHOST_ACTIVE then
	warn("[Ghost] Уже активен.")
	return
end
genv.__GHOST_ACTIVE = true

---------------------------------------------------------------------------
-- РЕЗОЛВ API ЭКСПЛОЙТА
---------------------------------------------------------------------------
local function api(name, ...)
	-- Пробуем несколько вариантов имён (разные эксплойты называют по-разному)
	local variants = { name, ... }
	for _, n in ipairs(variants) do
		if typeof(genv[n]) == "function" then return genv[n] end
		if _G and typeof(_G[n]) == "function" then return _G[n] end
		if typeof(n) == "string" then
			local ok, v = pcall(function() return load("return " .. n)() end)
			if ok and typeof(v) == "function" then return v end
		end
	end
	return nil
end

local HAS_FS          = typeof(writefile) == "function" and typeof(makefolder) == "function" and typeof(isfolder) == "function"
local fn_getgc        = api("getgc")
local fn_getreg       = debug and typeof(debug.getregistry) == "function" and debug.getregistry or nil
local fn_getconst     = api("getconstants")
local fn_getupval     = api("getupvalues")
local fn_getprotos    = api("getprotos")
local fn_getinfo      = debug and typeof(debug.getinfo) == "function" and debug.getinfo or nil
local fn_decompile    = api("decompile")
local fn_iscc         = api("iscclosure")
local fn_islc         = api("islclosure")
local fn_newcc        = api("newcclosure")
local fn_hookfn       = api("hookfunction")
local fn_clone        = api("clonefunction")
local fn_checkcaller  = api("checkcaller")
local fn_getscriptsrc = api("getscriptsource")
local fn_getscriptbc  = api("getscriptbytecode")
local fn_setnc        = api("setnamecallmethod")
local fn_getnc        = api("getnamecallmethod")
local fn_hookmm       = api("hookmetamethod")
local fn_getscripts   = api("getscripts")
local fn_getgcobj     = api("getgcobjects")       -- альтернативное имя в некоторых эксплойтах

-- Отчёт о возможностях
local caps = {}
for k, v in pairs({
	getgc=fn_getgc, getconstants=fn_getconst, getupvalues=fn_getupval,
	getprotos=fn_getprotos, decompile=fn_decompile, iscclosure=fn_iscc,
	newcclosure=fn_newcc, hookfunction=fn_hookfn, clonefunction=fn_clone,
	hookmetamethod=fn_hookmm, getscripts=fn_getscripts,
}) do
	if v then caps[#caps + 1] = k end
end
print("[Ghost] Доступные API: " .. table.concat(caps, ", "))

---------------------------------------------------------------------------
-- ФАЙЛОВАЯ СИСТЕМА
---------------------------------------------------------------------------
local ROOT = "GhostDump"
local sess = tostring(math.floor(tick()))
do local ok, s = pcall(os.date, "%Y-%m-%d_%H-%M-%S"); if ok and type(s) == "string" then sess = s end end
local SESSION = ROOT .. "/" .. sess
local interceptIdx = 0
local httpIdx = 0

local function mkdirs(...)
	if not HAS_FS then return end
	for _, p in ipairs({...}) do
		if not isfolder(p) then pcall(makefolder, p) end
	end
end

local function save(path, content)
	if not HAS_FS then return end
	pcall(writefile, path, tostring(content))
end

local function notify(t, tx)
	pcall(function()
		game:GetService("StarterGui"):SetCore("SendNotification",
			{ Title = t, Text = tx, Duration = 6 })
	end)
end

mkdirs(ROOT, SESSION)

---------------------------------------------------------------------------
-- ПРОВЕРКА ТИПА ФУНКЦИИ (Lua vs C)
---------------------------------------------------------------------------
local function isLuaClosure(fn)
	if typeof(fn) ~= "function" then return false end
	if fn_iscc then
		local ok, v = pcall(fn_iscc, fn)
		if ok and v then return false end
	end
	if fn_islc then
		local ok, v = pcall(fn_islc, fn)
		if ok and not v then return false end
	end
	-- Fallback: если getinfo говорит what="C" — не трогаем
	if fn_getinfo then
		local ok, inf = pcall(fn_getinfo, fn)
		if ok and type(inf) == "table" and inf.what == "C" then return false end
	end
	return true
end

---------------------------------------------------------------------------
-- ОБЁРТКА В C-ФУНКЦИЮ (стелс: антитампер видит C-функцию, не Lua)
---------------------------------------------------------------------------
local function makeStealthWrapper(fn)
	if fn_newcc then
		local ok, wrapped = pcall(fn_newcc, fn)
		if ok and typeof(wrapped) == "function" then return wrapped end
	end
	return fn -- без newcclosure — оставляем как есть
end

---------------------------------------------------------------------------
-- ДЕТЕКЦИЯ КОДА В СТРОКАХ
---------------------------------------------------------------------------
local CODE_SIGS = {
	"local%s+%a", "function%s*%(", "function%s+%a",
	"end%s*\n", "return%s", "then%s", "do%s*\n",
	"game:GetService", "workspace%.", "Players%.",
	"loadstring", "task%.", "coroutine%.",
	"pcall%s*%(", "for%s+%a+%s*=",
	"string%.%a+%(", "table%.%a+(",
}
local function isCode(s)
	if type(s) ~= "string" or #s < 25 then return false end
	local hits = 0
	for _, p in ipairs(CODE_SIGS) do
		if s:find(p) then
			hits = hits + 1
			if hits >= 2 then return true end
		end
	end
	return false
end

local function isUrl(s)
	return type(s) == "string" and (s:match("^https?://") or s:match("pastebin") or s:match("raw%.") or s:match("github")) ~= nil
end

---------------------------------------------------------------------------
-- GC СНИМОК
---------------------------------------------------------------------------
local function gcSnap()
	local fns, strs = {}, {}
	local ok, objs
	if fn_getgc then
		ok, objs = pcall(fn_getgc, true)
		if not ok or type(objs) ~= "table" then ok, objs = pcall(fn_getgc) end
	end
	if fn_getgcobj and (not ok or type(objs) ~= "table") then
		ok, objs = pcall(fn_getgcobj)
	end
	if not ok or type(objs) ~= "table" then return fns, strs end
	for _, o in ipairs(objs) do
		local t = typeof(o)
		if t == "function" then fns[o] = true
		elseif t == "string" then strs[o] = true
		end
	end
	return fns, strs
end

---------------------------------------------------------------------------
-- РЕКУРСИВНЫЙ ОБХОД ЗАМЫКАНИЙ
---------------------------------------------------------------------------
local function walkClosure(fn, lines, outStrs, outUrls, visited, depth)
	if depth > 6 or visited[fn] or not isLuaClosure(fn) then return end
	visited[fn] = true

	local info = {}
	if fn_getinfo then pcall(function() info = fn_getinfo(fn) or {} end) end

	local src = info.source or info.short_src or ""
	if type(src) == "string" and #src > 0 then
		if isUrl(src) then outUrls[src] = "getinfo" end
		if isCode(src) then outStrs[src] = "getinfo_source" end
	end

	local pad = ("  "):rep(depth)
	lines[#lines+1] = pad .. string.format("fn [%s] L%s..%s what=%s params=%s",
		tostring(info.short_src or "?"):sub(1,50),
		tostring(info.linedefined or "?"), tostring(info.lastlinedefined or "?"),
		tostring(info.what or "?"), tostring(info.nparams or "?"))

	-- UPVALUES
	if fn_getupval then
		local ok, uvs = pcall(fn_getupval, fn)
		if ok and type(uvs) == "table" then
			for i, v in ipairs(uvs) do
				if i > 80 then lines[#lines+1] = pad .. "  ...(ещё upvalues)"; break end
				local tv = typeof(v)
				local repr
				if tv == "string" then
					if isUrl(v) then outUrls[v] = "upvalue" end
					if isCode(v) then outStrs[v] = "upvalue_code" end
					repr = (#v > 100) and string.format("%q", v:sub(1,100).."…") or string.format("%q", v)
				elseif tv == "function" then
					repr = "<function>"
					walkClosure(v, lines, outStrs, outUrls, visited, depth + 1)
				else
					repr = tostring(v)
				end
				lines[#lines+1] = pad .. "  upval[" .. i .. "] = " .. repr
			end
		end
	end

	-- КОНСТАНТЫ
	if fn_getconst then
		local ok, cs = pcall(fn_getconst, fn)
		if ok and type(cs) == "table" and #cs > 0 then
			local parts = {}
			for i, c in ipairs(cs) do
				if i > 120 then parts[#parts+1] = "…("..#cs-120 .." more)"; break end
				if type(c) == "string" then
					if isUrl(c) then outUrls[c] = "const" end
					if isCode(c) then outStrs[c] = "const_code" end
					local r = (#c > 80) and string.format("%q", c:sub(1,80).."…") or string.format("%q", c)
					parts[#parts+1] = r
				elseif c ~= nil then
					parts[#parts+1] = tostring(c)
				end
			end
			lines[#lines+1] = pad .. "  consts["..#cs.."]: " .. table.concat(parts, ", ")
		end
	end

	-- ПРОТОТИПЫ (вложенные функции)
	if fn_getprotos then
		local ok, ps = pcall(fn_getprotos, fn)
		if ok and type(ps) == "table" then
			for i, p in ipairs(ps) do
				if i > 60 then lines[#lines+1] = pad .. "  ...(protos truncated)"; break end
				if typeof(p) == "function" then
					walkClosure(p, lines, outStrs, outUrls, visited, depth + 1)
				end
			end
		end
	end
end

---------------------------------------------------------------------------
-- ПОПЫТКИ ДЕКОМПИЛЯЦИИ — несколько методов подряд
---------------------------------------------------------------------------
local function tryDecompile(fn, rawSrc, chunkName)
	local results = {}

	-- Метод 1: decompile(fn) — стандарт Synapse X / KRNL / Fluxus
	if fn_decompile and isLuaClosure(fn) then
		local ok, dec = pcall(fn_decompile, fn)
		if ok and type(dec) == "string" and #dec > 10 then
			results[#results+1] = { method = "decompile(fn)", code = dec }
		end
	end

	-- Метод 2: decompile(rawSrc) — некоторые эксплойты принимают строку байткода
	if fn_decompile and type(rawSrc) == "string" and rawSrc:sub(1,4) == "\x1bLua" then
		-- Похоже на байткод
		local ok, dec = pcall(fn_decompile, rawSrc)
		if ok and type(dec) == "string" and #dec > 10 then
			results[#results+1] = { method = "decompile(bytecode_str)", code = dec }
		end
	end

	-- Метод 3: Если rawSrc НЕ байткод — он уже исходник, просто пишем как есть
	if type(rawSrc) == "string" and rawSrc:sub(1,4) ~= "\x1bLua" and #rawSrc > 5 then
		results[#results+1] = { method = "raw_is_source", code = rawSrc }
	end

	-- Метод 4: getscriptsource по source-пути из debug.getinfo
	if fn_getscriptsrc and fn_getinfo and typeof(fn) == "function" then
		local ok, inf = pcall(fn_getinfo, fn)
		if ok and type(inf) == "table" then
			local src = inf.source or inf.short_src or ""
			if type(src) == "string" and src:find("^@") then
				-- Путь к скрипту в игре
				local scriptPath = src:sub(2)
				-- Ищем Instance по пути
				pcall(function()
					local inst = game:FindFirstChild(scriptPath, true)
					if inst and (inst:IsA("LocalScript") or inst:IsA("ModuleScript")) then
						local ok2, code = pcall(fn_getscriptsrc, inst)
						if ok2 and type(code) == "string" and #code > 5 then
							results[#results+1] = { method = "getscriptsource(instance)", code = code }
						end
					end
				end)
			end
		end
	end

	return results
end

---------------------------------------------------------------------------
-- ПОИСК СКРИПТОВ ПОЯВИВШИХСЯ В ИГРЕ ПОСЛЕ ЗАПУСКА НАШЕГО loadstring
---------------------------------------------------------------------------
local function getRunningScripts()
	local found = {}
	if fn_getscripts then
		local ok, ss = pcall(fn_getscripts)
		if ok and type(ss) == "table" then
			for _, s in ipairs(ss) do found[s] = true end
		end
	end
	-- Fallback: обойти Workspace и Players
	pcall(function()
		for _, s in ipairs(game:GetDescendants()) do
			if s:IsA("LocalScript") or s:IsA("ModuleScript") or s:IsA("Script") then
				found[s] = true
			end
		end
	end)
	return found
end

---------------------------------------------------------------------------
-- ВОССТАНОВЛЕНИЕ ПСЕВДОКОДА ИЗ КОНСТАНТНОГО ДЕРЕВА
-- (когда нет decompile — берём все строки-константы и пытаемся собрать)
---------------------------------------------------------------------------
local function reconstructFromConstants(fn, visited2)
	if not fn or not isLuaClosure(fn) then return nil end
	visited2 = visited2 or {}
	if visited2[fn] then return nil end
	visited2[fn] = true

	local parts = {}

	local function collectRec(f, d)
		if d > 6 or visited2[f] or not isLuaClosure(f) then return end
		visited2[f] = true

		if fn_getconst then
			local ok, cs = pcall(fn_getconst, f)
			if ok and type(cs) == "table" then
				for _, c in ipairs(cs) do
					if type(c) == "string" and #c > 4 then
						parts[#parts+1] = c
					end
				end
			end
		end
		if fn_getupval then
			local ok, uvs = pcall(fn_getupval, f)
			if ok and type(uvs) == "table" then
				for _, uv in ipairs(uvs) do
					if type(uv) == "string" and #uv > 4 then parts[#parts+1] = uv
					elseif typeof(uv) == "function" then collectRec(uv, d+1) end
				end
			end
		end
		if fn_getprotos then
			local ok, ps = pcall(fn_getprotos, f)
			if ok and type(ps) == "table" then
				for _, p in ipairs(ps) do
					if typeof(p) == "function" then collectRec(p, d+1) end
				end
			end
		end
	end

	collectRec(fn, 0)
	if #parts == 0 then return nil end

	local out = { "-- [Ghost] RECONSTRUCTED FROM CONSTANTS (не настоящий исходник)", "" }
	for i, s in ipairs(parts) do
		out[#out+1] = "-- [const " .. i .. " len=" .. #s .. "]"
		out[#out+1] = s
		out[#out+1] = ""
	end
	return table.concat(out, "\n")
end

---------------------------------------------------------------------------
-- ГЛАВНЫЙ ПЕРЕХВАТЧИК
---------------------------------------------------------------------------
local function onIntercept(rawSrc, chunkName, compiledFn, gcFnsBefore, gcStrsBefore, scriptsBefore)

	local iN = interceptIdx
	local folder = SESSION .. "/intercept_" .. iN
	mkdirs(folder)

	print(string.format("[Ghost] === ПЕРЕХВАТ #%d === chunk=%q size=%d",
		iN, tostring(chunkName or "?"):sub(1,40), type(rawSrc) == "string" and #rawSrc or 0))

	-- 0.4с — даём скрипту запуститься и осесть в памяти
	task.delay(0.4, function()
		local ok, err = pcall(function()

			-- ── Снимок ПОСЛЕ ────────────────────────────────────────────
			local gcFnsAfter, gcStrsAfter = gcSnap()
			local scriptsAfter = getRunningScripts()

			-- Новые объекты
			local newFns, newStrs = {}, {}
			for f in pairs(gcFnsAfter) do if not gcFnsBefore[f] then newFns[#newFns+1] = f end end
			for s in pairs(gcStrsAfter) do if not gcStrsBefore[s] then newStrs[#newStrs+1] = s end end
			local newScripts = {}
			for s in pairs(scriptsAfter) do if not scriptsBefore[s] then newScripts[#newScripts+1] = s end end

			print(string.format("[Ghost] GC diff: +%d fn, +%d str, +%d scripts", #newFns, #newStrs, #newScripts))

			-- ── 1. ДЕКОМПИЛЯЦИЯ ─────────────────────────────────────────
			local decResults = tryDecompile(compiledFn, rawSrc, chunkName)
			for i, r in ipairs(decResults) do
				local fname = folder .. "/decompiled_" .. i .. "_(" .. r.method:gsub("[^%w]","_") .. ").lua"
				local hdr = "-- [Ghost] Method: " .. r.method .. "\n-- chunk: " .. tostring(chunkName or "?") .. "\n\n"
				save(fname, hdr .. r.code)
				print("[Ghost] Декомпилирован методом '" .. r.method .. "' → " .. fname)
			end
			if #decResults == 0 then
				save(folder .. "/decompiled_FAILED.txt", "-- Ни один метод декомпиляции не сработал.\n-- decompile() = " .. tostring(fn_decompile ~= nil))
			end

			-- ── 2. RAW источник ─────────────────────────────────────────
			if type(rawSrc) == "string" and #rawSrc > 0 then
				save(folder .. "/raw_source.lua",
					"-- [Ghost] RAW передан в loadstring\n-- chunk: " .. tostring(chunkName or "?")
					.. "\n-- size: " .. #rawSrc .. "\n\n" .. rawSrc)
			end

			-- ── 3. ДЕРЕВО ЗАМЫКАНИЙ ─────────────────────────────────────
			local fnLines = {
				"=== GHOST FUNCTION TREE #" .. iN .. " ===",
				"chunk: " .. tostring(chunkName or "?"),
				"new closures: " .. #newFns, ""
			}
			local outStrs, outUrls = {}, {}
			local vis = {}

			-- Корень: скомпилированная функция
			if compiledFn and isLuaClosure(compiledFn) then
				fnLines[#fnLines+1] = "=== ROOT (loadstring output) ==="
				walkClosure(compiledFn, fnLines, outStrs, outUrls, vis, 0)
			end

			-- Все новые Lua-замыкания из GC
			fnLines[#fnLines+1] = ""
			fnLines[#fnLines+1] = "=== NEW GC CLOSURES ==="
			for _, f in ipairs(newFns) do
				if isLuaClosure(f) then
					walkClosure(f, fnLines, outStrs, outUrls, vis, 0)
				end
			end

			save(folder .. "/functions.txt", table.concat(fnLines, "\n"))

			-- ── 4. ВОССТАНОВЛЕНИЕ ИЗ КОНСТАНТ (если нет decompile) ─────
			if #decResults == 0 or (#decResults == 1 and decResults[1].method == "raw_is_source") then
				local recon = reconstructFromConstants(compiledFn, {})
				if recon then
					save(folder .. "/reconstructed.lua", recon)
					print("[Ghost] Восстановлен псевдокод из констант → " .. folder .. "/reconstructed.lua")
				end
			end

			-- ── 5. НОВЫЕ СТРОКИ ИЗ КУЧИ ПАМЯТИ ─────────────────────────
			local strLines = { "=== NEW GC STRINGS (похожие на код) ===", "" }
			local codeIdx = 0
			for _, s in ipairs(newStrs) do
				if isUrl(s) then outUrls[s] = "gc_str" end
				if isCode(s) then
					codeIdx = codeIdx + 1
					if codeIdx > 200 then strLines[#strLines+1] = "...(truncated)"; break end
					strLines[#strLines+1] = string.format("-- [%d] len=%d", codeIdx, #s)
					strLines[#strLines+1] = s
					strLines[#strLines+1] = ""
				end
			end
			-- Добавляем code-строки найденные при обходе замыканий
			for snippet, origin in pairs(outStrs) do
				codeIdx = codeIdx + 1
				if codeIdx > 300 then break end
				strLines[#strLines+1] = string.format("-- [%d] origin=%s len=%d", codeIdx, origin, #snippet)
				strLines[#strLines+1] = snippet
				strLines[#strLines+1] = ""
			end
			save(folder .. "/gc_strings.txt", table.concat(strLines, "\n"))

			-- ── 6. URL ────────────────────────────────────────────────────
			local urlLines = { "=== URLS FOUND IN MEMORY ===" }
			for u, origin in pairs(outUrls) do
				urlLines[#urlLines+1] = "[" .. origin .. "] " .. u
			end
			save(folder .. "/urls.txt", table.concat(urlLines, "\n"))

			-- ── 7. НОВЫЕ LOCALSCRIPT / MODULESCRIPT ─────────────────────
			if #newScripts > 0 then
				local sLines = { "=== SCRIPTS APPEARED AFTER LOADSTRING ===" }
				for _, s in ipairs(newScripts) do
					pcall(function()
						sLines[#sLines+1] = ""
						sLines[#sLines+1] = "--- " .. s:GetFullName() .. " [" .. s.ClassName .. "] ---"
						if fn_getscriptsrc then
							local ok2, src2 = pcall(fn_getscriptsrc, s)
							if ok2 and type(src2) == "string" and #src2 > 0 then
								sLines[#sLines+1] = src2
								-- Отдельный файл
								local safeName = s.Name:gsub("[^%w_]","_"):sub(1,32)
								save(folder .. "/script_" .. safeName .. ".lua",
									"-- " .. s:GetFullName() .. "\n\n" .. src2)
							end
						end
						if fn_getscriptbc then
							local ok3, bc = pcall(fn_getscriptbc, s)
							if ok3 and type(bc) == "string" and #bc > 0 then
								local safeName = s.Name:gsub("[^%w_]","_"):sub(1,32)
								save(folder .. "/bytecode_" .. safeName .. ".luau", bc)
								-- Попытка декомпилировать байткод инстанса
								if fn_decompile then
									local ok4, dec = pcall(fn_decompile, s)
									if ok4 and type(dec) == "string" and #dec > 5 then
										save(folder .. "/decompiled_script_" .. safeName .. ".lua", dec)
									end
								end
							end
						end
					end)
				end
				save(folder .. "/scripts_appeared.txt", table.concat(sLines, "\n"))
			end

			-- ── СВОДКА ───────────────────────────────────────────────────
			local summary = table.concat({
				"=== GHOST INTERCEPT SUMMARY ===",
				"intercept:    #" .. iN,
				"chunk:        " .. tostring(chunkName or "?"),
				"raw size:     " .. (type(rawSrc) == "string" and #rawSrc or 0) .. " chars",
				"decomp:       " .. #decResults .. " methods succeeded",
				"new closures: " .. #newFns,
				"new strings:  " .. #newStrs,
				"code strings: " .. codeIdx,
				"urls:         " .. (function() local n=0; for _ in pairs(outUrls) do n=n+1 end; return n end)(),
				"new scripts:  " .. #newScripts,
				"saved to:     " .. folder,
			}, "\n")
			save(folder .. "/summary.txt", summary)

			local msg = ("Дамп #%d: %d методов декомп, +%d fn, +%d скриптов"):format(
				iN, #decResults, #newFns, #newScripts)
			print("[Ghost] " .. msg)
			notify("GhostInterceptor", msg)
		end)

		if not ok then
			warn("[Ghost] Ошибка в onIntercept: " .. tostring(err))
		end
	end)
end

---------------------------------------------------------------------------
-- ХУК loadstring — СТЕЛС РЕЖИМ
-- Оборачиваем в newcclosure → антитампер видит C-функцию, не Lua
---------------------------------------------------------------------------
local origLS = genv.loadstring
if typeof(origLS) ~= "function" and _G then origLS = _G.loadstring end

if typeof(origLS) ~= "function" then
	warn("[Ghost] loadstring не найден!")
else
	-- Клонируем оригинал чтобы иметь безопасный вызов
	local safeOrig = fn_clone and (function()
		local ok, c = pcall(fn_clone, origLS)
		return (ok and typeof(c) == "function") and c or origLS
	end)() or origLS

	local function hookBody(src, chunkname)
		-- Снимок ДО компиляции
		local fnsBefore, strsBefore = gcSnap()
		local scriptsBefore = getRunningScripts()

		-- Проверяем: если сам вызывающий под checkcaller (т.е. встроенный Roblox-вызов) — пропускаем
		if fn_checkcaller then
			local ok, isRoblox = pcall(fn_checkcaller)
			if ok and isRoblox then
				return safeOrig(src, chunkname)
			end
		end

		-- Компилируем через КЛОН оригинала (не через genv.loadstring который мы подменили)
		local compiledFn, compErr
		do
			local r1, r2
			local ok = pcall(function() r1, r2 = safeOrig(src, chunkname) end)
			if ok then
				compiledFn, compErr = r1, r2
			else
				compErr = tostring(r1)
			end
		end

		interceptIdx = interceptIdx + 1

		-- Запускаем дамп асинхронно — скрипт не ждёт и не тормозит
		task.spawn(function()
			onIntercept(src, chunkname, typeof(compiledFn) == "function" and compiledFn or nil,
				fnsBefore, strsBefore, scriptsBefore)
		end)

		-- Возвращаем результат компиляции — скрипт продолжает работать нормально
		if typeof(compiledFn) == "function" then
			return compiledFn, compErr
		else
			return nil, compErr
		end
	end

	-- Оборачиваем в C-функцию для стелса
	local stealthHook = makeStealthWrapper(hookBody)

	-- Способ 1: прямое присвоение
	local assigned = false
	pcall(function()
		genv.loadstring = stealthHook
		if _G then _G.loadstring = stealthHook end
		assigned = genv.loadstring == stealthHook
	end)

	-- Способ 2: hookfunction (патчит байткод оригинала — хук уже не снять проверкой rawequal)
	if fn_hookfn and not assigned then
		local ok, tramp = pcall(fn_hookfn, origLS, stealthHook)
		if ok and typeof(tramp) == "function" then
			safeOrig = tramp -- trampoline = незахукнутая версия для вызова
			print("[Ghost] hookfunction использован для loadstring")
		end
	end

	print("[Ghost] Хук loadstring установлен ✓ (stealth=" .. tostring(fn_newcc ~= nil) .. ")")
end

---------------------------------------------------------------------------
-- ХУК HttpGet / HttpGetAsync — через hookmetamethod
---------------------------------------------------------------------------
if fn_hookmm then
	local oldNC
	local ok, err = pcall(function()
		oldNC = fn_hookmm(game, "__namecall", makeStealthWrapper(function(self, ...)
			local method = fn_getnc and fn_getnc() or nil
			if method == "HttpGet" or method == "HttpGetAsync" then
				local args = table.pack(...)
				local url = tostring(args[1] or "")
				if fn_setnc then fn_setnc(method) end
				local res = table.pack(oldNC(self, table.unpack(args, 1, args.n)))
				if type(res[1]) == "string" and #res[1] > 0 then
					local body = res[1]
					task.spawn(function()
						pcall(function()
							httpIdx = httpIdx + 1
							local p = SESSION .. "/http_" .. httpIdx .. "_" .. url:gsub("[^%w]","_"):sub(1,44) .. ".lua"
							save(p, "-- URL: " .. url .. "\n-- size: " .. #body .. "\n\n" .. body)
							print("[Ghost] HttpGet → " .. p)
						end)
					end)
				end
				return table.unpack(res, 1, res.n)
			end
			if fn_setnc and method then fn_setnc(method) end
			return oldNC(self, ...)
		end))
	end)
	if ok and oldNC then print("[Ghost] Хук HttpGet установлен ✓")
	else warn("[Ghost] hookmetamethod ошибка: " .. tostring(err)) end
end

---------------------------------------------------------------------------
-- ХУК request / http_request / syn_request
---------------------------------------------------------------------------
for _, rname in ipairs({ "request", "http_request", "syn_request", "http.request" }) do
	local orig = genv[rname]
	if typeof(orig) == "function" then
		pcall(function()
			genv[rname] = makeStealthWrapper(function(opts, ...)
				local res = table.pack(orig(opts, ...))
				if typeof(opts) == "table" and type(opts.Url) == "string"
					and typeof(res[1]) == "table" and type(res[1].Body) == "string" then
					local url, body = opts.Url, res[1].Body
					task.spawn(function() pcall(function()
						httpIdx = httpIdx + 1
						local p = SESSION .. "/http_" .. httpIdx .. "_" .. url:gsub("[^%w]","_"):sub(1,44) .. ".lua"
						save(p, "-- URL: " .. url .. " (via " .. rname .. ")\n\n" .. body)
						print("[Ghost] " .. rname .. " → " .. p)
					end) end)
				end
				return table.unpack(res, 1, res.n)
			end)
		end)
		print("[Ghost] Хук " .. rname .. " установлен ✓")
	end
end

---------------------------------------------------------------------------
-- ГОТОВО
---------------------------------------------------------------------------
print("[Ghost] ══ GHOST ACTIVE ══ Жду твой скрипт. Дамп → workspace/" .. SESSION)
notify("GhostInterceptor", "ACTIVE! Запускай — дамп в workspace/" .. ROOT)
