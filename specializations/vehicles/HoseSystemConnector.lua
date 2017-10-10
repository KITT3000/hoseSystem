--
-- HoseSystemConnector
--
-- Authors: Wopster
-- Description: The HoseSystem connector script for vehicles
--
-- Copyright (c) Wopster, 2017

HoseSystemConnector = {
    baseDirectory = g_currentModDirectory
}

HoseSystemConnector.numTypes = 0
HoseSystemConnector.typesToInt = {}

HoseSystemConnector.PLAYER_DISTANCE = 1.3
HoseSystemConnector.DEFAULT_INRANGE_DISTANCE = 1.3

local srcDirectory = HoseSystemConnector.baseDirectory .. 'specializations/vehicles/strategies'

local files = {
    ('%s/%s'):format(srcDirectory, 'HoseSystemHoseCouplingStrategy.lua'),
    ('%s/%s'):format(srcDirectory, 'HoseSystemDockStrategy.lua')
}

for _, path in pairs(files) do
    source(path)
end

---
-- @param name
--
function HoseSystemConnector.formatTypeKey(name)
    return ('type_%s'):format(name:lower())
end

---
-- @param name
--
function HoseSystemConnector.registerType(name)
    local key = HoseSystemConnector.formatTypeKey(name)

    if HoseSystemConnector.typesToInt[key] == nil then
        HoseSystemConnector.numTypes = HoseSystemConnector.numTypes + 1
        HoseSystemConnector.typesToInt[key] = HoseSystemConnector.numTypes
    end
end

---
-- @param name
--
function HoseSystemConnector.getInitialType(name)
    local key = HoseSystemConnector.formatTypeKey(name)

    if HoseSystemConnector.typesToInt[key] ~= nil then
        return HoseSystemConnector.typesToInt[key]
    end

    return nil
end

HoseSystemConnector.registerType(HoseSystemHoseCouplingStrategy.TYPE)
HoseSystemConnector.registerType(HoseSystemDockStrategy.TYPE)

---
-- @param specializations
--
function HoseSystemConnector.prerequisitesPresent(specializations)
    return true
end

---
-- @param savegame
--
function HoseSystemConnector:preLoad(savegame)
    self.toggleLock = HoseSystemConnector.toggleLock
    self.toggleManureFlow = HoseSystemConnector.toggleManureFlow
    self.setIsUsed = HoseSystemConnector.setIsUsed
    self.getConnectedReference = HoseSystemConnector.getConnectedReference
    self.getValidFillObject = HoseSystemConnector.getValidFillObject
    self.getAllowedFillUnitIndex = HoseSystemConnector.getAllowedFillUnitIndex
    self.getLastGrabpointRecursively = HoseSystemConnector.getLastGrabpointRecursively
    self.getIsPlayerInReferenceRange = HoseSystemConnector.getIsPlayerInReferenceRange
    self.updateLiquidHoseSystem = HoseSystemConnector.updateLiquidHoseSystem

    -- overwrittenFunctions
    self.getIsOverloadingAllowed = Utils.overwrittenFunction(self.getIsOverloadingAllowed, HoseSystemConnector.getIsOverloadingAllowed)
end

