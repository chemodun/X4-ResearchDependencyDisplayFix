local ffi = require("ffi")
local C = ffi.C

ffi.cdef [[
  void ClearProductionItems(UniverseID productionmoduleid);
  uint32_t GetAmountOfWareAvailable(const char* wareid, UniverseID productionmoduleid);
  int64_t GetEstimatedResearchPrice(UniverseID containerid, const char* researchwareid);
  uint32_t GetHQs(UniverseID* result, uint32_t resultlen, const char* factionid);
  uint32_t GetNumHQs(const char* factionid);
  uint32_t GetNumResearchModules(UniverseID containerid);
  uint32_t GetNumWares(const char* tags, bool research, const char* licenceownerid, const char* exclusiontags);
  uint32_t GetResearchModules(UniverseID* result, uint32_t resultlen, UniverseID containerid);
  uint32_t GetWares(const char** result, uint32_t resultlen, const char* tags, bool research, const char* licenceownerid, const char* exclusiontags);
  bool HasResearched(const char* wareid);
  void StartResearch(const char* wareid, UniverseID researchmoduleid);
  void UpdateProduction(UniverseID containerormoduleid, bool force);
]]

local Lib = require("extensions.sn_mod_support_apis.ui.Library")

local ResearchDisplayFix = {
	egoMenuOnShowMenu = nil,
	egoMenuDisplay = nil,
	egoMenuExpandNode = nil
}

local menu = {}

-- config variable - put all static setup here
local config = {
	mainFrameLayer = 5,
	expandedMenuFrameLayer = 4,
	nodeoffsetx = 30,
	nodewidth = 270,
}

function ResearchDisplayFix.Init()
	menu = Lib.Get_Egosoft_Menu("ResearchMenu")
	if menu then
		DebugError("ResearchDisplayFix: Initializing Research Menu dependency display Fix")
		ResearchDisplayFix.egoMenuOnShowMenu = menu.onShowMenu
		menu.onShowMenu = function()
			ResearchDisplayFix.onShowMenu()
		end
		ResearchDisplayFix.egoMenuDisplay = menu.display
		menu.display = function()
			ResearchDisplayFix.display()
		end
		ResearchDisplayFix.egoMenuExpandNode = menu.expandNode
		if menu.uix_callbacks ~= nil and type(menu.uix_callbacks) == "table" then
			DebugError("ResearchDisplayFix: Detected UIX - applying UIX specific expandNode fix")
			menu.expandNode = function(_, ftable, _, data)
				ResearchDisplayFix.expandNodeUIX(_, ftable, _, data)
			end
		else
			menu.expandNode = function(_, ftable, _, data)
				ResearchDisplayFix.expandNode(_, ftable, _, data)
			end
		end
		menu.isResearchAvailableEntry = function(techentry)
			return ResearchDisplayFix.isResearchAvailableEntry(techentry)
		end
		DebugError("ResearchDisplayFix: Research Menu dependency display Fix applied")
	end
end

