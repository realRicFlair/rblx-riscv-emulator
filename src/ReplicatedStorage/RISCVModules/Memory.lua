--[[
	Memory.lua - Byte-addressable memory with MMU and Memory-Mapped I/O
	
	Place in: ReplicatedStorage/RISCVModules/Memory
	
	MEMORY MAP (physical addresses, matches QEMU virt):
		0x02000000 - 0x0200FFFF : CLINT (timer/software interrupts)
		0x0C000000 - 0x0FFFFFFF : PLIC  (external interrupt controller)
		0x10000000 - 0x10000007 : UART  (16550-compatible)
		0x80000000 - 0x80FFFFFF : RAM   (16 MB default)
	
	MMU SUPPORT:
		When an Sv32_MMU instance is attached, all public read/write
		calls go through virtual->physical translation first.
		Raw physical access is still available via read8_phys/write8_phys.
]]

local Memory = {}
Memory.__index = Memory

function Memory.new(ramSizeBytes)
	local self = setmetatable({}, Memory)
	
	self.ramSize = ramSizeBytes or (16 * 1024 * 1024) -- 16 MB default
	self.ram = {}            -- sparse table, byte-indexed
	self.mmioRegions = {}    -- {base, size, read, write}
	
	-- UART buffers
	self.uartInputBuffer = {}
	self.uartOutputCallback = nil
	
	-- MMU (set via attachMMU)
	self.mmu = nil
	
	-- Register default UART at 0x10000000
	self:_registerUART()
	
	return self
end

--------------------------------------------------------------------------------
-- MMU ATTACHMENT
--------------------------------------------------------------------------------

function Memory:attachMMU(mmu)
	self.mmu = mmu
end

--------------------------------------------------------------------------------
-- RAW PHYSICAL BYTE ACCESS (bypasses MMU, used internally and by MMU itself)
--------------------------------------------------------------------------------

function Memory:_rawRead8(addr)
	return self.ram[addr] or 0
end

function Memory:_rawWrite8(addr, val)
	self.ram[addr] = bit32.band(val, 0xFF)
end

--------------------------------------------------------------------------------
-- MMIO REGISTRATION
--------------------------------------------------------------------------------

function Memory:registerMMIO(base, size, readFn, writeFn)
	table.insert(self.mmioRegions, {
		base = base,
		size = size,
		read = readFn,
		write = writeFn,
	})
	-- Sort by base address for deterministic lookup order
	table.sort(self.mmioRegions, function(a, b) return a.base < b.base end)
end

function Memory:_findMMIO(addr)
	for _, region in ipairs(self.mmioRegions) do
		if addr >= region.base and addr < region.base + region.size then
			return region, addr - region.base
		end
	end
	return nil, 0
end

--------------------------------------------------------------------------------
-- UART (16550-style, minimal subset)
--------------------------------------------------------------------------------

function Memory:_registerUART()
	local UART_BASE = 0x10000000
	
	self:registerMMIO(UART_BASE, 0x100,
		-- READ
		function(offset)
			if offset == 0 then
				-- RBR: read next char from input buffer
				if #self.uartInputBuffer > 0 then
					return table.remove(self.uartInputBuffer, 1)
				end
				return 0
			elseif offset == 5 then
				-- LSR: line status register
				local status = 0x60 -- bits 5,6 set = transmitter empty+idle
				if #self.uartInputBuffer > 0 then
					status = bit32.bor(status, 0x01) -- bit 0 = data ready
				end
				return status
			elseif offset == 2 then
				-- IIR: interrupt identification register
				-- Bit 0 = 1 means no interrupt pending
				return 0x01
			end
			return 0
		end,
		-- WRITE
		function(offset, val)
			if offset == 0 then
				-- THR: transmit character
				if self.uartOutputCallback then
					self.uartOutputCallback(val)
				end
			end
			-- IER (1), FCR (2), LCR (3), MCR (4) silently ignored
		end
	)
end

function Memory:uartSendChar(charCode)
	table.insert(self.uartInputBuffer, bit32.band(charCode, 0xFF))
end

function Memory:uartSendString(str)
	for i = 1, #str do
		table.insert(self.uartInputBuffer, string.byte(str, i))
	end
end

function Memory:setUARTOutput(callback)
	self.uartOutputCallback = callback
end

--------------------------------------------------------------------------------
-- PHYSICAL READ/WRITE (checks MMIO first, then RAM - NO MMU translation)
-- These are what the MMU page walker uses, and what translated addresses hit.
--------------------------------------------------------------------------------

function Memory:read8_phys(addr)
	addr = bit32.band(addr, 0xFFFFFFFF)
	local region, offset = self:_findMMIO(addr)
	if region then return region.read(offset) end
	return self:_rawRead8(addr)
end

function Memory:read16_phys(addr)
	local lo = self:read8_phys(addr)
	local hi = self:read8_phys(addr + 1)
	return bit32.bor(lo, bit32.lshift(hi, 8))
end

function Memory:read32_phys(addr)
	local b0 = self:read8_phys(addr)
	local b1 = self:read8_phys(addr + 1)
	local b2 = self:read8_phys(addr + 2)
	local b3 = self:read8_phys(addr + 3)
	return bit32.bor(b0, bit32.lshift(b1, 8), bit32.lshift(b2, 16), bit32.lshift(b3, 24))
end

function Memory:write8_phys(addr, val)
	addr = bit32.band(addr, 0xFFFFFFFF)
	val = bit32.band(val, 0xFF)
	local region, offset = self:_findMMIO(addr)
	if region then region.write(offset, val); return end
	self:_rawWrite8(addr, val)
