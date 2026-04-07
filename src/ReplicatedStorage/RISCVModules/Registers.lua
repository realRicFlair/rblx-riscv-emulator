--[[
	Registers.lua - RISC-V register file + CSRs
	
	Place in: ReplicatedStorage/RISCVModules/Registers
	
	x0 is hardwired to 0 (writes are silently ignored).
	All values are unsigned 32-bit internally.
	
	CSRs include Machine + Supervisor level registers needed for Linux.
]]

local Registers = {}
Registers.__index = Registers

export type Registers = typeof(setmetatable({} :: {
	x: {[number]: number},
	pc: number,
	csr: {[number]: number},
	privLevel: number,
}, Registers))

-- ABI register names for debug display
Registers.ABI_NAMES = {
	[0]="zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
	"s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
	"a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
	"s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"
}

function Registers.new()
	local self = setmetatable({}, Registers)
	
	-- General-purpose registers x0-x31
	self.x = {}
	for i = 0, 31 do
		self.x[i] = 0
	end
	
	-- Program counter
	self.pc = 0x80000000
	
	-- CSR storage
	self.csr = {}
	self:_initCSRs()
	
	-- Privilege level: 0=User, 1=Supervisor, 3=Machine
	self.privLevel = 3
	
	return self
end

--------------------------------------------------------------------------------
-- GPR ACCESS
--------------------------------------------------------------------------------

function Registers:read(index)
	if index == 0 then return 0 end
	return self.x[index] or 0
end

function Registers:write(index, value)
	if index == 0 then return end
	self.x[index] = bit32.band(value, 0xFFFFFFFF)
end

--------------------------------------------------------------------------------
-- CSR ACCESS
--------------------------------------------------------------------------------

function Registers:_initCSRs()
	-- Machine-level CSRs
	self.csr[0x300] = 0          -- mstatus
	-- misa: MXL=1 (32-bit), extensions: I(8) M(12) A(0) S(18) U(20)
	self.csr[0x301] = 0x40141101 -- rv32imasu
	self.csr[0x302] = 0          -- medeleg
	self.csr[0x303] = 0          -- mideleg
	self.csr[0x304] = 0          -- mie
	self.csr[0x305] = 0          -- mtvec
	self.csr[0x306] = 0          -- mcounteren
	self.csr[0x310] = 0          -- mstatush (rv32 only)
	self.csr[0x340] = 0          -- mscratch
	self.csr[0x341] = 0          -- mepc
	self.csr[0x342] = 0          -- mcause
	self.csr[0x343] = 0          -- mtval
	self.csr[0x344] = 0          -- mip
	
	-- Physical Memory Protection (stubs - Linux checks for them)
	for i = 0, 3 do
		self.csr[0x3A0 + i] = 0  -- pmpcfg0-3
	end
	for i = 0, 15 do
		self.csr[0x3B0 + i] = 0  -- pmpaddr0-15
	end
	
	-- Machine info
	self.csr[0xF11] = 0          -- mvendorid
	self.csr[0xF12] = 0          -- marchid
	self.csr[0xF13] = 0          -- mimpid
	self.csr[0xF14] = 0          -- mhartid
	
	-- Supervisor-level CSRs
	self.csr[0x100] = 0          -- sstatus (view of mstatus)
	self.csr[0x104] = 0          -- sie (view of mie)
	self.csr[0x105] = 0          -- stvec
	self.csr[0x106] = 0          -- scounteren
	self.csr[0x140] = 0          -- sscratch
	self.csr[0x141] = 0          -- sepc
	self.csr[0x142] = 0          -- scause
	self.csr[0x143] = 0          -- stval
	self.csr[0x144] = 0          -- sip (view of mip)
	self.csr[0x180] = 0          -- satp
	
	-- Counters
	self.csr[0xC00] = 0          -- cycle
	self.csr[0xC01] = 0          -- time
	self.csr[0xC02] = 0          -- instret
	self.csr[0xC80] = 0          -- cycleh
	self.csr[0xC81] = 0          -- timeh
	self.csr[0xC82] = 0          -- instreth
end

-- Masks for sstatus bits visible from mstatus
local SSTATUS_MASK = bit32.bor(
	0x000C0122,   -- SIE, SPIE, SPP, FS, VS
	bit32.lshift(1, 18), -- SUM
	bit32.lshift(1, 19), -- MXR
	bit32.lshift(1, 8),  -- SPP
	0x000E0000   -- bits 19:17 (MXR, SUM, etc.)
)
-- Corrected: sstatus reads these bits from mstatus
local SSTATUS_READ_MASK = 0x800DE762
-- SIE(1), SPIE(5), UBE(6), SPP(8), VS(10:9), FS(14:13), 
-- XS(16:15), SUM(18), MXR(19), SD(31)

