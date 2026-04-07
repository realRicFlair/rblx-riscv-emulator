
--[[
	RV32I_Branch.lua - Conditional branch instructions
	
	Place in: ReplicatedStorage/RISCVModules/InstructionSets/RV32I_Branch
	
	Covers:
		BRANCH (0x63): BEQ, BNE, BLT, BGE, BLTU, BGEU
	
	NOTE: Branch handlers set cpu.branchTaken = true and cpu.branchTarget
	      so the CPU loop knows not to advance PC by 4.
]]

local function toU32(v) 
	return v % 0x100000000 
end
local function toI32(v)
	v = v % 0x100000000
	if v >= 0x80000000 then return v - 0x100000000 end
	return v
end

local module = {}

module.name = "RV32I_Branch"
module.description = "Conditional branches: BEQ, BNE, BLT, BGE, BLTU, BGEU"

module.lastbrnchtrgt = 0

local function branch(cpu, d, condition)
	if condition then 
		cpu.branchTarget = toU32(cpu.regs.pc + d.imm)
		cpu.branchTaken = true
	
		--[[
		if module.lastbrnchtrgt ~= cpu.branchTarget then
			print("Branching to 0x" .. cpu.branchTarget .. " from 0x" .. cpu.regs.pc .. "")
			module.lastbrnchtrgt = cpu.branchTarget
		end
		]]
	end
end

module.instructions = {
	[0x63] = {
		[0] = function(cpu, d) -- BEQ
			branch(cpu, d, cpu.regs:read(d.rs1) == cpu.regs:read(d.rs2))
		end,
		[1] = function(cpu, d) -- BNE
			branch(cpu, d, cpu.regs:read(d.rs1) ~= cpu.regs:read(d.rs2))
		end,
		[4] = function(cpu, d) -- BLT
			branch(cpu, d, toI32(cpu.regs:read(d.rs1)) < toI32(cpu.regs:read(d.rs2)))
		end,
		[5] = function(cpu, d) -- BGE
			branch(cpu, d, toI32(cpu.regs:read(d.rs1)) >= toI32(cpu.regs:read(d.rs2)))
		end,
		[6] = function(cpu, d) -- BLTU
			branch(cpu, d, toU32(cpu.regs:read(d.rs1)) < toU32(cpu.regs:read(d.rs2)))
		end,
		[7] = function(cpu, d) -- BGEU
			branch(cpu, d, toU32(cpu.regs:read(d.rs1)) >= toU32(cpu.regs:read(d.rs2)))
		end,
	},
}

return module
