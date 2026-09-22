--[[═════════════════════════════════════════════════════════════════════════
    MEMORY SCRIPT EXTRACTOR (пост-фактум дамп из памяти Luau VM)
    ─────────────────────────────────────────────────────────────────────────
    ИНСТРУКЦИЯ:
    1) Запусти нужный скрипт через loadstring (он уже отработал и находится в памяти).
    2) Запусти ЭТОТ скрипт (script_memory.lua).
    3) Он сканирует внутреннюю память Luau VM (Garbage Collector, Registry,
       активные потоки/корутины и глобальное окружение), находит созданные скриптом
       функции, реконструирует строки, константы и выкачивает найденный исходник.

    Куда сохраняется:
    workspace/ScriptMemoryDumps/<дата_сессии>/
        - sources/       — все обнаруженные куски исходного кода (Lua/Luau)
        - full_memory_dump.txt — структурированный отчёт по всем найденным функциям
        - captured_urls.txt    — все URL-адреса, найденные в константах/памяти
═══════════════════════════════════════════════════════════════════════════]]

local genv = (typeof(getgenv) == "function") and getgenv() or _G

--// Проверка API эксплойта ────────────────────────────────────────────────
local HAS_FS = (typeof(writefile) == "function")
	and (typeof(isfolder) == "function")
	and (typeof(makefolder) == "function")

local getgc_fn         = (typeof(getgc) == "function") and getgc or nil
local getreg_fn        = (typeof(debug) == "table" and typeof(debug.getregistry) == "function") and debug.getregistry or nil
local getconstants_fn  = (typeof(getconstants) == "function") and getconstants or nil
local getupvalues_fn   = (typeof(getupvalues) == "function") and getupvalues or nil
local getprotos_fn     = (typeof(getprotos) == "function") and getprotos or nil
local getinfo_fn       = (typeof(debug) == "table" and typeof(debug.getinfo) == "function") and debug.getinfo or nil
local iscclosure_fn    = (typeof(iscclosure) == "function") and iscclosure or nil
local islclosure_fn    = (typeof(islclosure) == "function") and islclosure or nil

local ROOT = "ScriptMemoryDumps"
local sessionName = tostring(math.floor(tick()))
do
	local ok, stamp = pcall(os.date, "%Y-%m-%d_%H-%M-%S")
	if ok and type(stamp) == "string" then sessionName = stamp end
end
local SESSION = ROOT .. "/" .. sessionName
local SOURCES_DIR = SESSION .. "/sources"

--// Утилиты файловой системы ──────────────────────────────────────────────
local function ensureDir(path)
	if not HAS_FS then return end
	if not isfolder(path) then pcall(makefolder, path) end
end

local function saveFile(path, content)
	if not HAS_FS then
		warn("[MemoryExtractor] Нет FS. Лог: " .. path)
		return
	end
	local ok, err = pcall(writefile, path, tostring(content))
	if not ok then
		warn("[MemoryExtractor] Ошибка записи: " .. tostring(err))
	end
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

--// Структуры для сбора данных ────────────────────────────────────────────
local visited = {}
local foundSources = {}
local foundUrls = {}
local dumpReport = {}
local totalClosuresScanned = 0

