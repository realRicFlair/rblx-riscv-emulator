--!strict
--[[
	Sv32_MMU.lua - Sv32 Virtual Memory / Page Table Walker
	
	Place in: ReplicatedStorage/RISCVModules/Sv32_MMU
	
	Sv32 address translation for RV32:
		Virtual address (32-bit): VPN[1](10) | VPN[0](10) | offset(12)
		Physical address (34-bit, we use 32): PPN[1](12) | PPN[0](10) | offset(12)
		
		Page Table Entry (32-bit):
			V(1) | R(1) | W(1) | X(1) | U(1) | G(1) | A(1) | D(1) | RSW(2) | PPN(22)
		
		satp CSR (0x180):
			MODE(1) | ASID(9) | PPN(22)
			MODE=1 -> Sv32 enabled
			MODE=0 -> bare (no translation)
	
	USAGE:
		local mmu = Sv32_MMU.new(memory, registers)
		-- Then replace memory access calls with:
		local physAddr = mmu:translate(virtualAddr, accessType)
		-- accessType: "read", "write", "exec"
		
	The CPU module should call mmu:translate() before every memory access
	when the MMU is enabled (satp.MODE == 1).
]]

local Sv32_MMU = {}
Sv32_MMU.__index = Sv32_MMU

-- PTE bit masks
local PTE_V = 0x001  -- Valid
local PTE_R = 0x002  -- Read
local PTE_W = 0x004  -- Write
local PTE_X = 0x008  -- Execute
local PTE_U = 0x010  -- User-mode accessible
local PTE_G = 0x020  -- Global
local PTE_A = 0x040  -- Accessed
local PTE_D = 0x080  -- Dirty

-- Page/superpage sizes
local PAGE_SIZE = 4096         -- 4 KB
local SUPERPAGE_SIZE = 4194304 -- 4 MB (1024 * 4KB)

-- Fault causes
local FAULT = {
	INST_PAGE_FAULT  = 12,
	LOAD_PAGE_FAULT  = 13,
	STORE_PAGE_FAULT = 15,
	INST_ACCESS      = 1,
	LOAD_ACCESS      = 5,
	STORE_ACCESS     = 7,
}

function Sv32_MMU.new(mem, regs)
	local self = setmetatable({}, Sv32_MMU)
	self.mem = mem        -- raw Memory module (physical access)
	self.regs = regs      -- Registers module (for satp, priv level)
	
	-- Simple TLB cache: maps virtual page number -> {ppn, pte, level}
	self.tlb = {}
	self.tlbSize = 64
	self.tlbEntries = 0
	
	return self
end

--------------------------------------------------------------------------------
-- TLB (Translation Lookaside Buffer)
--------------------------------------------------------------------------------

function Sv32_MMU:tlbLookup(vpn)
	return self.tlb[vpn]
end

function Sv32_MMU:tlbInsert(vpn, ppn, pte, level)
	if self.tlbEntries >= self.tlbSize then
		self:tlbFlush()
	end
	self.tlb[vpn] = { ppn = ppn, pte = pte, level = level }
	self.tlbEntries = self.tlbEntries + 1
end

function Sv32_MMU:tlbFlush()
	self.tlb = {}
	self.tlbEntries = 0
end

--------------------------------------------------------------------------------
-- ADDRESS TRANSLATION
--------------------------------------------------------------------------------

-- Check if MMU is enabled
function Sv32_MMU:isEnabled()
	local satp = self.regs:readCSR(0x180)
	-- MODE is bit 31
	return bit32.btest(satp, 0x80000000)
end

-- Get the root page table physical address from satp
function Sv32_MMU:getRootPPN()
	local satp = self.regs:readCSR(0x180)
	return bit32.band(satp, 0x003FFFFF) -- PPN field (bits 21:0)
end

