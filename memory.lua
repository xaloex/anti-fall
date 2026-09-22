--[[═════════════════════════════════════════════════════════════════════════
    SCRIPT MEMORY INTERCEPTOR  — запускать ПЕРВЫМ
    ─────────────────────────────────────────────────────────────────────────
    ПОРЯДОК:
      1) Запусти ЭТО (script_memory.lua) — ставит хуки и ждёт.
      2) Запусти любой скрипт через loadstring / HttpGet.
      3) В момент вызова loadstring() скрипт:
           a) сохраняет RAW исходник как есть
           b) делает снимок GC ДО выполнения целевого скрипта
           c) пропускает скрипт, ждёт пока он загрузится в память
           d) делает снимок GC ПОСЛЕ — находит новые объекты (функции, строки)
           e) обходит ВСЁ дерево замыканий до упора
              — getconstants, getupvalues, getprotos рекурсивно
              — debug.getinfo на каждой функции
              — decompile() если есть
           f) вытаскивает все URL, строки-кусочки кода, байткод
           g) сохраняет всё в workspace/ScriptMemDump/

    Хуки:
      • loadstring (главный)
      • game:HttpGet / HttpGetAsync (через hookmetamethod)
      • request / http_request / syn_request

    Файловая структура вывода:
      ScriptMemDump/<сессия>/dump_N/
        raw_source.lua        — исходник как был передан в loadstring
        decompiled.lua        — байткод-декомпиляция (если decompile() есть)
        functions.txt         — все замыкания: константы + upvalues + protos
        gc_new_strings.txt    — новые строки в памяти после запуска скрипта
        urls.txt              — все URL из памяти
        http_N_<name>.lua     — тела HttpGet ответов
═══════════════════════════════════════════════════════════════════════════]]

local genv = (typeof(getgenv) == "function") and getgenv() or _G

if genv.__SMI_ACTIVE then
	warn("[SMI] Уже активен. Перезапуск не нужен.")
	return
end
genv.__SMI_ACTIVE = true

---------------------------------------------------------------------------
-- API ЭКСПЛОЙТА
---------------------------------------------------------------------------
local HAS_FS         = (typeof(writefile)  == "function") and (typeof(isfolder) == "function") and (typeof(makefolder) == "function")
local getgc_fn       = (typeof(getgc)      == "function") and getgc       or nil
local getreg_fn      = (typeof(debug) == "table" and typeof(debug.getregistry) == "function") and debug.getregistry or nil
local getconst_fn    = (typeof(getconstants)== "function") and getconstants or nil
local getupval_fn    = (typeof(getupvalues) == "function") and getupvalues  or nil
local getprotos_fn   = (typeof(getprotos)   == "function") and getprotos    or nil
local getinfo_fn     = (typeof(debug) == "table" and typeof(debug.getinfo) == "function") and debug.getinfo or nil
local decompile_fn   = (typeof(decompile)   == "function") and decompile    or nil
local iscclosure_fn  = (typeof(iscclosure)  == "function") and iscclosure   or nil
local islclosure_fn  = (typeof(islclosure)  == "function") and islclosure   or nil

---------------------------------------------------------------------------
-- ПАПКИ СЕССИИ
---------------------------------------------------------------------------
local ROOT = "ScriptMemDump"
local sessionName = tostring(math.floor(tick()))
do local ok, s = pcall(os.date, "%Y-%m-%d_%H-%M-%S"); if ok and type(s) == "string" then sessionName = s end end
local SESSION = ROOT .. "/" .. sessionName
local dumpIndex = 0
local httpIndex = 0

---------------------------------------------------------------------------
-- УТИЛИТЫ FS
---------------------------------------------------------------------------
local function ensureDir(p)
	if not HAS_FS then return end
	if not isfolder(p) then pcall(makefolder, p) end
end

