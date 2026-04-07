--!strict
--[[
	CLINT.lua - Core Local Interruptor (Timer + Software Interrupts)
	
	Place in: ReplicatedStorage/RISCVModules/CLINT
	(Move OUT of InstructionSets - this is an MMIO device, not an instruction set)
	
	Memory-mapped at 0x02000000 (matches QEMU virt machine):
		0x0000      : msip    (Machine Software Interrupt Pending, per-hart)
		0x4000      : mtimecmp lo (64-bit timer compare register)
		0x4004      : mtimecmp hi
		0xBFF8      : mtime lo    (64-bit free-running timer)
		0xBFFC      : mtime hi
	
	USAGE:
		local clint = CLINT.new()
		memory:registerMMIO(0x02000000, 0x10000, clint.readFn, clint.writeFn)
		-- Each CPU step:
		clint:step(cpu)
]]

local CLINT = {}
CLINT.__index = CLINT

local BASE_ADDR = 0x02000000

function CLINT.new()
	local self = setmetatable({}, CLINT)
	
	self.baseAddr = BASE_ADDR
	
	-- 64-bit timer (split into hi/lo for 32-bit operations)
	self.mtime_lo = 0
	self.mtime_hi = 0
	
	-- 64-bit timer compare
	self.mtimecmp_lo = 0xFFFFFFFF  -- start high so no immediate interrupt
	self.mtimecmp_hi = 0xFFFFFFFF
	
	-- Machine software interrupt pending (per hart, we only have hart 0)
	self.msip = 0
	
	-- Build MMIO closures
	local s = self
	self.readFn = function(offset)
		-- MMIO read handler returns a single byte, but our Memory
		-- calls read8 which maps to individual byte offsets.
		-- We need to handle 32-bit aligned reads.
		-- The Memory module calls read8 for each byte, so we
		-- must handle byte-level access to our word registers.
		return s:readByte(offset)
	end
	self.writeFn = function(offset, val)
		s:writeByte(offset, val)
	end
	
	-- Internal: word-level register storage for byte access
	self._regs = {} -- cache of word values at word-aligned offsets
	
	return self
end

--------------------------------------------------------------------------------
-- BYTE-LEVEL ACCESS (Memory module calls read8/write8 per byte)
--------------------------------------------------------------------------------

function CLINT:readByte(offset)
	-- Determine which 32-bit register this byte belongs to
	local wordOffset = bit32.band(offset, 0xFFFFFFFC) -- align to 4
	local byteIdx = offset - wordOffset -- 0, 1, 2, or 3
	
	local word = self:_readWord(wordOffset)
	return bit32.band(bit32.rshift(word, byteIdx * 8), 0xFF)
end

function CLINT:writeByte(offset, val)
	local wordOffset = bit32.band(offset, 0xFFFFFFFC)
	local byteIdx = offset - wordOffset
	
	-- Read-modify-write
	local word = self:_readWord(wordOffset)
	local mask = bit32.bnot(bit32.lshift(0xFF, byteIdx * 8))
	word = bit32.band(word, mask)
	word = bit32.bor(word, bit32.lshift(bit32.band(val, 0xFF), byteIdx * 8))
	self:_writeWord(wordOffset, word)
end

function CLINT:_readWord(offset)
	if offset == 0x0000 then return self.msip end
	if offset == 0x4000 then return self.mtimecmp_lo end
	if offset == 0x4004 then return self.mtimecmp_hi end
	if offset == 0xBFF8 then return self.mtime_lo end
	if offset == 0xBFFC then return self.mtime_hi end
	return 0
end

function CLINT:_writeWord(offset, val)
	if offset == 0x0000 then
		self.msip = bit32.band(val, 1) -- only bit 0 matters
	elseif offset == 0x4000 then
		self.mtimecmp_lo = val
	elseif offset == 0x4004 then
		self.mtimecmp_hi = val
	elseif offset == 0xBFF8 then
		self.mtime_lo = val
	elseif offset == 0xBFFC then
		self.mtime_hi = val
	end
end

--------------------------------------------------------------------------------
-- STEP (call every CPU instruction)
--------------------------------------------------------------------------------

function CLINT:step(cpu)
	-- Increment mtime (wrapping 64-bit counter)
	self.mtime_lo = self.mtime_lo + 1
	if self.mtime_lo >= 0x100000000 then
		self.mtime_lo = 0
		self.mtime_hi = self.mtime_hi + 1
		if self.mtime_hi >= 0x100000000 then
			self.mtime_hi = 0
		end
	end
	
	-- Check timer interrupt: mtime >= mtimecmp
	local timerFired = false
	if self.mtime_hi > self.mtimecmp_hi then
		timerFired = true
	elseif self.mtime_hi == self.mtimecmp_hi and self.mtime_lo >= self.mtimecmp_lo then
		timerFired = true
	end
	
	local mip = cpu.regs:readCSR(0x344)
	
	if timerFired then
		-- Set MTIP (Machine Timer Interrupt Pending) bit 7
		mip = bit32.bor(mip, 0x80)
	else
		-- Clear MTIP
		mip = bit32.band(mip, bit32.bnot(0x80))
	end
	
	-- Machine software interrupt
	if self.msip ~= 0 then
		-- Set MSIP bit 3
		mip = bit32.bor(mip, 0x08)
	else
		mip = bit32.band(mip, bit32.bnot(0x08))
	end
	
	cpu.regs:writeCSR(0x344, mip)
end

return CLINT
