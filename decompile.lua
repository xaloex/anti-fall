--[[═════════════════════════════════════════════════════════════════════════
    SCRIPT GRABBER / DUMPER  (запускать ПЕРВЫМ)
    ─────────────────────────────────────────────────────────────────────────
    1) Запусти этот скрипт — он встанет в режим ожидания.
    2) Выполни любой другой скрипт (через loadstring / game:HttpGet и т.п.).
    3) Граббер перехватит его и сохранит в папку workspace/ScriptGrabber/
       (workspace — это папка "workspace" в директории твоего эксплойта):

       ScriptGrabber/<дата_сессии>/
           info.txt          — инфо о сессии и возможностях эксплойта
           dump_N/
               script.txt      — ИСХОДНИК перехваченного скрипта (гарантированно)
               script_clean.txt— версия с раскрытыми строками (\xNN \ddd \u{} \z)
               functions.txt   — дамп констант и upvalues (если включено)
           http_N_*.lua      — ответы HttpGet (исходники, скачанные скриптом)

    СТЕЛС:
    - ONE_SHOT_CAPTURE = true — хук ловит первый скрипт и больше не
      вмешивается в выполнение, чтобы античит/анти-тампер не заметил подмену.

    ЗАЩИТА ОТ ВЫЛЕТОВ:
    - decompile() НЕ вызывается на Lua-функциях из loadstring (в 99%
      эксплойтов это приводило к моментальному крашу Роблокса 0xC0000005).
    - hookmetamethod не дерегистрируется во время вызова __namecall (вызывало
      повреждение памяти и вылет).
    - unescapeSource оптимизирован через регулярные выражения и защищён от
      переполнения памяти при больших обфусцированных скриптах.
═══════════════════════════════════════════════════════════════════════════]]

local genv = (typeof(getgenv) == "function") and getgenv() or _G

if genv.__SCRIPT_GRABBER_ACTIVE then
	warn("[ScriptGrabber] Уже запущен — повторно не встаю.")
	return
end
genv.__SCRIPT_GRABBER_ACTIVE = true

--// Настройки ──────────────────────────────────────────────────────────────
local ONE_SHOT_CAPTURE   = true   -- снять активность хуков после 1-го перехвата
local HOOK_LOADSTRING    = true   -- перехват loadstring (основной источник дампа)
local HOOK_HTTPGET       = true   -- перехват game:HttpGet / HttpGetAsync
local HOOK_REQUEST       = true   -- перехват request / http_request
local DUMP_CLOSURE_INFO  = true   -- анализ прототипов/констант (поставь false при нестабильном эксплойте)

--// Проверка окружения эксплойта ──────────────────────────────────────────
local HAS_FS = (typeof(writefile) == "function")
	and (typeof(isfolder) == "function")
	and (typeof(makefolder) == "function")

local dbg_getinfo  = (typeof(debug) == "table" and typeof(debug.getinfo) == "function") and debug.getinfo or nil
local getconstants = (typeof(getconstants) == "function") and getconstants or nil
local getupvalues  = (typeof(getupvalues) == "function") and getupvalues or nil
local getprotos    = (typeof(getprotos) == "function") and getprotos or nil
local decompile_fn = (typeof(decompile) == "function") and decompile or nil
local iscclosure_fn= (typeof(iscclosure) == "function") and iscclosure or nil
local islclosure_fn= (typeof(islclosure) == "function") and islclosure or nil

local ROOT = "ScriptGrabber"
local sessionName = tostring(math.floor(tick()))
do
	local ok, stamp = pcall(os.date, "%Y-%m-%d_%H-%M-%S")
	if ok and type(stamp) == "string" then sessionName = stamp end
end
local SESSION = ROOT .. "/" .. sessionName
local dumpCount = 0
local httpCount = 0

--// Утилиты ───────────────────────────────────────────────────────────────
local function notify(title, text, dur)
	pcall(function()
		game:GetService("StarterGui"):SetCore("SendNotification", {
			Title = title, Text = text, Duration = dur or 4,
		})
	end)