---
-- @param savegame
--
function HoseSystemConnector:load(savegame)
    self.connectStrategies = {}

    table.insert(self.connectStrategies, HoseSystemDockStrategy:new(self))
    table.insert(self.connectStrategies, HoseSystemHoseCouplingStrategy:new(self))

    self.hoseSystemReferences = {}
    self.dockingSystemReferences = {}

    HoseSystemConnector.loadHoseReferences(self, self.xmlFile, 'vehicle.hoseSystemReferences.', self.hoseSystemReferences)
    -- HoseSystemConnector.loadDockingReferences(self, self.xmlFile, 'vehicle.dockingSystemReferences.', self.dockingSystemReferences)

    self.fillObject = nil
    self.fillObjectFound = false
    self.fillObjectHasPlane = false
    self.fillFromFillVolume = false
    self.fillUnitIndex = 0
    self.isSucking = false

    if self.isServer then
        self.lastFillObjectFound = false
        self.lastFillObjectHasPlane = false
        self.lastFillFromFillVolume = false
        self.lastFillUnitIndex = 0
    end

    if self.hasHoseSystemPumpMotor then
        self.pumpMotorFillMode = HoseSystemPumpMotor.getInitialFillMode('hoseSystem')
    end

    self.hasHoseSystem = true

    if self.unloadTrigger ~= nil then
        self.unloadTrigger:delete()
        self.unloadTrigger = nil
    end

    HoseSystemConnector:updateCurrentMissionInfo(self)
end

---
-- @param savegame
--
function HoseSystemConnector:postLoad(savegame)
    if savegame ~= nil and not savegame.resetVehicles then
        for id, reference in ipairs(self.hoseSystemReferences) do
            local key = string.format('%s.reference(%d)', savegame.key, id - 1)

            self:toggleLock(id, Utils.getNoNil(getXMLBool(savegame.xmlFile, key .. '#isLocked'), false), false, true)
            self:toggleManureFlow(id, Utils.getNoNil(getXMLBool(savegame.xmlFile, key .. '#flowOpened'), false), false, true)
        end
    end
end

---
-- @param self
-- @param xmlFile
-- @param base
-- @param references
--
function HoseSystemConnector.loadHoseReferences(self, xmlFile, base, references)
    local i = 0

    while true do
        local key = string.format(base .. 'hoseSystemReference(%d)', i)

        if not hasXMLProperty(xmlFile, key) then
            break
        end

        if #references == 2 ^ HoseSystemUtil.eventHelper.REFERENCES_NUM_SEND_BITS then
            HoseSystemUtil:log(HoseSystemUtil.ERROR, ('Max number of references is %s!'):format(2 ^ HoseSystemUtil.eventHelper.REFERENCES_NUM_SEND_BITS))
            break
        end

        -- Call strategies to load do this dirty for now.

        local typeString = getXMLString(xmlFile, key .. '#type')
        local typeDefault = HoseSystemConnector.getInitialType('hoseCoupling')
        local type = typeDefault

        if typeString ~= nil then
            type = HoseSystemConnector.getInitialType(typeString)

            if type == nil then
                HoseSystemUtil:log(HoseSystemUtil.ERROR, ('Invalid connector type %s!'):format(typeString))
                type = typeDefault
            end
        end

        if typeString == nil then
            typeString = 'hoseCoupling'
        end

        local createNode = Utils.getNoNil(getXMLBool(xmlFile, key .. '#createNode'), false)
        local node = not createNode and Utils.indexToObject(self.components, getXMLString(xmlFile, key .. '#index')) or createTransformGroup(('hoseSystemReference_node_%d'):format(i + 1))

        if createNode then
            local linkNode = Utils.indexToObject(self.components, Utils.getNoNil(getXMLString(xmlFile, key .. '#linkNode'), '0>'))

            local translation = { Utils.getVectorFromString(getXMLString(self.xmlFile, key .. '#position')) }
            if translation[1] ~= nil and translation[2] ~= nil and translation[3] ~= nil then
                setTranslation(node, unpack(translation))
            end

            local rotation = { Utils.getVectorFromString(getXMLString(self.xmlFile, key .. '#rotation')) }
            if rotation[1] ~= nil and rotation[2] ~= nil and rotation[3] ~= nil then
                setRotation(node, Utils.degToRad(rotation[1]), Utils.degToRad(rotation[2]), Utils.degToRad(rotation[3]))
            end

            link(linkNode, node)
        end

        if node ~= nil then
            -- defaults
            local entry = {
                id = i + 1,
                type = type,
                node = node,
                inRangeDistance = Utils.getNoNil(getXMLFloat(xmlFile, key .. 'inRangeDistance'), HoseSystemConnector.DEFAULT_INRANGE_DISTANCE),
            }

            entry = HoseSystemUtil.callStrategyFunction(self.connectStrategies, 'load' .. HoseSystemUtil:firstToUpper(typeString), { type, xmlFile, key, entry })

            table.insert(references, entry)
        else
            -- Todo: log invalid node
        end

        i = i + 1
    end
