local imgui = require('imgui')

local ui = {}

function ui.new(callbacks)
    return {
        callbacks = callbacks,
        prompts = {},
        prompted = {},
        config_open = { false },
    }
end

function ui.prompt(u, name)
    if u.prompted[name] then
        return false
    end
    u.prompted[name] = true
    u.prompts[#u.prompts + 1] = name
    return true
end

function ui.forget(u, name)
    if name == nil then
        u.prompted = {}
        return
    end
    u.prompted[name] = nil
end

function ui.toggle_config(u)
    u.config_open[1] = not u.config_open[1]
end

local function pop_prompt(u)
    table.remove(u.prompts, 1)
end

local function render_prompt(u)
    local name = u.prompts[1]
    if name == nil then
        return
    end
    imgui.SetNextWindowSize({ 360, -1 }, ImGuiCond_FirstUseEver)
    if imgui.Begin('pafo TH###pafo_th_prompt', nil, bit.bor(ImGuiWindowFlags_NoCollapse, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoSavedSettings)) then
        imgui.Text(('Does %s have TH2, TH3, or TH4?'):fmt(name))
        imgui.Spacing()
        for tier = 2, 4 do
            if imgui.Button(('TH%d'):fmt(tier), { 70, 24 }) then
                u.callbacks.answer(name, tier)
                pop_prompt(u)
            end
            imgui.SameLine()
        end
        if imgui.Button('Dismiss', { 80, 24 }) then
            u.callbacks.dismiss(name)
            pop_prompt(u)
        end
        if #u.prompts > 1 then
            imgui.TextDisabled(('%d more waiting'):fmt(#u.prompts - 1))
        end
    end
    imgui.End()
end

local function render_config(u)
    if not u.config_open[1] then
        return
    end
    imgui.SetNextWindowSize({ 420, 300 }, ImGuiCond_FirstUseEver)
    if imgui.Begin('pafo###pafo_config', u.config_open, ImGuiWindowFlags_NoCollapse) then
        local info = u.callbacks.info()
        imgui.Text(('Server:  %s'):fmt(info.server))
        imgui.Text(('Account: %s'):fmt(info.link))
        imgui.Text(('Capture: %s'):fmt(info.capture))
        imgui.Text(('Queue:   %s'):fmt(info.queue))
        imgui.Separator()
        imgui.Text('Cached TH answers')
        local answers = u.callbacks.answers()
        if #answers == 0 then
            imgui.TextDisabled('none')
        end
        for i, a in ipairs(answers) do
            imgui.Text(('%s  TH%d'):fmt(a.name, a.tier))
            imgui.SameLine()
            if imgui.Button(('Remove###pafo_rm_%d'):fmt(i), { 70, 20 }) then
                u.callbacks.remove(a.name)
            end
        end
    end
    imgui.End()
end

function ui.render(u)
    render_prompt(u)
    render_config(u)
end

return ui
