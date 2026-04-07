--[[
    Server.server.lua  --  fetches Image.bin from the local Python server
    and serves it to clients in 256 KB chunks via RemoteFunctions.

    Run PyServer/kernel_server.py BEFORE starting Roblox Studio playtest.
    HttpService must be enabled in Game Settings > Security.
]]

local HttpService       = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KERNEL_URL   = "http://127.0.0.1:8080"
local CHUNK_BYTES  = 256 * 1024   -- 256 KB per chunk; safe under Roblox remote limits

-- ── RemoteFunctions (created early so clients that join fast don't miss them) ──

local rfInfo  = Instance.new("RemoteFunction")
rfInfo.Name   = "KernelGetInfo"
rfInfo.Parent = ReplicatedStorage

local rfChunk  = Instance.new("RemoteFunction")
rfChunk.Name   = "KernelGetChunk"
rfChunk.Parent = ReplicatedStorage

-- ── State ─────────────────────────────────────────────────────────────────────

local chunks      = {}   -- array of binary strings
local totalBytes  = 0
local loaded      = false
local loadError   = nil

-- ── Fetch loop (runs in background) ───────────────────────────────────────────

task.spawn(function()
    print("[KernelServer] Contacting Python server at", KERNEL_URL)

    -- 1. Get file size
    local ok, result = pcall(HttpService.GetAsync, HttpService, KERNEL_URL .. "/size")
    if not ok or not result then
        loadError = "Could not reach kernel server. Is PyServer/kernel_server.py running?"
        warn("[KernelServer]", loadError)
        return
    end

    totalBytes = tonumber(result)
    if not totalBytes or totalBytes <= 0 then
        loadError = "Invalid size returned by kernel server: " .. tostring(result)
        warn("[KernelServer]", loadError)
        return
    end

    local mb = math.floor(totalBytes / 1024 / 1024 * 10 + 0.5) / 10
    print(string.format("[KernelServer] Image.bin size: %s MB (%d bytes)", mb, totalBytes))

    -- 2. Fetch in chunks
    local offset     = 0
    local chunkIndex = 1

    while offset < totalBytes do
        local remaining = totalBytes - offset
        local fetchSize = math.min(CHUNK_BYTES, remaining)
        local url = string.format(
            "%s/chunk?offset=%d&size=%d", KERNEL_URL, offset, fetchSize)

        local chunkOk, chunkData = pcall(HttpService.GetAsync, HttpService, url)
        if not chunkOk or not chunkData then
            loadError = string.format(
                "Failed to fetch chunk %d (offset=%d): %s", chunkIndex, offset, tostring(chunkData))
            warn("[KernelServer]", loadError)
            return
        end

        chunks[chunkIndex] = chunkData
        offset      = offset + #chunkData
        chunkIndex  = chunkIndex + 1

        if chunkIndex % 10 == 1 then   -- print progress every ~2.5 MB
            local pct = math.floor(offset / totalBytes * 100 + 0.5)
            print(string.format("[KernelServer] Loaded %d / %d MB  (%d%%)",
                math.floor(offset / 1024 / 1024), math.floor(totalBytes / 1024 / 1024), pct))
        end

        task.wait()  -- yield so the server doesn't stall
    end

    loaded = true
    print(string.format("[KernelServer] Done! %d chunks, %d bytes total", #chunks, totalBytes))
end)

-- ── Remote handlers ───────────────────────────────────────────────────────────

-- Returns: ready (bool), chunkCount (int), chunkBytes (int), errorMsg (string|nil)
rfInfo.OnServerInvoke = function(_player)
    -- Block until kernel is ready or an error occurs (max 5 min)
    local deadline = os.clock() + 300
    while not loaded and not loadError and os.clock() < deadline do
        task.wait(0.25)
    end

    if loadError then
        return false, 0, 0, loadError
    end
    if not loaded then
        return false, 0, 0, "Kernel load timed out after 5 minutes"
    end

    return true, #chunks, CHUNK_BYTES, nil
end

-- Returns: chunk binary string (or nil on bad index)
rfChunk.OnServerInvoke = function(_player, index)
    if not loaded then return nil end
    return chunks[index]
end
