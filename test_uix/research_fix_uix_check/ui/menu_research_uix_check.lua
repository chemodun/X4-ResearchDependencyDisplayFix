local ResearchFixUIXCheck = {}

local menuResearch

function ResearchFixUIXCheck.Init()
	Helper.isDebugCallbacks = true
	menuResearch = Helper.getMenu("ResearchMenu")
	menuResearch.registerCallback("expandNode_before_start_button", add_research_rows)
	DebugError("ResearchDisplayFix: UIX check is inited")
end


function add_research_rows(ftable, resources, data)
	DebugError("ResearchDisplayFix: UIX Check going to add rows")
	if ftable == nil then
		return
	end
	local row = ftable:addRow(nil, { fixed = true })
	row[1]:setColSpan(2):createText("Row added via UIX - one")
	row = ftable:addRow(nil, { fixed = true })
	row[1]:setColSpan(2):createText("Row added via UIX - two")
end

Register_Require_With_Init("extensions.research_fix_uix_check.ui.menu_research_uix_check", ResearchFixUIXCheck, ResearchFixUIXCheck.Init)

return ResearchFixUIXCheck
