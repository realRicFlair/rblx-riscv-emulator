--[[
	DTB.lua - Flattened Device Tree (FDT) generator
	
	Place in: ReplicatedStorage/RISCVModules/DTB
	
	Generates a minimal Device Tree Blob (DTB) that describes the
	emulated hardware to Linux. Linux reads this at boot to discover
	devices, memory layout, interrupt controllers, etc.
	
	The DTB is loaded into RAM and its address is passed in register a1
	when jumping to the kernel entry point.
	
	FDT format reference: https://devicetree-specification.readthedocs.io/
	
	USAGE:
		local DTB = require(path.to.DTB)
		local blob = DTB.generate({
			ramSize = 16 * 1024 * 1024,
			uartAddr = 0x10000000,
			plicAddr = 0x0C000000,
			clintAddr = 0x02000000,
		})
		cpu.mem:loadBinary(blob, 0x87000000)
		cpu.regs:write(11, 0x87000000) -- a1 = DTB address
]]

local DTB = {}

-- FDT magic and version constants
local FDT_MAGIC = 0xD00DFEED
local FDT_VERSION = 17
local FDT_LAST_COMP_VERSION = 16

-- FDT structure tokens
local FDT_BEGIN_NODE = 0x00000001
local FDT_END_NODE   = 0x00000002
local FDT_PROP       = 0x00000003
local FDT_NOP        = 0x00000004
local FDT_END        = 0x00000009

--------------------------------------------------------------------------------
-- BINARY BUILDER HELPERS
--------------------------------------------------------------------------------

local function u32be(val)
	-- Big-endian 32-bit
	val = val % 0x100000000
	return string.char(
		bit32.band(bit32.rshift(val, 24), 0xFF),
		bit32.band(bit32.rshift(val, 16), 0xFF),
		bit32.band(bit32.rshift(val, 8), 0xFF),
		bit32.band(val, 0xFF)
	)
end

local function u64be(val)
	local hi = math.floor(val / 0x100000000)
	local lo = val % 0x100000000
	return u32be(hi) .. u32be(lo)
end

