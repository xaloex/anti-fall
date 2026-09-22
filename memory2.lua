--[[═══════════════════════════════════════════════════════════════════════
    MEMORY SCRIPT INTERCEPTOR v2 (жёсткий перехват в реальном времени)
    ─────────────────────────────────────────────────────────────────────────
    ПОРЯДОК ЗАПУСКА (ВАЖНО!):
    1) СНАЧАЛА запусти ЭТОТ скрипт (script_memory.lua).
       Он поставит хуки на loadstring/load/HttpGet и включит постоянный
       поллинг оперативной памяти.
    2) ПОТОМ запускай свой loadstring-скрипт.
    3) Как только исходник попадёт в память устройства — он будет
       МГНОВЕННО перехвачен и сохранён, ещё даже ДО своего запуска.

    Куда сохраняется:
    workspace/ScriptMemoryDumps/<дата_сессии>/
        - intercepted/            — перехваченные исходники (мгновенно, файл на каждый)
        - intercepted/_log.txt    — лог перехватов (время, источник, размер)
        - sources/                — фрагменты кода из глубокого дампа
        - full_memory_dump.txt    — полный отчёт по функциям в памяти
        - captured_urls.txt       — все URL, замеченные в памяти/запросах
    ═══════════════════════════════════════════════════════════════════════]]

--// КОНФИГ ────────────────────────────────────────────────────────────────
local CONFIG = {
	POLL_INTERVAL    = 0.5,   -- как часто опрашивать память (сек)
	MIN_SOURCE_LEN   = 40,    -- минимальная длина строки из кучи, чтобы считать её кодом
	AUTO_DEEP_DUMP   = true,  -- автоматически гонять глубокий дамп после каждого перехвата
	DEEP_DUMP_DELAY  = 3,     -- задержка перед глубоким дампом после перехвата (сек)
	CAPTURE_HOOKED_RAW = true,-- хук loadstring сохраняет ВСЁ подряд без фильтра
	MAX_SEEN_STRINGS = 20000, -- защита от раздутия памяти на дедупе
}

local genv = (typeof(getgenv) == "function") and getgenv() or _G

--// Проверка API эксплойта ────────────────────────────────────────────────
local HAS_FS = (typeof(writefile) == "function")
	and (typeof(isfolder) == "function")
	and (typeof(makefolder) == "function")

local HAS_READ  = (typeof(readfile) == "function") and (typeof(isfile) == "function")

local getgc_fn         = (typeof(getgc) == "function") and getgc or nil
local getreg_fn        = (typeof(debug) == "table" and typeof(debug.getregistry) == "function") and debug.getregistry or nil
local getconstants_fn  = (typeof(getconstants) == "function") and getconstants or nil
local getupvalues_fn   = (typeof(getupvalues) == "function") and getupvalues or nil
local getprotos_fn     = (typeof(getprotos) == "function") and getprotos or nil
local getinfo_fn       = (typeof(debug) == "table" and typeof(debug.getinfo) == "function") and debug.getinfo or nil
local iscclosure_fn    = (typeof(iscclosure) == "function") and iscclosure or nil
local islclosure_fn    = (typeof(islclosure) == "function") and islclosure or nil
local hookfunction_fn  = (typeof(hookfunction) == "function") and hookfunction or nil
local hookmetamethod_fn= (typeof(hookmetamethod) == "function") and hookmetamethod or nil
local getnamecall_fn   = (typeof(getnamecallmethod) == "function") and getnamecallmethod or nil

local ROOT = "ScriptMemoryDumps"
local sessionName = tostring(math.floor(tick()))
do
	local ok, stamp = pcall(os.date, "%Y-%m-%d_%H-%M-%S")
	if ok and type(stamp) == "string" then sessionName = stamp end
end
local SESSION         = ROOT .. "/" .. sessionName
local SOURCES_DIR     = SESSION .. "/sources"
local INTERCEPTED_DIR = SESSION .. "/intercepted"

--// Утилиты файловой системы ──────────────────────────────────────────────
local function ensureDir(path)
	if not HAS_FS then return end
	if not isfolder(path) then pcall(makefolder, path) end
end

local function saveFile(path, content)
	if not HAS_FS then
		warn("[Interceptor] Нет FS. Лог: " .. path)
		return
	end
	local ok, err = pcall(writefile, path, tostring(content))
	if not ok then
		warn("[Interceptor] Ошибка записи: " .. tostring(err))
	end
end

local function appendFile(path, content)
	if not HAS_FS then return end
	local old = ""
	if HAS_READ then
		local ok, exists = pcall(isfile, path)
		if ok and exists then
			local okR, data = pcall(readfile, path)
			if okR and type(data) == "string" then old = data end
		end
	end
	saveFile(path, old .. content)
end

