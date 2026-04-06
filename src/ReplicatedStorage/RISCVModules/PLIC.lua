--[[
	PLIC.lua - Platform-Level Interrupt Controller
	
	Place in: ReplicatedStorage/RISCVModules/PLIC
	
	Memory-mapped at 0x0C000000 (matches QEMU virt machine layout).
	
	MEMORY MAP (offsets from 0x0C000000):
		0x000000 - 0x000FFC : Source priority      (4 bytes per source, source 0 reserved)
		0x001000 - 0x00107F : Pending bits          (1 bit per source, 32 sources per word)
		0x002000 - 0x00207F : Enable bits context 0 (1 bit per source)
		0x002080 - 0x0020FF : Enable bits context 1
		0x200000            : Priority threshold context 0
		0x200004            : Claim/complete context 0
		0x201000            : Priority threshold context 1
		0x201004            : Claim/complete context 1
	
	For single-hart RV32, we have 2 contexts:
		Context 0 = M-mode external interrupt
		Context 1 = S-mode external interrupt
	
	USAGE:
		local plic = PLIC.new()
		memory:registerMMIO(0x0C000000, 0x400000, plic.readFn, plic.writeFn)
		-- To raise an interrupt from a device:
		plic:raiseInterrupt(sourceId)
		-- Each CPU step, check:
		plic:updateInterrupts(cpu)
]]

local PLIC = {}
PLIC.__index = PLIC

local BASE_ADDR = 0x0C000000
local NUM_SOURCES = 64       -- support up to 64 interrupt sources
local NUM_CONTEXTS = 2       -- context 0 = M-mode, context 1 = S-mode

function PLIC.new()
	local self = setmetatable({}, PLIC)
	
	self.baseAddr = BASE_ADDR
	
	-- Priority of each source (0 = disabled, 1-7 = priority levels)
	self.priority = {}
	for i = 0, NUM_SOURCES do
		self.priority[i] = 0
	end
	
	-- Pending bits (which sources have a pending interrupt)
	self.pending = {}
	for i = 0, NUM_SOURCES do
		self.pending[i] = false
	end
	
	-- Per-context state
	self.contexts = {}
	for ctx = 0, NUM_CONTEXTS - 1 do
		self.contexts[ctx] = {
			enable = {},      -- which sources are enabled for this context
			threshold = 0,    -- priority threshold
			claimed = 0,      -- currently claimed source (0 = none)
		}
		for i = 0, NUM_SOURCES do
			self.contexts[ctx].enable[i] = false
		end
	end
	
	-- Build MMIO read/write functions (closures capturing self)
	local s = self
	self.readFn = function(offset) return s:read32(offset) end
	self.writeFn = function(offset, val) s:write32(offset, val) end
	
	return self
end

--------------------------------------------------------------------------------
-- INTERRUPT MANAGEMENT
--------------------------------------------------------------------------------

-- A device calls this to signal an interrupt
function PLIC:raiseInterrupt(source)
	if source > 0 and source <= NUM_SOURCES then
		self.pending[source] = true
	end
end

-- Clear a pending interrupt
function PLIC:clearInterrupt(source)
	if source > 0 and source <= NUM_SOURCES then
		self.pending[source] = false
	end
end

-- Find highest-priority pending+enabled source for a context
function PLIC:_bestCandidate(ctx)
	local bestSource = 0
	local bestPriority = 0
	local context = self.contexts[ctx]
	if not context then return 0 end
	
	for src = 1, NUM_SOURCES do
		if self.pending[src] and context.enable[src] then
			local pri = self.priority[src] or 0
			if pri > context.threshold and pri > bestPriority then
				bestPriority = pri
				bestSource = src
			end
		end
	end
	return bestSource
end

-- Call each CPU step to update external interrupt pending bits
function PLIC:updateInterrupts(cpu)
	-- Context 0 -> MEIP (Machine External Interrupt Pending) in mip, bit 11
	-- Context 1 -> SEIP (Supervisor External Interrupt Pending) in mip, bit 9
	local mip = cpu.regs:readCSR(0x344)
	
	local mCandidate = self:_bestCandidate(0)
	if mCandidate > 0 then
		mip = bit32.bor(mip, bit32.lshift(1, 11)) -- set MEIP
	else
		mip = bit32.band(mip, bit32.bnot(bit32.lshift(1, 11))) -- clear MEIP
	end
	
	local sCandidate = self:_bestCandidate(1)
	if sCandidate > 0 then
		mip = bit32.bor(mip, bit32.lshift(1, 9)) -- set SEIP
	else
		mip = bit32.band(mip, bit32.bnot(bit32.lshift(1, 9))) -- clear SEIP
	end
	
	cpu.regs:writeCSR(0x344, mip)
