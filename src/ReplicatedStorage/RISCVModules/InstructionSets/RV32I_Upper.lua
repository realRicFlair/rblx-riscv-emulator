--[[
	RV32I_Upper.lua - Upper-immediate, jump, and fence instructions
	
	Place in: ReplicatedStorage/RISCVModules/InstructionSets/RV32I_Upper
	
	Covers:
		LUI   (0x37): Load Upper Immediate
		AUIPC (0x17): Add Upper Immediate to PC
		JAL   (0x6F): Jump And Link
		JALR  (0x67): Jump And Link Register
		FENCE   (0x0F, funct3=0): Memory fence (NOP in this emulator)
		FENCE.I (0x0F, funct3=1): Instruction fence (NOP in this emulator)
]]

local function toU32(v) return v % 0x100000000 end

local module = {}

module.name = "RV32I_Upper"
module.description = "LUI, AUIPC, JAL, JALR, FENCE, FENCE.I"

module.instructions = {
	-- LUI (opcode 0x37) - no funct3 dispatch, use special key
	[0x37] = {
		["_all"] = function(cpu, d)
			cpu.regs:write(d.rd, toU32(d.imm))
		end,
	},
	
	-- AUIPC (opcode 0x17)
	[0x17] = {
		["_all"] = function(cpu, d)
			cpu.regs:write(d.rd, toU32(cpu.regs.pc + d.imm))
		end,
	},
	
	-- JAL (opcode 0x6F)
	[0x6F] = {
		["_all"] = function(cpu, d)
			cpu.regs:write(d.rd, toU32(cpu.regs.pc + 4))
			cpu.branchTarget = toU32(cpu.regs.pc + d.imm)
			cpu.branchTaken = true
		end,
	},
	
	-- JALR (opcode 0x67)
	[0x67] = {
		[0] = function(cpu, d)
			local target = toU32(cpu.regs:read(d.rs1) + d.imm)
			target = bit32.band(target, 0xFFFFFFFE) -- clear bit 0
			cpu.regs:write(d.rd, toU32(cpu.regs.pc + 4))
			cpu.branchTarget = target
			cpu.branchTaken = true
		end,
	},
	
	-- FENCE (opcode 0x0F, funct3=0) - NOP for single-hart emulator
	[0x0F] = {
		[0] = function(cpu, d)
			-- No-op: memory ordering is inherently sequential here
		end,
		-- FENCE.I (funct3=1) - Instruction cache fence
		-- NOP for us (no instruction cache), but the SBI firmware uses it
		[1] = function(cpu, d)
			-- No-op: we don't cache decoded instructions
		end,
	},
}

return module