local function addReport(line)
	if #dumpReport < 8000 then
		dumpReport[#dumpReport + 1] = line
	end
end

-- Проверка: похожа ли строка на фрагмент исходного кода Lua
local function isLikelyCode(str)
	if type(str) ~= "string" or #str < 40 then return false end

	-- Ключевые слова и конструкции Lua
	local matches = 0
	if str:find("function", 1, true) then matches = matches + 1 end
	if str:find("local ", 1, true) then matches = matches + 1 end
	if str:find("game:", 1, true) or str:find("GetService", 1, true) then matches = matches + 1 end
	if str:find("then", 1, true) and str:find("end", 1, true) then matches = matches + 1 end
	if str:find("return", 1, true) then matches = matches + 1 end
	if str:find("pcall", 1, true) or str:find("task%.spawn", 1, true) then matches = matches + 1 end

	return matches >= 2
end

-- Извлечение URL
local function checkUrl(str)
	if type(str) == "string" and (str:find("https?://") or str:find("loadstring")) then
		if not foundUrls[str] then
			foundUrls[str] = true
		end
	end
end

-- Форматирование значений констант
local function formatVal(v)
	local t = typeof(v)
	if t == "string" then
		checkUrl(v)
		if isLikelyCode(v) and not foundSources[v] then
			foundSources[v] = "string_constant"
		end
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

--// Анализ замыкания (функции в памяти) ────────────────────────────────────
local function inspectClosure(fn, depth)
	if depth > 4 or visited[fn] then return end
	visited[fn] = true

	-- Проверяем, является ли функция Lua-функцией (C-функции пропускаем, они крашат getconstants)
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
		if isLikelyCode(src) and not foundSources[src] then
			foundSources[src] = "debug_getinfo_source"
		end
	end

	local pad = string.rep("  ", depth)
	addReport(string.format("%s• Func [%s] lines %s-%s (params: %s, what: %s)",
		pad,
		tostring(info.short_src or "unknown"):sub(1, 40),
		tostring(info.linedefined or "?"),
		tostring(info.lastlinedefined or "?"),
		tostring(info.nparams or "?"),
		tostring(info.what or "?")
	))

	-- Константы функции
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
			addReport(pad .. "    consts: " .. table.concat(parts, ", "))
		end
	end

	-- Upvalues функции
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
			addReport(pad .. "    upvalues: " .. table.concat(parts, ", "))
		end
	end

	-- Вложенные прототипы (sub-функции)
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

--// Главный сборщик из кучи памяти (GC) ────────────────────────────────────
print("[MemoryExtractor] Начинаю сканирование памяти Luau VM...")
notify("MemoryExtractor", "Сканирую оперативную память...")

-- 1. Сканируем getgc()
if getgc_fn then
	local okGc, gcObjects = pcall(getgc_fn, true)
	if not okGc or type(gcObjects) ~= "table" then
		okGc, gcObjects = pcall(getgc_fn)
	end

	if okGc and type(gcObjects) == "table" then
		print("[MemoryExtractor] Найдено объектов в GC: " .. #gcObjects)
		for _, obj in ipairs(gcObjects) do
			local t = typeof(obj)
			if t == "function" then
				pcall(inspectClosure, obj, 0)
			elseif t == "string" then
				checkUrl(obj)
				if isLikelyCode(obj) and not foundSources[obj] then
					foundSources[obj] = "gc_string_heap"
				end
			elseif t == "table" then
				-- Проверяем строковые поля в глобальных таблицах
				pcall(function()
					for k, v in pairs(obj) do
						if typeof(v) == "string" then
							checkUrl(v)
							if isLikelyCode(v) and not foundSources[v] then
								foundSources[v] = "table_value"
							end
						elseif typeof(v) == "function" then
							inspectClosure(v, 0)
						end
					end
				end)
			end
		end
	else
		warn("[MemoryExtractor] getgc() вернул ошибку")
	end
else
	warn("[MemoryExtractor] getgc() не поддерживается твоим эксплойтом")
end

-- 2. Сканируем debug.getregistry()
if getreg_fn then
	local okReg, reg = pcall(getreg_fn)
	if okReg and type(reg) == "table" then
		print("[MemoryExtractor] Сканирую реестр Luau...")
		for _, v in pairs(reg) do
			if typeof(v) == "function" then
				pcall(inspectClosure, v, 0)
			elseif typeof(v) == "string" and isLikelyCode(v) then
				foundSources[v] = "registry_string"
			end
		end
	end
end

-- 3. Сканируем глобальное окружение
pcall(function()
	for k, v in pairs(genv) do
		if typeof(v) == "function" then
			pcall(inspectClosure, v, 0)
		end
	end
end)

--// Сохранение результатов ────────────────────────────────────────────────
local sourceIndex = 0
for codeSnippet, origin in pairs(foundSources) do
	sourceIndex = sourceIndex + 1
	local fileName = SOURCES_DIR .. "/source_" .. sourceIndex .. ".lua"
	local header = table.concat({
		"-- [MemoryExtractor] Исходник #" .. sourceIndex,
		"-- Источник в памяти: " .. tostring(origin),
		"-- Длина: " .. #codeSnippet .. " символов",
		"----------------------------------------------------------------",
		"",
	}, "\n")
	saveFile(fileName, header .. codeSnippet)
	print("[MemoryExtractor] Обнаружен исходник скрипта! Сохранён в: " .. fileName)
end

-- Сохраняем найденные URL (скрипты на гитхабе/пастебине, откуда грузился лоадстринг)
local urlList = {}
for u, _ in pairs(foundUrls) do
	urlList[#urlList + 1] = u
end
if #urlList > 0 then
	saveFile(SESSION .. "/captured_urls.txt", table.concat(urlList, "\n"))
	print("[MemoryExtractor] Найдено URL в памяти: " .. #urlList)
end

-- Сохраняем полный отчёт по функциям
local reportSummary = table.concat({
	"=== Memory Extractor Report ===",
	"Сессия: " .. sessionName,
	"Всего исследовано функций в памяти: " .. totalClosuresScanned,
	"Найдено фрагментов кода/исходников: " .. sourceIndex,
	"Найдено адресов загрузки (URLs): " .. #urlList,
	"----------------------------------------------------------------",
	"",
	table.concat(dumpReport, "\n")
}, "\n")

saveFile(SESSION .. "/full_memory_dump.txt", reportSummary)

-- Итоги
local resultMsg = string.format("Готово! Найдено исходников: %d, URL: %d. Папка: %s", sourceIndex, #urlList, SESSION)
print("[MemoryExtractor] " .. resultMsg)
notify("MemoryExtractor", resultMsg)
