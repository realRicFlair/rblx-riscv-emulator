--[[
	RV32I_ALU.lua - Integer ALU instructions
	
	Place in: ReplicatedStorage/RISCVModules/InstructionSets/RV32I_ALU
	
	Covers:
		OP-IMM (0x13): ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI
		OP     (0x33): ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND
]]

local function toU32(v) return v % 0x100000000 end
local function toI32(v)
	v = v % 0x100000000
	if v >= 0x80000000 then return v - 0x100000000 end
	return v
end

local module = {}

module.name = "RV32I_ALU"
module.description = "Base integer ALU: register-register and register-immediate ops"

module.instructions = {
	-- OP-IMM (opcode 0x13)
	[0x13] = {
		-- funct3 -> handler(cpu, decoded)
		[0] = function(cpu, d) -- ADDI
			cpu.regs:write(d.rd, toU32(cpu.regs:read(d.rs1) + d.imm))
		end,
		[1] = function(cpu, d) -- SLLI
			local shamt = bit32.band(d.imm, 0x1F)
			cpu.regs:write(d.rd, bit32.lshift(cpu.regs:read(d.rs1), shamt))
		end,
		[2] = function(cpu, d) -- SLTI
			local rs1 = toI32(cpu.regs:read(d.rs1))
			cpu.regs:write(d.rd, rs1 < d.imm and 1 or 0)
		end,
		[3] = function(cpu, d) -- SLTIU
			local rs1 = toU32(cpu.regs:read(d.rs1))
			local imm = toU32(d.imm)
			cpu.regs:write(d.rd, rs1 < imm and 1 or 0)
		end,
		[4] = function(cpu, d) -- XORI
			cpu.regs:write(d.rd, bit32.bxor(cpu.regs:read(d.rs1), toU32(d.imm)))
		end,
		[5] = function(cpu, d) -- SRLI / SRAI
			local shamt = bit32.band(d.imm, 0x1F)
			local rs1 = cpu.regs:read(d.rs1)
			if bit32.btest(d.funct7, 0x20) then
				-- SRAI
				cpu.regs:write(d.rd, bit32.arshift(rs1, shamt))
			else
				-- SRLI
				cpu.regs:write(d.rd, bit32.rshift(rs1, shamt))
			end
		end,
		[6] = function(cpu, d) -- ORI
			cpu.regs:write(d.rd, bit32.bor(cpu.regs:read(d.rs1), toU32(d.imm)))
		end,
		[7] = function(cpu, d) -- ANDI
			cpu.regs:write(d.rd, bit32.band(cpu.regs:read(d.rs1), toU32(d.imm)))
		end,
	},
	
	-- OP (opcode 0x33)
	[0x33] = {
		[0] = function(cpu, d) -- ADD / SUB
			local rs1 = cpu.regs:read(d.rs1)
			local rs2 = cpu.regs:read(d.rs2)
			if d.funct7 == 0x20 then
				cpu.regs:write(d.rd, toU32(rs1 - rs2)) -- SUB
			else
				cpu.regs:write(d.rd, toU32(rs1 + rs2)) -- ADD
			end
		end,
		[1] = function(cpu, d) -- SLL
			local shamt = bit32.band(cpu.regs:read(d.rs2), 0x1F)
			cpu.regs:write(d.rd, bit32.lshift(cpu.regs:read(d.rs1), shamt))
		end,
		[2] = function(cpu, d) -- SLT
			cpu.regs:write(d.rd, toI32(cpu.regs:read(d.rs1)) < toI32(cpu.regs:read(d.rs2)) and 1 or 0)
		end,
		[3] = function(cpu, d) -- SLTU
			cpu.regs:write(d.rd, toU32(cpu.regs:read(d.rs1)) < toU32(cpu.regs:read(d.rs2)) and 1 or 0)
		end,
		[4] = function(cpu, d) -- XOR
			cpu.regs:write(d.rd, bit32.bxor(cpu.regs:read(d.rs1), cpu.regs:read(d.rs2)))
		end,
		[5] = function(cpu, d) -- SRL / SRA
			local shamt = bit32.band(cpu.regs:read(d.rs2), 0x1F)
			if d.funct7 == 0x20 then
				cpu.regs:write(d.rd, bit32.arshift(cpu.regs:read(d.rs1), shamt)) -- SRA
			else
				cpu.regs:write(d.rd, bit32.rshift(cpu.regs:read(d.rs1), shamt)) -- SRL
			end
		end,
		[6] = function(cpu, d) -- OR
			cpu.regs:write(d.rd, bit32.bor(cpu.regs:read(d.rs1), cpu.regs:read(d.rs2)))
		end,
		[7] = function(cpu, d) -- AND
			cpu.regs:write(d.rd, bit32.band(cpu.regs:read(d.rs1), cpu.regs:read(d.rs2)))
		end,
	},
}

return module
