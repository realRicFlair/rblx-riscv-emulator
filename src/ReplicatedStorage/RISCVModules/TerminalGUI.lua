--[[
	TerminalGUI.lua - Creates and manages the terminal UI
	
	Place in: ReplicatedStorage/RISCVModules/TerminalGUI
	
	Creates a retro-styled terminal ScreenGui.
	Call TerminalGUI.create(playerGui) to build the GUI.
	Returns a terminal object with :write(), :writeLine(), :clear(), etc.
	
	The terminal hooks into CPU's UART output and feeds keyboard
	input back into UART receive.
]]

local TerminalGUI = {}
TerminalGUI.__index = TerminalGUI


-- Terminal dimensions
local TERMINAL_CONFIG = {
	width = 800,
	height = 500,
	bgColor = Color3.fromRGB(10, 10, 10),
	fgColor = Color3.fromRGB(0, 255, 65),
	cursorColor = Color3.fromRGB(0, 255, 65),
	fontFace = Font.fromEnum(Enum.Font.RobotoMono),
	fontSize = 14,
	maxLines = 500,     -- scrollback buffer
	title = "RoroCorp Terminal",
}

function TerminalGUI.create(playerGui)
	local self = setmetatable({}, TerminalGUI)
	
	self.lines = {}
	self.currentLine = ""
	self.inputCallback = nil  -- function(text) called when user presses Enter
	
	-- Build GUI hierarchy
	self.screenGui = Instance.new("ScreenGui")
	self.screenGui.Name = "RISCVTerminal"
	self.screenGui.ResetOnSpawn = false
	self.screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	
	-- Main frame
	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.Size = UDim2.fromOffset(TERMINAL_CONFIG.width, TERMINAL_CONFIG.height)
	mainFrame.Position = UDim2.new(0.5, -TERMINAL_CONFIG.width/2, 0.5, -TERMINAL_CONFIG.height/2)
	mainFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	mainFrame.BorderSizePixel = 0
	mainFrame.Parent = self.screenGui
	
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = mainFrame
	
	-- Title bar
	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, 30)
	titleBar.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
	titleBar.BorderSizePixel = 0
	titleBar.Parent = mainFrame
	
	local titleCorner = Instance.new("UICorner")
	titleCorner.CornerRadius = UDim.new(0, 8)
	titleCorner.Parent = titleBar
	
	-- Square off bottom corners of title bar
	local titleFix = Instance.new("Frame")
	titleFix.Size = UDim2.new(1, 0, 0, 8)
	titleFix.Position = UDim2.new(0, 0, 1, -8)
	titleFix.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
	titleFix.BorderSizePixel = 0
	titleFix.Parent = titleBar
	
	local titleLabel = Instance.new("TextLabel")
	titleLabel.Size = UDim2.new(1, -20, 1, 0)
	titleLabel.Position = UDim2.new(0, 10, 0, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = TERMINAL_CONFIG.title
	titleLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.FontFace = TERMINAL_CONFIG.fontFace
	titleLabel.TextSize = 13
	titleLabel.Parent = titleBar
	
	-- Window dots
--[[
	for i, color in ipairs({Color3.fromRGB(255,95,86), Color3.fromRGB(255,189,46), Color3.fromRGB(39,201,63)}) do
		local dot = Instance.new("Frame")
		dot.Size = UDim2.fromOffset(12, 12)
		dot.Position = UDim2.new(1, -20 - (3-i)*20, 0.5, -6)
		dot.BackgroundColor3 = color
		dot.BorderSizePixel = 0
		dot.Parent = titleBar
		local dc = Instance.new("UICorner")
		dc.CornerRadius = UDim.new(1, 0)
		dc.Parent = dot
	end
]]	
	-- Terminal output area (scrolling)
	local outputFrame = Instance.new("ScrollingFrame")
	outputFrame.Name = "OutputFrame"
	outputFrame.Size = UDim2.new(1, -10, 1, -70)
	outputFrame.Position = UDim2.new(0, 5, 0, 32)
	outputFrame.BackgroundColor3 = TERMINAL_CONFIG.bgColor
	outputFrame.BorderSizePixel = 0
	outputFrame.ScrollingEnabled = true
	outputFrame.ScrollBarThickness = 6
	outputFrame.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 80)
	outputFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	outputFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	outputFrame.Parent = mainFrame



	
	local outputLayout = Instance.new("UIListLayout")
	outputLayout.SortOrder = Enum.SortOrder.LayoutOrder
	outputLayout.Parent = outputFrame
	
	local outputPadding = Instance.new("UIPadding")
	outputPadding.PaddingLeft = UDim.new(0, 6)
	outputPadding.PaddingTop = UDim.new(0, 4)
	outputPadding.Parent = outputFrame
	
	self.outputFrame = outputFrame
	self.lineCount = 0
	
	-- Input area
	local inputFrame = Instance.new("Frame")
	inputFrame.Name = "InputFrame"
	inputFrame.Size = UDim2.new(1, -10, 0, 28)
	inputFrame.Position = UDim2.new(0, 5, 1, -33)
	inputFrame.BackgroundColor3 = TERMINAL_CONFIG.bgColor
	inputFrame.BorderSizePixel = 1
	inputFrame.BorderColor3 = Color3.fromRGB(0, 180, 45)
	inputFrame.Parent = mainFrame
	
	local promptLabel = Instance.new("TextLabel")
	promptLabel.Size = UDim2.new(0, 20, 1, 0)
	promptLabel.BackgroundTransparency = 1
	promptLabel.Text = "$"
	promptLabel.TextColor3 = TERMINAL_CONFIG.fgColor
	promptLabel.FontFace = TERMINAL_CONFIG.fontFace
	promptLabel.TextSize = TERMINAL_CONFIG.fontSize
	promptLabel.Parent = inputFrame
	
	local inputBox = Instance.new("TextBox")
	inputBox.Name = "InputBox"
	inputBox.Size = UDim2.new(1, -25, 1, 0)
	inputBox.Position = UDim2.new(0, 22, 0, 0)
	inputBox.BackgroundTransparency = 1
	inputBox.Text = ""
	inputBox.PlaceholderText = "Type Here . . ."
	inputBox.PlaceholderColor3 = Color3.fromRGB(0, 100, 30)
	inputBox.TextColor3 = TERMINAL_CONFIG.fgColor
	inputBox.FontFace = TERMINAL_CONFIG.fontFace
	inputBox.TextSize = TERMINAL_CONFIG.fontSize
	inputBox.TextXAlignment = Enum.TextXAlignment.Left
	inputBox.ClearTextOnFocus = false
	inputBox.Parent = inputFrame
	
	self.inputBox = inputBox
	
	-- Handle Enter key
	inputBox.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			local text = inputBox.Text
			inputBox.Text = ""
			self:writeLine("$ " .. text)
			if self.inputCallback then
				self.inputCallback(text)
			end
		end
	end)
	
	-- Make draggable
	self:_makeDraggable(mainFrame, titleBar)
	
	-- Parent to PlayerGui
	self.screenGui.Parent = playerGui
	
	return self
