--!strict
--[[
	RV32I_Mem.lua - Load and Store instructions
	
	Place in: ReplicatedStorage/RISCVModules/InstructionSets/RV32I_Mem
	
	Covers:
		LOAD  (0x03): LB, LH, LW, LBU, LHU
		STORE (0x23): SB, SH, SW
]]

local function toU32(v) return v % 0x100000000 end
local function signExtend8(v)
	if v >= 0x80 then return v - 0x100 end
	return v
end
local function signExtend16(v)
	if v >= 0x8000 then return v - 0x10000 end
	return v
end

local module = {}

module.name = "RV32I_Mem"
module.description = "Load and store instructions (byte, halfword, word)"

module.instructions = {
	-- LOAD (opcode 0x03)
	[0x03] = {
		[0] = function(cpu, d) -- LB
			local addr = toU32(cpu.regs:read(d.rs1) + d.imm)
			local val = signExtend8(cpu.mem:read8(addr))
			cpu.regs:write(d.rd, toU32(val))
		end,
		[1] = function(cpu, d) -- LH
			local addr = toU32(cpu.regs:read(d.rs1) + d.imm)
			local val = signExtend16(cpu.mem:read16(addr))
			cpu.regs:write(d.rd, toU32(val))
		end,
		[2] = function(cpu, d) -- LW
			local addr = toU32(cpu.regs:read(d.rs1) + d.imm)
			cpu.regs:write(d.rd, cpu.mem:read32(addr))
		end,
		[4] = function(cpu, d) -- LBU
			local addr = toU32(cpu.regs:read(d.rs1) + d.imm)
			cpu.regs:write(d.rd, cpu.mem:read8(addr))
		end,
		[5] = function(cpu, d) -- LHU
			local addr = toU32(cpu.regs:read(d.rs1) + d.imm)
			cpu.regs:write(d.rd, cpu.mem:read16(addr))
		end,
	},
	
	-- STORE (opcode 0x23)
	[0x23] = {
		[0] = function(cpu, d) -- SB
			local addr = toU32(cpu.regs:read(d.rs1) + d.imm)
			cpu.mem:write8(addr, cpu.regs:read(d.rs2))
		end,
		[1] = function(cpu, d) -- SH
			local addr = toU32(cpu.regs:read(d.rs1) + d.imm)
			cpu.mem:write16(addr, cpu.regs:read(d.rs2))
		end,
		[2] = function(cpu, d) -- SW
			local addr = toU32(cpu.regs:read(d.rs1) + d.imm)
			cpu.mem:write32(addr, cpu.regs:read(d.rs2))
		end,
	},
}

return module
