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
               script.txt      — ИСХОДНИК перехваченного скрипта (как есть)
               script_clean.txt— то же, но строки раскрыты (\xNN \ddd \u{} \z)
               functions.txt   — дамп всех функций (прото, константы, upvalue)
               decompiled.txt  — попытка декомпиляции байткода Luau VM
           http_N_*.lua      — ответы HttpGet (исходники, скачанные скриптом)

    СТЕЛС: хуки одноразовые (ONE_SHOT_CAPTURE) — после первого перехвата
    loadstring/HttpGet мгновенно восстанавливаются в оригинал, чтобы
    анти-тампер скрипта не заметил подмену и не кикнул. Если всё равно
    кикает — поставь HOOK_HTTPGET = false и лови только через loadstring.

    Декомпиляция байткода работает только если в эксплойте есть функция
    decompile() (Synapse и т.п.). Если её нет — сохраняется исходный source.

    Бонус: getgenv().DumpGameScript(скрипт_из_игры) — дамп любого
    LocalScript/ModuleScript из игры: source + байткод + декомпиляция.
═══════════════════════════════════════════════════════════════════════════]]

local genv = (typeof(getgenv) == "function") and getgenv() or _G

if genv.__SCRIPT_GRABBER_ACTIVE then
	warn("[ScriptGrabber] Уже запущен — повторно не встаю.")
	return
end
genv.__SCRIPT_GRABBER_ACTIVE = true

--// Настройки стелса ──────────────────────────────────────────────────────
local ONE_SHOT_CAPTURE = true   -- снять все хуки сразу после 1-го перехвата (защита от анти-тампера)
local HOOK_LOADSTRING  = true   -- перехват loadstring (главный источник дампа)
local HOOK_HTTPGET     = true   -- перехват game:HttpGet / HttpGetAsync / request

--// Проверка окружения эксплойта ──────────────────────────────────────────
local HAS_FS = (typeof(writefile) == "function")
	and (typeof(isfolder) == "function")
	and (typeof(makefolder) == "function")

local dbg_getinfo  = (typeof(debug) == "table" and typeof(debug.getinfo) == "function") and debug.getinfo or nil
local getconstants = (typeof(getconstants) == "function") and getconstants or nil
local getupvalues  = (typeof(getupvalues) == "function") and getupvalues or nil
local getprotos    = (typeof(getprotos) == "function") and getprotos or nil
local decompile_fn = (typeof(decompile) == "function") and decompile or nil

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
		warn("[ScriptGrabber] Файловая система недоступна, вывожу в консоль:", path)
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

--// Раскрытие escape-строк внутри литералов исходника ─────────────────────
-- Обфускаторы прячут текст в \xNN, \ddd, \u{...}, \z — без этого в дампе
-- каша. Меняется содержимое ТОЛЬКО строковых литералов, код не трогаем.
local function decodeEscapes(body)
	if not body:find("\\", 1, true) then return nil end -- эскейпов нет — не трогаем
	local s = body:gsub("\\z%s+", "")
	s = s:gsub("\\u%{(%x+)%}", function(hex)
		local ok, ch = pcall(utf8.char, tonumber(hex, 16) or 0xFFFD)
		return (ok and ch) or "?"
	end)
	s = s:gsub("\\x(%x%x)", function(h)
		return string.char(tonumber(h, 16) or 63)
	end)
	s = s:gsub("\\(%d%d?%d?)", function(d)
		local num = tonumber(d)
		return (num and num < 256) and string.char(num) or d
	end)
	-- если после раскрытия появились кавычки/переводы строк — литерал сломается,
	-- оставляем как было
	if s:find("[\"'\r\n]") then return nil end
	return s
end