end

function Memory:write16_phys(addr, val)
	self:write8_phys(addr, bit32.band(val, 0xFF))
	self:write8_phys(addr + 1, bit32.band(bit32.rshift(val, 8), 0xFF))
end

function Memory:write32_phys(addr, val)
	self:write8_phys(addr, bit32.band(val, 0xFF))
	self:write8_phys(addr + 1, bit32.band(bit32.rshift(val, 8), 0xFF))
	self:write8_phys(addr + 2, bit32.band(bit32.rshift(val, 16), 0xFF))
	self:write8_phys(addr + 3, bit32.band(bit32.rshift(val, 24), 0xFF))
end

--------------------------------------------------------------------------------
-- PUBLIC VIRTUAL READ/WRITE (goes through MMU if enabled)
-- These are what instruction handlers call.
-- 
-- The CPU sets self._currentAccessType before each memory access so the
-- MMU knows whether this is a read, write, or exec.
-- If a page fault occurs, these return 0 and the CPU's fault handler
-- is invoked via the cpu reference.
--------------------------------------------------------------------------------

-- The CPU must set these before memory ops so the MMU can check permissions
Memory._currentAccessType = "read"  -- default
Memory._cpu = nil                   -- set by CPU during init

function Memory:read8(addr)
	addr = bit32.band(addr, 0xFFFFFFFF)
	if self.mmu then
		local paddr, fault = self.mmu:translate(addr, self._currentAccessType or "read")
		if fault then
			if self._cpu then
				self._cpu:trap(fault, addr)
			end
			return 0
		end
		return self:read8_phys(paddr)
	end
	-- No MMU
	local region, offset = self:_findMMIO(addr)
	if region then return region.read(offset) end
	return self:_rawRead8(addr)
end

function Memory:read16(addr)
	local lo = self:read8(addr)
	local hi = self:read8(addr + 1)
	return bit32.bor(lo, bit32.lshift(hi, 8))
end

function Memory:read32(addr)
	-- Fast path: if no MMU, use physical directly
	if not self.mmu then
		addr = bit32.band(addr, 0xFFFFFFFF)
		local region, offset = self:_findMMIO(addr)
		if region then
			local b0 = region.read(offset)
			local b1 = region.read(offset + 1)
			local b2 = region.read(offset + 2)
			local b3 = region.read(offset + 3)
			return bit32.bor(b0, bit32.lshift(b1, 8), bit32.lshift(b2, 16), bit32.lshift(b3, 24))
		end
		local b0 = self:_rawRead8(addr)
		local b1 = self:_rawRead8(addr + 1)
		local b2 = self:_rawRead8(addr + 2)
		local b3 = self:_rawRead8(addr + 3)
		return bit32.bor(b0, bit32.lshift(b1, 8), bit32.lshift(b2, 16), bit32.lshift(b3, 24))
	end
	
	-- MMU path
	local b0 = self:read8(addr)
	local b1 = self:read8(addr + 1)
	local b2 = self:read8(addr + 2)
	local b3 = self:read8(addr + 3)
	return bit32.bor(b0, bit32.lshift(b1, 8), bit32.lshift(b2, 16), bit32.lshift(b3, 24))
end

function Memory:write8(addr, val)
	addr = bit32.band(addr, 0xFFFFFFFF)
	val = bit32.band(val, 0xFF)
	if self.mmu then
		local paddr, fault = self.mmu:translate(addr, "write")
		if fault then
			if self._cpu then
				self._cpu:trap(fault, addr)
			end
			return
		end
		self:write8_phys(paddr, val)
		return
	end
	local region, offset = self:_findMMIO(addr)
	if region then region.write(offset, val); return end
	self:_rawWrite8(addr, val)
end

function Memory:write16(addr, val)
	self:write8(addr, bit32.band(val, 0xFF))
	self:write8(addr + 1, bit32.band(bit32.rshift(val, 8), 0xFF))
end

function Memory:write32(addr, val)
	self:write8(addr, bit32.band(val, 0xFF))
	self:write8(addr + 1, bit32.band(bit32.rshift(val, 8), 0xFF))
	self:write8(addr + 2, bit32.band(bit32.rshift(val, 16), 0xFF))
	self:write8(addr + 3, bit32.band(bit32.rshift(val, 24), 0xFF))
end

--------------------------------------------------------------------------------
-- BULK LOAD (always physical, for bootloader use)
--------------------------------------------------------------------------------

function Memory:loadBinary(baseAddr, data)
	if type(data) == "string" then
		for i = 1, #data do
			self:_rawWrite8(baseAddr + i - 1, string.byte(data, i))
		end
	elseif type(data) == "table" then
		for i, byte in ipairs(data) do
			self:_rawWrite8(baseAddr + i - 1, byte)
		end
	end
end

function Memory:loadWords(baseAddr, words)
	for i, word in ipairs(words) do
		local addr = baseAddr + (i - 1) * 4
		self:write8_phys(addr, bit32.band(word, 0xFF))
		self:write8_phys(addr + 1, bit32.band(bit32.rshift(word, 8), 0xFF))
		self:write8_phys(addr + 2, bit32.band(bit32.rshift(word, 16), 0xFF))
		self:write8_phys(addr + 3, bit32.band(bit32.rshift(word, 24), 0xFF))
	end
end

function Memory:clear()
	self.ram = {}
	self.uartInputBuffer = {}
	if self.mmu then
		self.mmu:tlbFlush()
	end
end

return Memory