local function saveFile(path, content)
	if not HAS_FS then print("[SMI] " .. path .. "\n" .. tostring(content)); return end
	local ok, e = pcall(writefile, path, tostring(content))
	if not ok then warn("[SMI] writefile err: " .. tostring(e)) end
end

local function notify(t, tx)
	pcall(function() game:GetService("StarterGui"):SetCore("SendNotification", { Title = t, Text = tx, Duration = 5 }) end)
end

ensureDir(ROOT)
ensureDir(SESSION)

---------------------------------------------------------------------------
-- ФИЛЬТРЫ
---------------------------------------------------------------------------
-- Является ли функция Lua-замыканием (не C)?
local function isLuaFunc(fn)
	if typeof(fn) ~= "function" then return false end
	if iscclosure_fn then local ok, v = pcall(iscclosure_fn, fn); if ok and v then return false end end
	if islclosure_fn then local ok, v = pcall(islclosure_fn, fn); if ok and not v then return false end end
	return true
end

-- Похожа ли строка на Lua-исходник?
local LUA_PATTERNS = {
	"local%s+%w", "function%s+%w", "function%s*%(", "end%s*$", "return%s",
	"game:GetService", "workspace%.", "Players%.", "GetService%(",
	"loadstring", "pcall", "task%.spawn", "coroutine%.",
	"if%s+.+%s+then", "for%s+%w", "while%s+.+%s+do",
}
local function isLikelyCode(s)
	if type(s) ~= "string" or #s < 30 then return false end
	local hits = 0
	for _, p in ipairs(LUA_PATTERNS) do
		if s:find(p) then hits = hits + 1 end
		if hits >= 2 then return true end
	end
	return false
end

-- Является ли строка URL?
local function isUrl(s)
	return type(s) == "string" and (s:match("^https?://") ~= nil or s:match("^http://") ~= nil)
end

---------------------------------------------------------------------------
-- ФОРМАТИРОВАНИЕ ЗНАЧЕНИЙ (для отчёта functions.txt)
---------------------------------------------------------------------------
local function fmtVal(v)
	local t = typeof(v)
	if t == "string" then
		local s = v:gsub("%c", " ")
		if #s > 150 then s = s:sub(1, 150) .. "…" end
		return string.format("%q", s)
	elseif t == "number" or t == "boolean" then return tostring(v)
	elseif t == "table" then return "<table>"
	elseif t == "function" then return "<function>"
	elseif t == "Instance" then
		local ok, cls = pcall(function() return v.ClassName end)
		return "<" .. (ok and tostring(cls) or "Instance") .. ">"
	end
	return "<" .. t .. ">"
end

---------------------------------------------------------------------------
-- СНИМОК GC — получить все объекты сейчас
---------------------------------------------------------------------------
local function gcSnapshot()
	local funcs, strings, tables = {}, {}, {}
	if not getgc_fn then return funcs, strings, tables end

	local ok, objs = pcall(getgc_fn, true)
	if not ok or type(objs) ~= "table" then
		ok, objs = pcall(getgc_fn)
	end
	if not ok or type(objs) ~= "table" then return funcs, strings, tables end

	for _, o in ipairs(objs) do
		local t = typeof(o)
		if t == "function" then
			funcs[o] = true
		elseif t == "string" then
			strings[o] = true
		elseif t == "table" then
			tables[o] = true
		end
	end
	return funcs, strings, tables
end