local function notify(title, text)
	pcall(function()
		game:GetService("StarterGui"):SetCore("SendNotification", {
			Title = title, Text = text, Duration = 5,
		})
	end)
end

ensureDir(ROOT)
ensureDir(SESSION)
ensureDir(SOURCES_DIR)
ensureDir(INTERCEPTED_DIR)

--// Состояние ─────────────────────────────────────────────────────────────
local captured        = {}   -- дедуп перехваченных строк
local seenCount       = 0
local foundUrls       = {}
local urlList         = {}
local visited         = {}   -- дедуп функций для глубокого дампа
local dumpReport      = {}
local totalClosuresScanned = 0
local captureCount    = 0
local deepDumpPending = false
local scheduleDeepDump -- (forward declaration, назначается ниже)

local LOG_FILE = INTERCEPTED_DIR .. "/_log.txt"

--// Эвристика: похожа ли строка на исходник Lua/Luau ──────────────────────
local function looksLikeSource(s)
	if type(s) ~= "string" or #s < CONFIG.MIN_SOURCE_LEN then return false end

	local score = 0
	if s:find("function", 1, true) then score = score + 1 end
	if s:find("local ", 1, true) then score = score + 1 end
	if s:find("game", 1, true) or s:find("GetService", 1, true) then score = score + 1 end
	if s:find("then", 1, true) or s:find("do", 1, true) then score = score + 1 end
	if s:find("end", 1, true) then score = score + 1 end
	if s:find("return", 1, true) or s:find("=", 1, true) then score = score + 1 end

	return score >= 3
end