local function unescapeSource(src)
	if type(src) ~= "string" or #src == 0 then return src end
	local out = {}
	local i, n = 1, #src
	local segStart = i
	local function copy(from, to)
		out[#out + 1] = src:sub(from, to)
	end
	while i <= n do
		local b = src:byte(i)
		if b == 34 or b == 39 or (b == 45 and src:byte(i + 1) == 45) then -- " или ' или --
			if segStart <= i - 1 then copy(segStart, i - 1) end
			if b == 45 then
				-- однострочный комментарий — копируем как есть
				local nl = string.find(src, "\n", i, true)
				if nl then
					copy(i, nl - 1)
					out[#out + 1] = "\n"
					i = nl + 1
				else
					copy(i, n)
					i = n + 1
				end
			else
				-- строковый литерал: сканируем до закрытия
				local quote, j, closed = b, i + 1, false
				local buf = {}
				while j <= n do
					local cb = src:byte(j)
					if cb == 92 then -- backslash
						buf[#buf + 1] = src:sub(j, math.min(j + 1, n))
						j = j + 2
					elseif cb == quote then
						closed = true
						break
					elseif cb == 10 then -- строка не закрыта
						break
					else
						buf[#buf + 1] = src:sub(j, j)
						j = j + 1
					end
				end
				local raw = table.concat(buf)
				if closed then
					local decoded = decodeEscapes(raw)
					out[#out + 1] = string.char(quote) .. (decoded or raw) .. string.char(quote)
					i = j + 1
				else
					copy(i, n)
					i = n + 1
				end
			end
			segStart = i
		else
			i = i + 1
		end
	end
	if segStart <= n then copy(segStart, n) end
	return table.concat(out)
end

ensureDir(ROOT)
ensureDir(SESSION)
saveFile(SESSION .. "/info.txt", table.concat({
	"ScriptGrabber — сессия: " .. sessionName,
	"Эксплойт: " .. tostring((typeof(identifyexecutor) == "function") and identifyexecutor() or "неизвестно"),
	"Файловая система: " .. tostring(HAS_FS),
	"Стелс (ONE_SHOT_CAPTURE): " .. tostring(ONE_SHOT_CAPTURE),
	"decompile (декомпиляция байткода): " .. tostring(decompile_fn ~= nil),
	"getconstants: " .. tostring(getconstants ~= nil)
		.. " | getupvalues: " .. tostring(getupvalues ~= nil)
		.. " | getprotos: " .. tostring(getprotos ~= nil),
	"",
}, "\n"))

--// Дамп функций (прото-дерево + константы + upvalue) ─────────────────────
local MAX_LINES = 12000
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
		if #s > 300 then s = s:sub(1, 300) .. "…(обрезано)" end
		return string.format("%q", s)
	elseif t == "table" then return "<table>"
	elseif t == "function" then return "<function>"
	elseif t == "Instance" then
		local ok, cls = pcall(function() return v.ClassName end)
		return "<Instance: " .. (ok and tostring(cls) or "?") .. ">"
	end
	return tostring(v)
end

local function dumpClosure(fn, name, depth)
	if depth > 20 then return end

	local info = {}
	if dbg_getinfo then
		pcall(function() info = dbg_getinfo(fn) or {} end)
	end
	local pad = string.rep("    ", depth)
	addLine(string.format(
		"%s%s = function(...)  -- [%s] строки %s..%s | what=%s | параметров=%s | vararg=%s",
		pad, name,
		tostring(info.short_src or info.source or "?"),
		tostring(info.linedefined or 0),
		tostring(info.lastlinedefined or 0),
		tostring(info.what or "?"),
		tostring(info.nparams or "?"),
		tostring((info.is_vararg == 1 or info.is_vararg == true) and "да" or "нет")
	))

	if getupvalues then
		local ok, uvs = pcall(getupvalues, fn)
		if ok and type(uvs) == "table" and #uvs > 0 then
			local parts = {}
			for i, uv in ipairs(uvs) do
				parts[#parts + 1] = "upvalue" .. i .. " = " .. prettyValue(uv)
			end
			addLine(pad .. "    " .. table.concat(parts, ", "))
		end
	end

	if getconstants then
		local ok, consts = pcall(getconstants, fn)
		if ok and type(consts) == "table" and #consts > 0 then
			local parts = {}
			for i, c in ipairs(consts) do
				if i > 150 then
					parts[#parts + 1] = ("… (ещё %d констант — читаемые строки ищи в script_clean.txt)"):format(#consts - 150)
					break
				end
				parts[#parts + 1] = prettyValue(c)
			end
			addLine(pad .. "    константы (" .. #consts .. "): " .. table.concat(parts, ", "))
		end
	end

	if getprotos then
		local ok, protos = pcall(getprotos, fn)
		if ok and type(protos) == "table" then
			for i, proto in ipairs(protos) do
				if typeof(proto) == "function" then
					dumpClosure(proto, name .. ".proto" .. i, depth + 1)
				end
			end
		end
	end
end

--// Сохранение перехваченного скрипта ─────────────────────────────────────
local function saveDump(chunkName, source, fn, errText)
	dumpCount = dumpCount + 1
	local folder = SESSION .. "/dump_" .. dumpCount
	ensureDir(folder)

	-- 1) Исходник → script.txt
	saveFile(folder .. "/script.txt", table.concat({
		"-- ══ ScriptGrabber ══",
		"-- chunkname: " .. tostring(chunkName or "loadstring"),
		"-- длина исходника: " .. tostring(source and #source or 0) .. " символов",
		"",
		tostring(source or "(исходник недоступен)"),
	}, "\n"))

	-- 1b) Версия с раскрытыми строками (\xNN, \ddd, \u{}, \z)
	if type(source) == "string" then
		saveFile(folder .. "/script_clean.txt", unescapeSource(source))
	end

	-- 2) Дамп функций → functions.txt
	dumpLines = { "=== Дамп функций: " .. tostring(chunkName or "loadstring") .. " ===" }
	if errText then
		addLine("(!) Ошибка компиляции: " .. errText)
	end
	if fn then
		dumpClosure(fn, "chunk", 0)
	else
		addLine("(функция не создана — скрипт не скомпилировался)")
	end
	saveFile(folder .. "/functions.txt", table.concat(dumpLines, "\n"))

	-- 3) Декомпиляция байткода Luau VM → decompiled.txt
	if fn and decompile_fn then
		local ok, res = pcall(decompile_fn, fn)
		saveFile(folder .. "/decompiled.txt",
			(ok and type(res) == "string") and res
			or ("-- decompile() не сработал: " .. tostring(res)))
	else
		saveFile(folder .. "/decompiled.txt", table.concat({
			"-- В этом эксплойте нет функции decompile() — декомпилировать байткод нечем.",
			"-- Если исходник передавался напрямую в loadstring, он уже в script.txt / script_clean.txt.",
			"-- Исходник, скачанный через HttpGet, лежит рядом в http_N_*.lua",
		}, "\n"))
	end

	print("[ScriptGrabber] Перехвачен скрипт #" .. dumpCount .. " → " .. folder)
	notify("ScriptGrabber", "Скрипт #" .. dumpCount .. " сохранён в " .. ROOT, 5)
end

--// Бонус: дамп скрипта из игры (source + байткод + декомпиляция) ──────────
genv.DumpGameScript = function(inst)
	pcall(function()
		assert(typeof(inst) == "Instance", "передай Instance (LocalScript/ModuleScript)")
		dumpCount = dumpCount + 1
		local folder = SESSION .. "/gamescript_" .. dumpCount .. "_" .. inst.Name:gsub("[^%w_]", "_")
		ensureDir(folder)

		local okSrc, src = pcall(function() return inst.Source end)
		saveFile(folder .. "/script.txt",
			okSrc and tostring(src) or "(нет доступа к Source — эксплойт не даёт читать исходники игры)")

		if typeof(getscriptbytecode) == "function" then
			local okBc, bc = pcall(getscriptbytecode, inst)
			saveFile(folder .. "/bytecode.luau", okBc and tostring(bc) or "(getscriptbytecode не сработал)")
		end

		if decompile_fn then
			local okDec, dec = pcall(decompile_fn, inst)
			if not (okDec and type(dec) == "string") then
				okDec, dec = pcall(decompile_fn, src)
			end
			saveFile(folder .. "/decompiled.txt", okDec and tostring(dec) or "(decompile не сработал: " .. tostring(dec) .. ")")
		else
			saveFile(folder .. "/decompiled.txt", "(в этом эксплойте нет decompile)")
		end

		print("[ScriptGrabber] Дамп скрипта игры: " .. folder)
		notify("ScriptGrabber", "Скрипт игры сохранён: " .. folder, 5)
	end)
end

--// Хук на loadstring ──────────────────────────────────────────────────────
local function installLoadstringHook()
	if not HOOK_LOADSTRING then return end
	local original = genv.loadstring
	if typeof(original) ~= "function" then
		warn("[ScriptGrabber] loadstring не найден — основной хук не работает")
		return
	end

	local unhooked = false
	local wrapped = function(src, chunkname)
		local results = table.pack(original(src, chunkname))
		local fn = (typeof(results[1]) == "function") and results[1] or nil
		local err = (fn == nil and results.n >= 2) and tostring(results[2]) or nil
		task.spawn(saveDump, chunkname, src, fn, err)
		-- Стелс: сразу возвращаем оригинал — анти-тампер не увидит подмену
		if ONE_SHOT_CAPTURE and not unhooked then
			unhooked = true
			pcall(function() genv.loadstring = original end)
			print("[ScriptGrabber] Хук loadstring снят (стелс-режим), оригинал восстановлен")
		end
		return table.unpack(results, 1, results.n)
	end

	local okSet = pcall(function() genv.loadstring = wrapped end)
	if not okSet and typeof(hookfunction) == "function" then
		pcall(hookfunction, original, wrapped)
	elseif not okSet then
		warn("[ScriptGrabber] Не удалось подменить loadstring")
	end
end

--// Хук на game:HttpGet / HttpGetAsync ─────────────────────────────────────
local function installHttpGetHook()
	if not HOOK_HTTPGET then return end
	if typeof(hookmetamethod) ~= "function" then
		warn("[ScriptGrabber] hookmetamethod недоступен — HttpGet не логируется")
		return
	end

	local restored = false
	local ok = pcall(function()
		local old
		old = hookmetamethod(game, "__namecall", function(self, ...)
			local method = (typeof(getnamecallmethod) == "function") and getnamecallmethod() or nil
			if method == "HttpGet" or method == "HttpGetAsync" then
				local args = table.pack(...)
				local url = tostring(args[1])
				local results = table.pack(old(self, table.unpack(args, 1, args.n)))
				if typeof(results[1]) == "string" and #results[1] > 0 then
					task.spawn(function()
						httpCount = httpCount + 1
						local path = SESSION .. "/http_" .. httpCount .. "_" .. urlToName(url) .. ".lua"
						saveFile(path, "-- URL: " .. url .. "\n\n" .. results[1])
						print("[ScriptGrabber] HttpGet сохранён → " .. path)
					end)
				end
				-- Стелс: снимаем хук после первого перехвата
				if ONE_SHOT_CAPTURE and not restored then
					restored = true
					pcall(function() hookmetamethod(game, "__namecall", old) end)
					print("[ScriptGrabber] Хук __namecall снят (стелс-режим)")
				end
				return table.unpack(results, 1, results.n)
			end
			return old(self, ...)
		end)
		return old ~= nil
	end)
	if not ok then
		warn("[ScriptGrabber] Хук __namecall не установился")
	end
end

--// Хук на request / http_request ──────────────────────────────────────────
local function installRequestHook()
	for _, name in ipairs({ "request", "http_request" }) do
		local original = genv[name]
		if typeof(original) == "function" then
			pcall(function()
				genv[name] = function(opts, ...)
					local results = table.pack(original(opts, ...))
					if typeof(opts) == "table" and typeof(opts.Url) == "string"
						and typeof(results[1]) == "table" and typeof(results[1].Body) == "string" then
						task.spawn(function()
							httpCount = httpCount + 1
							local path = SESSION .. "/http_" .. httpCount .. "_" .. urlToName(opts.Url) .. ".lua"
							saveFile(path, "-- URL: " .. opts.Url .. " (через " .. name .. ")\n\n" .. results[1].Body)
						end)
					end
					-- Стелс: снимаем подмену после первого перехвата
					if ONE_SHOT_CAPTURE then
						pcall(function() genv[name] = original end)
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

print("[ScriptGrabber] ══ АКТИВЕН ══ Жду твой скрипт. Всё сохраняется в workspace/" .. SESSION)
notify("ScriptGrabber", "Активен! Выполняй скрипт — сохраню в workspace/" .. ROOT, 6)