end

--------------------------------------------------------------------------------
-- MMIO READ
--------------------------------------------------------------------------------

function PLIC:read32(offset)
	-- Source priority: 0x000000 - 0x000FFC
	if offset >= 0x000000 and offset < 0x001000 then
		local source = math.floor(offset / 4)
		return self.priority[source] or 0
	end
	
	-- Pending bits: 0x001000 - 0x00107F
	if offset >= 0x001000 and offset < 0x001080 then
		local wordIdx = math.floor((offset - 0x001000) / 4)
		local val = 0
		for bit = 0, 31 do
			local src = wordIdx * 32 + bit
			if self.pending[src] then
				val = bit32.bor(val, bit32.lshift(1, bit))
			end
		end
		return val
	end
	
	-- Enable bits: 0x002000 + ctx * 0x80
	if offset >= 0x002000 and offset < 0x002000 + NUM_CONTEXTS * 0x80 then
		local ctxOffset = offset - 0x002000
		local ctx = math.floor(ctxOffset / 0x80)
		local wordOffset = ctxOffset % 0x80
		local wordIdx = math.floor(wordOffset / 4)
		local context = self.contexts[ctx]
		if not context then return 0 end
		local val = 0
		for bit = 0, 31 do
			local src = wordIdx * 32 + bit
			if context.enable[src] then
				val = bit32.bor(val, bit32.lshift(1, bit))
			end
		end
		return val
	end
	
	-- Context threshold/claim: 0x200000 + ctx * 0x1000
	if offset >= 0x200000 then
		local ctxOffset = offset - 0x200000
		local ctx = math.floor(ctxOffset / 0x1000)
		local reg = ctxOffset % 0x1000
		local context = self.contexts[ctx]
		if not context then return 0 end
		
		if reg == 0 then
			-- Threshold
			return context.threshold
		elseif reg == 4 then
			-- Claim: returns highest priority pending source and marks it claimed
			local best = self:_bestCandidate(ctx)
			if best > 0 then
				self.pending[best] = false
				context.claimed = best
			end
			return best
		end
	end
	
	return 0
end

--------------------------------------------------------------------------------
-- MMIO WRITE
--------------------------------------------------------------------------------

function PLIC:write32(offset, val)
	-- Source priority
	if offset >= 0x000000 and offset < 0x001000 then
		local source = math.floor(offset / 4)
		if source > 0 and source <= NUM_SOURCES then
			self.priority[source] = bit32.band(val, 0x07) -- 3-bit priority
		end
		return
	end
	
	-- Pending bits are read-only (set by devices, cleared by claim)
	if offset >= 0x001000 and offset < 0x001080 then
		return
	end
	
	-- Enable bits
	if offset >= 0x002000 and offset < 0x002000 + NUM_CONTEXTS * 0x80 then
		local ctxOffset = offset - 0x002000
		local ctx = math.floor(ctxOffset / 0x80)
		local wordOffset = ctxOffset % 0x80
		local wordIdx = math.floor(wordOffset / 4)
		local context = self.contexts[ctx]
		if not context then return end
		for b = 0, 31 do
			local src = wordIdx * 32 + b
			if src <= NUM_SOURCES then
				context.enable[src] = bit32.btest(val, bit32.lshift(1, b))
			end
		end
		return
	end
	
	-- Context threshold/complete
	if offset >= 0x200000 then
		local ctxOffset = offset - 0x200000
		local ctx = math.floor(ctxOffset / 0x1000)
		local reg = ctxOffset % 0x1000
		local context = self.contexts[ctx]
		if not context then return end
		
		if reg == 0 then
			-- Threshold
			context.threshold = bit32.band(val, 0x07)
		elseif reg == 4 then
			-- Complete: signals that handling of source `val` is done
			context.claimed = 0
			-- (interrupt can be re-raised by the device if still active)
		end
	end
end

return PLIC