local function checkUrl(str)
	if type(str) ~= "string" then return end
	if str:find("https?://") or str:find("loadstring") then
		if not foundUrls[str] then
			foundUrls[str] = true
			urlList[#urlList + 1] = str
			saveFile(SESSION .. "/captured_urls.txt", table.concat(urlList, "\n"))
		end
	end
end

--// ГЛАВНЫЙ ПЕРЕХВАТ: мгновенное сохранение исходника ─────────────────────
local function captureSource(str, origin)
	if type(str) ~= "string" or #str == 0 then return false end
	if captured[str] then return false end

	-- Из хуков сохраняем ВСЁ (жёсткий режим), из кучи — только по эвристике
	if origin ~= "hooked" and not CONFIG.CAPTURE_HOOKED_RAW then
		if not looksLikeSource(str) then return false end
	elseif origin ~= "hooked" and not looksLikeSource(str) then
		return false
	end

	captured[str] = true
	seenCount = seenCount + 1
	if seenCount > CONFIG.MAX_SEEN_STRINGS then
		captured = {} -- сброс дедупа, чтобы не жрать память бесконечно
		seenCount = 0
	end

	captureCount = captureCount + 1
	local safeOrigin = tostring(origin):gsub("[^%w]", "_")
	local fileName = INTERCEPTED_DIR .. "/capture_" .. captureCount .. "_" .. safeOrigin .. ".lua"

	local header = table.concat({
		"-- [Interceptor] ПЕРЕХВАЧЕНО #" .. captureCount,
		"-- Время: " .. os.date("%H:%M:%S"),
		"-- Источник: " .. tostring(origin),
		"-- Длина: " .. #str .. " символов",
		"----------------------------------------------------------------",
		"",
	}, "\n")

	saveFile(fileName, header .. str)
	appendFile(LOG_FILE, string.format("[%s] #%d | %s | %d символов | %s\n",
		os.date("%H:%M:%S"), captureCount, tostring(origin), #str,
		str:sub(1, 80):gsub("%c", " ")))

	print("[Interceptor] ⚡ ПЕРЕХВАЧЕНО! #" .. captureCount .. " (" .. tostring(origin) .. ", " .. #str .. " симв) → " .. fileName)
	notify("Interceptor ⚡", "Перехват #" .. captureCount .. " (" .. #str .. " симв)")

	checkUrl(str)
	scheduleDeepDump()

	return true
end

--// ХУКИ ──────────────────────────────────────────────────────────────────
local function hookGlobalFn(name)
	local fn = genv[name]
	if typeof(fn) ~= "function" then return end
	if not hookfunction_fn then
		warn("[Interceptor] hookfunction недоступен — хук на " .. name .. " не поставлен")
		return
	end

	local orig
	local ok, err = pcall(function()
		orig = hookfunction_fn(fn, function(src, chunk)
			-- Перехват ДО выполнения: сохраняем исходник мгновенно
			pcall(captureSource, src, "hooked_" .. name)
			if type(chunk) == "string" then checkUrl(chunk) end
			return orig(src, chunk)
		end)
	end)

	if ok and typeof(orig) == "function" then
		print("[Interceptor] ✅ Хук поставлен на " .. name)
	else
		warn("[Interceptor] ❌ Не смог захукать " .. name .. ": " .. tostring(err))
	end
end

hookGlobalFn("loadstring")
hookGlobalFn("load")

-- Хук на game:HttpGet / HttpGetAsync через __namecall — ловим тело ответа
if hookmetamethod_fn and getnamecall_fn then
	local ok, err = pcall(function()
		local oldNamecall
		oldNamecall = hookmetamethod_fn(game, "__namecall", function(self, ...)
			local method = getnamecall_fn()
			if method == "HttpGet" or method == "HttpGetAsync" then
				local args = { ... }
				if type(args[1]) == "string" then checkUrl(args[1]) end
				local res = oldNamecall(self, ...)
				if type(res) == "string" then
					pcall(captureSource, res, "hooked_HttpGet")
				end
				return res
			end
			return oldNamecall(self, ...)
		end)
	end)
	if ok then
		print("[Interceptor] ✅ Хук поставлен на game:HttpGet/HttpGetAsync")
	else
		warn("[Interceptor] ❌ Не смог захукать __namecall: " .. tostring(err))
	end
end

-- Хуки на http_request / request / syn.request
for _, name in ipairs({ "http_request", "request", "syn_request" }) do
	local fn = genv[name] or (name == "syn_request" and typeof(syn) == "table" and syn.request or nil)
	if typeof(fn) == "function" and hookfunction_fn then
		pcall(function()
			local orig
			orig = hookfunction_fn(fn, function(url, opts)
				local res = orig(url, opts)
				if type(res) == "string" then
					pcall(captureSource, res, "hooked_" .. name)
				elseif type(res) == "table" and type(res.Body) == "string" then
					pcall(captureSource, res.Body, "hooked_" .. name)
				end
				return res
			end)
			print("[Interceptor] ✅ Хук поставлен на " .. name)
		end)
	end
end

--// ФОНОВЫЙ ПОЛЛИНГ ПАМЯТИ ────────────────────────────────────────────────
-- Даже если хуки не сработали — строка будет поймана сразу после того,
-- как попадёт в кучу GC. Поллим каждые CONFIG.POLL_INTERVAL секунд.
task.spawn(function()
	local polls = 0
	while true do
		if getgc_fn then
			local ok, gcObjects = pcall(getgc_fn, true)
			if not ok or type(gcObjects) ~= "table" then
				ok, gcObjects = pcall(getgc_fn)
			end
			if ok and type(gcObjects) == "table" then
				for _, obj in ipairs(gcObjects) do
					if typeof(obj) == "string" then
						checkUrl(obj)
						pcall(captureSource, obj, "gc_poll")
					end
				end
			end
		end
		polls = polls + 1
		if polls % 20 == 0 then
			print("[Interceptor] Поллинг жив: опрос #" .. polls .. ", перехвачено: " .. captureCount)
		end
		task.wait(CONFIG.POLL_INTERVAL)
	end
end)

--// ГЛУБОКИЙ ДАМП (функции, константы, upvalues) ──────────────────────────
local function formatVal(v)
	local t = typeof(v)
	if t == "string" then
		checkUrl(v)
		pcall(captureSource, v, "deep_dump_const")
		local s = v:gsub("%c", " ")
		if #s > 120 then s = s:sub(1, 120) .. "..." end
		return string.format("%q", s)
	elseif t == "table" then
		return "<table>"
	elseif t == "function" then
		return "<function>"
	end
	return tostring(v)
end

local function inspectClosure(fn, depth)
	if depth > 4 or visited[fn] then return end
	visited[fn] = true

	if iscclosure_fn then
		local okC, isC = pcall(iscclosure_fn, fn)
		if okC and isC then return end
	end
	if islclosure_fn then
		local okL, isL = pcall(islclosure_fn, fn)
		if okL and not isL then return end
	end

	totalClosuresScanned = totalClosuresScanned + 1

	local info = {}
	if getinfo_fn then
		pcall(function() info = getinfo_fn(fn) or {} end)
	end

	local src = info.source or info.short_src or ""
	if type(src) == "string" and #src > 0 then
		checkUrl(src)
		pcall(captureSource, src, "debug_getinfo_source")
	end

	local pad = string.rep("  ", depth)
	dumpReport[#dumpReport + 1] = string.format("%s• Func [%s] lines %s-%s (params: %s, what: %s)",
		pad,
		tostring(info.short_src or "unknown"):sub(1, 40),
		tostring(info.linedefined or "?"),
		tostring(info.lastlinedefined or "?"),
		tostring(info.nparams or "?"),
		tostring(info.what or "?")
	)

	if getconstants_fn then
		local okConst, consts = pcall(getconstants_fn, fn)
		if okConst and type(consts) == "table" and #consts > 0 then
			local parts = {}
			for i, c in ipairs(consts) do
				if i > 40 then
					parts[#parts + 1] = "... (" .. (#consts - 40) .. " ещё)"
					break
				end
				parts[#parts + 1] = formatVal(c)
			end
			dumpReport[#dumpReport + 1] = pad .. "    consts: " .. table.concat(parts, ", ")
		end
	end

	if getupvalues_fn then
		local okUv, uvs = pcall(getupvalues_fn, fn)
		if okUv and type(uvs) == "table" and #uvs > 0 then
			local parts = {}
			for i, uv in ipairs(uvs) do
				if i > 30 then
					parts[#parts + 1] = "... (" .. (#uvs - 30) .. " ещё)"
					break
				end
				parts[#parts + 1] = "uv" .. i .. "=" .. formatVal(uv)
				if typeof(uv) == "function" then
					inspectClosure(uv, depth + 1)
				end
			end
			dumpReport[#dumpReport + 1] = pad .. "    upvalues: " .. table.concat(parts, ", ")
		end
	end

	if getprotos_fn then
		local okProto, protos = pcall(getprotos_fn, fn)
		if okProto and type(protos) == "table" then
			for i, proto in ipairs(protos) do
				if i > 25 then break end
				if typeof(proto) == "function" then
					inspectClosure(proto, depth + 1)
				end
			end
		end
	end
end

local function runDeepDump(reason)
	dumpReport[#dumpReport + 1] = "=== Глубокий дамп (" .. tostring(reason) .. ") @ " .. os.date("%H:%M:%S") .. " ==="

	if getgc_fn then
		local okGc, gcObjects = pcall(getgc_fn, true)
		if not okGc or type(gcObjects) ~= "table" then
			okGc, gcObjects = pcall(getgc_fn)
		end
		if okGc and type(gcObjects) == "table" then
			for _, obj in ipairs(gcObjects) do
				local t = typeof(obj)
				if t == "function" then
					pcall(inspectClosure, obj, 0)
				elseif t == "table" then
					pcall(function()
						for _, v in pairs(obj) do
							if typeof(v) == "function" then
								inspectClosure(v, 0)
							elseif typeof(v) == "string" then
								checkUrl(v)
								pcall(captureSource, v, "deep_dump_table")
							end
						end
					end)
				end
			end
		end
	end

	if getreg_fn then
		local okReg, reg = pcall(getreg_fn)
		if okReg and type(reg) == "table" then
			for _, v in pairs(reg) do
				if typeof(v) == "function" then
					pcall(inspectClosure, v, 0)
				elseif typeof(v) == "string" then
					pcall(captureSource, v, "registry")
				end
			end
		end
	end

	pcall(function()
		for _, v in pairs(genv) do
			if typeof(v) == "function" then
				pcall(inspectClosure, v, 0)
			end
		end
	end)

	-- Сохраняем отчёт
	local reportSummary = table.concat({
		"=== Memory Interceptor Report ===",
		"Сессия: " .. sessionName,
		"Причина дампа: " .. tostring(reason),
		"Всего исследовано функций: " .. totalClosuresScanned,
		"Перехвачено исходников: " .. captureCount,
		"Найдено URL: " .. #urlList,
		"----------------------------------------------------------------",
		"",
		table.concat(dumpReport, "\n"),
	}, "\n")
	saveFile(SESSION .. "/full_memory_dump.txt", reportSummary)
	print("[Interceptor] Глубокий дамп завершён (" .. tostring(reason) .. "). Функций: " .. totalClosuresScanned)
end

-- Автозапуск глубокого дампа после перехвата (с защитой от спама)
scheduleDeepDump = function()
	if not CONFIG.AUTO_DEEP_DUMP or deepDumpPending then return end
	deepDumpPending = true
	task.delay(CONFIG.DEEP_DUMP_DELAY, function()
		deepDumpPending = false
		pcall(runDeepDump, "auto_after_capture")
	end)
end

--// СТАРТ ─────────────────────────────────────────────────────────────────
print("[Interceptor] ══════════════════════════════════════════")
print("[Interceptor] ПЕРЕХВАТЧИК АКТИВЕН. Сессия: " .. SESSION)
print("[Interceptor] Хуки: loadstring/load/HttpGet | Поллинг памяти каждые " .. CONFIG.POLL_INTERVAL .. " сек")
print("[Interceptor] → Теперь запускай свой loadstring-скрипт. Он будет перехвачен мгновенно.")
print("[Interceptor] ══════════════════════════════════════════")
notify("Interceptor", "Активен! Жду loadstring-скрипт...")

-- Базовый дамп при старте (функции, которые уже были в памяти)
task.delay(1, function()
	pcall(runDeepDump, "startup_baseline")
end)