end

local function ensureDir(path)
	if not HAS_FS then return end
	if not isfolder(path) then pcall(makefolder, path) end
end

local function saveFile(path, content)
	if not HAS_FS then
		warn("[ScriptGrabber] Файловая система недоступна, консоль:", path)
		print(tostring(content))
		return
	end
	local ok, err = pcall(writefile, path, tostring(content))
	if not ok then
		warn("[ScriptGrabber] Ошибка записи '" .. path .. "': " .. tostring(err))
	end
end

local function urlToName(url)
	return tostring(url):gsub("[^%w]", "_"):sub(1, 48)
end

--// Безопасное раскрытие escape-строк ─────────────────────────────────────
-- Обфускаторы прячут читаемый текст в \xNN, \ddd, \u{...}, \z.
-- Прежний побайтовый парсер создавал миллионы строк и крашил память.
-- Этот метод использует безопасный gsub и декодирует только печатные символы,
-- не ломая структуру кавычек и синтаксис.
local function unescapeSource(src)
	if type(src) ~= "string" or #src == 0 then return src end
	-- Если скрипт огромный (>1.5MB), пропускаем раскрытие во избежание фриза
	if #src > 1500 * 1024 then return src end

	local ok, result = pcall(function()
		local s = src
		-- \z - пропуск пробелов и переносов строк
		s = s:gsub("\\z%s*", "")

		-- \xNN - шестнадцатеричные байты
		s = s:gsub("\\x(%x%x)", function(h)
			local code = tonumber(h, 16)
			-- Декодируем только безопасные печатные символы (без кавычек ' ", бэкслеша \ и спецсимволов)
			if code and code >= 32 and code <= 126 and code ~= 34 and code ~= 39 and code ~= 92 then
				return string.char(code)
			end
		end)

		-- \ddd - десятичные коды байтов (например \065 -> 'A')
		s = s:gsub("\\(%d%d?%d?)", function(d)
			local code = tonumber(d)
			if code and code >= 32 and code <= 126 and code ~= 34 and code ~= 39 and code ~= 92 then
				return string.char(code)
			end
		end)

		-- \u{...} - юникод codepoints
		s = s:gsub("\\u%{(%x+)%}", function(hex)
			local code = tonumber(hex, 16)
			if code and code >= 32 and code <= 126 and code ~= 34 and code ~= 39 and code ~= 92 then
				return string.char(code)
			end
		end)

		return s
	end)

	return (ok and type(result) == "string") and result or src
end

ensureDir(ROOT)
ensureDir(SESSION)
saveFile(SESSION .. "/info.txt", table.concat({
	"ScriptGrabber — сессия: " .. sessionName,
	"Эксплойт: " .. tostring((typeof(identifyexecutor) == "function") and identifyexecutor() or "неизвестно"),
	"Файловая система: " .. tostring(HAS_FS),
	"Стелс (ONE_SHOT_CAPTURE): " .. tostring(ONE_SHOT_CAPTURE),
	"decompile: " .. tostring(decompile_fn ~= nil),
	"getconstants: " .. tostring(getconstants ~= nil)
		.. " | getupvalues: " .. tostring(getupvalues ~= nil)
		.. " | getprotos: " .. tostring(getprotos ~= nil),
	"",
}, "\n"))

--// Безопасный дамп функций (прототипы + константы + upvalue) ────────────
local MAX_LINES = 5000
local dumpLines = {}

local function addLine(s)
	if #dumpLines < MAX_LINES then
		dumpLines[#dumpLines + 1] = s
	end
end

local function prettyValue(v)
	local t = typeof(v)
	if t == "string" then
		local s = tostring(v):gsub("%c", " ")
		if #s > 200 then s = s:sub(1, 200) .. "…(обрезано)" end
		return string.format("%q", s)
	elseif t == "table" then return "<table>"
	elseif t == "function" then return "<function>"
	elseif t == "Instance" then
		local ok, cls = pcall(function() return v.ClassName end)
		return "<Instance: " .. (ok and tostring(cls) or "?") .. ">"
	end
	local ok, str = pcall(tostring, v)
	return ok and str or "<unprintable>"
end

local function dumpClosure(fn, name, depth, visited)
	if depth > 4 then return end
	visited = visited or {}
	if visited[fn] then return end
	visited[fn] = true

	-- Пропускаем C-функции во избежание крашей debug-библиотеки эксплойта
	if iscclosure_fn then
		local ok, isC = pcall(iscclosure_fn, fn)
		if ok and isC then return end
	end
	if islclosure_fn then
		local ok, isL = pcall(islclosure_fn, fn)
		if ok and not isL then return end
	end

	local info = {}
	if dbg_getinfo then
		pcall(function() info = dbg_getinfo(fn) or {} end)
	end
	local pad = string.rep("    ", depth)
	addLine(string.format(
		"%s%s = function(...)  -- [%s] строки %s..%s | what=%s | параметров=%s",
		pad, name,
		tostring(info.short_src or info.source or "?"),
		tostring(info.linedefined or 0),
		tostring(info.lastlinedefined or 0),
		tostring(info.what or "?"),
		tostring(info.nparams or "?")
	))

	if getupvalues then
		local ok, uvs = pcall(getupvalues, fn)
		if ok and type(uvs) == "table" and #uvs > 0 then
			local parts = {}
			for i, uv in ipairs(uvs) do
				if i > 50 then
					parts[#parts + 1] = "… (" .. (#uvs - 50) .. " ещё)"
					break
				end
				parts[#parts + 1] = "uv" .. i .. "=" .. prettyValue(uv)
			end
			addLine(pad .. "    [upvalues]: " .. table.concat(parts, ", "))
		end
	end

	if getconstants then
		local ok, consts = pcall(getconstants, fn)
		if ok and type(consts) == "table" and #consts > 0 then
			local parts = {}
			for i, c in ipairs(consts) do
				if i > 80 then
					parts[#parts + 1] = "… (" .. (#consts - 80) .. " ещё)"
					break
				end
				parts[#parts + 1] = prettyValue(c)
			end
			addLine(pad .. "    [константы (" .. #consts .. ")]: " .. table.concat(parts, ", "))
		end
	end

	if getprotos then
		local ok, protos = pcall(getprotos, fn)
		if ok and type(protos) == "table" then
			for i, proto in ipairs(protos) do
				if i > 30 then break end
				if typeof(proto) == "function" then
					dumpClosure(proto, name .. ".proto" .. i, depth + 1, visited)
				end
			end
		end
	end
end

--// Сохранение перехваченного скрипта ─────────────────────────────────────
local function saveDump(chunkName, source, fn, errText)
	local okSave = pcall(function()
		dumpCount = dumpCount + 1
		local folder = SESSION .. "/dump_" .. dumpCount
		ensureDir(folder)

		-- 1) Исходник → script.txt (пишется первым, гарантированно)
		saveFile(folder .. "/script.txt", table.concat({
			"-- ══ ScriptGrabber ══",
			"-- chunkname: " .. tostring(chunkName or "loadstring"),
			"-- длина исходника: " .. tostring(source and #source or 0) .. " символов",
			"",
			tostring(source or "(исходник недоступен)"),
		}, "\n"))

		-- 1b) Версия с раскрытыми строками (\xNN, \ddd, \u{}, \z)
		if type(source) == "string" and #source > 0 then
			local clean = unescapeSource(source)
			if clean and clean ~= source then
				saveFile(folder .. "/script_clean.txt", clean)
			end
		end

		-- 2) Дамп функций (константы / upvalues) → functions.txt
		if DUMP_CLOSURE_INFO then
			local okFuncs, errF = pcall(function()
				dumpLines = { "=== Дамп функций: " .. tostring(chunkName or "loadstring") .. " ===" }
				if errText then
					addLine("(!) Ошибка компиляции: " .. tostring(errText))
				end
				if fn and typeof(fn) == "function" then
					dumpClosure(fn, "chunk", 0, {})
				else
					addLine("(функция недоступна / не скомпилировалась)")
				end
				saveFile(folder .. "/functions.txt", table.concat(dumpLines, "\n"))
			end)
			if not okFuncs then
				saveFile(folder .. "/functions.txt", "(!) Ошибка при снятии дампа функций: " .. tostring(errF))
			end
		end

		print("[ScriptGrabber] Скрипт #" .. dumpCount .. " успешно сохранён → " .. folder)
		notify("ScriptGrabber", "Скрипт #" .. dumpCount .. " сохранён в " .. ROOT, 5)
	end)

	if not okSave then
		warn("[ScriptGrabber] Ошибка внутри saveDump")
	end
end

--// Бонус: дамп скрипта из игры (Instance) ────────────────────────────────
genv.DumpGameScript = function(inst)
	pcall(function()
		assert(typeof(inst) == "Instance", "Передай Instance (LocalScript/ModuleScript)")
		dumpCount = dumpCount + 1
		local folder = SESSION .. "/gamescript_" .. dumpCount .. "_" .. inst.Name:gsub("[^%w_]", "_")
		ensureDir(folder)

		local okSrc, src = pcall(function() return inst.Source end)
		saveFile(folder .. "/script.txt",
			okSrc and tostring(src) or "(нет доступа к Source — исходник скрыт)")

		if typeof(getscriptbytecode) == "function" then
			local okBc, bc = pcall(getscriptbytecode, inst)
			if okBc and bc then
				saveFile(folder .. "/bytecode.luau", tostring(bc))
			end
		end

		-- decompile() вызывается ТОЛЬКО на Instance LocalScript/ModuleScript
		if decompile_fn and (inst:IsA("LocalScript") or inst:IsA("ModuleScript")) then
			local okDec, dec = pcall(decompile_fn, inst)
			saveFile(folder .. "/decompiled.txt",
				(okDec and type(dec) == "string") and dec or ("-- decompile не сработал: " .. tostring(dec)))
		else
			saveFile(folder .. "/decompiled.txt", "-- decompile недоступен для этого скрипта")
		end

		print("[ScriptGrabber] Дамп скрипта игры: " .. folder)
		notify("ScriptGrabber", "Скрипт игры сохранён: " .. folder, 5)
	end)
end

--// Хук на loadstring ──────────────────────────────────────────────────────
local function installLoadstringHook()
	if not HOOK_LOADSTRING then return end

	local original = genv.loadstring
	if typeof(original) ~= "function" and _G and typeof(_G.loadstring) == "function" then
		original = _G.loadstring
	end

	if typeof(original) ~= "function" then
		warn("[ScriptGrabber] loadstring не найден — хук loadstring пропущен")
		return
	end

	local captured = false

	local function wrapped(src, chunkname)
		-- Компилируем через оригинальный loadstring
		local compOk, res1, res2 = pcall(original, src, chunkname)
		local fn = (compOk and typeof(res1) == "function") and res1 or nil
		local err = (not compOk and tostring(res1)) or (compOk and fn == nil and tostring(res2)) or nil

		-- Сохраняем исходник асинхронно
		task.spawn(function()
			saveDump(chunkname or "loadstring", src, fn, err)
		end)

		-- Стелс-режим: восстанавливаем оригинальный loadstring
		if ONE_SHOT_CAPTURE and not captured then
			captured = true
			pcall(function()
				genv.loadstring = original
				if _G then _G.loadstring = original end
			end)
			print("[ScriptGrabber] Стелс: loadstring восстановлен в оригинал")
		end

		if compOk then
			return res1, res2
		else
			error(res1, 2)
		end
	end

	-- Подменяем в genv и _G
	genv.loadstring = wrapped
	if _G then _G.loadstring = wrapped end

	-- Если прямое переназначение не зацепило (или окружение защищено),
	-- используем hookfunction корректно, сохраняя возвращённый трамплин
	if genv.loadstring ~= wrapped and typeof(hookfunction) == "function" then
		local oldLs
		local okHook = pcall(function()
			oldLs = hookfunction(original, function(src, chunkname)
				if ONE_SHOT_CAPTURE and captured then
					return oldLs(src, chunkname)
				end
				return wrapped(src, chunkname)
			end)
		end)
		if okHook and typeof(oldLs) == "function" then
			original = oldLs
		end
	end

	print("[ScriptGrabber] Хук loadstring установлен")
end

--// Хук на game:HttpGet / HttpGetAsync ─────────────────────────────────────
local function installHttpGetHook()
	if not HOOK_HTTPGET then return end
	if typeof(hookmetamethod) ~= "function" then
		warn("[ScriptGrabber] hookmetamethod недоступен — HttpGet не логируется")
		return
	end

	local captured = false
	local oldNamecall

	local ok, err = pcall(function()
		oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
			local method = (typeof(getnamecallmethod) == "function") and getnamecallmethod() or nil

			if (method == "HttpGet" or method == "HttpGetAsync") and not (ONE_SHOT_CAPTURE and captured) then
				if ONE_SHOT_CAPTURE then
					captured = true
				end

				local args = table.pack(...)
				local url = tostring(args[1] or "")

				if typeof(setnamecallmethod) == "function" and method then
					setnamecallmethod(method)
				end
				local results = table.pack(oldNamecall(self, table.unpack(args, 1, args.n)))

				if typeof(results[1]) == "string" and #results[1] > 0 then
					local body = results[1]
					task.spawn(function()
						pcall(function()
							httpCount = httpCount + 1
							local path = SESSION .. "/http_" .. httpCount .. "_" .. urlToName(url) .. ".lua"
							saveFile(path, "-- URL: " .. url .. "\n\n" .. body)
							print("[ScriptGrabber] HttpGet сохранён → " .. path)
						end)
					end)
				end

				print("[ScriptGrabber] HttpGet перехвачен (" .. url:sub(1, 60) .. ")")
				return table.unpack(results, 1, results.n)
			end

			if typeof(setnamecallmethod) == "function" and method then
				setnamecallmethod(method)
			end
			return oldNamecall(self, ...)
		end)
	end)

	if not ok or not oldNamecall then
		warn("[ScriptGrabber] Хук __namecall не установился: " .. tostring(err))
	else
		print("[ScriptGrabber] Хук HttpGet (__namecall) установлен")
	end
end

--// Хук на request / http_request / syn_request ────────────────────────────
local function installRequestHook()
	if not HOOK_REQUEST then return end

	for _, name in ipairs({ "request", "http_request", "syn_request" }) do
		local original = genv[name]
		if typeof(original) == "function" then
			local captured = false
			pcall(function()
				genv[name] = function(opts, ...)
					if ONE_SHOT_CAPTURE and captured then
						return original(opts, ...)
					end

					local results = table.pack(original(opts, ...))
					if typeof(opts) == "table" and typeof(opts.Url) == "string"
						and typeof(results[1]) == "table" and typeof(results[1].Body) == "string" then
						if ONE_SHOT_CAPTURE then
							captured = true
						end
						local url = opts.Url
						local body = results[1].Body
						task.spawn(function()
							pcall(function()
								httpCount = httpCount + 1
								local path = SESSION .. "/http_" .. httpCount .. "_" .. urlToName(url) .. ".lua"
								saveFile(path, "-- URL: " .. url .. " (через " .. name .. ")\n\n" .. body)
								print("[ScriptGrabber] Запрос (" .. name .. ") сохранён → " .. path)
							end)
						end)
					end
					return table.unpack(results, 1, results.n)
				end
			end)
		end
	end
end

--// Запуск ────────────────────────────────────────────────────────────────
installLoadstringHook()
installHttpGetHook()
installRequestHook()

print("[ScriptGrabber] ══ АКТИВЕН ══ Запускай свой скрипт. Сохраняю в workspace/" .. SESSION)
notify("ScriptGrabber", "Активен! Выполняй скрипт — сохраню в workspace/" .. ROOT, 6)
