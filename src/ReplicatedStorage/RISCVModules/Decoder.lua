--[[
	Decoder.lua - RISC-V instruction decoder
	
	Place in: ReplicatedStorage/RISCVModules/Decoder
	
	Decodes a 32-bit instruction word into a table with all relevant fields.
	Instruction format detection is automatic based on opcode.
	
	Returned decoded table fields:
		.raw     : original 32-bit instruction
		.opcode  : bits [6:0]
		.rd      : bits [11:7]
		.funct3  : bits [14:12]
		.rs1     : bits [19:15]
		.rs2     : bits [24:20]
		.funct7  : bits [31:25]
		.imm     : sign-extended immediate (varies by format)
		.format  : "R", "I", "S", "B", "U", "J", or "UNKNOWN"
]]

local Decoder = {}

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function signExtend(value, bits)
	if bit32.btest(value, bit32.lshift(1, bits - 1)) then
		return value - bit32.lshift(1, bits)
	end
	return value
end

-- Opcode -> format mapping
local FORMAT_MAP = {
	[0x33] = "R",  -- OP       (register-register ALU)
	[0x13] = "I",  -- OP-IMM   (immediate ALU)
	[0x03] = "I",  -- LOAD
	[0x67] = "I",  -- JALR
	[0x73] = "I",  -- SYSTEM   (ECALL/EBREAK/CSR)
	[0x0F] = "I",  -- MISC-MEM (FENCE)
	[0x23] = "S",  -- STORE
	[0x63] = "B",  -- BRANCH
	[0x37] = "U",  -- LUI
	[0x17] = "U",  -- AUIPC
	[0x6F] = "J",  -- JAL
	-- RV32M (multiply/divide) uses R-format with opcode 0x33
	-- RV32A (atomics) uses R-format with opcode 0x2F
	[0x2F] = "R",  -- AMO (atomics)
}

--------------------------------------------------------------------------------
-- MAIN DECODE
--------------------------------------------------------------------------------

function Decoder.decode(instruction)
	local d = {}
	d.raw = instruction
	
	-- Extract common fields
	d.opcode = bit32.band(instruction, 0x7F)
	d.rd     = bit32.band(bit32.rshift(instruction, 7), 0x1F)
	d.funct3 = bit32.band(bit32.rshift(instruction, 12), 0x07)
	d.rs1    = bit32.band(bit32.rshift(instruction, 15), 0x1F)
	d.rs2    = bit32.band(bit32.rshift(instruction, 20), 0x1F)
	d.funct7 = bit32.band(bit32.rshift(instruction, 25), 0x7F)
	
	-- Determine format and extract immediate
	d.format = FORMAT_MAP[d.opcode] or "UNKNOWN"
	
	if d.format == "I" then
		-- imm[11:0] = inst[31:20]
		d.imm = signExtend(bit32.rshift(instruction, 20), 12)
		
	elseif d.format == "S" then
		-- imm[4:0]  = inst[11:7]
		-- imm[11:5] = inst[31:25]
		local lo = bit32.band(bit32.rshift(instruction, 7), 0x1F)
		local hi = bit32.band(bit32.rshift(instruction, 25), 0x7F)
		d.imm = signExtend(bit32.bor(lo, bit32.lshift(hi, 5)), 12)
		
	elseif d.format == "B" then
		-- imm[12|10:5|4:1|11]
		local b11  = bit32.band(bit32.rshift(instruction, 7), 1)
		local b4_1 = bit32.band(bit32.rshift(instruction, 8), 0xF)
		local b10_5 = bit32.band(bit32.rshift(instruction, 25), 0x3F)
		local b12  = bit32.band(bit32.rshift(instruction, 31), 1)
		d.imm = signExtend(
			bit32.bor(
				bit32.lshift(b4_1, 1),
				bit32.lshift(b11, 11),
				bit32.lshift(b10_5, 5),
				bit32.lshift(b12, 12)
			), 13)
		
	elseif d.format == "U" then
		-- imm[31:12] = inst[31:12], lower 12 bits are zero
		d.imm = bit32.band(instruction, 0xFFFFF000)
		-- Sign extend for Lua number range
		if d.imm >= 0x80000000 then
			d.imm = d.imm - 0x100000000
		end
		
	elseif d.format == "J" then
		-- imm[20|10:1|11|19:12]
		local b19_12 = bit32.band(bit32.rshift(instruction, 12), 0xFF)
		local b11    = bit32.band(bit32.rshift(instruction, 20), 1)
		local b10_1  = bit32.band(bit32.rshift(instruction, 21), 0x3FF)
		local b20    = bit32.band(bit32.rshift(instruction, 31), 1)
		d.imm = signExtend(
			bit32.bor(
				bit32.lshift(b10_1, 1),
				bit32.lshift(b11, 11),
				bit32.lshift(b19_12, 12),
				bit32.lshift(b20, 20)
			), 21)
		
	elseif d.format == "R" then
		d.imm = 0 -- R-type has no immediate
		
	else
		d.imm = 0
	end
	
	return d
end

-- Utility: disassemble a decoded instruction to a readable string (for debug)
function Decoder.disassemble(d)
	return string.format(
		"[%08X] op=%02X rd=x%d rs1=x%d rs2=x%d f3=%d f7=%02X imm=%d fmt=%s",
		d.raw, d.opcode, d.rd, d.rs1, d.rs2, d.funct3, d.funct7, d.imm, d.format
	)
end

return Decoder
