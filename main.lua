local PlayerModule = Instance.new("ModuleScript")
PlayerModule.Name = "PlayerModule"
PlayerModule.Source = [[

local PlayerModule = {}
PlayerModule.__index = PlayerModule

function PlayerModule.new()
	local self = setmetatable({},PlayerModule)
	self.cameras = require(script:WaitForChild("CameraModule"))
	self.controls = require(script:WaitForChild("ControlModule"))
	return self
end

function PlayerModule:GetCameras()
	return self.cameras
end

function PlayerModule:GetControls()
	return self.controls
end

function PlayerModule:GetClickToMoveController()
	return self.controls:GetClickToMoveController()
end

return PlayerModule.new()
]]

local CameraModule = Instance.new("ModuleScript")
CameraModule.Name = "CameraModule"
CameraModule.Parent = PlayerModule
CameraModule.Source = [[

local CameraModule = {}
CameraModule.__index = CameraModule

local FFlagUserRemoveTheCameraApi do
	local success, result = pcall(function()
		return UserSettings():IsUserFeatureEnabled("UserRemoveTheCameraApi")
	end)
	FFlagUserRemoveTheCameraApi = success and result
end

local FFlagUserFixCameraSelectModuleWarning do
	local success, result = pcall(function()
		return UserSettings():IsUserFeatureEnabled("UserFixCameraSelectModuleWarning")
	end)
	FFlagUserFixCameraSelectModuleWarning = success and result
end

-- NOTICE: Player property names do not all match their StarterPlayer equivalents,
-- with the differences noted in the comments on the right
local PLAYER_CAMERA_PROPERTIES =
	{
		"CameraMinZoomDistance",
		"CameraMaxZoomDistance",
		"CameraMode",
		"DevCameraOcclusionMode",
		"DevComputerCameraMode",			-- Corresponds to StarterPlayer.DevComputerCameraMovementMode
		"DevTouchCameraMode",				-- Corresponds to StarterPlayer.DevTouchCameraMovementMode

		-- Character movement mode
		"DevComputerMovementMode",
		"DevTouchMovementMode",
		"DevEnableMouseLock",				-- Corresponds to StarterPlayer.EnableMouseLockOption
	}

local USER_GAME_SETTINGS_PROPERTIES =
	{
		"ComputerCameraMovementMode",
		"ComputerMovementMode",
		"ControlMode",
		"GamepadCameraSensitivity",
		"MouseSensitivity",
		"RotationType",
		"TouchCameraMovementMode",
		"TouchMovementMode",
	}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local UserGameSettings = UserSettings():GetService("UserGameSettings")

-- Static camera utils
local CameraUtils = require(script:WaitForChild("CameraUtils"))
local CameraInput = require(script:WaitForChild("CameraInput"))

-- Load Roblox Camera Controller Modules
local ClassicCamera = require(script:WaitForChild("ClassicCamera"))
local OrbitalCamera = require(script:WaitForChild("OrbitalCamera"))
local LegacyCamera = require(script:WaitForChild("LegacyCamera"))
local VehicleCamera = require(script:WaitForChild("VehicleCamera"))

-- Load Roblox Occlusion Modules
local Invisicam = require(script:WaitForChild("Invisicam"))
local Poppercam = require(script:WaitForChild("Poppercam"))

-- Load the near-field character transparency controller and the mouse lock "shift lock" controller
local TransparencyController = require(script:WaitForChild("TransparencyController"))
local MouseLockController = require(script:WaitForChild("MouseLockController"))

-- Table of camera controllers that have been instantiated. They are instantiated as they are used.
local instantiatedCameraControllers = {}
local instantiatedOcclusionModules = {}

-- Management of which options appear on the Roblox User Settings screen
do
	local PlayerScripts = Players.LocalPlayer:WaitForChild("PlayerScripts")

	PlayerScripts:RegisterTouchCameraMovementMode(Enum.TouchCameraMovementMode.Default)
	PlayerScripts:RegisterTouchCameraMovementMode(Enum.TouchCameraMovementMode.Follow)
	PlayerScripts:RegisterTouchCameraMovementMode(Enum.TouchCameraMovementMode.Classic)

	PlayerScripts:RegisterComputerCameraMovementMode(Enum.ComputerCameraMovementMode.Default)
	PlayerScripts:RegisterComputerCameraMovementMode(Enum.ComputerCameraMovementMode.Follow)
	PlayerScripts:RegisterComputerCameraMovementMode(Enum.ComputerCameraMovementMode.Classic)
	PlayerScripts:RegisterComputerCameraMovementMode(Enum.ComputerCameraMovementMode.CameraToggle)
end


function CameraModule.new()
	local self = setmetatable({},CameraModule)

	-- Current active controller instances
	self.activeCameraController = nil
	self.activeOcclusionModule = nil
	self.activeTransparencyController = nil
	self.activeMouseLockController = nil

	self.currentComputerCameraMovementMode = nil

	-- Connections to events
	self.cameraSubjectChangedConn = nil
	self.cameraTypeChangedConn = nil

	-- Adds CharacterAdded and CharacterRemoving event handlers for all current players
	for _,player in pairs(Players:GetPlayers()) do
		self:OnPlayerAdded(player)
	end

	-- Adds CharacterAdded and CharacterRemoving event handlers for all players who join in the future
	Players.PlayerAdded:Connect(function(player)
		self:OnPlayerAdded(player)
	end)

	self.activeTransparencyController = TransparencyController.new()
	self.activeTransparencyController:Enable(true)

	if not UserInputService.TouchEnabled then
		self.activeMouseLockController = MouseLockController.new()
		local toggleEvent = self.activeMouseLockController:GetBindableToggleEvent()
		if toggleEvent then
			toggleEvent:Connect(function()
				self:OnMouseLockToggled()
			end)
		end
	end

	self:ActivateCameraController(self:GetCameraControlChoice())
	self:ActivateOcclusionModule(Players.LocalPlayer.DevCameraOcclusionMode)
	self:OnCurrentCameraChanged() -- Does initializations and makes first camera controller
	RunService:BindToRenderStep("cameraRenderUpdate", Enum.RenderPriority.Camera.Value, function(dt) self:Update(dt) end)

	-- Connect listeners to camera-related properties
	for _, propertyName in pairs(PLAYER_CAMERA_PROPERTIES) do
		Players.LocalPlayer:GetPropertyChangedSignal(propertyName):Connect(function()
			self:OnLocalPlayerCameraPropertyChanged(propertyName)
		end)
	end

	for _, propertyName in pairs(USER_GAME_SETTINGS_PROPERTIES) do
		UserGameSettings:GetPropertyChangedSignal(propertyName):Connect(function()
			self:OnUserGameSettingsPropertyChanged(propertyName)
		end)
	end
	game.Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		self:OnCurrentCameraChanged()
	end)

	self.lastInputType = UserInputService:GetLastInputType()
	UserInputService.LastInputTypeChanged:Connect(function(newLastInputType)
		self.lastInputType = newLastInputType
	end)

	return self
end

function CameraModule:GetCameraMovementModeFromSettings()
	local cameraMode = Players.LocalPlayer.CameraMode

	-- Lock First Person trumps all other settings and forces ClassicCamera
	if cameraMode == Enum.CameraMode.LockFirstPerson then
		return CameraUtils.ConvertCameraModeEnumToStandard(Enum.ComputerCameraMovementMode.Classic)
	end

	local devMode, userMode
	if UserInputService.TouchEnabled then
		devMode = CameraUtils.ConvertCameraModeEnumToStandard(Players.LocalPlayer.DevTouchCameraMode)
		userMode = CameraUtils.ConvertCameraModeEnumToStandard(UserGameSettings.TouchCameraMovementMode)
	else
		devMode = CameraUtils.ConvertCameraModeEnumToStandard(Players.LocalPlayer.DevComputerCameraMode)
		userMode = CameraUtils.ConvertCameraModeEnumToStandard(UserGameSettings.ComputerCameraMovementMode)
	end

	if devMode == Enum.DevComputerCameraMovementMode.UserChoice then
		-- Developer is allowing user choice, so user setting is respected
		return userMode
	end

	return devMode
end

function CameraModule:ActivateOcclusionModule(occlusionMode: Enum.DevCameraOcclusionMode)
	local newModuleCreator
	if occlusionMode == Enum.DevCameraOcclusionMode.Zoom then
		newModuleCreator = Poppercam
	elseif occlusionMode == Enum.DevCameraOcclusionMode.Invisicam then
		newModuleCreator = Invisicam
	else
		warn("CameraScript ActivateOcclusionModule called with unsupported mode")
		return
	end

	self.occlusionMode = occlusionMode

	-- First check to see if there is actually a change. If the module being requested is already
	-- the currently-active solution then just make sure it's enabled and exit early
	if self.activeOcclusionModule and self.activeOcclusionModule:GetOcclusionMode() == occlusionMode then
		if not self.activeOcclusionModule:GetEnabled() then
			self.activeOcclusionModule:Enable(true)
		end
		return
	end

	-- Save a reference to the current active module (may be nil) so that we can disable it if
	-- we are successful in activating its replacement
	local prevOcclusionModule = self.activeOcclusionModule

	-- If there is no active module, see if the one we need has already been instantiated
	self.activeOcclusionModule = instantiatedOcclusionModules[newModuleCreator]

	-- If the module was not already instantiated and selected above, instantiate it
	if not self.activeOcclusionModule then
		self.activeOcclusionModule = newModuleCreator.new()
		if self.activeOcclusionModule then
			instantiatedOcclusionModules[newModuleCreator] = self.activeOcclusionModule
		end
	end

	-- If we were successful in either selecting or instantiating the module,
	-- enable it if it's not already the currently-active enabled module
	if self.activeOcclusionModule then
		local newModuleOcclusionMode = self.activeOcclusionModule:GetOcclusionMode()
		-- Sanity check that the module we selected or instantiated actually supports the desired occlusionMode
		if newModuleOcclusionMode ~= occlusionMode then
			warn("CameraScript ActivateOcclusionModule mismatch: ",self.activeOcclusionModule:GetOcclusionMode(),"~=",occlusionMode)
		end

		-- Deactivate current module if there is one
		if prevOcclusionModule then
			-- Sanity check that current module is not being replaced by itself (that should have been handled above)
			if prevOcclusionModule ~= self.activeOcclusionModule then
				prevOcclusionModule:Enable(false)
			else
				warn("CameraScript ActivateOcclusionModule failure to detect already running correct module")
			end
		end

		-- Occlusion modules need to be initialized with information about characters and cameraSubject
		-- Invisicam needs the LocalPlayer's character
		-- Poppercam needs all player characters and the camera subject
		if occlusionMode == Enum.DevCameraOcclusionMode.Invisicam then
			-- Optimization to only send Invisicam what we know it needs
			if Players.LocalPlayer.Character then
				self.activeOcclusionModule:CharacterAdded(Players.LocalPlayer.Character, Players.LocalPlayer )
			end
		else
			-- When Poppercam is enabled, we send it all existing player characters for its raycast ignore list
			for _, player in pairs(Players:GetPlayers()) do
				if player and player.Character then
					self.activeOcclusionModule:CharacterAdded(player.Character, player)
				end
			end
			self.activeOcclusionModule:OnCameraSubjectChanged(game.Workspace.CurrentCamera.CameraSubject)
		end

		-- Activate new choice
		self.activeOcclusionModule:Enable(true)
	end
end

function CameraModule:ShouldUseVehicleCamera()
	local camera = workspace.CurrentCamera
	if not camera then
		return false
	end

	local cameraType = camera.CameraType
	local cameraSubject = camera.CameraSubject

	local isEligibleType = cameraType == Enum.CameraType.Custom or cameraType == Enum.CameraType.Follow
	local isEligibleSubject = cameraSubject and cameraSubject:IsA("VehicleSeat") or false
	local isEligibleOcclusionMode = self.occlusionMode ~= Enum.DevCameraOcclusionMode.Invisicam

	return isEligibleSubject and isEligibleType and isEligibleOcclusionMode
end

-- When supplied, legacyCameraType is used and cameraMovementMode is ignored (should be nil anyways)
-- Next, if userCameraCreator is passed in, that is used as the cameraCreator
function CameraModule:ActivateCameraController(cameraMovementMode, legacyCameraType: Enum.CameraType?)
	local newCameraCreator = nil

	if legacyCameraType~=nil then

		if legacyCameraType == Enum.CameraType.Scriptable then
			if FFlagUserFixCameraSelectModuleWarning then
				if self.activeCameraController then
					self.activeCameraController:Enable(false)
					self.activeCameraController = nil
				end
				return
			else
				if self.activeCameraController then
					self.activeCameraController:Enable(false)
					self.activeCameraController = nil
					return
				end
			end
		elseif legacyCameraType == Enum.CameraType.Custom then
			cameraMovementMode = self:GetCameraMovementModeFromSettings()

		elseif legacyCameraType == Enum.CameraType.Track then
			-- Note: The TrackCamera module was basically an older, less fully-featured
			-- version of ClassicCamera, no longer actively maintained, but it is re-implemented in
			-- case a game was dependent on its lack of ClassicCamera's extra functionality.
			cameraMovementMode = Enum.ComputerCameraMovementMode.Classic

		elseif legacyCameraType == Enum.CameraType.Follow then
			cameraMovementMode = Enum.ComputerCameraMovementMode.Follow

		elseif legacyCameraType == Enum.CameraType.Orbital then
			cameraMovementMode = Enum.ComputerCameraMovementMode.Orbital

		elseif legacyCameraType == Enum.CameraType.Attach or
			legacyCameraType == Enum.CameraType.Watch or
			legacyCameraType == Enum.CameraType.Fixed then
			newCameraCreator = LegacyCamera
		else
			warn("CameraScript encountered an unhandled Camera.CameraType value: ",legacyCameraType)
		end
	end

	if not newCameraCreator then
		if cameraMovementMode == Enum.ComputerCameraMovementMode.Classic or
			cameraMovementMode == Enum.ComputerCameraMovementMode.Follow or
			cameraMovementMode == Enum.ComputerCameraMovementMode.Default or
			cameraMovementMode == Enum.ComputerCameraMovementMode.CameraToggle then
			newCameraCreator = ClassicCamera
		elseif cameraMovementMode == Enum.ComputerCameraMovementMode.Orbital then
			newCameraCreator = OrbitalCamera
		else
			warn("ActivateCameraController did not select a module.")
			return
		end
	end

	local isVehicleCamera = self:ShouldUseVehicleCamera()
	if isVehicleCamera then
		newCameraCreator = VehicleCamera
	end

	-- Create the camera control module we need if it does not already exist in instantiatedCameraControllers
	local newCameraController
	if not instantiatedCameraControllers[newCameraCreator] then
		newCameraController = newCameraCreator.new()
		instantiatedCameraControllers[newCameraCreator] = newCameraController
	else
		newCameraController = instantiatedCameraControllers[newCameraCreator]
		if newCameraController.Reset then
			newCameraController:Reset()
		end
	end

	if self.activeCameraController then
		-- deactivate the old controller and activate the new one
		if self.activeCameraController ~= newCameraController then
			self.activeCameraController:Enable(false)
			self.activeCameraController = newCameraController
			self.activeCameraController:Enable(true)
		elseif not self.activeCameraController:GetEnabled() then
			self.activeCameraController:Enable(true)
		end
	elseif newCameraController ~= nil then
		-- only activate the new controller
		self.activeCameraController = newCameraController
		self.activeCameraController:Enable(true)
	end

	if self.activeCameraController then
		if cameraMovementMode~=nil then
			self.activeCameraController:SetCameraMovementMode(cameraMovementMode)
		elseif legacyCameraType~=nil then
			-- Note that this is only called when legacyCameraType is not a type that
			-- was convertible to a ComputerCameraMovementMode value, i.e. really only applies to LegacyCamera
			self.activeCameraController:SetCameraType(legacyCameraType)
		end
	end
end

-- Note: The active transparency controller could be made to listen for this event itself.
function CameraModule:OnCameraSubjectChanged()
	local camera = workspace.CurrentCamera
	local cameraSubject = camera and camera.CameraSubject

	if self.activeTransparencyController then
		self.activeTransparencyController:SetSubject(cameraSubject)
	end

	if self.activeOcclusionModule then
		self.activeOcclusionModule:OnCameraSubjectChanged(cameraSubject)
	end

	self:ActivateCameraController(nil, camera.CameraType)
end

function CameraModule:OnCameraTypeChanged(newCameraType: Enum.CameraType)
	if newCameraType == Enum.CameraType.Scriptable then
		if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
	end

	-- Forward the change to ActivateCameraController to handle
	self:ActivateCameraController(nil, newCameraType)
end

-- Note: Called whenever workspace.CurrentCamera changes, but also on initialization of this script
function CameraModule:OnCurrentCameraChanged()
	local currentCamera = game.Workspace.CurrentCamera
	if not currentCamera then return end

	if self.cameraSubjectChangedConn then
		self.cameraSubjectChangedConn:Disconnect()
	end

	if self.cameraTypeChangedConn then
		self.cameraTypeChangedConn:Disconnect()
	end

	self.cameraSubjectChangedConn = currentCamera:GetPropertyChangedSignal("CameraSubject"):Connect(function()
		self:OnCameraSubjectChanged(currentCamera.CameraSubject)
	end)

	self.cameraTypeChangedConn = currentCamera:GetPropertyChangedSignal("CameraType"):Connect(function()
		self:OnCameraTypeChanged(currentCamera.CameraType)
	end)

	self:OnCameraSubjectChanged(currentCamera.CameraSubject)
	self:OnCameraTypeChanged(currentCamera.CameraType)
end

function CameraModule:OnLocalPlayerCameraPropertyChanged(propertyName: string)
	if propertyName == "CameraMode" then
		-- CameraMode is only used to turn on/off forcing the player into first person view. The
		-- Note: The case "Classic" is used for all other views and does not correspond only to the ClassicCamera module
		if Players.LocalPlayer.CameraMode == Enum.CameraMode.LockFirstPerson then
			-- Locked in first person, use ClassicCamera which supports this
			if not self.activeCameraController or self.activeCameraController:GetModuleName() ~= "ClassicCamera" then
				self:ActivateCameraController(CameraUtils.ConvertCameraModeEnumToStandard(Enum.DevComputerCameraMovementMode.Classic))
			end

			if self.activeCameraController then
				self.activeCameraController:UpdateForDistancePropertyChange()
			end
		elseif Players.LocalPlayer.CameraMode == Enum.CameraMode.Classic then
			-- Not locked in first person view
			local cameraMovementMode = self:GetCameraMovementModeFromSettings()
			self:ActivateCameraController(CameraUtils.ConvertCameraModeEnumToStandard(cameraMovementMode))
		else
			warn("Unhandled value for property player.CameraMode: ",Players.LocalPlayer.CameraMode)
		end

	elseif propertyName == "DevComputerCameraMode" or 
		propertyName == "DevTouchCameraMode" then
		local cameraMovementMode = self:GetCameraMovementModeFromSettings()
		self:ActivateCameraController(CameraUtils.ConvertCameraModeEnumToStandard(cameraMovementMode))

	elseif propertyName == "DevCameraOcclusionMode" then
		self:ActivateOcclusionModule(Players.LocalPlayer.DevCameraOcclusionMode)

	elseif propertyName == "CameraMinZoomDistance" or propertyName == "CameraMaxZoomDistance" then
		if self.activeCameraController then
			self.activeCameraController:UpdateForDistancePropertyChange()
		end
	elseif propertyName == "DevTouchMovementMode" then
	elseif propertyName == "DevComputerMovementMode" then
	elseif propertyName == "DevEnableMouseLock" then
		-- This is the enabling/disabling of "Shift Lock" mode, not LockFirstPerson (which is a CameraMode)
		-- Note: Enabling and disabling of MouseLock mode is normally only a publish-time choice made via
		-- the corresponding EnableMouseLockOption checkbox of StarterPlayer, and this script does not have
		-- support for changing the availability of MouseLock at runtime (this would require listening to
		-- Player.DevEnableMouseLock changes)
	end
end

function CameraModule:OnUserGameSettingsPropertyChanged(propertyName: string)
	if propertyName == "ComputerCameraMovementMode" then
		local cameraMovementMode = self:GetCameraMovementModeFromSettings()
		self:ActivateCameraController(CameraUtils.ConvertCameraModeEnumToStandard(cameraMovementMode))
	end
end


function CameraModule:Update(dt)

	if self.activeCameraController then
		self.activeCameraController:UpdateMouseBehavior()

		local newCameraCFrame, newCameraFocus = self.activeCameraController:Update(dt)
		self.activeCameraController:ApplyVRTransform()
		if self.activeOcclusionModule then
			newCameraCFrame, newCameraFocus = self.activeOcclusionModule:Update(dt, newCameraCFrame, newCameraFocus)
		end

		-- Here is where the new CFrame and Focus are set for this render frame
		game.Workspace.CurrentCamera.CFrame = newCameraCFrame
		game.Workspace.CurrentCamera.Focus = newCameraFocus

		-- Update to character local transparency as needed based on camera-to-subject distance
		if self.activeTransparencyController then
			self.activeTransparencyController:Update()
		end

		if CameraInput.getInputEnabled() then
			CameraInput.resetInputForFrameEnd()
		end
	end
end

-- Formerly getCurrentCameraMode, this function resolves developer and user camera control settings to
-- decide which camera control module should be instantiated. The old method of converting redundant enum types
function CameraModule:GetCameraControlChoice()
	local player = Players.LocalPlayer

	if player then
		if self.lastInputType == Enum.UserInputType.Touch or UserInputService.TouchEnabled then
			-- Touch
			if player.DevTouchCameraMode == Enum.DevTouchCameraMovementMode.UserChoice then
				return CameraUtils.ConvertCameraModeEnumToStandard( UserGameSettings.TouchCameraMovementMode )
			else
				return CameraUtils.ConvertCameraModeEnumToStandard( player.DevTouchCameraMode )
			end
		else
			-- Computer
			if player.DevComputerCameraMode == Enum.DevComputerCameraMovementMode.UserChoice then
				local computerMovementMode = CameraUtils.ConvertCameraModeEnumToStandard(UserGameSettings.ComputerCameraMovementMode)
				return CameraUtils.ConvertCameraModeEnumToStandard(computerMovementMode)
			else
				return CameraUtils.ConvertCameraModeEnumToStandard(player.DevComputerCameraMode)
			end
		end
	end
end

function CameraModule:OnCharacterAdded(char, player)
	if self.activeOcclusionModule then
		self.activeOcclusionModule:CharacterAdded(char, player)
	end
end

function CameraModule:OnCharacterRemoving(char, player)
	if self.activeOcclusionModule then
		self.activeOcclusionModule:CharacterRemoving(char, player)
	end
end

function CameraModule:OnPlayerAdded(player)
	player.CharacterAdded:Connect(function(char)
		self:OnCharacterAdded(char, player)
	end)
	player.CharacterRemoving:Connect(function(char)
		self:OnCharacterRemoving(char, player)
	end)
end

function CameraModule:OnMouseLockToggled()
	if self.activeMouseLockController then
		local mouseLocked = self.activeMouseLockController:GetIsMouseLocked()
		local mouseLockOffset = self.activeMouseLockController:GetMouseLockOffset()
		if self.activeCameraController then
			self.activeCameraController:SetIsMouseLocked(mouseLocked)
			self.activeCameraController:SetMouseLockOffset(mouseLockOffset)
		end
	end
end

local cameraModuleObject = CameraModule.new()
local cameraApi = {}

if FFlagUserRemoveTheCameraApi then
	return cameraApi
else
	return cameraModuleObject
end
]]