function ResearchDisplayFix.onShowMenu()
	Helper.setTabScrollCallback(menu, menu.onTabScroll)
	registerForEvent("inputModeChanged", getElement("Scene.UIContract"), menu.onInputModeChanged)

	menu.topRows = {}
	menu.firstCols = {}
	menu.selectedRows = {}
	menu.selectedCols = {}

	local stationhqlist = {}
	Helper.ffiVLA(stationhqlist, "UniverseID", C.GetNumHQs, C.GetHQs, "player")
	menu.hq = stationhqlist[1] or 0

	menu.researchmodules = {}
	for i = 1, #stationhqlist do
		Helper.ffiVLA(menu.researchmodules, "UniverseID", C.GetNumResearchModules, C.GetResearchModules, stationhqlist
		[i])
		-- trigger a production update to ensure any completed research items have been added to the player research database
		C.UpdateProduction(stationhqlist[i], false)
	end
	menu.availableresearchmodule = nil

	if #menu.techtree == 0 then
		-- Get all research wares from the WareDB.
		local numtechs = C.GetNumWares("", true, "", "hidden")
		local rawtechlist = ffi.new("const char*[?]", numtechs)
		local temptechlist = {}
		numtechs = C.GetWares(rawtechlist, numtechs, "", true, "", "hidden")
		for i = 0, numtechs - 1 do
			local tech = ffi.string(rawtechlist[i])
			if IsKnownItem("researchables", tech) then
				table.insert(temptechlist, tech)
			end
		end
		-- NB: don't really need to sort at this point, but will help the entries in the menu stay consistent.
		table.sort(temptechlist, Helper.sortWareSortOrder)

		-- print("searching for wares without precursor")
		for i = #temptechlist, 1, -1 do
			local techprecursors, sortorder = GetWareData(temptechlist[i], "researchprecursors", "sortorder")
			if #techprecursors == 0 then
				if not GetWareData(temptechlist[i], "ismissiononly") then
					-- print("found " .. temptechlist[i])
					local state_completed = C.HasResearched(temptechlist[i])
					-- start fix: added empty precursor list
					table.insert(menu.techtree,
						{ [1] = { [1] = { tech = temptechlist[i], sortorder = sortorder, completed = state_completed, precursors = {} } } })
					-- end fix: added empty precursor list
				end
				table.remove(temptechlist, i)
			else
				local hasonlymissionprecursors = true
				for i, precursor in ipairs(techprecursors) do
					if not GetWareData(precursor, "ismissiononly") then
						hasonlymissionprecursors = false
						break
					end
				end
				if hasonlymissionprecursors then
					-- print("found with only mission precursors" .. temptechlist[i])
					local state_completed = C.HasResearched(temptechlist[i])
					-- start fix: added empty precursor list
					table.insert(menu.techtree,
						{ [1] = { [1] = { tech = temptechlist[i], sortorder = sortorder, completed = state_completed, precursors = {} } } })
					-- end fix: added empty precursor list
					table.remove(temptechlist, i)
				end
			end
		end

		-- print("\ngoing through remaining wares")
		local loopcounter = 0
		local idx = 1
		while #temptechlist > 0 do
			-- print("looking at: " .. temptechlist[idx])
			local techprecursors, sortorder = GetWareData(temptechlist[idx], "researchprecursors", "sortorder")
			-- print("    #precusors: " .. #techprecursors)
			local precursordata = {}
			local smallestMainIdx, foundPrecusorCol
			-- try to find all precusors in existing data
			for i, precursor in ipairs(techprecursors) do
				local mainIdx, precursorCol = menu.findTech(menu.techtree, precursor)
				-- print("    precusor " .. precursor .. ": " .. tostring(mainIdx) .. ", " .. tostring(precursorCol))
				if mainIdx and ((not smallestMainIdx) or (smallestMainIdx > mainIdx)) then
					smallestMainIdx = mainIdx
					foundPrecusorCol = precursorCol
				end
				precursordata[i] = { mainIdx = mainIdx, precursorCol = precursorCol }
			end
			-- sort so that highest index comes first - important for deletion order and keeping smallestMainIdx valid
			table.sort(precursordata, menu.precursorSorter)

			if smallestMainIdx then
				-- print("    smallestMainIdx: " .. smallestMainIdx .. ", foundPrecusorCol: " .. foundPrecusorCol)
				-- fix wares without precursors that there wrongly placed in different main entries
				for i, entry in ipairs(precursordata) do
					if entry.mainIdx and (entry.mainIdx ~= smallestMainIdx) then
						-- print("    precusor " .. techprecursors[i] .. " @ " .. entry.mainIdx .. " ... merging")
						for col, columndata in ipairs(menu.techtree[entry.mainIdx]) do
							for techidx, techentry in ipairs(columndata) do
								-- print("    adding menu.techtree[" .. entry.mainIdx .. "][" .. col .. "][" .. techidx .. "] to menu.techtree[" .. smallestMainIdx .. "][" .. col .. "]")
								table.insert(menu.techtree[smallestMainIdx][col], techentry)
							end
						end
						-- print("    removing mainIdx " .. entry.mainIdx)
						table.remove(menu.techtree, entry.mainIdx)
					end
				end

				-- add this tech to the tree and remove it from the list
				local state_completed = C.HasResearched(temptechlist[idx])
				-- start fix: build new entry with precursor links
				local newentry = { tech = temptechlist[idx], sortorder = sortorder, completed = state_completed, precursors = {} }
				for _, precursor in ipairs(techprecursors) do
					local precursorMainIdx, precursorCol, precursorTechIdx = menu.findTech(menu.techtree, precursor)
					if precursorMainIdx and precursorCol and precursorTechIdx then
						newentry.precursors[#newentry.precursors + 1] = menu.techtree[precursorMainIdx][precursorCol]
						[precursorTechIdx]
					end
				end
				-- end fix: build new entry with precursor links
				if menu.techtree[smallestMainIdx][foundPrecusorCol + 1] then
					-- print("    adding")
					-- start fix: adding the data with precursor links
					table.insert(menu.techtree[smallestMainIdx][foundPrecusorCol + 1], newentry)
					-- end fix: adding the data with precursor links
				else
					-- print("    new entry")
					-- start fix: replacing the data with precursor links
					menu.techtree[smallestMainIdx][foundPrecusorCol + 1] = { [1] = newentry }
					-- end fix: replacing the data with precursor links
				end
				-- print("    removed")
				table.remove(temptechlist, idx)
			end

			if idx >= #temptechlist then
				loopcounter = loopcounter + 1
				idx = 1
			else
				idx = idx + 1
			end
			if loopcounter > 100 then
				DebugError("Infinite loop detected - aborting.")
				break
			end
		end
	end

	menu.flowchartRows = 0
	menu.flowchartCols = 0
	local lastsortorder = 0
	for i, mainentry in ipairs(menu.techtree) do
		if (menu.flowchartRows ~= 0) and (math.floor(mainentry[1][1].sortorder / 100) ~= math.floor(lastsortorder / 100)) then
			menu.flowchartRows = menu.flowchartRows + 1
		end
		lastsortorder = mainentry[1][1].sortorder

		menu.flowchartCols = math.max(menu.flowchartCols, #mainentry)
		local maxRows = 0
		for col, columnentry in ipairs(mainentry) do
			maxRows = math.max(maxRows, #columnentry)
			table.sort(columnentry, menu.sortTechName)
		end

		menu.flowchartRows = menu.flowchartRows + maxRows
	end
	-- add column for account node
	menu.flowchartCols = menu.flowchartCols + 1

	menu.display()
end

function ResearchDisplayFix.display()
	-- remove old data
	Helper.clearDataForRefresh(menu)

	-- Organize Visual Menu
	local width = Helper.viewWidth
	local height = Helper.viewHeight
	local xoffset = 0
	local yoffset = 0

	local numcategories = 0

	menu.frame = Helper.createFrameHandle(menu,
		{ height = height, width = width, x = xoffset, y = yoffset, layer = config.mainFrameLayer })
	menu.frame:setBackground("solid", { color = Color["frame_background_semitransparent"] })

	menu.createTopLevel(menu.frame)

	width = width - 2 * Helper.frameBorder
	xoffset = xoffset + Helper.frameBorder

	-- HACK: Disabling the top level tab table as interactive object
	local table_data = menu.frame:addTable(1,
		{ tabOrder = 1, highlightMode = "column", width = width, x = xoffset, y = menu.topLevelOffsetY +
		Helper.borderSize })

	local rightBarX = Helper.viewWidth - Helper.scaleX(Helper.sidebarWidth) - Helper.frameBorder
	local width = rightBarX - Helper.frameBorder - Helper.borderSize

	menu.flowchart = menu.frame:addFlowchart(menu.flowchartRows, menu.flowchartCols,
		{ borderHeight = 3, borderColor = Color["row_background_blue"], minRowHeight = 45, minColWidth = 80, x = Helper
		.frameBorder, y = menu.topLevelOffsetY + Helper.borderSize, width = width })
	menu.flowchart:setDefaultNodeProperties({
		expandedFrameLayer = config.expandedMenuFrameLayer,
		expandedTableNumColumns = 2,
		x = config.nodeoffsetx,
		width = config.nodewidth,
	})
	for col = 2, menu.flowchartCols, 2 do
		menu.flowchart:setColBackgroundColor(col, Color["row_background_blue"])
	end

	-- update current research and available research module
	menu.currentResearch = {}
	for _, module in ipairs(menu.researchmodules) do
		local module64 = ConvertStringTo64Bit(tostring(module))
		local proddata = GetProductionModuleData(module64)
		if (proddata.state == "empty") and (not GetComponentData(module64, "ishacked")) then
			if not menu.availableresearchmodule then
				menu.availableresearchmodule = module
			end
		elseif (proddata.state == "producing") or (proddata.state == "waitingforresources") then
			menu.currentResearch[proddata.blueprintware] = module
		end
	end

	-- update research status of given tech if any
	if menu.checkResearch then
		local mainIdx, col, techIdx = menu.findTech(menu.techtree, menu.checkResearch)
		menu.techtree[mainIdx][col][techIdx].completed = C.HasResearched(menu.checkResearch)
		menu.checkResearch = nil
	end

	-- account info
	if menu.hq ~= 0 then
		local container = ConvertStringTo64Bit(tostring(menu.hq))
		local money, productionmoney = GetComponentData(container, "money", "productionmoney")
		local supplymoney = tonumber(C.GetSupplyBudget(container)) / 100
		local tradewaremoney = tonumber(C.GetTradeWareBudget(container)) / 100
		local budget = math.floor(productionmoney + supplymoney + tradewaremoney)

		local shownamount = money
		local shownmax = math.max(shownamount, budget)

		local statustext = string.format("%s/%s %s", ConvertMoneyString(money, false, true, 3, true, false),
			ConvertMoneyString(productionmoney + supplymoney + tradewaremoney, false, true, 3, true, false),
			ReadText(1001, 101))
		menu.accountnode = menu.flowchart:addNode(1, 1,
			{ data = { account = true }, expandHandler = menu.expandAccountNode },
			{ shape = "rectangle", value = shownamount, max = shownmax }):setText(ReadText(1001, 7413)):setStatusText(
		statustext)

		menu.accountnode.handlers.onExpanded = menu.onFlowchartNodeExpanded
		menu.accountnode.handlers.onCollapsed = menu.onFlowchartNodeCollapsed
	end

	local rowCounter = 1
	local lastsortorder = 0
	for i, mainentry in ipairs(menu.techtree) do
		if (rowCounter ~= 1) and (math.floor(mainentry[1][1].sortorder / 100) ~= math.floor(lastsortorder / 100)) then
			rowCounter = rowCounter + 1
		end
		lastsortorder = mainentry[1][1].sortorder

		local maxRows = 0
		for col, columnentry in ipairs(mainentry) do
			maxRows = math.max(maxRows, #columnentry)
			for j, techentry in ipairs(columnentry) do
				local value, max = 0, 100
				local statusText
				local icon
				local iconmouseovertext
				if techentry.completed then
					value = 100
				elseif menu.currentResearch[techentry.tech] then
					local proddata = GetProductionModuleData(ConvertStringTo64Bit(tostring(menu.currentResearch
					[techentry.tech])))
					value = function() return Helper.round(math.max(1,
							menu.currentResearch[techentry.tech] and
							(GetProductionModuleData(ConvertStringTo64Bit(tostring(menu.currentResearch[techentry.tech]))).cycleprogress or 0) or
							100)) end
					statusText = function() return Helper.round(math.max(1,
							menu.currentResearch[techentry.tech] and
							(GetProductionModuleData(ConvertStringTo64Bit(tostring(menu.currentResearch[techentry.tech]))).cycleprogress or 0) or
							100)) .. " %" end

					if proddata.state == "waitingforresources" then
						local resources = GetWareData(techentry.tech, "resources")
						for _, resourcedata in ipairs(resources) do
							local locamount = C.GetAmountOfWareAvailable(resourcedata.ware,
								menu.currentResearch[techentry.tech])
							if locamount < resourcedata.amount then
								icon = "lso_warning"
								iconmouseovertext = ColorText["text_warning"] .. ReadText(1026, 8007)
								break
							end
						end
					end
					-- start fix: fixed research availability check
				elseif menu.isResearchAvailableEntry(techentry) then
					-- end fix: fixed research availability check
					local resources = GetWareData(techentry.tech, "resources")
					for _, resourcedata in ipairs(resources) do
						local locamount = C.GetAmountOfWareAvailable(resourcedata.ware, menu.availableresearchmodule)
						if locamount < resourcedata.amount then
							icon = "lso_warning"
							iconmouseovertext = ColorText["text_warning"] .. ReadText(1026, 8007)
							break
						end
					end
				end
				local color
				-- start fix: fixed research availability check
				if (not techentry.completed) and (not menu.currentResearch[techentry.tech]) and (not menu.isResearchAvailableEntry(techentry)) then
					-- end fix: fixed research availability check
					color = Color["research_incomplete"]
				end

				techentry.node = menu.flowchart:addNode(rowCounter + j - 1, col + 1,
					{ data = { mainIdx = i, col = col, techdata = techentry }, expandHandler = menu.expandNode },
					{ shape = "stadium", value = value, max = max, statusIconMouseOverText = iconmouseovertext })
				:setText(GetWareData(techentry.tech, "name"), { color = color }):setStatusText(statusText,
					{ color = color })
				techentry.node.properties.outlineColor = color

				if icon then
					techentry.node:setStatusIcon(icon, { color = Color["icon_warning"] })
				end

				techentry.node.handlers.onExpanded = menu.onFlowchartNodeExpanded
				techentry.node.handlers.onCollapsed = menu.onFlowchartNodeCollapsed

				if menu.restoreNodeTech and menu.restoreNodeTech == techentry.tech then
					menu.restoreNode = techentry.node
					menu.restoreNodeTech = nil
				end
				-- start fix: added predecessors handling to apply dependency fix
				local predecessors = techentry.precursors or {}
				if (#predecessors == 0) and (col > 1) then
					local fallbackColumn = mainentry[col - 1]
					if fallbackColumn then
						predecessors = fallbackColumn
					end
				end
				for k = 1, #predecessors do
					local previousentry = predecessors[k]
					if previousentry.node then
						--end fix: added predecessors handling to apply dependency fix
						local edge = previousentry.node:addEdgeTo(techentry.node)
						if not previousentry.completed then
							edge.properties.sourceSlotColor = Color["research_incomplete"]
							edge.properties.color = Color["research_incomplete"]
						end
						edge.properties.destSlotColor = color
					end
				end
			end
		end

		local skiprow = false
		if math.floor(mainentry[1][1].sortorder / 100) ~= math.floor(lastsortorder / 100) then
			lastsortorder = mainentry[1][1].sortorder
			skiprow = true
		end

		rowCounter = rowCounter + maxRows
	end

	menu.restoreFlowchartState("flowchart", menu.flowchart)

	local stationhqlist = {}
	Helper.ffiVLA(stationhqlist, "UniverseID", C.GetNumHQs, C.GetHQs, "player")
	Helper.createRightSideBar(menu.frame, ConvertStringTo64Bit(tostring(stationhqlist[1] or 0)),
		#menu.researchmodules > 0, "research", menu.buttonRightBar)

	-- display view/frame
	menu.frame:display()
end

function ResearchDisplayFix.expandNode(_, ftable, _, data)
	AddUITriggeredEvent(menu.name, "research_selected", data.techdata.tech)
	local description, researchtime = GetWareData(data.techdata.tech, "description", "researchtime")
	-- description
	local row = ftable:addRow(nil, { fixed = true })
	row[1]:setColSpan(2):createText(description .. "\n ", { wordwrap = true })
	if menu.currentResearch[data.techdata.tech] then
		-- remaining time
		local row = ftable:addRow(nil, { fixed = true })
		row[1]:setColSpan(2):createText(function() return menu.researchStateText(data.techdata.tech) end)
		local row = ftable:addRow(nil, { fixed = true })
		row[1]:setColSpan(2):createText(function() return menu.researchTimeText(data.techdata.tech, researchtime) end,
			{ halign = "right" })
		if GetProductionModuleData(ConvertStringTo64Bit(tostring(menu.currentResearch[data.techdata.tech]))).state == "waitingforresources" then
			local resources, precursors = GetWareData(data.techdata.tech, "resources", "researchprecursors")
			-- mission precursors
			local hasmissionprecursors = false
			for i, precursor in ipairs(precursors) do
				if GetWareData(precursor, "ismissiononly") and (not C.HasResearched(precursor)) then
					hasmissionprecursors = true
					break
				end
			end
			if (#precursors > 0) and hasmissionprecursors then
				local row = ftable:addRow(nil, { fixed = true })
				row[1]:setColSpan(2):createText(ReadText(1001, 7412) .. ReadText(1001, 120))
				for i, precursor in ipairs(precursors) do
					local name, ismissiononly = GetWareData(precursor, "name", "ismissiononly")
					if ismissiononly and (not C.HasResearched(precursor)) then
						local row = ftable:addRow(nil, { fixed = true })
						row[1]:setColSpan(2):createText("  " .. name)
					end
				end
			end
			-- resources
			if #resources > 0 then
				local row = ftable:addRow(nil, { fixed = true })
				row[1]:setColSpan(2):createText(ReadText(1001, 7411) .. ReadText(1001, 120))
				for _, resourcedata in ipairs(resources) do
					local locamount = C.GetAmountOfWareAvailable(resourcedata.ware,
						menu.currentResearch[data.techdata.tech])
					local color
					if locamount and (locamount < resourcedata.amount) then
						color = Color["text_warning"]
					end
					local row = ftable:addRow(nil, { fixed = true })
					row[1]:createText("  " .. GetWareData(resourcedata.ware, "name"), { color = color })
					row[2]:createText((locamount and (locamount .. " / ") or "") .. resourcedata.amount,
						{ halign = "right", color = color })
				end
				ftable:addEmptyRow()
				local row = ftable:addRow(nil, { fixed = true })
				row[1]:setColSpan(2):createText(ReadText(1001, 7929) .. ReadText(1001, 120))
				local row = ftable:addRow(nil, { fixed = true })
				row[1]:setColSpan(2):createText(
				ConvertMoneyString(tonumber(C.GetEstimatedResearchPrice(menu.hq, data.techdata.tech)), false, true, 0,
					true, false) .. " " .. ReadText(1001, 101), { halign = "right" })
			end
			-- cancel
			local row = ftable:addRow(true, { fixed = true })
			row[1]:setColSpan(2):createButton({ active = function() return GetProductionModuleData(ConvertStringTo64Bit(
				tostring(menu.currentResearch[data.techdata.tech]))).state == "waitingforresources" end }):setText(
			ReadText(1001, 7410))
			row[1].handlers.onClick = function() return menu.buttonCancelResearch(data.techdata) end
			row[1].properties.uiTriggerID = data.techdata.tech .. "_cancel"
		end
	elseif data.techdata.completed then
		-- completed
		local row = ftable:addRow(nil, { fixed = true })
		row[1]:setColSpan(2):createText(ReadText(1001, 7408))
	else
		-- research time
		local row = ftable:addRow(nil, { fixed = true })
		row[1]:setColSpan(2):createText(ReadText(1001, 7406) .. ReadText(1001, 120))
		local row = ftable:addRow(nil, { fixed = true })
		row[1]:setColSpan(2):createText(ConvertTimeString(researchtime), { halign = "right" })
		local resources, precursors = GetWareData(data.techdata.tech, "resources", "researchprecursors")
		-- mission precursors
		local hasmissionprecursors = false
		for i, precursor in ipairs(precursors) do
			if GetWareData(precursor, "ismissiononly") and (not C.HasResearched(precursor)) then
				hasmissionprecursors = true
				break
			end
		end
		if (#precursors > 0) and hasmissionprecursors then
			local row = ftable:addRow(nil, { fixed = true })
			row[1]:setColSpan(2):createText(ReadText(1001, 7412) .. ReadText(1001, 120))
			for i, precursor in ipairs(precursors) do
				local name, ismissiononly = GetWareData(precursor, "name", "ismissiononly")
				if ismissiononly and (not C.HasResearched(precursor)) then
					local row = ftable:addRow(nil, { fixed = true })
					row[1]:setColSpan(2):createText("  " .. name)
				end
			end
		end
		-- resources
		if #resources > 0 then
			local row = ftable:addRow(nil, { fixed = true })
			row[1]:setColSpan(2):createText(ReadText(1001, 7411) .. ReadText(1001, 120))
			for _, resourcedata in ipairs(resources) do
				local locamount = menu.availableresearchmodule and
				C.GetAmountOfWareAvailable(resourcedata.ware, menu.availableresearchmodule) or nil
				local color
				if locamount and (locamount < resourcedata.amount) then
					color = Color["text_warning"]
				end
				local row = ftable:addRow(nil, { fixed = true })
				row[1]:createText("  " .. GetWareData(resourcedata.ware, "name"), { color = color })
				row[2]:createText((locamount and (locamount .. " / ") or "") .. resourcedata.amount,
					{ halign = "right", color = color })
			end
			ftable:addEmptyRow()
			local row = ftable:addRow(nil, { fixed = true })
			row[1]:setColSpan(2):createText(ReadText(1001, 7929) .. ReadText(1001, 120))
			local row = ftable:addRow(nil, { fixed = true })
			row[1]:setColSpan(2):createText(
			ConvertMoneyString(tonumber(C.GetEstimatedResearchPrice(menu.hq, data.techdata.tech)), false, true, 0, true,
				false) .. " " .. ReadText(1001, 101), { halign = "right" })
		end
		-- start button
		local row = ftable:addRow(true, { fixed = true })
		-- start fix: fixed research availability check
		local isavailable = menu.isResearchAvailableEntry(data.techdata)
		-- end fix: fixed research availability check
		local mouseovertext = ""
		if not isavailable then
			if menu.availableresearchmodule then
				mouseovertext = ColorText["text_error"] .. ReadText(1026, 7402)
			else
				if (#menu.researchmodules > 0) and GetComponentData(ConvertStringTo64Bit(tostring(menu.researchmodules[1])), "ishacked") then
					mouseovertext = ColorText["text_error"] .. ReadText(1026, 7403)
				else
					mouseovertext = ColorText["text_error"] .. ReadText(1026, 7401)
				end
			end
		end
		row[1]:setColSpan(2):createButton({ active = isavailable, mouseOverText = mouseovertext }):setText(ReadText(1001,
			7407))
		row[1].handlers.onClick = function() return menu.buttonStartResearch(data.techdata) end
		row[1].properties.uiTriggerID = data.techdata.tech
	end

	menu.restoreTableState("nodeTable", ftable)
end

function ResearchDisplayFix.expandNodeUIX(_, ftable, _, data)
	AddUITriggeredEvent(menu.name, "research_selected", data.techdata.tech)
	local description, researchtime = GetWareData(data.techdata.tech, "description", "researchtime")
	-- description
	local row = ftable:addRow(nil, { fixed = true })
	row[1]:setColSpan(2):createText(description .. "\n ", { wordwrap = true })
	if menu.currentResearch[data.techdata.tech] then
		-- remaining time
		local row = ftable:addRow(nil, { fixed = true })
		row[1]:setColSpan(2):createText(function() return menu.researchStateText(data.techdata.tech) end)
		local row = ftable:addRow(nil, { fixed = true })
		row[1]:setColSpan(2):createText(function() return menu.researchTimeText(data.techdata.tech, researchtime) end,
			{ halign = "right" })
		if GetProductionModuleData(ConvertStringTo64Bit(tostring(menu.currentResearch[data.techdata.tech]))).state == "waitingforresources" then
			local resources, precursors = GetWareData(data.techdata.tech, "resources", "researchprecursors")
			-- mission precursors
			local hasmissionprecursors = false
			for i, precursor in ipairs(precursors) do
				if GetWareData(precursor, "ismissiononly") and (not C.HasResearched(precursor)) then
					hasmissionprecursors = true
					break
				end
			end
			if (#precursors > 0) and hasmissionprecursors then
				local row = ftable:addRow(nil, { fixed = true })
				row[1]:setColSpan(2):createText(ReadText(1001, 7412) .. ReadText(1001, 120))
				for i, precursor in ipairs(precursors) do
					local name, ismissiononly = GetWareData(precursor, "name", "ismissiononly")
					if ismissiononly and (not C.HasResearched(precursor)) then
						local row = ftable:addRow(nil, { fixed = true })
						row[1]:setColSpan(2):createText("  " .. name)
					end
				end
			end
			-- resources
			if #resources > 0 then
				local row = ftable:addRow(nil, { fixed = true })
				row[1]:setColSpan(2):createText(ReadText(1001, 7411) .. ReadText(1001, 120))
				for _, resourcedata in ipairs(resources) do
					local locamount = C.GetAmountOfWareAvailable(resourcedata.ware,
						menu.currentResearch[data.techdata.tech])
					local color
					if locamount and (locamount < resourcedata.amount) then
						color = Color["text_warning"]
					end
					local row = ftable:addRow(nil, { fixed = true })
					row[1]:createText("  " .. GetWareData(resourcedata.ware, "name"), { color = color })
					row[2]:createText((locamount and (locamount .. " / ") or "") .. resourcedata.amount,
						{ halign = "right", color = color })
				end
				ftable:addEmptyRow()
				local row = ftable:addRow(nil, { fixed = true })
				row[1]:setColSpan(2):createText(ReadText(1001, 7929) .. ReadText(1001, 120))
				local row = ftable:addRow(nil, { fixed = true })
				row[1]:setColSpan(2):createText(
				ConvertMoneyString(tonumber(C.GetEstimatedResearchPrice(menu.hq, data.techdata.tech)), false, true, 0,
					true, false) .. " " .. ReadText(1001, 101), { halign = "right" })
			end
			-- cancel
			local row = ftable:addRow(true, { fixed = true })
			row[1]:setColSpan(2):createButton({ active = function() return GetProductionModuleData(ConvertStringTo64Bit(
				tostring(menu.currentResearch[data.techdata.tech]))).state == "waitingforresources" end }):setText(
			ReadText(1001, 7410))
			row[1].handlers.onClick = function() return menu.buttonCancelResearch(data.techdata) end
			row[1].properties.uiTriggerID = data.techdata.tech .. "_cancel"
		end
	elseif data.techdata.completed then
		-- completed
		local row = ftable:addRow(nil, { fixed = true })
		row[1]:setColSpan(2):createText(ReadText(1001, 7408))
	else
		-- research time
		local row = ftable:addRow(nil, { fixed = true })
		row[1]:setColSpan(2):createText(ReadText(1001, 7406) .. ReadText(1001, 120))
		local row = ftable:addRow(nil, { fixed = true })
		row[1]:setColSpan(2):createText(ConvertTimeString(researchtime), { halign = "right" })
		local resources, precursors = GetWareData(data.techdata.tech, "resources", "researchprecursors")
		-- mission precursors
		local hasmissionprecursors = false
		for i, precursor in ipairs(precursors) do
			if GetWareData(precursor, "ismissiononly") and (not C.HasResearched(precursor)) then
				hasmissionprecursors = true
				break
			end
		end
		if (#precursors > 0) and hasmissionprecursors then
			local row = ftable:addRow(nil, { fixed = true })
			row[1]:setColSpan(2):createText(ReadText(1001, 7412) .. ReadText(1001, 120))
			for i, precursor in ipairs(precursors) do
				local name, ismissiononly = GetWareData(precursor, "name", "ismissiononly")
				if ismissiononly and (not C.HasResearched(precursor)) then
					local row = ftable:addRow(nil, { fixed = true })
					row[1]:setColSpan(2):createText("  " .. name)
				end
			end
		end
		-- resources
		if #resources > 0 then
			local row = ftable:addRow(nil, { fixed = true })
			row[1]:setColSpan(2):createText(ReadText(1001, 7411) .. ReadText(1001, 120))
			for _, resourcedata in ipairs(resources) do
				local locamount = menu.availableresearchmodule and
				C.GetAmountOfWareAvailable(resourcedata.ware, menu.availableresearchmodule) or nil
				local color
				if locamount and (locamount < resourcedata.amount) then
					color = Color["text_warning"]
				end
				local row = ftable:addRow(nil, { fixed = true })
				row[1]:createText("  " .. GetWareData(resourcedata.ware, "name"), { color = color })
				row[2]:createText((locamount and (locamount .. " / ") or "") .. resourcedata.amount,
					{ halign = "right", color = color })
			end
			ftable:addEmptyRow()
			local row = ftable:addRow(nil, { fixed = true })
			row[1]:setColSpan(2):createText(ReadText(1001, 7929) .. ReadText(1001, 120))
			local row = ftable:addRow(nil, { fixed = true })
			row[1]:setColSpan(2):createText(
			ConvertMoneyString(tonumber(C.GetEstimatedResearchPrice(menu.hq, data.techdata.tech)), false, true, 0, true,
				false) .. " " .. ReadText(1001, 101), { halign = "right" })
		end

		-- start: kuertee call-back
		if menu.uix_callbacks["expandNode_before_start_button"] then
			for uix_id, uix_callback in pairs(menu.uix_callbacks["expandNode_before_start_button"]) do
				uix_callback(ftable, resources, data)
			end
		end
		-- end: kuertee call-back

		-- start button
		local row = ftable:addRow(true, { fixed = true })
		-- start fix: fixed research availability check
		local isavailable = menu.isResearchAvailableEntry(data.techdata)
		-- end fix: fixed research availability check
		local mouseovertext = ""
		if not isavailable then
			if menu.availableresearchmodule then
				mouseovertext = ColorText["text_error"] .. ReadText(1026, 7402)
			else
				if (#menu.researchmodules > 0) and GetComponentData(ConvertStringTo64Bit(tostring(menu.researchmodules[1])), "ishacked") then
					mouseovertext = ColorText["text_error"] .. ReadText(1026, 7403)
				else
					mouseovertext = ColorText["text_error"] .. ReadText(1026, 7401)
				end
			end
		end
		row[1]:setColSpan(2):createButton({ active = isavailable, mouseOverText = mouseovertext }):setText(ReadText(1001,
			7407))
		row[1].handlers.onClick = function() return menu.buttonStartResearch(data.techdata) end
		row[1].properties.uiTriggerID = data.techdata.tech
	end

	menu.restoreTableState("nodeTable", ftable)
end

function ResearchDisplayFix.isResearchAvailableEntry(techentry)
	if not menu.availableresearchmodule then
		return false
	end
	if techentry.precursors then
		for i = 1, #techentry.precursors do
			local precursor = techentry.precursors[i]
			if not precursor.completed then
				return false
			end
		end
	end
	return true
end

Register_OnLoad_Init(ResearchDisplayFix.Init, "extensions.research_display_fix.ui.research_display_fix")