end

--------------------------------------------------------------------------------
-- TEXT OUTPUT
--------------------------------------------------------------------------------
function binaryToString(bin)
    local result = ""

    for byte in string.gmatch(bin, "%d%d%d%d%d%d%d%d") do
        local charCode = tonumber(byte, 2)
        if charCode then
            result = result .. string.char(charCode)
        end
    end

    return result
end

function TerminalGUI:write(text)
	self.currentLine = self.currentLine .. text
	-- Check for newlines
	while true do
		local nlPos = string.find(self.currentLine, "\n")
		if nlPos then
			local line = string.sub(self.currentLine, 1, nlPos - 1)
			self:_pushLine(line)
			print(line)
			self.currentLine = string.sub(self.currentLine, nlPos + 1)
		else
			break
		end
	end
	-- Update current partial line display
	self:_updateCurrentLine()
end

function TerminalGUI:writeLine(text)
	self:write(text .. "\n")
end

function TerminalGUI:_pushLine(text)
	self.lineCount = self.lineCount + 1
	
	local label = Instance.new("TextLabel")
	label.Name = "Line_" .. self.lineCount
	label.Size = UDim2.new(1, -10, 0, TERMINAL_CONFIG.fontSize + 2)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = TERMINAL_CONFIG.fgColor
	label.FontFace = TERMINAL_CONFIG.fontFace
	label.TextSize = TERMINAL_CONFIG.fontSize
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextWrapped = true
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.RichText = false
	label.LayoutOrder = self.lineCount
	label.Parent = self.outputFrame
	
	-- Trim old lines
	local children = self.outputFrame:GetChildren()
	local labels = {}
	for _, c in ipairs(children) do
		if c:IsA("TextLabel") then table.insert(labels, c) end
	end
	while #labels > TERMINAL_CONFIG.maxLines do
		labels[1]:Destroy()
		table.remove(labels, 1)
	end
	
	-- Auto-scroll to bottom
	--task.defer(function()
	--	self.outputFrame.CanvasPosition = Vector2.new(0, math.huge)
	--end)
	--self.outputFrame.UIListLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Wait()

	-- Scroll to bottom
	self.outputFrame.CanvasPosition = Vector2.new(0, self.outputFrame.AbsoluteCanvasSize.Y)
end

function TerminalGUI:_updateCurrentLine()
	-- Show partial line (before newline)
	local partial = self.outputFrame:FindFirstChild("_PartialLine")
	if self.currentLine ~= "" then
		if not partial then
			partial = Instance.new("TextLabel")
			partial.Name = "_PartialLine"
			partial.Size = UDim2.new(1, -10, 0, TERMINAL_CONFIG.fontSize + 2)
			partial.BackgroundTransparency = 1
			partial.TextColor3 = TERMINAL_CONFIG.fgColor
			partial.FontFace = TERMINAL_CONFIG.fontFace
			partial.TextSize = TERMINAL_CONFIG.fontSize
			partial.TextXAlignment = Enum.TextXAlignment.Left
			partial.AutomaticSize = Enum.AutomaticSize.Y
			partial.LayoutOrder = 999999
			partial.Parent = self.outputFrame
		end
		partial.Text = self.currentLine
	elseif partial then
		partial:Destroy()
	end
end

function TerminalGUI:clear()
	for _, child in ipairs(self.outputFrame:GetChildren()) do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	self.lineCount = 0
	self.currentLine = ""
end

--------------------------------------------------------------------------------
-- DRAGGING
--------------------------------------------------------------------------------

function TerminalGUI:_makeDraggable(frame, handle)
	local dragging = false
	local dragStart, startPos
	
	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or
		   input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = frame.Position
		end
	end)
	
	game:GetService("UserInputService").InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or
		   input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			frame.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y
			)
		end
	end)
	
	game:GetService("UserInputService").InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or
		   input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

--------------------------------------------------------------------------------
-- CPU INTEGRATION
--------------------------------------------------------------------------------

-- Connect this terminal to a CPU instance
function TerminalGUI:connectCPU(cpu)
	-- UART output -> terminal display
	cpu.mem:setUARTOutput(function(charCode)
		if charCode == 13 then return end -- ignore CR, only use LF
		local char = string.char(charCode)
		self:write(char)
	end)
	
	-- Terminal input -> UART input
	self.inputCallback = function(text)
		cpu.mem:uartSendString(text .. "\n")
	end
end

return TerminalGUI
