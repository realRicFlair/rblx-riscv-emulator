--[[
	Main.lua - RISC-V Emulator entry point (SBI + Kernel boot)
	
	Place in: StarterPlayerScripts/RISCVMain (LocalScript)
	
	BOOT FLOW:
		1. Load SBI firmware at 0x80000000
		2. Load kernel (test or Linux) at 0x80200000
		3. Generate and load DTB at 0x87000000
		4. Set a0=hartid(0), a1=DTB addr, PC=0x80000000
		5. SBI runs in M-mode, sets up hardware, mret into kernel at S-mode
		6. Kernel calls SBI via ecall when it needs M-mode services
	
	TO USE:
		- Build the SBI:        make sbi
		- Build test kernel:    make test_kernel
		- Put sbi.lua and test_kernel.lua as ModuleScripts in ReplicatedStorage
		- This script loads both and boots the system
	I luhh crack
	MODULE LAYOUT IN ROBLOX:
		ReplicatedStorage/
		├── RISCVModules/       (all emulator modules)
		├── SBIFirmware         (ModuleScript from sbi/sbi.lua)
		├── TestKernel          (ModuleScript from sbi/test_kernel.lua)
		└── LinuxKernel         (ModuleScript, optional, your compiled kernel)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local modules = ReplicatedStorage:WaitForChild("RISCVModules")
local CPU = require(modules:WaitForChild("CPU"))
local TerminalGUI = require(modules:WaitForChild("TerminalGUI"))
local DTB = require(modules:WaitForChild("DTB"))

local player = Players.LocalPlayer

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local CONFIG = {
	RAM_SIZE    = 16 * 1024 * 1024,  -- 16 MB
	SBI_ADDR    = 0x80000000,        -- SBI firmware load address
	KERNEL_ADDR = 0x80200000,        -- Kernel load address (2 MB offset)
	DTB_ADDR    = 0x87000000,        -- Device tree blob address
	
	-- Execution limits
	MAX_INSTRUCTIONS = 10000000,     -- 10M instructions before stopping
	YIELD_EVERY      = 5000,         -- yield to Roblox every N instructions
	
	-- Set to true to see every instruction traced
	DEBUG = false,
}

--------------------------------------------------------------------------------
-- MODULE LOADING HELPERS
--------------------------------------------------------------------------------

-- Try to load a ModuleScript, return nil on failure
local function tryRequire(name, timeout)
	local ok, mod = pcall(function()
		local ms = ReplicatedStorage:WaitForChild(name, timeout or 3)
		if ms then return require(ms) end
		return nil
	end)
	if ok then return mod end
	return nil
end

--------------------------------------------------------------------------------
-- BOOT SEQUENCE
--------------------------------------------------------------------------------

local function boot()
	-- Create CPU
	local cpu = CPU.new({
		debug = CONFIG.DEBUG,
		entryPoint = CONFIG.SBI_ADDR,
		ramSize = CONFIG.RAM_SIZE,
	})
	
	-- Create terminal
	local terminal = TerminalGUI.create(player:WaitForChild("PlayerGui"))
	terminal:connectCPU(cpu)

	local sbiModule = tryRequire("SBIFirmware", 5)--load sbi
	
	-- Boot banner
	terminal:writeLine("=== RISC-V Emulator v0.1 ===")
	terminal:writeLine("Extensions: RV32IMAZicsr_Zifencei")
	terminal:writeLine("MMU: Sv32 | CLINT: yes | PLIC: yes | SBI: yes")
	terminal:writeLine("RAM: " .. math.floor(CONFIG.RAM_SIZE / 1024 / 1024) .. " MB")
	terminal:writeLine("")
	
	---------- Step 1: Load SBI Firmware ----------
	-- Load SBI firmware
	if not sbiModule or not sbiModule.program then
		terminal:writeLine("[ERROR] SBIFirmware module not found!")
		terminal:writeLine("  Build it: make sbi")
		terminal:writeLine("  Put sbi/sbi.lua as ReplicatedStorage/SBIFirmware")
		
		-- Fall back to demo program if available
		local dcode = tryRequire("Code", 2)
		if dcode and dcode.program then
			terminal:writeLine("")
			terminal:writeLine("[FALLBACK] Loading Code module directly...")
			cpu:loadProgram(dcode.program, CONFIG.SBI_ADDR)
		else
			terminal:writeLine("[HALT] Nothing to run.")
			return
		end
	else
		terminal:writeLine("[BOOT] Loading SBI firmware at 0x80000000...")
		cpu:loadProgram(sbiModule.program, CONFIG.SBI_ADDR)
		
		---------- Step 2: Load Kernel ----------
		
		-- Try Linux kernel first, then test kernel
		local kernelModule = tryRequire("LinuxKernel", 2)
		local kernelName = "Linux"
		
		if not kernelModule or not kernelModule.program then
			kernelModule = tryRequire("TestKernel", 3)
			kernelName = "TestKernel"
		end
		
		if kernelModule and kernelModule.program then
			terminal:writeLine("[BOOT] Loading " .. kernelName .. " at 0x80200000...")
			cpu.mem:loadWords(CONFIG.KERNEL_ADDR, kernelModule.program)
		else
			terminal:writeLine("[WARN] No kernel found! SBI will boot but has nothing to jump to.")
			terminal:writeLine("  Build test: make test_kernel")
			terminal:writeLine("  Put sbi/test_kernel.lua as ReplicatedStorage/TestKernel")
		end
		
		---------- Step 3: Load DTB ----------
		
		terminal:writeLine("[BOOT] Generating DTB at 0x87000000...")
		local dtbBlob = DTB.generate({
			ramBase   = CONFIG.SBI_ADDR,
			ramSize   = CONFIG.RAM_SIZE,
			uartAddr  = 0x10000000,
			plicAddr  = 0x0C000000,
			clintAddr = 0x02000000,
			bootargs  = "earlycon=sbi console=ttyS0",
		})
		cpu.mem:loadBinary(CONFIG.DTB_ADDR, dtbBlob)
		
		---------- Step 4: Set Boot Registers ----------
		
		-- Linux/SBI boot convention:
		--   a0 (x10) = hart ID (0)
		--   a1 (x11) = DTB physical address
		cpu.regs:write(10, 0)                -- a0 = hartid
		cpu.regs:write(11, CONFIG.DTB_ADDR)  -- a1 = dtb address
		cpu.regs.pc = CONFIG.SBI_ADDR        -- PC = SBI entry
		
		terminal:writeLine("[BOOT] a0=0 (hartid), a1=0x87000000 (DTB)")
	end
	
	---------- Debug Commands ----------
	
	local originalCallback = terminal.inputCallback
	terminal.inputCallback = function(text)
		if text == "regs" then
			terminal:writeLine(cpu:dump())
			return
		elseif text == "reset" then
			cpu.halted = true
			terminal:writeLine("[CPU Reset - reload the game to reboot]")
			return
		elseif text == "halt" then
			cpu.halted = true
			terminal:writeLine("[CPU Halted]")
			return
		elseif text == "mmu" then
			local satp = cpu.regs:readCSR(0x180)
			local enabled = bit32.btest(satp, 0x80000000)
			terminal:writeLine(string.format("[MMU] satp=0x%08X enabled=%s", satp, tostring(enabled)))
			return
		elseif text == "timer" then
			terminal:writeLine(string.format("[CLINT] mtime_lo=%d mtimecmp_lo=%d",
				cpu.clint.mtime_lo, cpu.clint.mtimecmp_lo))
			return
		elseif text == "priv" then
			local levels = {[0]="User", [1]="Supervisor", [3]="Machine"}
			terminal:writeLine("[PRIV] " .. (levels[cpu.regs.privLevel] or "Unknown")
				.. " (level " .. cpu.regs.privLevel .. ")")
			return
		elseif text == "csr" then
			terminal:writeLine(string.format(
				"mstatus=%08X mepc=%08X mcause=%08X\n" ..
				"mtvec=%08X mie=%08X mip=%08X\n" ..
				"stvec=%08X sepc=%08X scause=%08X\n" ..
				"satp=%08X medeleg=%08X mideleg=%08X",
				cpu.regs:readCSR(0x300), cpu.regs:readCSR(0x341), cpu.regs:readCSR(0x342),
				cpu.regs:readCSR(0x305), cpu.regs:readCSR(0x304), cpu.regs:readCSR(0x344),
				cpu.regs:readCSR(0x105), cpu.regs:readCSR(0x141), cpu.regs:readCSR(0x142),
				cpu.regs:readCSR(0x180), cpu.regs:readCSR(0x302), cpu.regs:readCSR(0x303)
			))
			return
		elseif text == "help" then
			terminal:writeLine("Debug commands:")
			terminal:writeLine("  regs  - dump all registers")
			terminal:writeLine("  csr   - dump key CSRs")
			terminal:writeLine("  priv  - show privilege level")
			terminal:writeLine("  mmu   - show MMU status")
			terminal:writeLine("  timer - show CLINT state")
			terminal:writeLine("  halt  - stop CPU")
			terminal:writeLine("  help  - this message")
			return
		end
		originalCallback(text)
	end
	
	---------- Run ----------
	
	task.spawn(function()
		terminal:writeLine("[BOOT] Starting CPU...")
		terminal:writeLine("")
		cpu:run(CONFIG.MAX_INSTRUCTIONS, CONFIG.YIELD_EVERY)
	
		
		if cpu.halted then
			terminal:writeLine("")
			terminal:writeLine(string.format(
				"[CPU Halted after %d instructions at PC=0x%08X priv=%d]",
				cpu.instructionCount, cpu.regs.pc, cpu.regs.privLevel))
		end
	end)
end

boot()