end

---
-- @param object
--
function HoseSystemConnector:updateCurrentMissionInfo(object)
    if #object.hoseSystemReferences > 0 then
        if g_currentMission.hoseSystemReferences == nil then
            g_currentMission.hoseSystemReferences = {}
        end

        table.insert(g_currentMission.hoseSystemReferences, object)
    end
end

---
--
function HoseSystemConnector:preDelete()
    if self.hoseSystemReferences ~= nil and g_currentMission.hoseSystemHoses ~= nil then
        for referenceId, reference in pairs(self.hoseSystemReferences) do
            if reference.isUsed then
                if reference.hoseSystem ~= nil and reference.hoseSystem.grabPoints ~= nil then
                    for grabPointIndex, grabPoint in pairs(reference.hoseSystem.grabPoints) do
                        if HoseSystem:getIsConnected(grabPoint.state) and grabPoint.connectorRefId == referenceId then
                            reference.hoseSystem.poly.interactiveHandling:detach(grabPointIndex, self, referenceId, false)
                        end
                    end
                end
            end
        end
    end
end

---
--
function HoseSystemConnector:delete()
    HoseSystemUtil:removeElementFromList(g_currentMission.hoseSystemReferences, self)
    HoseSystemUtil:removeElementFromList(g_currentMission.dockingSystemReferences, self)
end

---
-- @param streamId
-- @param connection
--
function HoseSystemConnector:readStream(streamId, connection)
    if connection:getIsServer() then
        --
    end

    for _, class in pairs(self.connectStrategies) do
        if class.readStream ~= nil then
            class:readStream(streamId, connection)
        end
    end
end

---
-- @param streamId
-- @param connection
--
function HoseSystemConnector:writeStream(streamId, connection)
    if not connection:getIsServer() then
        --
    end

    for _, class in pairs(self.connectStrategies) do
        if class.writeStream ~= nil then
            class:writeStream(streamId, connection)
        end
    end
end

---
-- @param nodeIdent
--
function HoseSystemConnector:getSaveAttributesAndNodes(nodeIdent)
    local nodes = ""

    if self.hoseSystemReferences ~= nil then
        for id, reference in pairs(self.hoseSystemReferences) do
            if id > 1 then
                nodes = nodes .. "\n"
            end

            nodes = nodes .. nodeIdent .. ('<reference id="%s" isLocked="%s" flowOpened="%s" />'):format(id, tostring(reference.isLocked), tostring(reference.flowOpened))
        end
    end

    return nil, nodes
end

---
-- @param posX
-- @param posY
-- @param isDown
-- @param isUp
-- @param button
--
function HoseSystemConnector:mouseEvent(posX, posY, isDown, isUp, button)
end

---
-- @param unicode
-- @param sym
-- @param modifier
-- @param isDown
--
function HoseSystemConnector:keyEvent(unicode, sym, modifier, isDown)
end

---
-- @param dt
--
function HoseSystemConnector:update(dt)
    for _, class in pairs(self.connectStrategies) do
        if class.update ~= nil then
            class:update(dt)
        end
    end
end

