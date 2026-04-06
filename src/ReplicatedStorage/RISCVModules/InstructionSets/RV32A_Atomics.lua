--[[
	RV32A_Atomics.lua - Atomic memory operations
	
	Place in: ReplicatedStorage/RISCVModules/InstructionSets/RV32A_Atomics
	
	Covers:
		AMO (0x2F): LR.W, SC.W, AMOSWAP.W, AMOADD.W, AMOXOR.W, 
		            AMOAND.W, AMOOR.W, AMOMIN.W, AMOMAX.W, 
		            AMOMINU.W, AMOMAXU.W
	
	NOTE: Requires cpu.reservationSet state for LR/SC pair to work.
]]

local function toU32(v) return v % 0x100000000 end
local function toI32(v)
	v = v % 0x100000000
	if v >= 0x80000000 then return v - 0x100000000 end
	return v
end

local module = {}

module.name = "RV32A_Atomics"
module.description = "Atomic memory operations (LR.W, SC.W, AMO*)"

module.instructions = {
	[0x2F] = {
		[2] = function(cpu, d) -- funct3 = 2 means 32-bit word operation
			
			-- The actual operation is stored in the top 5 bits of funct7.
			-- We shift right by 2 to ignore the 'aq' and 'rl' ordering bits.
			local amo_op = bit32.rshift(d.funct7, 2)
			local addr = cpu.regs:read(d.rs1)

			-- ENFORCE ALIGNMENT FOR ATOMICS: Address must be a multiple of 4
			if addr % 4 ~= 0 then
			    if cpu.trap then
			        -- Trap Cause 6: Store/AMO address misaligned
			        -- Trap Cause 4: Load address misaligned (for LR.W)
			        local cause = (amo_op == 0x02) and 4 or 6
			        cpu:trap(cause, addr)
			    end
			    return -- Halt instruction execution
			end
			
			-- Helper function for standard AMO operations:
			-- Read from memory, perform operation with rs2, write new value to memory, 
			-- and write the *original* memory value to rd.
			local function performAMO(operationCallback)
				local valInMem = cpu.mem:read32(addr)
				local valInReg = cpu.regs:read(d.rs2)
				
				local result = operationCallback(valInMem, valInReg)
				
				cpu.mem:write32(addr, result)
				cpu.regs:write(d.rd, valInMem) 
			end

			

			if amo_op == 0x02 then 
				-- LR.W (Load Reserved)
				local val = cpu.mem:read32(addr)
				cpu.reservationSet = addr -- Place a reservation on this address
				cpu.regs:write(d.rd, val)
				
			elseif amo_op == 0x03 then 
				-- SC.W (Store Conditional)
				if cpu.reservationSet == addr then
					-- Reservation is valid: write to memory, return 0 (success)
					cpu.mem:write32(addr, cpu.regs:read(d.rs2))
					cpu.regs:write(d.rd, 0)
					cpu.reservationSet = nil -- Clear reservation
				else
					-- Reservation invalid: do not write, return non-zero (failure)
					cpu.regs:write(d.rd, 1) 
				end
				
			elseif amo_op == 0x01 then -- AMOSWAP.W
				performAMO(function(mem, reg) return reg end)
				
			elseif amo_op == 0x00 then -- AMOADD.W
				performAMO(function(mem, reg) return toU32(mem + reg) end)
				
			elseif amo_op == 0x04 then -- AMOXOR.W
				performAMO(function(mem, reg) return bit32.bxor(mem, reg) end)
				
			elseif amo_op == 0x0C then -- AMOAND.W
				performAMO(function(mem, reg) return bit32.band(mem, reg) end)
				
			elseif amo_op == 0x08 then -- AMOOR.W
				performAMO(function(mem, reg) return bit32.bor(mem, reg) end)
				
			elseif amo_op == 0x10 then -- AMOMIN.W
				performAMO(function(mem, reg) return toI32(mem) < toI32(reg) and mem or reg end)
				
			elseif amo_op == 0x14 then -- AMOMAX.W
				performAMO(function(mem, reg) return toI32(mem) > toI32(reg) and mem or reg end)
				
			elseif amo_op == 0x18 then -- AMOMINU.W
				performAMO(function(mem, reg) return toU32(mem) < toU32(reg) and mem or reg end)
				
			elseif amo_op == 0x1C then -- AMOMAXU.W
				performAMO(function(mem, reg) return toU32(mem) > toU32(reg) and mem or reg end)
				
			else
				-- Illegal Instruction (Instruction page fault / illegal instruction trap)
				if cpu.trap then
					cpu:trap(2, d.raw) 
				end
			end
		end,
	},
}

return module