-- Разность двух снимков (новые объекты в B, которых не было в A)
local function gcDiff(oldSet, newSet)
	local diff = {}
	for obj in pairs(newSet) do
		if not oldSet[obj] then
			diff[#diff + 1] = obj
		end
	end
	return diff
end

---------------------------------------------------------------------------
-- ПОЛНЫЙ ОБХОД ДЕРЕВА ЗАМЫКАНИЙ
---------------------------------------------------------------------------
local function deepDumpClosure(fn, lines, visited, depth)
	if depth > 8 or visited[fn] or not isLuaFunc(fn) then return end
	visited[fn] = true

	local info = {}
	if getinfo_fn then pcall(function() info = getinfo_fn(fn) or {} end) end

	local pad = string.rep("  ", depth)
	lines[#lines + 1] = string.format(
		"%s[func] src=%s lines=%s..%s params=%s what=%s",
		pad,
		tostring(info.short_src or info.source or "?"):sub(1, 60),
		tostring(info.linedefined or "?"),
		tostring(info.lastlinedefined or "?"),
		tostring(info.nparams or "?"),
		tostring(info.what or "?")
	)

	-- Upvalues
	if getupval_fn then
		local ok, uvs = pcall(getupval_fn, fn)
		if ok and type(uvs) == "table" then
			for i, uv in ipairs(uvs) do
				if i > 60 then lines[#lines + 1] = pad .. "  ... upvalues truncated"; break end
				lines[#lines + 1] = pad .. "  upval[" .. i .. "] = " .. fmtVal(uv)
				if typeof(uv) == "function" then
					deepDumpClosure(uv, lines, visited, depth + 1)
				end
			end
		end
	end

	-- Константы
	if getconst_fn then
		local ok, cs = pcall(getconst_fn, fn)
		if ok and type(cs) == "table" and #cs > 0 then
			local parts = {}
			for i, c in ipairs(cs) do
				if i > 100 then parts[#parts + 1] = "…(" .. (#cs - 100) .. " more)"; break end
				parts[#parts + 1] = fmtVal(c)
			end
			lines[#lines + 1] = pad .. "  consts[" .. #cs .. "]: " .. table.concat(parts, ", ")
		end
	end

	-- Прототипы (вложенные функции)
	if getprotos_fn then
		local ok, ps = pcall(getprotos_fn, fn)
		if ok and type(ps) == "table" then
			for i, p in ipairs(ps) do
				if i > 40 then lines[#lines + 1] = pad .. "  ... protos truncated"; break end
				if typeof(p) == "function" then
					deepDumpClosure(p, lines, visited, depth + 1)
				end
			end
		end
	end
end

---------------------------------------------------------------------------
-- ИЗВЛЕЧЕНИЕ СТРОК И URL ИЗ КОНСТАНТЫ ВСЕГО ДЕРЕВА
---------------------------------------------------------------------------
local function collectStringsFromClosure(fn, outStrings, outUrls, visited, depth)
	if depth > 8 or visited[fn] or not isLuaFunc(fn) then return end
	visited[fn] = true

	if getconst_fn then
		local ok, cs = pcall(getconst_fn, fn)
		if ok and type(cs) == "table" then
			for _, c in ipairs(cs) do
				if type(c) == "string" then
					if isUrl(c) then outUrls[c] = "constant" end
					if isLikelyCode(c) then outStrings[c] = "constant_code" end
				end
			end
		end
	end

	if getupval_fn then
		local ok, uvs = pcall(getupval_fn, fn)
		if ok and type(uvs) == "table" then
			for _, uv in ipairs(uvs) do
				if type(uv) == "string" then
					if isUrl(uv) then outUrls[uv] = "upvalue" end
					if isLikelyCode(uv) then outStrings[uv] = "upvalue_code" end
				elseif typeof(uv) == "function" then
					collectStringsFromClosure(uv, outStrings, outUrls, visited, depth + 1)
				end
			end
		end
	end

	if getprotos_fn then
		local ok, ps = pcall(getprotos_fn, fn)
		if ok and type(ps) == "table" then
			for _, p in ipairs(ps) do
				if typeof(p) == "function" then
					collectStringsFromClosure(p, outStrings, outUrls, visited, depth + 1)
				end
			end
		end
	end
end

---------------------------------------------------------------------------
-- ГЛАВНЫЙ ДАМПЕР — вызывается после перехвата loadstring
---------------------------------------------------------------------------
local function performDump(rawSource, chunkName, compiledFn, gcBefore)

	dumpIndex = dumpIndex + 1
	local folder = SESSION .. "/dump_" .. dumpIndex
	ensureDir(folder)

	-- ── 1. RAW исходник ─────────────────────────────────────────────────
	local header = table.concat({
		"-- [SMI] RAW SOURCE DUMP #" .. dumpIndex,
		"-- chunkname: " .. tostring(chunkName or "unknown"),
		"-- size: " .. tostring(rawSource and #rawSource or 0) .. " chars",
		"-- session: " .. sessionName,
		"",
		""
	}, "\n")
	saveFile(folder .. "/raw_source.lua", header .. tostring(rawSource or "(nil)"))

	-- ── 2. Деcompиляция байткода (только если decompile() есть) ─────────
	if decompile_fn and compiledFn then
		-- decompile() безопасно вызываем только на Lua-функциях
		if isLuaFunc(compiledFn) then
			local ok, dec = pcall(decompile_fn, compiledFn)
			if ok and type(dec) == "string" and #dec > 0 then
				saveFile(folder .. "/decompiled.lua", dec)
			else
				saveFile(folder .. "/decompiled.lua", "-- decompile() failed: " .. tostring(dec))
			end
		end
	end

	-- ── 3. Ждём немного чтобы скрипт успел запуститься и осесть в памяти
	task.delay(0.35, function()
		local ok, err = pcall(function()

			-- Снимок GC ПОСЛЕ запуска
			local gcFuncsAfter, gcStringsAfter, _ = gcSnapshot()

			-- Новые функции появившиеся после запуска скрипта
			local newFuncs = {}
			do
				local oldFuncs = gcBefore.funcs or {}
				for fn in pairs(gcFuncsAfter) do
					if not oldFuncs[fn] then newFuncs[#newFuncs + 1] = fn end
				end
			end

			-- Новые строки
			local newStrings = {}
			do
				local oldStrings = gcBefore.strings or {}
				for s in pairs(gcStringsAfter) do
					if not oldStrings[s] then newStrings[#newStrings + 1] = s end
				end
			end

			print(string.format("[SMI] GC diff: +%d функций, +%d строк в памяти", #newFuncs, #newStrings))

			-- ── 4. Полный дамп всех новых замыканий ─────────────────────
			local funcLines = {
				"=== SMI FUNCTION DUMP #" .. dumpIndex .. " ===",
				"chunkname: " .. tostring(chunkName or "?"),
				"new closures found: " .. #newFuncs,
				""
			}
			local visitedF = {}

			-- Сначала дампим скомпилированную функцию из loadstring (корень)
			if compiledFn and isLuaFunc(compiledFn) then
				funcLines[#funcLines + 1] = "=== ROOT (compiled fn from loadstring) ==="
				deepDumpClosure(compiledFn, funcLines, visitedF, 0)
			end

			-- Потом все новые функции из GC
			funcLines[#funcLines + 1] = ""
			funcLines[#funcLines + 1] = "=== NEW CLOSURES FROM GC ==="
			for _, fn in ipairs(newFuncs) do
				if isLuaFunc(fn) then
					deepDumpClosure(fn, funcLines, visitedF, 0)
				end
			end

			saveFile(folder .. "/functions.txt", table.concat(funcLines, "\n"))

			-- ── 5. Строки-фрагменты кода и URL из памяти ─────────────────
			local codeStrings = {}
			local urlStrings  = {}

			-- Из новых GC строк
			for _, s in ipairs(newStrings) do
				if isUrl(s) then urlStrings[s] = "gc_new" end
				if isLikelyCode(s) then codeStrings[s] = "gc_new_string" end
			end

			-- Из констант/upvalues всех новых замыканий
			local visitedS = {}
			for _, fn in ipairs(newFuncs) do
				collectStringsFromClosure(fn, codeStrings, urlStrings, visitedS, 0)
			end
			if compiledFn and isLuaFunc(compiledFn) then
				collectStringsFromClosure(compiledFn, codeStrings, urlStrings, visitedS, 0)
			end

			-- Сохраняем найденные строки кода (обфускатор мог раздробить скрипт)
			local gcStringLines = { "=== NEW STRINGS IN MEMORY AFTER SCRIPT RUN ===", "" }
			local codeIdx = 0
			for snippet, origin in pairs(codeStrings) do
				codeIdx = codeIdx + 1
				gcStringLines[#gcStringLines + 1] = ("-- [%d] origin=%s len=%d"):format(codeIdx, origin, #snippet)
				gcStringLines[#gcStringLines + 1] = snippet
				gcStringLines[#gcStringLines + 1] = ""
			end
			if codeIdx == 0 then gcStringLines[#gcStringLines + 1] = "(нет фрагментов кода в новых строках GC)" end
			saveFile(folder .. "/gc_new_strings.txt", table.concat(gcStringLines, "\n"))

			-- ── 6. Список URL ─────────────────────────────────────────────
			local urlLines = { "=== CAPTURED URLS ===" }
			for u, origin in pairs(urlStrings) do
				urlLines[#urlLines + 1] = "[" .. origin .. "] " .. u
			end
			if #urlLines == 1 then urlLines[#urlLines + 1] = "(URL не найдены)" end
			saveFile(folder .. "/urls.txt", table.concat(urlLines, "\n"))

			-- ── 7. Сводка ─────────────────────────────────────────────────
			local summary = table.concat({
				"=== SMI SUMMARY #" .. dumpIndex .. " ===",
				"chunkname:      " .. tostring(chunkName or "?"),
				"source size:    " .. tostring(rawSource and #rawSource or 0) .. " chars",
				"new closures:   " .. #newFuncs,
				"new gc strings: " .. #newStrings,
				"code snippets:  " .. codeIdx,
				"urls found:     " .. (function() local n = 0; for _ in pairs(urlStrings) do n = n + 1 end; return n end)(),
				"files saved to: " .. folder,
			}, "\n")
			saveFile(folder .. "/summary.txt", summary)

			local msg = ("Дамп #%d готов! +%d замыканий, +%d строк → %s"):format(
				dumpIndex, #newFuncs, #newStrings, folder)
			print("[SMI] " .. msg)
			notify("ScriptMemoryInterceptor", msg)
		end)

		if not ok then
			warn("[SMI] Ошибка в performDump: " .. tostring(err))
		end
	end)
end

---------------------------------------------------------------------------
-- ХУК НА loadstring
---------------------------------------------------------------------------
local originalLoadstring = genv.loadstring
if typeof(originalLoadstring) ~= "function" and _G then
	originalLoadstring = _G.loadstring
end

if typeof(originalLoadstring) ~= "function" then
	warn("[SMI] loadstring не найден — основной хук не установлен!")
else
	local function hookedLoadstring(src, chunkname)
		-- Снимок GC ДО компиляции (ловим разницу объектов)
		local gcFuncsBefore, gcStrsBefore, _ = gcSnapshot()
		local gcBefore = { funcs = gcFuncsBefore, strings = gcStrsBefore }

		-- Компилируем через оригинал
		local compOk, fn, compErr = true, nil, nil
		do
			local r1, r2
			compOk, r1, r2 = pcall(originalLoadstring, src, chunkname)
			if compOk then
				fn, compErr = r1, r2
			else
				fn, compErr = nil, tostring(r1)
				compOk = true -- для return ниже
			end
		end

		print(string.format("[SMI] Перехват loadstring! chunk=%q size=%d compiled=%s",
			tostring(chunkname or "?"):sub(1, 40),
			type(src) == "string" and #src or 0,
			typeof(fn) == "function" and "YES" or ("NO:" .. tostring(compErr))
		))

		-- Запускаем дамп асинхронно чтобы не тормозить сам скрипт
		task.spawn(function()
			performDump(src, chunkname, typeof(fn) == "function" and fn or nil, gcBefore)
		end)

		-- Возвращаем результат как есть — скрипт работает нормально
		if typeof(fn) == "function" then
			return fn, compErr
		else
			return nil, compErr
		end
	end

	-- Подменяем в genv и _G
	pcall(function() genv.loadstring = hookedLoadstring end)
	pcall(function() if _G then _G.loadstring = hookedLoadstring end end)

	-- Резерв: hookfunction если прямое присвоение не сработало
	if genv.loadstring ~= hookedLoadstring and typeof(hookfunction) == "function" then
		local trampoline
		local hOk = pcall(function()
			trampoline = hookfunction(originalLoadstring, function(src, chunkname)
				return hookedLoadstring(src, chunkname)
			end)
		end)
		if hOk and trampoline then
			originalLoadstring = trampoline
			print("[SMI] Использован hookfunction для loadstring")
		end
	end

	print("[SMI] Хук loadstring установлен ✓")
end

---------------------------------------------------------------------------
-- ХУК НА HttpGet / HttpGetAsync
---------------------------------------------------------------------------
if typeof(hookmetamethod) == "function" then
	local oldNamecall
	local ok, err = pcall(function()
		oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
			local method = typeof(getnamecallmethod) == "function" and getnamecallmethod() or nil
			if method == "HttpGet" or method == "HttpGetAsync" then
				local args = table.pack(...)
				local url = tostring(args[1] or "")
				if typeof(setnamecallmethod) == "function" then setnamecallmethod(method) end
				local results = table.pack(oldNamecall(self, table.unpack(args, 1, args.n)))
				if typeof(results[1]) == "string" and #results[1] > 0 then
					local body = results[1]
					task.spawn(function()
						pcall(function()
							httpIndex = httpIndex + 1
							local fname = SESSION .. "/http_" .. httpIndex .. "_" .. url:gsub("[^%w]","_"):sub(1,48) .. ".lua"
							saveFile(fname, "-- URL: " .. url .. "\n-- size: " .. #body .. "\n\n" .. body)
							print("[SMI] HttpGet сохранён → " .. fname)
						end)
					end)
				end
				return table.unpack(results, 1, results.n)
			end
			if typeof(setnamecallmethod) == "function" and method then setnamecallmethod(method) end
			return oldNamecall(self, ...)
		end)
	end)
	if ok and oldNamecall then
		print("[SMI] Хук HttpGet (__namecall) установлен ✓")
	else
		warn("[SMI] hookmetamethod не сработал: " .. tostring(err))
	end
end

---------------------------------------------------------------------------
-- ХУК НА request / http_request / syn_request
---------------------------------------------------------------------------
for _, rname in ipairs({ "request", "http_request", "syn_request" }) do
	local orig = genv[rname]
	if typeof(orig) == "function" then
		pcall(function()
			genv[rname] = function(opts, ...)
				local results = table.pack(orig(opts, ...))
				if typeof(opts) == "table" and type(opts.Url) == "string"
					and typeof(results[1]) == "table" and type(results[1].Body) == "string" then
					local url, body = opts.Url, results[1].Body
					task.spawn(function()
						pcall(function()
							httpIndex = httpIndex + 1
							local fname = SESSION .. "/http_" .. httpIndex .. "_" .. url:gsub("[^%w]","_"):sub(1,48) .. ".lua"
							saveFile(fname, "-- URL: " .. url .. " (via " .. rname .. ")\n-- size: " .. #body .. "\n\n" .. body)
							print("[SMI] request сохранён → " .. fname)
						end)
					end)
				end
				return table.unpack(results, 1, results.n)
			end
		end)
		print("[SMI] Хук " .. rname .. " установлен ✓")
	end
end

---------------------------------------------------------------------------
-- ГОТОВО
---------------------------------------------------------------------------
print("[SMI] ══ АКТИВЕН ══ Жду твой loadstring. Дамп → workspace/" .. SESSION)
notify("ScriptMemInterceptor", "Активен! Запускай свой loadstring → " .. ROOT)