local CameraUtils = Instance.new("ModuleScript")
CameraUtils.Name = "CameraUtils"
CameraUtils.Parent = CameraModule
CameraUtils.Source = [[

local CameraUtils = {}

local function round(num: number)
	return math.floor(num + 0.5)
end

-- Critically damped spring class for fluid motion effects
local Spring = {} do
	Spring.__index = Spring

	-- Initialize to a given undamped frequency and default position
	function Spring.new(freq, pos)
		return setmetatable({
			freq = freq,
			goal = pos,
			pos = pos,
			vel = 0,
		}, Spring)
	end

	-- Advance the spring simulation by `dt` seconds
	function Spring:step(dt: number)
		local f: number = self.freq*2*math.pi
		local g: Vector3 = self.goal
		local p0: Vector3 = self.pos
		local v0: Vector3 = self.vel

		local offset = p0 - g
		local decay = math.exp(-f*dt)

		local p1 = (offset*(1 + f*dt) + v0*dt)*decay + g
		local v1 = (v0*(1 - f*dt) - offset*(f*f*dt))*decay

		self.pos = p1
		self.vel = v1

		return p1
	end
end

CameraUtils.Spring = Spring

-- map a value from one range to another
function CameraUtils.map(x: number, inMin: number, inMax: number, outMin: number, outMax: number): number
	return (x - inMin)*(outMax - outMin)/(inMax - inMin) + outMin
end

-- maps a value from one range to another, clamping to the output range. order does not matter
function CameraUtils.mapClamp(x: number, inMin: number, inMax: number, outMin: number, outMax: number): number
	return math.clamp(
		(x - inMin)*(outMax - outMin)/(inMax - inMin) + outMin,
		math.min(outMin, outMax),
		math.max(outMin, outMax)
	)
end

-- Ritter's loose bounding sphere algorithm
function CameraUtils.getLooseBoundingSphere(parts: {BasePart})
	local points = table.create(#parts)
	for idx, part in pairs(parts) do
		points[idx] = part.Position
	end

	-- pick an arbitrary starting point
	local x = points[1]

	-- get y, the point furthest from x
	local y = x
	local yDist = 0

	for _, p in ipairs(points) do
		local pDist = (p - x).Magnitude

		if pDist > yDist then
			y = p
			yDist = pDist
		end
	end

	-- get z, the point furthest from y
	local z = y
	local zDist = 0

	for _, p in ipairs(points) do
		local pDist = (p - y).Magnitude

		if pDist > zDist then
			z = p
			zDist = pDist
		end
	end

	-- use (y, z) as the initial bounding sphere
	local sc = (y + z)*0.5
	local sr = (y - z).Magnitude*0.5

	-- expand sphere to fit any outlying points
	for _, p in ipairs(points) do
		local pDist = (p - sc).Magnitude

		if pDist > sr then
			-- shift to midpoint
			sc = sc + (pDist - sr)*0.5*(p - sc).Unit

			-- expand
			sr = (pDist + sr)*0.5
		end
	end

	return sc, sr
end

-- canonicalize an angle to +-180 degrees
function CameraUtils.sanitizeAngle(a: number): number
	return (a + math.pi)%(2*math.pi) - math.pi
end

-- From TransparencyController
function CameraUtils.Round(num: number, places: number): number
	local decimalPivot = 10^places
	return math.floor(num * decimalPivot + 0.5) / decimalPivot
end

function CameraUtils.IsFinite(val: number): boolean
	return val == val and val ~= math.huge and val ~= -math.huge
end

function CameraUtils.IsFiniteVector3(vec3: Vector3): boolean
	return CameraUtils.IsFinite(vec3.X) and CameraUtils.IsFinite(vec3.Y) and CameraUtils.IsFinite(vec3.Z)
end

-- Legacy implementation renamed
function CameraUtils.GetAngleBetweenXZVectors(v1: Vector3, v2: Vector3): number
	return math.atan2(v2.X*v1.Z-v2.Z*v1.X, v2.X*v1.X+v2.Z*v1.Z)
end

function CameraUtils.RotateVectorByAngleAndRound(camLook: Vector3, rotateAngle: number, roundAmount: number): number
	if camLook.Magnitude > 0 then
		camLook = camLook.unit
		local currAngle = math.atan2(camLook.z, camLook.x)
		local newAngle = round((math.atan2(camLook.z, camLook.x) + rotateAngle) / roundAmount) * roundAmount
		return newAngle - currAngle
	end
	return 0
end

-- K is a tunable parameter that changes the shape of the S-curve
-- the larger K is the more straight/linear the curve gets
local k = 0.35
local lowerK = 0.8
local function SCurveTranform(t: number)
	t = math.clamp(t, -1, 1)
	if t >= 0 then
		return (k*t) / (k - t + 1)
	end
	return -((lowerK*-t) / (lowerK + t + 1))
end

local DEADZONE = 0.1
local function toSCurveSpace(t: number)
	return (1 + DEADZONE) * (2*math.abs(t) - 1) - DEADZONE
end

local function fromSCurveSpace(t: number)
	return t/2 + 0.5
end

function CameraUtils.GamepadLinearToCurve(thumbstickPosition: Vector2)
	local function onAxis(axisValue)
		local sign = 1
		if axisValue < 0 then
			sign = -1
		end
		local point = fromSCurveSpace(SCurveTranform(toSCurveSpace(math.abs(axisValue))))
		point = point * sign
		return math.clamp(point, -1, 1)
	end
	return Vector2.new(onAxis(thumbstickPosition.x), onAxis(thumbstickPosition.y))
end

-- This function converts 4 different, redundant enumeration types to one standard so the values can be compared
function CameraUtils.ConvertCameraModeEnumToStandard(enumValue: 
	Enum.TouchCameraMovementMode | 
	Enum.ComputerCameraMovementMode | 
	Enum.DevTouchCameraMovementMode |
	Enum.DevComputerCameraMovementMode): Enum.ComputerCameraMovementMode | Enum.DevComputerCameraMovementMode
	if enumValue == Enum.TouchCameraMovementMode.Default then
		return Enum.ComputerCameraMovementMode.Follow
	end

	if enumValue == Enum.ComputerCameraMovementMode.Default then
		return Enum.ComputerCameraMovementMode.Classic
	end

	if enumValue == Enum.TouchCameraMovementMode.Classic or
		enumValue == Enum.DevTouchCameraMovementMode.Classic or
		enumValue == Enum.DevComputerCameraMovementMode.Classic or
		enumValue == Enum.ComputerCameraMovementMode.Classic then
		return Enum.ComputerCameraMovementMode.Classic
	end

	if enumValue == Enum.TouchCameraMovementMode.Follow or
		enumValue == Enum.DevTouchCameraMovementMode.Follow or
		enumValue == Enum.DevComputerCameraMovementMode.Follow or
		enumValue == Enum.ComputerCameraMovementMode.Follow then
		return Enum.ComputerCameraMovementMode.Follow
	end

	if enumValue == Enum.TouchCameraMovementMode.Orbital or
		enumValue == Enum.DevTouchCameraMovementMode.Orbital or
		enumValue == Enum.DevComputerCameraMovementMode.Orbital or
		enumValue == Enum.ComputerCameraMovementMode.Orbital then
		return Enum.ComputerCameraMovementMode.Orbital
	end

	if enumValue == Enum.ComputerCameraMovementMode.CameraToggle or
		enumValue == Enum.DevComputerCameraMovementMode.CameraToggle then
		return Enum.ComputerCameraMovementMode.CameraToggle
	end

	-- Note: Only the Dev versions of the Enums have UserChoice as an option
	if enumValue == Enum.DevTouchCameraMovementMode.UserChoice or
		enumValue == Enum.DevComputerCameraMovementMode.UserChoice then
		return Enum.DevComputerCameraMovementMode.UserChoice
	end

	-- For any unmapped options return Classic camera
	return Enum.ComputerCameraMovementMode.Classic
end

return CameraUtils

]]

local BaseOcclusion = Instance.new("ModuleScript")
BaseOcclusion.Name = "BaseOcclusion"
BaseOcclusion.Parent = CameraModule
BaseOcclusion.Source = [[
local BaseOcclusion = {}
BaseOcclusion.__index = BaseOcclusion
setmetatable(BaseOcclusion, {
	__call = function(_, ...)
		return BaseOcclusion.new(...)
	end
})

function BaseOcclusion.new()
	local self = setmetatable({}, BaseOcclusion)
	return self
end

-- Called when character is added
function BaseOcclusion:CharacterAdded(char: Model, player: Player)
end

-- Called when character is about to be removed
function BaseOcclusion:CharacterRemoving(char: Model, player: Player)
end

function BaseOcclusion:OnCameraSubjectChanged(newSubject)
end
function BaseOcclusion:GetOcclusionMode(): Enum.DevCameraOcclusionMode?
	-- Must be overridden in derived classes to return an Enum.DevCameraOcclusionMode value
	warn("BaseOcclusion GetOcclusionMode must be overridden by derived classes")
	return nil
end

function BaseOcclusion:Enable(enabled: boolean)
	warn("BaseOcclusion Enable must be overridden by derived classes")
end

function BaseOcclusion:Update(dt: number, desiredCameraCFrame: CFrame, desiredCameraFocus: CFrame)
	warn("BaseOcclusion Update must be overridden by derived classes")
	return desiredCameraCFrame, desiredCameraFocus
end

return BaseOcclusion
]]

local BaseCamera = Instance.new("ModuleScript")
BaseCamera.Name = "BaseCamera"
BaseCamera.Parent = CameraModule

local VehicleCamera = Instance.new("ModuleScript")
VehicleCamera.Name = "VehicleCamera"
VehicleCamera.Parent = CameraModule

local VehicleCameraCore = Instance.new("ModuleScript")
VehicleCameraCore.Name = "VehicleCameraCore"
VehicleCameraCore.Parent = VehicleCamera

local VehicleCameraConfig = Instance.new("ModuleScript")
VehicleCameraConfig.Name = "VehicleCameraConfig"
VehicleCameraConfig.Parent = VehicleCamera

local CameraInput = Instance.new("ModuleScript")
CameraInput.Name = "CameraInput"
CameraInput.Parent = CameraModule

local ClassicCamera = Instance.new("ModuleScript")
ClassicCamera.Name = "ClassicCamera"
ClassicCamera.Parent = CameraModule

local LegacyCamera = Instance.new("ModuleScript")
LegacyCamera.Name = "LegacyCamera"
LegacyCamera.Parent = CameraModule

local OrbitalCamera = Instance.new("ModuleScript")
OrbitalCamera.Name = "OrbitalCamera"
OrbitalCamera.Parent = CameraModule

local Invisicam = Instance.new("ModuleScript")
Invisicam.Name = "Invisicam"
Invisicam.Parent = CameraModule

local Poppercam = Instance.new("ModuleScript")
Poppercam.Name = "Poppercam"
Poppercam.Parent = CameraModule

local ZoomController = Instance.new("ModuleScript")
ZoomController.Name = "ZoomController"
ZoomController.Parent = CameraModule

local Popper = Instance.new("ModuleScript")
Popper.Name = "Popper"
Popper.Parent = ZoomController

local TransparencyController = Instance.new("ModuleScript")
TransparencyController.Name = "TransparencyController"
TransparencyController.Parent = CameraModule

local CameraToggleStateController = Instance.new("ModuleScript")
CameraToggleStateController.Name = "CameraToggleStateController"
CameraToggleStateController.Parent = CameraModule

local MouseLockController = Instance.new("ModuleScript")
MouseLockController.Name = "MouseLockController"
MouseLockController.Parent = CameraModule

local BoundKeys = Instance.new("StringValue")
BoundKeys.Name = "BoundKeys"
BoundKeys.Value = "LeftShift,RightShift"
BoundKeys.Parent = MouseLockController

local CameraUI = Instance.new("ModuleScript")
CameraUI.Name = "CameraUI"
CameraUI.Parent = CameraModule

local ControlModule = Instance.new("ModuleScript")
ControlModule.Name = "ControlModule"
ControlModule.Parent = PlayerModule

local ClickToMoveDisplay = Instance.new("ModuleScript")
ClickToMoveDisplay.Name = "ClickToMoveDisplay"
ClickToMoveDisplay.Parent = ControlModule

local TouchThumbstick = Instance.new("ModuleScript")
TouchThumbstick.Name = "TouchThumbstick"
TouchThumbstick.Parent = ControlModule

local DynamicThumbstick = Instance.new("ModuleScript")
DynamicThumbstick.Name = "DynamicThumbstick"
DynamicThumbstick.Parent = ControlModule

local BaseCharacterController = Instance.new("ModuleScript")
BaseCharacterController.Name = "BaseCharacterController"
BaseCharacterController.Parent = ControlModule

local TouchJump = Instance.new("ModuleScript")
TouchJump.Name = "TouchJump"
TouchJump.Parent = ControlModule

local VRNavigation = Instance.new("ModuleScript")
VRNavigation.Name = "VRNavigation"
VRNavigation.Parent = ControlModule

local PathDisplay = Instance.new("ModuleScript")
PathDisplay.Name = "PathDisplay"
PathDisplay.Parent = ControlModule

local Gamepad = Instance.new("ModuleScript")
Gamepad.Name = "Gamepad"
Gamepad.Parent = ControlModule

local Keyboard = Instance.new("ModuleScript")
Keyboard.Name = "Keyboard"
Keyboard.Parent = ControlModule

local VehicleController = Instance.new("ModuleScript")
VehicleController.Name = "VehicleController"
VehicleController.Parent = ControlModule

local ClickToMoveController = Instance.new("ModuleScript")
ClickToMoveController.Name = "ClickToMoveController"
ClickToMoveController.Parent = ControlModule

PlayerModule.Parent = workspace