function Registers:readCSR(addr)
	addr = bit32.band(addr, 0xFFF)
	
	-- sstatus is a filtered view of mstatus
	if addr == 0x100 then
		return bit32.band(self.csr[0x300] or 0, SSTATUS_READ_MASK)
	end
	
	-- sie is a filtered view of mie (supervisor interrupt bits: SSIE, STIE, SEIE)
	if addr == 0x104 then
		return bit32.band(self.csr[0x304] or 0, 0x222) -- bits 1, 5, 9
	end
	
	-- sip is a filtered view of mip
	if addr == 0x144 then
		return bit32.band(self.csr[0x344] or 0, 0x222)
	end
	
	-- cycle/time/instret: also accessible via mcycle etc.
	if addr == 0xB00 then return self.csr[0xC00] or 0 end -- mcycle -> cycle
	if addr == 0xB02 then return self.csr[0xC02] or 0 end -- minstret -> instret
	if addr == 0xB80 then return self.csr[0xC80] or 0 end -- mcycleh
	if addr == 0xB82 then return self.csr[0xC82] or 0 end -- minstreth
	
	return self.csr[addr] or 0
end

function Registers:writeCSR(addr, value)
	addr = bit32.band(addr, 0xFFF)
	value = bit32.band(value, 0xFFFFFFFF)
	
	-- Read-only CSRs (top 2 bits of addr = 11)
	if bit32.band(bit32.rshift(addr, 10), 3) == 3 then
		return
	end
	
	-- sstatus writes through to mstatus (only S-mode bits)
	if addr == 0x100 then
		local mstatus = self.csr[0x300] or 0
		mstatus = bit32.band(mstatus, bit32.bnot(SSTATUS_READ_MASK))
		mstatus = bit32.bor(mstatus, bit32.band(value, SSTATUS_READ_MASK))
		self.csr[0x300] = mstatus
		return
	end
	
	-- sie writes through to mie (S-mode interrupt bits only)
	if addr == 0x104 then
		local mie = self.csr[0x304] or 0
		mie = bit32.band(mie, bit32.bnot(0x222))
		mie = bit32.bor(mie, bit32.band(value, 0x222))
		self.csr[0x304] = mie
		return
	end
	
	-- sip writes through to mip (only SSIP is writable by software)
	if addr == 0x144 then
		local mip = self.csr[0x344] or 0
		mip = bit32.band(mip, bit32.bnot(0x002)) -- clear SSIP
		mip = bit32.bor(mip, bit32.band(value, 0x002)) -- set new SSIP
		self.csr[0x344] = mip
		return
	end
	
	-- mip: some bits are read-only (set by hardware)
	-- Software can only write SSIP (bit 1), STIP (bit 5), SEIP (bit 9)
	-- MTIP (7), MSIP (3), MEIP (11) are set by CLINT/PLIC
	if addr == 0x344 then
		-- Allow all writes for now since CLINT/PLIC set the hardware bits directly
		self.csr[0x344] = value
		return
	end
	
	-- satp: when written, TLB should be flushed (handled by CPU via SFENCE.VMA)
	
	-- Counter writes (mcycle, minstret)
	if addr == 0xB00 then self.csr[0xC00] = value; return end
	if addr == 0xB02 then self.csr[0xC02] = value; return end
	if addr == 0xB80 then self.csr[0xC80] = value; return end
	if addr == 0xB82 then self.csr[0xC82] = value; return end
	
	self.csr[addr] = value
end

function Registers:incrementInstret()
	local lo = (self.csr[0xC02] or 0) + 1
	if lo >= 0x100000000 then
		lo = 0
		self.csr[0xC82] = ((self.csr[0xC82] or 0) + 1) % 0x100000000
	end
	self.csr[0xC02] = lo
	-- Also increment cycle (we treat them the same)
	self.csr[0xC00] = lo
	self.csr[0xC80] = self.csr[0xC82]
end

--------------------------------------------------------------------------------
-- RESET / DEBUG
--------------------------------------------------------------------------------

function Registers:reset(entryPoint)
	for i = 0, 31 do self.x[i] = 0 end
	self.pc = entryPoint or 0x80000000
	self.privLevel = 3
	self:_initCSRs()
end

function Registers:dump()
	local lines = {}
	table.insert(lines, string.format("PC = 0x%08X  Priv = %d", self.pc, self.privLevel))
	for i = 0, 31, 4 do
		local s = ""
		for j = 0, 3 do
			local r = i + j
			s = s .. string.format("x%02d(%-4s)=%08X ", r, Registers.ABI_NAMES[r], self.x[r])
		end
		table.insert(lines, s)
	end
	-- Key CSRs
	table.insert(lines, string.format("mstatus=%08X mtvec=%08X mepc=%08X mcause=%08X",
		self.csr[0x300] or 0, self.csr[0x305] or 0,
		self.csr[0x341] or 0, self.csr[0x342] or 0))
	table.insert(lines, string.format("sstatus=%08X stvec=%08X sepc=%08X scause=%08X",
		bit32.band(self.csr[0x300] or 0, SSTATUS_READ_MASK),
		self.csr[0x105] or 0, self.csr[0x141] or 0, self.csr[0x142] or 0))
	table.insert(lines, string.format("satp=%08X mie=%08X mip=%08X",
		self.csr[0x180] or 0, self.csr[0x304] or 0, self.csr[0x344] or 0))
	return table.concat(lines, "\n")
end

return Registers