-- Align data to 4-byte boundary
local function align4(data)
	local pad = (4 - (#data % 4)) % 4
	return data .. string.rep("\0", pad)
end

--------------------------------------------------------------------------------
-- STRING TABLE BUILDER
--------------------------------------------------------------------------------

local StringTable = {}
StringTable.__index = StringTable

function StringTable.new()
	local self = setmetatable({}, StringTable)
	self.strings = {}
	self.offsets = {}
	self.data = ""
	return self
end

function StringTable:add(str)
	if self.offsets[str] then
		return self.offsets[str]
	end
	local offset = #self.data
	self.offsets[str] = offset
	self.data = self.data .. str .. "\0"
	table.insert(self.strings, str)
	return offset
end

--------------------------------------------------------------------------------
-- STRUCTURE BLOCK BUILDER
--------------------------------------------------------------------------------

local StructBuilder = {}
StructBuilder.__index = StructBuilder

function StructBuilder.new(strtab)
	local self = setmetatable({}, StructBuilder)
	self.data = ""
	self.strtab = strtab
	return self
end

function StructBuilder:beginNode(name)
	self.data = self.data .. u32be(FDT_BEGIN_NODE)
	self.data = self.data .. align4(name .. "\0")
end

function StructBuilder:endNode()
	self.data = self.data .. u32be(FDT_END_NODE)
end

function StructBuilder:propU32(name, value)
	local nameOff = self.strtab:add(name)
	self.data = self.data .. u32be(FDT_PROP)
	self.data = self.data .. u32be(4) -- length
	self.data = self.data .. u32be(nameOff)
	self.data = self.data .. u32be(value)
end

function StructBuilder:propU64(name, value)
	local nameOff = self.strtab:add(name)
	self.data = self.data .. u32be(FDT_PROP)
	self.data = self.data .. u32be(8) -- length
	self.data = self.data .. u32be(nameOff)
	self.data = self.data .. u64be(value)
end

function StructBuilder:propString(name, value)
	local nameOff = self.strtab:add(name)
	local valData = value .. "\0"
	self.data = self.data .. u32be(FDT_PROP)
	self.data = self.data .. u32be(#valData)
	self.data = self.data .. u32be(nameOff)
	self.data = self.data .. align4(valData)
end

function StructBuilder:propStringList(name, values)
	local nameOff = self.strtab:add(name)
	local valData = ""
	for _, v in ipairs(values) do
		valData = valData .. v .. "\0"
	end
	self.data = self.data .. u32be(FDT_PROP)
	self.data = self.data .. u32be(#valData)
	self.data = self.data .. u32be(nameOff)
	self.data = self.data .. align4(valData)
end

function StructBuilder:propEmpty(name)
	local nameOff = self.strtab:add(name)
	self.data = self.data .. u32be(FDT_PROP)
	self.data = self.data .. u32be(0) -- length = 0
	self.data = self.data .. u32be(nameOff)
end

function StructBuilder:propRaw(name, rawBytes)
	local nameOff = self.strtab:add(name)
	self.data = self.data .. u32be(FDT_PROP)
	self.data = self.data .. u32be(#rawBytes)
	self.data = self.data .. u32be(nameOff)
	self.data = self.data .. align4(rawBytes)
end

function StructBuilder:finish()
	self.data = self.data .. u32be(FDT_END)
end

--------------------------------------------------------------------------------
-- DTB GENERATION
--------------------------------------------------------------------------------

function DTB.generate(config)
	config = config or {}
	local ramBase   = config.ramBase   or 0x80000000
	local ramSize   = config.ramSize   or (16 * 1024 * 1024)
	local uartAddr  = config.uartAddr  or 0x10000000
	local plicAddr  = config.plicAddr  or 0x0C000000
	local clintAddr = config.clintAddr or 0x02000000
	local bootargs  = config.bootargs  or "earlycon=sbi console=ttyS0"
	
	-- Phandle IDs for cross-references
	local PLIC_PHANDLE  = 1
	local CLINT_PHANDLE = 2
	local CPU_PHANDLE   = 3
	
	local strtab = StringTable.new()
	local sb = StructBuilder.new(strtab)
	
	-- Root node
	sb:beginNode("")
	sb:propU32("#address-cells", 2)
	sb:propU32("#size-cells", 2)
	sb:propString("compatible", "riscv-virtio")
	sb:propString("model", "riscv-virtio,qemu")
	
	-- /chosen
	sb:beginNode("chosen")
	sb:propString("bootargs", bootargs)
	sb:propString("stdout-path", "/soc/serial@" .. string.format("%x", uartAddr))
	sb:endNode()
	
	-- /memory@80000000
	sb:beginNode("memory@80000000")
	sb:propString("device_type", "memory")
	-- reg = <base_hi base_lo size_hi size_lo>
	sb:propRaw("reg", u32be(0) .. u32be(ramBase) .. u32be(0) .. u32be(ramSize))
	sb:endNode()
	
	-- /cpus
	sb:beginNode("cpus")
	sb:propU32("#address-cells", 1)
	sb:propU32("#size-cells", 0)
	sb:propU32("timebase-frequency", 10000000) -- 10 MHz
	
	-- /cpus/cpu@0
	sb:beginNode("cpu@0")
	sb:propString("device_type", "cpu")
	sb:propU32("reg", 0)
	sb:propString("compatible", "riscv")
	sb:propString("riscv,isa", "rv32ima")
	sb:propString("mmu-type", "riscv,sv32")
	sb:propString("status", "okay")
	sb:propU32("phandle", CPU_PHANDLE)
	
	-- /cpus/cpu@0/interrupt-controller
	sb:beginNode("interrupt-controller")
	sb:propU32("#interrupt-cells", 1)
	sb:propEmpty("interrupt-controller")
	sb:propString("compatible", "riscv,cpu-intc")
	sb:propU32("phandle", CPU_PHANDLE + 10) -- cpu intc phandle
	sb:endNode() -- interrupt-controller
	
	sb:endNode() -- cpu@0
	sb:endNode() -- cpus
	
	-- /soc
	sb:beginNode("soc")
	sb:propU32("#address-cells", 2)
	sb:propU32("#size-cells", 2)
	sb:propStringList("compatible", {"simple-bus"})
	sb:propEmpty("ranges")
	
	-- /soc/clint@2000000
	sb:beginNode(string.format("clint@%x", clintAddr))
	sb:propStringList("compatible", {"riscv,clint0"})
	sb:propRaw("reg", u32be(0) .. u32be(clintAddr) .. u32be(0) .. u32be(0x10000))
	-- interrupts-extended: <&cpu_intc 3 &cpu_intc 7>
	-- 3 = M-mode software interrupt, 7 = M-mode timer interrupt
	sb:propRaw("interrupts-extended",
		u32be(CPU_PHANDLE + 10) .. u32be(3) ..
		u32be(CPU_PHANDLE + 10) .. u32be(7)
	)
	sb:propU32("phandle", CLINT_PHANDLE)
	sb:endNode()
	
	-- /soc/plic@c000000
	sb:beginNode(string.format("interrupt-controller@%x", plicAddr))
	sb:propStringList("compatible", {"riscv,plic0"})
	sb:propU32("#interrupt-cells", 1)
	sb:propEmpty("interrupt-controller")
	sb:propRaw("reg", u32be(0) .. u32be(plicAddr) .. u32be(0) .. u32be(0x400000))
	sb:propU32("riscv,ndev", 31)
	-- interrupts-extended: <&cpu_intc 11 &cpu_intc 9>
	-- 11 = M-mode external, 9 = S-mode external
	sb:propRaw("interrupts-extended",
		u32be(CPU_PHANDLE + 10) .. u32be(11) ..
		u32be(CPU_PHANDLE + 10) .. u32be(9)
	)
	sb:propU32("phandle", PLIC_PHANDLE)
	sb:endNode()
	
	-- /soc/serial@10000000 (UART 16550)
	sb:beginNode(string.format("serial@%x", uartAddr))
	sb:propString("compatible", "ns16550a")
	sb:propRaw("reg", u32be(0) .. u32be(uartAddr) .. u32be(0) .. u32be(0x100))
	sb:propU32("clock-frequency", 3686400)
	sb:propU32("interrupt-parent", PLIC_PHANDLE)
	sb:propRaw("interrupts", u32be(10)) -- UART = IRQ 10
	sb:endNode()
	
	sb:endNode() -- soc
	sb:endNode() -- root
	sb:finish()
	
	-- Now assemble the full FDT blob
	local structData = sb.data
	local stringsData = strtab.data
	
	-- Memory reservation block (empty for us)
	local memRsvd = u64be(0) .. u64be(0) -- one empty entry terminates the block
	
	-- Header is 40 bytes
	local headerSize = 40
	local offMemRsvd = headerSize
	local offStruct = offMemRsvd + #memRsvd
	-- Align struct offset to 4 bytes (should already be)
	offStruct = offStruct + ((4 - (offStruct % 4)) % 4)
	local offStrings = offStruct + #structData
	local totalSize = offStrings + #stringsData
	-- Align total to 4 bytes
	totalSize = totalSize + ((4 - (totalSize % 4)) % 4)
	
	local header = u32be(FDT_MAGIC)
		.. u32be(totalSize)
		.. u32be(offStruct)
		.. u32be(offStrings)
		.. u32be(offMemRsvd)
		.. u32be(FDT_VERSION)
		.. u32be(FDT_LAST_COMP_VERSION)
		.. u32be(0)  -- boot_cpuid_phys
		.. u32be(#stringsData)
		.. u32be(#structData)
	
	-- Pad between header and mem reservation block if needed
	local padAfterHeader = string.rep("\0", offMemRsvd - #header)
	local padAfterRsvd = string.rep("\0", offStruct - offMemRsvd - #memRsvd)
	local padEnd = string.rep("\0", totalSize - offStrings - #stringsData)
	
	local blob = header .. padAfterHeader .. memRsvd .. padAfterRsvd .. structData .. stringsData .. padEnd
	
	return blob
end

-- Convert string blob to byte table for loadBinary
function DTB.toBytes(blob)
	local bytes = {}
	for i = 1, #blob do
		bytes[i] = string.byte(blob, i)
	end
	return bytes
end

return DTB
