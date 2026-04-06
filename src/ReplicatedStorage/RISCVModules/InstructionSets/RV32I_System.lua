--[[
	RV32I_System.lua - System instructions and trap handling
	
	Place in: ReplicatedStorage/RISCVModules/InstructionSets/RV32I_System
	
	Covers:
		SYSTEM (0x73):
			ECALL  (funct3=0, imm=0)  - environment call (syscall)
			EBREAK (funct3=0, imm=1)  - breakpoint
			MRET   (funct3=0, imm=0x302) - return from machine trap
			SRET   (funct3=0, imm=0x102) - return from supervisor trap
			WFI    (funct3=0, imm=0x105) - wait for interrupt
			CSRRW  (funct3=1) - CSR read/write
			CSRRS  (funct3=2) - CSR read/set bits
			CSRRC  (funct3=3) - CSR read/clear bits
			CSRRWI (funct3=5) - CSR read/write immediate
			CSRRSI (funct3=6) - CSR read/set bits immediate
			CSRRCI (funct3=7) - CSR read/clear bits immediate
	
	TRAP HANDLING:
		cpu:trap(cause, tval) is called for exceptions.
		The CPU module provides this method.
]]

local function toU32(v) return v % 0x100000000 end

local module = {}

module.name = "RV32I_System"
module.description = "ECALL, EBREAK, MRET, SRET, WFI, and CSR instructions"

module.instructions = {
	[0x73] = {
		-- funct3 = 0: ECALL / EBREAK / MRET / SRET / WFI
		[0] = function(cpu, d)
			local imm = bit32.band(bit32.rshift(d.raw, 20), 0xFFF)
			
			if imm == 0x000 then
				-- ECALL
				local cause
				if cpu.regs.privLevel == 0 then
					cause = 8  -- Environment call from U-mode
				elseif cpu.regs.privLevel == 1 then
					cause = 9  -- Environment call from S-mode
				else
					cause = 11 -- Environment call from M-mode
				end
				cpu:trap(cause, 0)
				
			elseif imm == 0x001 then
				-- EBREAK
				cpu:trap(3, cpu.regs.pc) -- Breakpoint
				
			elseif imm == 0x302 then
				-- MRET: return from machine-mode trap
				local mepc = cpu.regs:readCSR(0x341)
				local mstatus = cpu.regs:readCSR(0x300)
				-- Restore MIE from MPIE (bit 3 from bit 7)
				local mpie = bit32.band(bit32.rshift(mstatus, 7), 1)
				mstatus = bit32.bor(
					bit32.band(mstatus, bit32.bnot(0x88)), -- clear MIE and MPIE
					bit32.lshift(mpie, 3), -- restore MIE
					bit32.lshift(1, 7)     -- set MPIE
				)
				-- Restore privilege from MPP (bits 12:11)
				local mpp = bit32.band(bit32.rshift(mstatus, 11), 3)
				cpu.regs.privLevel = mpp
				-- Clear MPP
				mstatus = bit32.band(mstatus, bit32.bnot(bit32.lshift(3, 11)))
				cpu.regs:writeCSR(0x300, mstatus)
				cpu.branchTarget = mepc
				cpu.branchTaken = true
				
			elseif imm == 0x102 then
				-- SRET: return from supervisor-mode trap
				local sepc = cpu.regs:readCSR(0x141)
				local sstatus = cpu.regs:readCSR(0x100)
				-- Restore SIE from SPIE
				local spie = bit32.band(bit32.rshift(sstatus, 5), 1)
				sstatus = bit32.bor(
					bit32.band(sstatus, bit32.bnot(0x22)), -- clear SIE and SPIE
					bit32.lshift(spie, 1), -- restore SIE
					bit32.lshift(1, 5)     -- set SPIE
				)
				-- Restore privilege from SPP (bit 8)
				local spp = bit32.band(bit32.rshift(sstatus, 8), 1)
				cpu.regs.privLevel = spp
				-- Clear SPP
				sstatus = bit32.band(sstatus, bit32.bnot(bit32.lshift(1, 8)))
				cpu.regs:writeCSR(0x100, sstatus)
				cpu.branchTarget = sepc
				cpu.branchTaken = true
				
			elseif imm == 0x105 then
				-- WFI: wait for interrupt (treat as NOP for now)
				-- In a real impl, this would sleep until an interrupt fires
			end
		end,
		
		-- CSRRW (funct3 = 1)
		[1] = function(cpu, d)
			local csrAddr = bit32.band(bit32.rshift(d.raw, 20), 0xFFF)
			local old = cpu.regs:readCSR(csrAddr)
			cpu.regs:writeCSR(csrAddr, cpu.regs:read(d.rs1))
			cpu.regs:write(d.rd, old)
		end,
		
		-- CSRRS (funct3 = 2)
		[2] = function(cpu, d)
			local csrAddr = bit32.band(bit32.rshift(d.raw, 20), 0xFFF)
			local old = cpu.regs:readCSR(csrAddr)
			if d.rs1 ~= 0 then
				cpu.regs:writeCSR(csrAddr, bit32.bor(old, cpu.regs:read(d.rs1)))
			end
			cpu.regs:write(d.rd, old)
		end,
		
		-- CSRRC (funct3 = 3)
		[3] = function(cpu, d)
			local csrAddr = bit32.band(bit32.rshift(d.raw, 20), 0xFFF)
			local old = cpu.regs:readCSR(csrAddr)
			if d.rs1 ~= 0 then
				cpu.regs:writeCSR(csrAddr, bit32.band(old, bit32.bnot(cpu.regs:read(d.rs1))))
			end
			cpu.regs:write(d.rd, old)
		end,
		
		-- CSRRWI (funct3 = 5)
		[5] = function(cpu, d)
			local csrAddr = bit32.band(bit32.rshift(d.raw, 20), 0xFFF)
			local old = cpu.regs:readCSR(csrAddr)
			cpu.regs:writeCSR(csrAddr, d.rs1) -- rs1 field is the zimm
			cpu.regs:write(d.rd, old)
		end,
		
		-- CSRRSI (funct3 = 6)
		[6] = function(cpu, d)
			local csrAddr = bit32.band(bit32.rshift(d.raw, 20), 0xFFF)
			local old = cpu.regs:readCSR(csrAddr)
			if d.rs1 ~= 0 then
				cpu.regs:writeCSR(csrAddr, bit32.bor(old, d.rs1))
			end
			cpu.regs:write(d.rd, old)
		end,
		
		-- CSRRCI (funct3 = 7)
		[7] = function(cpu, d)
			local csrAddr = bit32.band(bit32.rshift(d.raw, 20), 0xFFF)
			local old = cpu.regs:readCSR(csrAddr)
			if d.rs1 ~= 0 then
				cpu.regs:writeCSR(csrAddr, bit32.band(old, bit32.bnot(d.rs1)))
			end
			cpu.regs:write(d.rd, old)
		end,
	},
}

return module
