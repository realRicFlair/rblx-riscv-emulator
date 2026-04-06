--[[
	_Template.lua - COPY THIS FILE TO CREATE NEW INSTRUCTION EXTENSIONS
	
	Place in: ReplicatedStorage/RISCVModules/InstructionSets/<YourExtensionName>
	
	=== HOW TO ADD NEW INSTRUCTIONS ===
	
	1. Copy this file and rename it (e.g., "RV32A_Atomics")
	2. Set module.name and module.description
	3. Add your instruction handlers to module.instructions
	4. The CPU auto-discovers all ModuleScripts in InstructionSets/
	5. No other code changes needed!
	
	=== HANDLER STRUCTURE ===
	
	module.instructions = {
		[OPCODE] = {                        -- 7-bit opcode (e.g., 0x33 for OP)
			[FUNCT3] = function(cpu, d)     -- 3-bit function code
				-- d = decoded instruction with fields:
				--   d.raw     : full 32-bit instruction word
				--   d.opcode  : 7-bit opcode
				--   d.rd      : destination register index (0-31)
				--   d.rs1     : source register 1 index (0-31)
				--   d.rs2     : source register 2 index (0-31)
				--   d.funct3  : 3-bit function code
				--   d.funct7  : 7-bit function code (R-type)
				--   d.imm     : sign-extended immediate
				--   d.format  : "R", "I", "S", "B", "U", "J"
				
				-- Access registers:
				--   cpu.regs:read(index) -> uint32
				--   cpu.regs:write(index, value)
				--   cpu.regs.pc -> current PC
				
				-- Access memory:
				--   cpu.mem:read8/16/32(addr) -> value
				--   cpu.mem:write8/16/32(addr, value)
				
				-- For branches/jumps:
				--   cpu.branchTaken = true
				--   cpu.branchTarget = targetAddress
				
				-- For traps/exceptions:
				--   cpu:trap(cause, tval)
				
				-- CSR access:
				--   cpu.regs:readCSR(addr) -> value
				--   cpu.regs:writeCSR(addr, value)
			end,
		},
	}
	
	=== SPECIAL KEYS ===
	
	["_all"] : Catches ALL funct3 values for an opcode.
	           Used for U-type and J-type that don't use funct3.
	           Example: LUI (0x37) uses ["_all"]
	
	=== SHARING OPCODES (funct7 disambiguation) ===
	
	If your extension shares an opcode with another (like M-extension
	shares 0x33 with base ALU), set these flags:
	
	module.useFunct7 = true
	module.funct7 = 0x01  -- your funct7 value
	
	The CPU will check funct7 before dispatching.
	
	=== HELPER FUNCTIONS YOU'LL LIKELY NEED ===
	
	local function toU32(v) return v % 0x100000000 end
	local function toI32(v)
		v = v % 0x100000000
		if v >= 0x80000000 then return v - 0x100000000 end
		return v
	end
	
	=== LINUX ROADMAP - EXTENSIONS STILL NEEDED ===
	
	Priority order for running Linux:
	1. [DONE] RV32I   - Base integer (this emulator)
	2. [DONE] RV32M   - Multiply/Divide
	3. [TODO] RV32A   - Atomics (LR.W, SC.W, AMO*)
	4. [TODO] Sv32    - Virtual memory / MMU (in Memory.lua)
	5. [TODO] PLIC    - Platform-Level Interrupt Controller
	6. [TODO] CLINT   - Core Local Interruptor (timer)
	7. [TODO] RV32F   - Single-precision float (optional)
	8. [TODO] RV32C   - Compressed instructions (optional, 16-bit)
]]

local function toU32(v) return v % 0x100000000 end
local function toI32(v)
	v = v % 0x100000000
	if v >= 0x80000000 then return v - 0x100000000 end
	return v
end

local module = {}

module.name = "_Template"
module.description = "Template module - copy and modify this!"

-- Uncomment if this extension shares an opcode with another module:
-- module.useFunct7 = true
-- module.funct7 = 0x00

module.instructions = {
	-- Example: a hypothetical instruction at opcode 0x0B, funct3=0
	-- [0x0B] = {
	--     [0] = function(cpu, d)
	--         -- Your instruction logic here
	--         local result = cpu.regs:read(d.rs1) + cpu.regs:read(d.rs2)
	--         cpu.regs:write(d.rd, toU32(result))
	--     end,
	-- },
}

return module
