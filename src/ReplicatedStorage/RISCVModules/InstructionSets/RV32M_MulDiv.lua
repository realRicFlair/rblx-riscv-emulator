--[[
	RV32M_MulDiv.lua - Multiply/Divide extension
	
	Place in: ReplicatedStorage/RISCVModules/InstructionSets/RV32M_MulDiv
	
	Covers opcode 0x33 with funct7 = 0x01:
		MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU
	
	EXAMPLE OF EXTENDING THE EMULATOR:
	This module demonstrates how to add a new extension.
	It shares opcode 0x33 with RV32I_ALU but uses funct7=0x01
	to distinguish. The CPU dispatcher checks funct7 when
	the "useFunct7" flag is set.
]]

local function toU32(v) return v % 0x100000000 end
local function toI32(v)
	v = v % 0x100000000
	if v >= 0x80000000 then return v - 0x100000000 end
	return v
end

local module = {}

module.name = "RV32M_MulDiv"
module.description = "RV32M: MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU"

-- This flag tells the CPU to also check funct7 when dispatching
-- Since this extension shares opcode 0x33 with the base ALU
module.useFunct7 = true
module.funct7 = 0x01

module.instructions = {
	[0x33] = {
		[0] = function(cpu, d) -- MUL (lower 32 bits)
			local a = toI32(cpu.regs:read(d.rs1))
			local b = toI32(cpu.regs:read(d.rs2))
			cpu.regs:write(d.rd, toU32(a * b))
		end,
		[1] = function(cpu, d) -- MULH (upper 32 bits, signed x signed)
			local a = toI32(cpu.regs:read(d.rs1))
			local b = toI32(cpu.regs:read(d.rs2))
			-- Use Lua's native 64-bit floats for the full product
			local product = a * b
			local upper = math.floor(product / 0x100000000)
			cpu.regs:write(d.rd, toU32(upper))
		end,
		[2] = function(cpu, d) -- MULHSU (signed x unsigned)
			local a = toI32(cpu.regs:read(d.rs1))
			local b = toU32(cpu.regs:read(d.rs2))
			local product = a * b
			local upper = math.floor(product / 0x100000000)
			cpu.regs:write(d.rd, toU32(upper))
		end,
		[3] = function(cpu, d) -- MULHU (unsigned x unsigned)
			local a = toU32(cpu.regs:read(d.rs1))
			local b = toU32(cpu.regs:read(d.rs2))
			local product = a * b
			local upper = math.floor(product / 0x100000000)
			cpu.regs:write(d.rd, toU32(upper))
		end,
		[4] = function(cpu, d) -- DIV (signed)
			local a = toI32(cpu.regs:read(d.rs1))
			local b = toI32(cpu.regs:read(d.rs2))
			if b == 0 then
				cpu.regs:write(d.rd, 0xFFFFFFFF) -- division by zero
			elseif a == -2147483648 and b == -1 then
				cpu.regs:write(d.rd, toU32(a)) -- overflow
			else
				-- Truncate toward zero
				local result = a / b
				result = result >= 0 and math.floor(result) or -math.floor(-result)
				cpu.regs:write(d.rd, toU32(result))
			end
		end,
		[5] = function(cpu, d) -- DIVU (unsigned)
			local a = toU32(cpu.regs:read(d.rs1))
			local b = toU32(cpu.regs:read(d.rs2))
			if b == 0 then
				cpu.regs:write(d.rd, 0xFFFFFFFF)
			else
				cpu.regs:write(d.rd, math.floor(a / b))
			end
		end,
		[6] = function(cpu, d) -- REM (signed, truncated toward zero)
			local a = toI32(cpu.regs:read(d.rs1))
			local b = toI32(cpu.regs:read(d.rs2))
			if b == 0 then
				cpu.regs:write(d.rd, toU32(a))
			elseif a == -2147483648 and b == -1 then
				cpu.regs:write(d.rd, 0) -- overflow
			else
				-- Truncated division: remainder follows sign of dividend
				local q = a / b
				q = q >= 0 and math.floor(q) or -math.floor(-q)
				cpu.regs:write(d.rd, toU32(a - q * b))
			end
		end,
		[7] = function(cpu, d) -- REMU (unsigned)
			local a = toU32(cpu.regs:read(d.rs1))
			local b = toU32(cpu.regs:read(d.rs2))
			if b == 0 then
				cpu.regs:write(d.rd, toU32(a))
			else
				cpu.regs:write(d.rd, a % b)
			end
		end,
	},
}

return module
