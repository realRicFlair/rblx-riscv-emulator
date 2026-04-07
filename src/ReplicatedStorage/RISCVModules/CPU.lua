
--[[
	CPU.lua - Main RISC-V CPU orchestrator (Linux-capable)
	
	Place in: ReplicatedStorage/RISCVModules/CPU
	
	This module:
	- Creates Memory, Registers, MMU, CLINT, PLIC instances
	- Auto-discovers all InstructionSet modules
	- Runs fetch → decode → execute with interrupt checking
	- Handles traps and interrupt dispatch
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Memory    = require(script.Parent.Memory)
local Registers = require(script.Parent.Registers)
local Decoder   = require(script.Parent.Decoder)
local Sv32_MMU  = require(script.Parent.Sv32_MMU)
local CLINTMod  = require(script.Parent.CLINT)
local PLICMod   = require(script.Parent.PLIC)

local RegistersType = require(script.Parent.Registers).Registers

local CPU = {}
CPU.__index = CPU

function CPU.new(config)
	local self = setmetatable({}, CPU)
	config = config or {}
	
	-- Core components
	self.mem  = Memory.new(config.ramSize)
	self.regs = Registers.new()
	
	-- MMU
	self.mmu = Sv32_MMU.new(self.mem, self.regs)
	self.mem:attachMMU(self.mmu)
	self.mem._cpu = self  -- so Memory can invoke trap on page fault
	
	-- CLINT (timer + software interrupts)
	self.clint = CLINTMod.new()
	self.mem:registerMMIO(0x02000000, 0x10000, self.clint.readFn, self.clint.writeFn)
	
	-- PLIC (external interrupt controller)
	self.plic = PLICMod.new()
	self.mem:registerMMIO(0x0C000000, 0x400000, self.plic.readFn, self.plic.writeFn)
	
	-- Instruction dispatch table
	self.dispatch = {}
	self.dispatchF7 = {}
	
	-- Per-cycle state
	self.branchTaken = false
	self.branchTarget = 0
	self.halted = false
	self.trapPending = false
	
	-- Atomic LR/SC reservation
	self.reservationSet = nil
	
	-- Debug
	self.debugMode = config.debug or false
	self.instructionCount = 0
	self.onTrap = nil
	self.breakpoints = {}
	
	-- Entry point
	self.entryPoint = config.entryPoint or 0x80000000
	self.regs.pc = self.entryPoint
	
	-- Set up stack pointer (top of RAM, 16-byte aligned)
	self.regs:write(2, 0x80000000 + (config.ramSize or 16*1024*1024) - 16)
	
	-- Auto-discover instruction sets
	self:_loadInstructionSets()
	
	return self
end

--------------------------------------------------------------------------------
-- INSTRUCTION SET AUTO-DISCOVERY
--------------------------------------------------------------------------------

function CPU:_loadInstructionSets()
	local modulesFolder = script.Parent
	local isetsFolder = modulesFolder:FindFirstChild("InstructionSets")
	
	if not isetsFolder then
		warn("[RISCV-CPU] No InstructionSets folder found!")
		return
	end
	
	local loaded = {}
	for _, child in ipairs(isetsFolder:GetChildren()) do
		if child:IsA("ModuleScript") and child.Name ~= "_Template" and child.Name ~= "CLINT" then
			local ok, iset = pcall(require, child)
			if ok and iset and iset.instructions then
				self:_registerInstructionSet(iset)
				table.insert(loaded, iset.name or child.Name)
			else
				warn("[RISCV-CPU] Failed to load instruction set: " .. child.Name)
				if not ok then warn(iset) end
			end
		end
	end
	
	if self.debugMode then
		print("[RISCV-CPU] Loaded instruction sets: " .. table.concat(loaded, ", "))
	end
end

function CPU:_registerInstructionSet(iset)
	for opcode, handlers in pairs(iset.instructions) do
		if iset.useFunct7 then
			if not self.dispatchF7[opcode] then
				self.dispatchF7[opcode] = {}
			end
			if not self.dispatchF7[opcode][iset.funct7] then
				self.dispatchF7[opcode][iset.funct7] = {}
			end
			for funct3, handler in pairs(handlers) do
				self.dispatchF7[opcode][iset.funct7][funct3] = handler
			end
		else
			if not self.dispatch[opcode] then
				self.dispatch[opcode] = {}
			end
			for funct3, handler in pairs(handlers) do
				self.dispatch[opcode][funct3] = handler
			end
		end
	end
end

function CPU:registerExtension(iset)
	self:_registerInstructionSet(iset)
end

--------------------------------------------------------------------------------
-- INTERRUPT CHECKING
-- Called before each instruction to see if a pending interrupt should fire.
-- Interrupts only fire when globally enabled and individually enabled+pending.
--------------------------------------------------------------------------------

function CPU:_checkInterrupts()
	local mstatus = self.regs:readCSR(0x300)
	local mie_csr = self.regs:readCSR(0x304)  -- interrupt enable bits
	local mip = self.regs:readCSR(0x344)       -- interrupt pending bits
	local mideleg = self.regs:readCSR(0x303)   -- interrupt delegation
	
	-- Determine which interrupts can fire based on privilege + global enable
	local globalEnabled = 0
	
	if self.regs.privLevel < 3 then
		-- Lower than M-mode: M-mode interrupts always enabled
		globalEnabled = bit32.bor(globalEnabled, bit32.bnot(mideleg))
	elseif bit32.btest(mstatus, 0x08) then
		-- M-mode with MIE set
		globalEnabled = bit32.bor(globalEnabled, bit32.bnot(mideleg))
	end
	
	if self.regs.privLevel < 1 then
		-- U-mode: S-mode interrupts always enabled
		globalEnabled = bit32.bor(globalEnabled, mideleg)
	elseif self.regs.privLevel == 1 then
		-- S-mode: check SIE bit (bit 1 of sstatus/mstatus)
		if bit32.btest(mstatus, 0x02) then
			globalEnabled = bit32.bor(globalEnabled, mideleg)
		end
	end
	
	-- Actionable = pending AND enabled_in_mie AND globally_enabled
	local actionable = bit32.band(mip, mie_csr)
	actionable = bit32.band(actionable, globalEnabled)
	
	if actionable == 0 then return end
	
	-- Priority order: MEI(11) > MSI(3) > MTI(7) > SEI(9) > SSI(1) > STI(5)
	local priorities = {11, 3, 7, 9, 1, 5}
	for _, bitNum in ipairs(priorities) do
		if bit32.btest(actionable, bit32.lshift(1, bitNum)) then
			-- Fire this interrupt
			-- Interrupt cause = bitNum with bit 31 set
			local cause = bit32.bor(0x80000000, bitNum)
			
			-- Determine if delegated to S-mode
			if bit32.btest(mideleg, bit32.lshift(1, bitNum)) then
				self:_trapToSupervisor(cause, 0)
			else
				self:_trapToMachine(cause, 0)
			end
			return
		end
	end
end

--------------------------------------------------------------------------------
-- TRAP HANDLING
--------------------------------------------------------------------------------

function CPU:trap(cause, tval)
	-- Determine target privilege level based on delegation
	local delegated = false
	-- Only delegate if cause is an exception (bit 31 not set) and we're not already in M-mode
	if not bit32.btest(cause, 0x80000000) then
		-- Exception
		if self.regs.privLevel <= 1 then
			local medeleg = self.regs:readCSR(0x302)
			if bit32.btest(medeleg, bit32.lshift(1, cause)) then
				delegated = true
			end
		end
	else
		-- Interrupt - check mideleg
		local intNum = bit32.band(cause, 0x7FFFFFFF)
		if self.regs.privLevel <= 1 then
			local mideleg = self.regs:readCSR(0x303)
			if bit32.btest(mideleg, bit32.lshift(1, intNum)) then
				delegated = true
			end
		end
	end
	
	if delegated then
		self:_trapToSupervisor(cause, tval or 0)
	else
		self:_trapToMachine(cause, tval or 0)
	end
	
	self.trapPending = true
	
	if self.onTrap then
		print("[DEBUG] Decoding 0x800000D0 - 0x800000F0:")
		for addr = 0x800000D0, 0x800000F0, 4 do
		    local instr = self.mem:read32_phys(addr)
		    local d = Decoder.decode(instr)
		    print(string.format("  %08X: %08X  op=%02X f3=%d f7=%02X rd=x%d rs1=x%d rs2=x%d imm=%d",
		        addr, instr, d.opcode, d.funct3, d.funct7, d.rd, d.rs1, d.rs2, d.imm))
		end

		self.onTrap(cause, tval, self.regs.pc)
		
	end
end

function CPU:_trapToSupervisor(cause, tval)
	self.regs:writeCSR(0x141, self.regs.pc)    -- sepc
	self.regs:writeCSR(0x142, cause)            -- scause
	self.regs:writeCSR(0x143, tval or 0)        -- stval
	
	local sstatus = self.regs:readCSR(0x100)
	local sie = bit32.band(bit32.rshift(sstatus, 1), 1)
	sstatus = bit32.band(sstatus, bit32.bnot(0x122)) -- clear SIE, SPIE, SPP
	sstatus = bit32.bor(sstatus,
		bit32.lshift(sie, 5),
		bit32.lshift(self.regs.privLevel, 8)
	)
	self.regs:writeCSR(0x100, sstatus)
	self.regs.privLevel = 1
	
	local stvec = self.regs:readCSR(0x105)
	local mode = bit32.band(stvec, 3)
	local base = bit32.band(stvec, 0xFFFFFFFC)
	
	if mode == 1 and bit32.btest(cause, 0x80000000) then
		-- Vectored mode for interrupts
		local intNum = bit32.band(cause, 0x7FFFFFFF)
		self.branchTarget = base + intNum * 4
	else
		self.branchTarget = base
	end
	self.branchTaken = true
end

function CPU:_trapToMachine(cause, tval)
	self.regs:writeCSR(0x341, self.regs.pc)    -- mepc
	self.regs:writeCSR(0x342, cause)            -- mcause
	self.regs:writeCSR(0x343, tval or 0)        -- mtval
	
	local mstatus = self.regs:readCSR(0x300)
	local mie = bit32.band(bit32.rshift(mstatus, 3), 1)
	mstatus = bit32.band(mstatus, bit32.bnot(0x1888)) -- clear MIE, MPIE, MPP
	mstatus = bit32.bor(mstatus,
		bit32.lshift(mie, 7),
		bit32.lshift(self.regs.privLevel, 11)
	)
	self.regs:writeCSR(0x300, mstatus)
	self.regs.privLevel = 3
	
	local mtvec = self.regs:readCSR(0x305)
	local mode = bit32.band(mtvec, 3)
	local base = bit32.band(mtvec, 0xFFFFFFFC)
	
	if mode == 1 and bit32.btest(cause, 0x80000000) then
		local intNum = bit32.band(cause, 0x7FFFFFFF)
		self.branchTarget = base + intNum * 4
	else
		self.branchTarget = base
	end
	self.branchTaken = true
end

--------------------------------------------------------------------------------
-- FETCH / DECODE / EXECUTE
--------------------------------------------------------------------------------

function CPU:step()
	if self.halted then return false end
	
	-- Check for pending interrupts before fetching
	self:_checkInterrupts()
	if self.branchTaken then
		-- Interrupt was taken, update PC and continue next cycle
		self.regs.pc = self.branchTarget
		self.branchTaken = false
		self.branchTarget = 0
		self.instructionCount = self.instructionCount + 1
		return true
	end
	
	-- FETCH (instruction fetch goes through MMU with "exec" access type)
	self.mem._currentAccessType = "exec"
	local instruction = self.mem:read32(self.regs.pc)
	
	-- Check if page fault occurred during fetch
	if self.trapPending then
		if self.branchTaken then
			self.regs.pc = self.branchTarget
		end
		self.branchTaken = false
		self.branchTarget = 0
		self.trapPending = false
		self.instructionCount = self.instructionCount + 1
		return true
	end
	
	-- Handle empty memory
	if instruction == 0 then
		if self.debugMode then
			print(string.format("[HALT] Zero instruction at PC=0x%08X", self.regs.pc))
		end
		self.halted = true
		return false
	end
	
	-- DECODE
	local d = Decoder.decode(instruction)
	
	-- Reset per-instruction state
	self.branchTaken = false
	self.branchTarget = 0
	self.trapPending = false
	
	-- Set default memory access type for data operations
	self.mem._currentAccessType = "read"
	
	-- Debug trace
	if self.debugMode then
		print(string.format("[%08X] %s", self.regs.pc, Decoder.disassemble(d)))
	end
	
	-- EXECUTE
	local executed = false
	
	-- Check for SFENCE.VMA (opcode 0x73, funct7 0x09, funct3 0)
	if d.opcode == 0x73 and d.funct3 == 0 and d.funct7 == 0x09 then
		-- SFENCE.VMA: flush TLB
		self.mmu:tlbFlush()
		executed = true
	end
	
	-- Try funct7-qualified dispatch
	if not executed then
		local f7table = self.dispatchF7[d.opcode]
		if f7table then
			local f7handlers = f7table[d.funct7]
			if f7handlers then
				local handler = f7handlers[d.funct3] or f7handlers["_all"]
				if handler then
					handler(self, d)
					executed = true
				end
			end
		end
	end
	
	-- Try standard dispatch
	if not executed then
		local opcodeHandlers = self.dispatch[d.opcode]
		if opcodeHandlers then
			local handler = opcodeHandlers[d.funct3] or opcodeHandlers["_all"]
			if handler then
				handler(self, d)
				executed = true
			end
		end
	end
	
	-- Unhandled instruction
	if not executed then
		if self.debugMode then
			warn(string.format("[ILLEGAL] %s", Decoder.disassemble(d)))
		end
		self:trap(2, instruction)
	end
	
	-- Advance PC
	if self.branchTaken then
		self.regs.pc = self.branchTarget
	elseif not self.trapPending then
		self.regs.pc = self.regs.pc + 4
	end
	
	-- Update counters
	self.instructionCount = self.instructionCount + 1
	self.regs:incrementInstret()
	
	-- Step CLINT (timer) - do this every N instructions for performance
	if self.instructionCount % 4 == 0 then
		self.clint:step(self)
	end
	
	-- Step PLIC (external interrupts) - less frequently
	if self.instructionCount % 64 == 0 then
		self.plic:updateInterrupts(self)
	end
	
	-- Breakpoint check
	if self.breakpoints[self.regs.pc] then
		self.halted = true
		if self.debugMode then
			print(string.format("[BREAK] Hit breakpoint at 0x%08X", self.regs.pc))
		end
		return false
	end

	if self.instructionCount > (self.MAX_INSTRUCTIONS_TR - 25) then
        print(string.format("Trace: PC = 0x%08X", self.regs.pc))
    end
	
	return true
end

-- Run N instructions (or until halted)
function CPU:run(maxInstructions, yieldEvery)
	maxInstructions = maxInstructions or math.huge
	yieldEvery = yieldEvery or 10000
	
	self.halted = false
	local count = 0
	
	while count < maxInstructions and not self.halted do
		self:step()
		count = count + 1
		
		if count % yieldEvery == 0 then
			task.wait()
		end
	end
	
	return count
end

--------------------------------------------------------------------------------
-- PROGRAM LOADING
--------------------------------------------------------------------------------

function CPU:loadProgram(words, addr)
	addr = addr or self.entryPoint
	self.mem:loadWords(addr, words)
	self.regs.pc = addr
end

function CPU:loadBinary(data, addr)
	addr = addr or self.entryPoint
	self.mem:loadBinary(addr, data)
	self.regs.pc = addr
end

--------------------------------------------------------------------------------
-- DEBUG HELPERS
--------------------------------------------------------------------------------

function CPU:setBreakpoint(addr)
	self.breakpoints[addr] = true
end

function CPU:removeBreakpoint(addr)
	self.breakpoints[addr] = nil
end

function CPU:reset(entryPoint)
	self.regs:reset(entryPoint or self.entryPoint)
	self.mem:clear()
	self.halted = false
	self.instructionCount = 0
	self.branchTaken = false
	self.trapPending = false
	self.reservationSet = nil
end

function CPU:dump()
	return self.regs:dump() .. string.format("\nInstructions executed: %d | Halted: %s",
		self.instructionCount, tostring(self.halted))
end

return CPU