--[[
	translate(vaddr, accessType) -> physAddr, fault
	
	accessType: "read", "write", "exec"
	
	Returns:
		physAddr : translated physical address (or nil on fault)
		fault    : fault cause number (or nil on success)
		
	When MMU is disabled (bare mode), returns vaddr unchanged.
]]
function Sv32_MMU:translate(vaddr, accessType)
	-- If MMU not enabled, pass through
	if not self:isEnabled() then
		return vaddr, nil
	end
	
	-- M-mode accesses bypass MMU (unless MPRV is set, which we skip for now)
	if self.regs.privLevel == 3 then
		return vaddr, nil
	end
	
	local vpn1 = bit32.band(bit32.rshift(vaddr, 22), 0x3FF)  -- bits 31:22
	local vpn0 = bit32.band(bit32.rshift(vaddr, 12), 0x3FF)  -- bits 21:12
	local offset = bit32.band(vaddr, 0xFFF)                   -- bits 11:0
	
	-- TLB lookup (use full VPN as key)
	local fullVPN = bit32.bor(bit32.lshift(vpn1, 10), vpn0)
	local cached = self:tlbLookup(fullVPN)
	if cached then
		local pte = cached.pte
		-- Quick permission check on cached entry
		local ok, fault = self:_checkPermissions(pte, accessType)
		if not ok then
			return nil, fault
		end
		
		local physAddr
		if cached.level == 1 then
			-- Superpage: PPN[1] from PTE, VPN[0] passes through as offset
			physAddr = bit32.bor(
				bit32.lshift(cached.ppn, 22),
				bit32.lshift(vpn0, 12),
				offset
			)
		else
			physAddr = bit32.bor(
				bit32.lshift(cached.ppn, 12),
				offset
			)
		end
		return physAddr, nil
	end
	
	-- Page table walk
	local rootPPN = self:getRootPPN()
	local a = rootPPN * PAGE_SIZE -- root page table physical address
	
	-- Level 1: read PTE from root table
	local pte1_addr = a + vpn1 * 4
	local pte1 = self.mem:read32(pte1_addr)
	
	-- Check valid
	if not bit32.btest(pte1, PTE_V) then
		return nil, self:_faultCause(accessType)
	end
	
	-- Check if leaf (has R, W, or X set)
	if self:_isLeaf(pte1) then
		-- Superpage (4 MB)
		-- Misaligned superpage check: PPN[0] must be zero
		local ppn0 = bit32.band(bit32.rshift(pte1, 10), 0x3FF)
		if ppn0 ~= 0 then
			return nil, self:_faultCause(accessType)
		end
		
		local ok, fault = self:_checkPermissions(pte1, accessType)
		if not ok then return nil, fault end
		
		-- Set A and D bits if needed
		pte1 = self:_updateAD(pte1, accessType, pte1_addr)
		
		local ppn1 = bit32.band(bit32.rshift(pte1, 20), 0xFFF)
		local physAddr = bit32.bor(
			bit32.lshift(ppn1, 22),
			bit32.lshift(vpn0, 12),
			offset
		)
		
		-- Cache in TLB
		self:tlbInsert(fullVPN, ppn1, pte1, 1)
		
		return physAddr, nil
	end
	
	-- Not a leaf: this is a pointer to next level page table
	local ppn_full = bit32.rshift(pte1, 10)
	a = ppn_full * PAGE_SIZE
	
	-- Level 0: read PTE from second-level table
	local pte0_addr = a + vpn0 * 4
	local pte0 = self.mem:read32(pte0_addr)
	
	-- Check valid
	if not bit32.btest(pte0, PTE_V) then
		return nil, self:_faultCause(accessType)
	end
	
	-- Must be a leaf at level 0
	if not self:_isLeaf(pte0) then
		return nil, self:_faultCause(accessType)
	end
	
	local ok, fault = self:_checkPermissions(pte0, accessType)
	if not ok then return nil, fault end
	
	-- Set A and D bits
	pte0 = self:_updateAD(pte0, accessType, pte0_addr)
	
	local ppn = bit32.rshift(pte0, 10)
	local physAddr = bit32.bor(
		bit32.lshift(ppn, 12),
		offset
	)
	
	-- Cache in TLB
	self:tlbInsert(fullVPN, ppn, pte0, 0)
	
	return physAddr, nil
end

--------------------------------------------------------------------------------
-- PERMISSION CHECKS
--------------------------------------------------------------------------------

function Sv32_MMU:_isLeaf(pte)
	return bit32.btest(pte, bit32.bor(PTE_R, PTE_W, PTE_X))
end

function Sv32_MMU:_checkPermissions(pte, accessType)
	local isUser = (self.regs.privLevel == 0)
	
	-- Supervisor accessing U-page: need SUM bit in sstatus
	-- User accessing non-U page: fault
	local isUPage = bit32.btest(pte, PTE_U)
	if isUser and not isUPage then
		return false, self:_faultCause(accessType)
	end
	if not isUser and isUPage then
		-- Check SUM (Supervisor User Memory access) bit in sstatus (bit 18)
		local sstatus = self.regs:readCSR(0x100)
		if not bit32.btest(sstatus, bit32.lshift(1, 18)) then
			return false, self:_faultCause(accessType)
		end
	end
	
	-- Check R/W/X permissions
	if accessType == "read" then
		if not bit32.btest(pte, PTE_R) then
			-- Check MXR (Make eXecutable Readable) bit in sstatus (bit 19)
			local sstatus = self.regs:readCSR(0x100)
			if not (bit32.btest(sstatus, bit32.lshift(1, 19)) and bit32.btest(pte, PTE_X)) then
				return false, FAULT.LOAD_PAGE_FAULT
			end
		end
	elseif accessType == "write" then
		if not bit32.btest(pte, PTE_W) then
			return false, FAULT.STORE_PAGE_FAULT
		end
	elseif accessType == "exec" then
		if not bit32.btest(pte, PTE_X) then
			return false, FAULT.INST_PAGE_FAULT
		end
	end
	
	return true, nil
end

function Sv32_MMU:_faultCause(accessType)
	if accessType == "exec" then return FAULT.INST_PAGE_FAULT end
	if accessType == "write" then return FAULT.STORE_PAGE_FAULT end
	return FAULT.LOAD_PAGE_FAULT
end

-- Update Accessed and Dirty bits in PTE (write back to memory)
function Sv32_MMU:_updateAD(pte, accessType, pteAddr)
	local needUpdate = false
	if not bit32.btest(pte, PTE_A) then
		pte = bit32.bor(pte, PTE_A)
		needUpdate = true
	end
	if accessType == "write" and not bit32.btest(pte, PTE_D) then
		pte = bit32.bor(pte, PTE_D)
		needUpdate = true
	end
	if needUpdate then
		self.mem:write32(pteAddr, pte)
	end
	return pte
end

return Sv32_MMU