---
-- @param dt
--
function HoseSystemConnector:updateTick(dt)
    if self.hasHoseSystemPumpMotor then
        self:getValidFillObject()

        if self.isServer then
            if self:getFillMode() == self.pumpMotorFillMode then
                local isSucking = false

                local reference = self.hoseSystemReferences[self.currentReferenceIndex]

                -- Todo: Moved feature to version 1.1 determine pump efficiency based on hose chain lenght
                --                if reference ~= nil then
                --                    local count = self.pumpFillEfficiency.maxTimeStatic / 10 * reference.hoseSystem.currentChainCount
                --                    self.pumpFillEfficiency.maxTime = reference.hoseSystem.currentChainCount > 0 and  self.pumpFillEfficiency.maxTimeStatic + count or self.pumpFillEfficiency.maxTimeStatic
                --                    print("CurrentChainCount= " .. reference.hoseSystem.currentChainCount .. "maxTime= " .. self.pumpFillEfficiency.maxTime .. 'What we do to it= ' .. count)
                --                end

                if self.pumpIsStarted and self.fillObject ~= nil then
                    if self.fillDirection == HoseSystemPumpMotor.IN then
                        local objectFillTypes = self.fillObject:getCurrentFillTypes()

                        -- isn't below dubble code?
                        if self.fillObject:getFreeCapacity() ~= self.fillObject:getCapacity() then
                            for _, objectFillType in pairs(objectFillTypes) do
                                if self:allowUnitFillType(self.fillUnitIndex, objectFillType, false) then
                                    local objectFillLevel = self.fillObject:getFillLevel(objectFillType)
                                    local fillLevel = self:getUnitFillLevel(self.fillUnitIndex)

                                    if objectFillLevel > 0 and fillLevel < self:getUnitCapacity(self.fillUnitIndex) then
                                        if self.fillObject.checkPlaneY ~= nil then
                                            local lastGrabPoint, _ = self:getLastGrabpointRecursively(reference.hoseSystem.grabPoints[HoseSystemConnector:getFillableVehicle(self.currentGrabPointIndex, #reference.hoseSystem.grabPoints)])

                                            if not HoseSystem:getIsConnected(lastGrabPoint.state) then
                                                local _, y, _ = getWorldTranslation(lastGrabPoint.raycastNode)

                                                if reference.hoseSystem.lastRaycastDistance ~= 0 then
                                                    isSucking, _ = self.fillObject:checkPlaneY(y)
                                                end
                                            else
                                                isSucking = reference ~= nil
                                            end
                                        else
                                            isSucking = reference ~= nil
                                        end

                                        self:pumpIn(dt, objectFillLevel, objectFillType)
                                    else
                                        self:setPumpStarted(false, HoseSystemPumpMotor.UNIT_EMPTY)
                                    end
                                else
                                    self:setPumpStarted(false, HoseSystemPumpMotor.INVALID_FILLTYPE)
                                end
                            end
                        else
                            self:setPumpStarted(false, HoseSystemPumpMotor.OBJECT_EMPTY)
                        end
                    else
                        self:pumpOut(dt)
                    end
                end

                if self.isSucking ~= isSucking then
                    self.isSucking = isSucking
                    g_server:broadcastEvent(IsSuckingEvent:new(self, self.isSucking))
                end
            end

            if self.fillObjectFound then
                if self.fillObject ~= nil and self.fillObject.checkPlaneY ~= nil then -- we are raycasting a fillplane
                    if self.fillObject.updateShaderPlane ~= nil then
                        self.fillObject:updateShaderPlane(self.pumpIsStarted, self.fillDirection, self.pumpFillEfficiency.litersPerSecond)
                    end
                end
            end
        end

        if self.isClient then
            if self.fillObjectHasPlane then
                if self.fillObjectFound or self.fillFromFillVolume then
                    self:updateLiquidHoseSystem(true)
                end
            else
                if not self.fillObjectFound and self.pumpIsStarted then
                    self:updateLiquidHoseSystem(false)
                end
            end
        end
    end
end

---
--
function HoseSystemConnector:draw()
end

---
-- @param allow
--
function HoseSystemConnector:updateLiquidHoseSystem(allow)
    if self.currentGrabPointIndex ~= nil and self.currentReferenceIndex ~= nil then
        local reference = self.hoseSystemReferences[self.currentReferenceIndex]

        if reference ~= nil then
            local lastGrabPoint, lastHose = self:getLastGrabpointRecursively(reference.hoseSystem.grabPoints[HoseSystemConnector:getFillableVehicle(self.currentGrabPointIndex, #reference.hoseSystem.grabPoints)], reference.hoseSystem)

            if lastGrabPoint ~= nil and lastHose ~= nil then
                local fillType = self:getUnitLastValidFillType(self.fillUnitIndex)

                lastHose:toggleEmptyingEffect(allow and self.pumpIsStarted and self.fillDirection == HoseSystemPumpMotor.OUT, lastGrabPoint.id > 1 and 1 or -1, lastGrabPoint.id, fillType)
            end
        end
    end
end

---
--
function HoseSystemConnector:getIsPlayerInReferenceRange()
    local playerTrans = { getWorldTranslation(g_currentMission.player.rootNode) }
    local playerDistanceSequence = HoseSystemConnector.PLAYER_DISTANCE

    if self.hoseSystemReferences ~= nil then
        for referenceId, reference in pairs(self.hoseSystemReferences) do
            if reference.isUsed and not reference.parkable and reference.hoseSystem ~= nil then
                local trans = { getWorldTranslation(reference.node) }
                local distance = Utils.vector3Length(trans[1] - playerTrans[1], trans[2] - playerTrans[2], trans[3] - playerTrans[3])

                playerDistanceSequence = Utils.getNoNil(reference.inRangeDistance, playerDistanceSequence)

                if distance < playerDistanceSequence then
                    playerDistanceSequence = distance

                    return true, referenceId
                end
            end
        end
    end

    return false, nil
end

---
-- @param object
--
function HoseSystemConnector:getAllowedFillUnitIndex(object)
    if self.fillUnits == nil then
        return 0
    end

    for index, fillUnit in pairs(self.fillUnits) do
        if fillUnit.currentFillType ~= FillUtil.FILLTYPE_UNKNOWN then
            if object:allowFillType(fillUnit.currentFillType) then
                return index
            end
        else
            local fillTypes = self:getUnitFillTypes(index)

            for fillType, bool in pairs(fillTypes) do
                -- check if object accepts any of our fillTypes
                if object:allowFillType(fillType) then
                    return index
                end
            end
        end
    end

    return 0
end

---
--
function HoseSystemConnector:getValidFillObject()
    self.currentReferenceIndex = nil
    self.currentGrabPointIndex = nil

    self.currentReferenceIndex, self.currentGrabPointIndex = self:getConnectedReference()

    if self.isServer then
        if self:getFillMode() == self.pumpMotorFillMode then
            -- clean tables/bools
            self.fillObject = nil
            self.fillObjectFound = false
            self.fillObjectIsObject = false -- to check if we not pump to a vehicle
            self.fillObjectHasPlane = false
            self.fillFromFillVolume = false
            self.fillUnitIndex = 0
        end

        if self.currentGrabPointIndex ~= nil and self.currentReferenceIndex ~= nil then
            local reference = self.hoseSystemReferences[self.currentReferenceIndex]

            if reference ~= nil then
                local lastGrabPoint, _ = self:getLastGrabpointRecursively(reference.hoseSystem.grabPoints[HoseSystemConnector:getFillableVehicle(self.currentGrabPointIndex, #reference.hoseSystem.grabPoints)])

                if lastGrabPoint ~= nil then
                    -- check if the last grabPoint is connected
                    if HoseSystem:getIsConnected(lastGrabPoint.state) and not lastGrabPoint.connectable then
                        local lastVehicle = HoseSystemReferences:getReferenceVehicle(lastGrabPoint.connectorVehicle)
                        local lastReference = lastVehicle.hoseSystemReferences[lastGrabPoint.connectorRefId]

                        if lastReference ~= nil and lastVehicle ~= nil and lastVehicle.grabPoints == nil then -- checks if it's not a hose!
                            if lastReference.isUsed and lastReference.flowOpened and lastReference.isLocked then
                                if lastReference.isObject or SpecializationUtil.hasSpecialization(Fillable, lastVehicle.specializations) then
                                    -- check fill units to allow
                                    local allowedFillUnitIndex = self:getAllowedFillUnitIndex(lastVehicle)

                                    if allowedFillUnitIndex ~= 0 then
                                        if self:getFillMode() ~= self.pumpMotorFillMode then
                                            self:setFillMode(self.pumpMotorFillMode)
                                        end

                                        -- we can pump
                                        self.fillObjectFound = true
                                        self.fillObjectIsObject = lastReference.isObject
                                        self.fillObject = lastVehicle
                                        self.fillUnitIndex = allowedFillUnitIndex
                                    end
                                end
                            end
                        end
                    else
                        if HoseSystem:getIsDetached(lastGrabPoint.state) then -- don't lookup when the player picks up the hose from the pit
                            -- check what the lastGrabPoint has on it's raycast
                            local hoseSystem = reference.hoseSystem

                            if hoseSystem ~= nil then
                                if hoseSystem.lastRaycastDistance ~= 0 then
                                    if hoseSystem.lastRaycastObject ~= nil then -- or how i called it
                                        local allowedFillUnitIndex = self:getAllowedFillUnitIndex(hoseSystem.lastRaycastObject)

                                        if allowedFillUnitIndex ~= 0 then
                                            -- we have something else to pump with
                                            if self:getFillMode() ~= self.pumpMotorFillMode then
                                                self:setFillMode(self.pumpMotorFillMode)
                                            end

                                            -- we can pump
                                            self.fillObjectFound = true
                                            self.fillObject = hoseSystem.lastRaycastObject
                                            self.fillUnitIndex = allowedFillUnitIndex

                                            if self.fillObject.checkPlaneY ~= nil then
                                                self.fillObjectHasPlane = true
                                                self.fillObjectIsObject = true
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        if self:getFillMode() == self.pumpMotorFillMode then
            if self.lastFillObjectFound ~= self.fillObjectFound or self.lastFillFromFillVolume ~= self.fillFromFillVolume or self.lastFillUnitIndex ~= self.fillUnitIndex or self.lastFillObjectHasPlane ~= self.fillObjectHasPlane then
                g_server:broadcastEvent(SendUpdateOnFillEvent:new(self, self.fillObjectFound, self.fillFromFillVolume, self.fillUnitIndex, self.fillObjectHasPlane))

                self.lastFillUnitIndex = self.fillUnitIndex
                self.lastFillObjectFound = self.fillObjectFound
                self.lastFillFromFillVolume = self.fillFromFillVolume
                self.lastFillObjectHasPlane = self.fillObjectHasPlane
            end
        end
    end
end

---
-- @param grabPoint
-- @param hoseSystem
--
function HoseSystemConnector:getLastGrabpointRecursively(grabPoint, hoseSystem)
    if grabPoint ~= nil then
        if grabPoint.connectorVehicle ~= nil then
            if grabPoint.connectorVehicle.grabPoints ~= nil then
                for i, connectorGrabPoint in pairs(grabPoint.connectorVehicle.grabPoints) do
                    if connectorGrabPoint ~= nil then
                        local reference = HoseSystemReferences:getReference(grabPoint.connectorVehicle, grabPoint.connectorRefId, grabPoint)

                        if connectorGrabPoint ~= reference then
                            self:getLastGrabpointRecursively(connectorGrabPoint, reference.hoseSystem)
                        end
                    end
                end
            end
        end

        return grabPoint, hoseSystem
    end

    return nil, nil
end

---
-- @param index
-- @param max
--
function HoseSystemConnector:getFillableVehicle(index, max)
    return index > 1 and 1 or max
end

---
--
function HoseSystemConnector:getConnectedReference()
    -- Todo: Moved to version 1.1
    -- but what if we have more? Can whe pump with multiple hoses? Does that lower the pumpEfficiency or increase the throughput? Priority reference? There is a cleaner way to-do this.

    if self.hoseSystemReferences ~= nil then
        for referenceIndex, reference in pairs(self.hoseSystemReferences) do
            if reference.isUsed and reference.flowOpened and reference.isLocked then
                if reference.hoseSystem ~= nil and reference.hoseSystem.grabPoints ~= nil then
                    for grabPointIndex, grabPoint in pairs(reference.hoseSystem.grabPoints) do
                        if HoseSystem:getIsConnected(grabPoint.state) then
                            if grabPoint.connectorVehicle == self then
                                return referenceIndex, grabPointIndex
                            end
                        end
                    end
                end
            end
        end
    end

    return nil, nil
end

---
-- @param index
-- @param state
-- @param force
-- @param noEventSend
--
function HoseSystemConnector:toggleLock(index, state, force, noEventSend)
    local reference = self.hoseSystemReferences[index]

    if reference ~= nil and not reference.parkable and reference.isLocked ~= state or force then
        HoseSystemReferenceLockEvent.sendEvent(self, index, state, force, noEventSend)

        if reference.lockAnimationName ~= nil then
            local dir = state and 1 or -1
            local shouldPlay = force or not self:getIsAnimationPlaying(reference.lockAnimationName)

            if shouldPlay then
                self:playAnimation(reference.lockAnimationName, dir, nil, true)
                reference.isLocked = state
            end
        else
            reference.isLocked = state
        end
    end
end

---
-- @param index
-- @param state
-- @param force
-- @param noEventSend
--
function HoseSystemConnector:toggleManureFlow(index, state, force, noEventSend)
    local reference = self.hoseSystemReferences[index]

    if reference ~= nil and not reference.parkable and reference.flowOpened ~= state or force then
        HoseSystemReferenceManureFlowEvent.sendEvent(self, index, state, force, noEventSend)

        if reference.manureFlowAnimationName ~= nil then
            local dir = state and 1 or -1
            local shouldPlay = force or not self:getIsAnimationPlaying(reference.manureFlowAnimationName)

            if shouldPlay then
                self:playAnimation(reference.manureFlowAnimationName, dir, nil, true)
                reference.flowOpened = state
            end
        else
            reference.flowOpened = state
        end
    end
end

---
-- @param index
-- @param state
-- @param hoseSystem
-- @param noEventSend
--
function HoseSystemConnector:setIsUsed(index, state, hoseSystem, noEventSend)
    if self.hoseSystemReferences ~= nil then
        local reference = self.hoseSystemReferences[index]

        if reference ~= nil and reference.isUsed ~= state then
            HoseSystemReferenceIsUsedEvent.sendEvent(self, index, state, hoseSystem, noEventSend)

            reference.isUsed = state
            reference.hoseSystem = hoseSystem

            if not reference.parkable then
                if reference.lockAnimationName == nil then
                    self:toggleLock(index, state, true, true)
                end

                if reference.manureFlowAnimationName == nil then
                    self:toggleManureFlow(index, state, true, true)
                end

                -- When detaching while on gameload we do need to sync the animations
                if not state then
                    if reference.isLocked then
                        self:toggleLock(index, not reference.isLocked, false, true)
                    end

                    if reference.flowOpened then
                        self:toggleManureFlow(index, not reference.flowOpened, false, true)
                    end
                end
            end

            if reference.parkable and reference.parkAnimationName ~= nil then
                local dir = state and 1 or -1

                if not self:getIsAnimationPlaying(reference.parkAnimationName) then
                    self:playAnimation(reference.parkAnimationName, dir, nil, true)
                end
            end
        end
    end
end

---
--
function HoseSystemConnector:getIsOverloadingAllowed()
    return false
end