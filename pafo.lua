addon.name = 'pafo'
addon.author = 'Hanayaka'
addon.version = '0.3.0'
addon.desc = 'Records drop observations and submits them to the PSXI drop-rate aggregator.'
addon.link = 'https://www.psxi.gg/'

package.path = addon.path .. '?.lua;' .. package.path

require('common')

local packets = require('core.packets')
local ids = require('core.ids')
local configlib = require('core.config')
local devicelib = require('core.device')
local th = require('core.th')
local kills = require('core.kills')
local steallib = require('core.steal')
local bflib = require('core.battlefield')
local submitlib = require('core.submit')

local transport = require('ashita.transport')
local store = require('ashita.store')
local game = require('ashita.game')
local uilib = require('ashita.ui')
local bfnames = require('data.battlefields')

local ENDPOINTS = {
    config = '/api/pafo/config',
    device = '/auth/device',
    token = '/auth/token',
}

local state = nil
local cfg = nil
local session = {
    kills = nil,
    bf = bflib.new(),
    claims = {},
    submit = nil,
    ui = nil,
    config_fetched = false,
    disabled_notified = false,
    login_active = false,
    detected_host = nil,
    detected = false,
    server_announced = false,
    dismissed = {},
    thf_hints = {},
    last_tick = 0,
}

local function msg(text)
    print('\30\08[pafo] \30\01' .. tostring(text))
end

local function log(text)
    print('\30\08[pafo] \30\06' .. tostring(text))
end

local function now()
    return os.time()
end

local function save_state()
    local ok, err = store.save_state(state)
    if not ok then
        log('could not save settings: ' .. tostring(err))
    end
end

local function persist_queue()
    local ok, err = store.save_queue(submitlib.export(session.submit))
    if not ok then
        log('could not save queue: ' .. tostring(err))
    end
end

local function active_server()
    return configlib.server(cfg, state.server)
end

local function answer_key(name)
    return (state.server or '') .. '|' .. name
end

local function cached_answer(name)
    local v = state.th_answers[answer_key(name)]
    return tonumber(v)
end

local function base_url()
    return store.DEFAULT_BASE_URL
end

local function capture_allowed()
    if not state.capture then
        return false
    end
    local server = active_server()
    return server ~= nil and server.enabled
end

local function reporter()
    local me = game.self()
    if me == nil then
        return nil
    end
    local job = game.job_abbr(me.main_job)
    if job == nil then
        return nil
    end
    return {
        char_name = me.name,
        job = job,
        sub = game.job_abbr(me.sub_job),
        level = math.max(1, me.level or 1),
    }
end

local function submit_context()
    if not state.capture then
        return nil, 'off'
    end
    if state.server == nil or state.server == '' then
        return nil, 'no_server'
    end
    if state.token == nil or state.token == '' then
        return nil, 'no_token'
    end
    if cfg == nil then
        return nil, 'no_config'
    end
    local server = active_server()
    if server == nil then
        return nil, 'unknown_server'
    end
    if not server.enabled then
        return nil, 'server_disabled'
    end
    local rep = reporter()
    if rep == nil then
        return nil, 'no_player'
    end
    return {
        token = state.token,
        ingest_url = cfg.ingest_url,
        server_slug = state.server,
        addon_version = addon.version,
        reporter = rep,
        batch = cfg.batch,
    }
end

local function send_batch(url, token, body, callback)
    transport.request('POST', url, { Authorization = 'Bearer ' .. token }, body, callback)
end

local function apply_config(body, from_cache)
    local parsed, err = configlib.normalize(body)
    if parsed == nil then
        return false, err
    end
    cfg = parsed
    if not from_cache then
        state.config = body
        state.config_at = now()
        save_state()
    end
    return true
end

local function detect_server()
    local host = configlib.server_host(game.command_line())
    session.detected_host = host
    local slug = configlib.slug_for_host(cfg, host)
    session.detected = slug ~= nil
    -- The server comes only from detection, never from saved settings: this
    -- overwrites whatever pafo.json holds so it cannot be hand-edited.
    if (state.server or '') == (slug or '') then
        return
    end
    state.server = slug or ''
    session.disabled_notified = false
    save_state()
end

local function fetch_config()
    transport.request('GET', base_url() .. ENDPOINTS.config, {}, nil, function(status, body)
        session.config_fetched = true
        if status == 200 then
            local ok, err = apply_config(body, false)
            if not ok then
                log('config rejected: ' .. tostring(err))
            end
        else
            local reason = status == nil and tostring(body or 'network error') or ('http ' .. tostring(status))
            log(('config fetch failed (%s); using cached copy'):format(reason))
        end
        detect_server()
        local server = active_server()
        if server and not server.enabled and not session.disabled_notified then
            session.disabled_notified = true
            msg(('server %s is disabled for submissions; nothing will be recorded'):format(server.name))
        elseif server and server.enabled and not session.server_announced then
            session.server_announced = true
            msg('connected to ' .. server.name)
        end
    end)
end

local function push_event(ev)
    ev.id = ids.new()
    if state.server ~= nil and state.server ~= '' then
        ev.server_slug = state.server
    end
    submitlib.push(session.submit, ev)
end

local function on_auth_lost()
    msg('PSXI rejected the token; run /pafo login again. Events are kept until then.')
end

local function on_server_disabled(n)
    msg(('server %s is disabled; %d queued events were discarded'):format(state.server, n))
end

local function on_outdated()
    msg('PSXI no longer accepts this addon version; update pafo. Events are kept until then.')
end

local function self_actor(me)
    local server = active_server()
    local sources = 0
    if me.main_job == th.THF and (me.level or 0) >= th.LEVEL_TH3 then
        sources = th.gear_sources(game.equipped(), server and server.th_plus_item_ids or {})
    end
    return {
        server_id = me.server_id,
        name = me.name,
        is_self = true,
        main_job = me.main_job,
        sub_job = me.sub_job,
        level = me.level,
        gear_sources = sources,
    }
end

local function member_actor(server_id)
    local m = game.party_member(server_id)
    if m == nil then
        return nil
    end
    return {
        server_id = m.server_id,
        name = m.name,
        is_self = false,
        main_job = m.main_job,
        sub_job = m.sub_job,
        level = m.level,
        gear_sources = 0,
        thf_hint = session.thf_hints[m.server_id],
    }
end

local function maybe_prompt(actor)
    if session.dismissed[actor.name] then
        return
    end
    actor.answer = cached_answer(actor.name)
    local min_tier = th.prompt_min(actor)
    if min_tier == nil then
        return
    end
    uilib.prompt(session.ui, actor.name, min_tier, th.hint_note(actor))
end

local function handle_action(data)
    local ok, action = pcall(packets.action, data)
    if not ok then
        return
    end
    local me = game.self()
    if me == nil then
        return
    end
    local t = now()
    local zone = game.zone_id()

    if not game.is_mob_id(action.actor_id) then
        for _, ev in ipairs(steallib.from_action(action, me.server_id)) do
            local ent = game.entity_by_id(ev.mob_id)
            push_event(steallib.to_event(ev, t, zone, ent and ent.name or 'unknown'))
        end
    end

    local floor = th.hint_floor(action.cmd_no, action.cmd_arg)
    if floor ~= nil and (session.thf_hints[action.actor_id] or -1) < floor then
        session.thf_hints[action.actor_id] = floor
    end

    if not packets.HOSTILE_CMDS[action.cmd_no] then
        return
    end
    local actor = nil
    if action.actor_id == me.server_id then
        actor = self_actor(me)
    else
        actor = member_actor(action.actor_id)
    end
    if actor == nil then
        return
    end
    for _, target in ipairs(action.targets) do
        if game.is_mob_id(target.id) then
            local ent = game.entity_by_id(target.id)
            kills.on_action(session.kills, target.id, actor, t, ent and ent.hpp or nil)
            maybe_prompt(actor)
        end
    end
end

local function handle_entity_update(data)
    local e = packets.entity_update(data)
    if e.claim_id ~= nil then
        session.claims[e.server_id] = e.claim_id
    end
    if not packets.is_death(e) or not kills.tracked(session.kills, e.server_id) then
        return
    end
    local ent = game.entity_by_index(e.index)
    local claim = session.claims[e.server_id]
    if (claim == nil or claim == 0) and ent then
        claim = ent.claim_id
    end
    local claimed = claim ~= nil and game.party_ids()[claim] == true
    kills.on_death(session.kills, e.server_id, now(), {
        name = ent and ent.name or 'unknown',
        claimed = claimed,
        zone_id = game.zone_id(),
    })
end

local function handle_trophy(data)
    local t = packets.trophy(data)
    if t.dropper_id == 0 or t.old == 1 then
        return
    end
    local at = now()
    if bflib.on_drop(session.bf, t.dropper_id, t.item_id, t.count, at) then
        return
    end
    if kills.on_drop(session.kills, t.dropper_id, t.item_id, t.count, at) then
        return
    end
    local ent = game.entity_by_index(t.dropper_index)
    if ent and bflib.is_crate(ent.name) then
        bflib.on_open(session.bf, t.dropper_id, at, game.gil(), game.zone_id())
        bflib.on_drop(session.bf, t.dropper_id, t.item_id, t.count, at)
    end
end

local function flush_partial_crate()
    local partial = bflib.on_zone(session.bf, game.gil())
    if partial and capture_allowed() then
        push_event(partial)
    end
end

local function handle_zone_out()
    flush_partial_crate()
    kills.reset(session.kills, now())
    session.claims = {}
    persist_queue()
end

local function handle_zone_in()
    kills.reset(session.kills, now())
    session.claims = {}
end

local function handle_action_out(data)
    local p = packets.action_out(data)
    local ent = game.entity_by_index(p.target_index)
    if ent and bflib.is_crate(ent.name) then
        bflib.on_open(session.bf, ent.server_id, now(), game.gil(), game.zone_id())
    end
end

local function handle_event_end_out(data)
    local p = packets.event_end_out(data)
    if p.event_num ~= bflib.ENTRY_EVENT then
        return
    end
    local index = bflib.option_index(p.option)
    if index == nil then
        return
    end
    local zone = game.zone_id()
    local names = bfnames[zone]
    bflib.on_select(session.bf, zone, index, names and names[index] or nil)
end

local function tick()
    local t = now()
    if t == session.last_tick then
        return
    end
    session.last_tick = t
    local events = kills.tick(session.kills, t, function(actor)
        return cached_answer(actor.name)
    end, (active_server() or {}).max_th or 4)
    for _, ev in ipairs(events) do
        push_event(ev)
    end
    local crate = bflib.tick(session.bf, t, game.gil())
    if crate then
        push_event(crate)
    end
    submitlib.tick(session.submit)
end

local function login()
    if session.login_active then
        msg('a login is already in progress')
        return
    end
    session.login_active = true
    local base = base_url()
    msg('requesting a device code from PSXI...')
    ashita.tasks.once(0, function()
        local status, body = transport.request_sync('POST', base .. ENDPOINTS.device, {}, { kind = 'pafo' })
        local d, err = nil, nil
        if status == 200 then
            d, err = devicelib.start_result(body)
        else
            err = devicelib.start_error(status, body)
        end
        if d == nil then
            transport.defer(function()
                session.login_active = false
                msg('login failed: ' .. tostring(err))
            end)
            return
        end
        local verify = devicelib.verify_link(d, base)
        transport.defer(function()
            msg('open ' .. verify)
            msg('and enter code: ' .. d.user_code)
            pcall(ashita.misc.open_url, verify)
        end)
        local result, value = devicelib.poll(d, {
            now = os.time,
            active = function() return session.login_active end,
            -- ashita tasks are coroutines on the game thread: socket.sleep here
            -- freezes rendering for the whole login window.
            sleep = coroutine.sleep,
            request = function(device_code)
                return transport.request_sync('POST', base .. ENDPOINTS.token, {},
                    { device_code = device_code })
            end,
        })
        transport.defer(function()
            if result == 'ok' then
                state.token = value
                save_state()
                session.login_active = false
                submitlib.resume(session.submit)
                msg('account linked; submissions enabled')
            elseif result == 'terminal' then
                session.login_active = false
                msg(('login %s; run /pafo login to try again'):format(tostring(value)))
            elseif result == 'timeout' and session.login_active then
                session.login_active = false
                msg('login timed out; run /pafo login to try again')
            end
        end)
    end)
end

local function logout()
    state.token = ''
    save_state()
    msg('token removed')
end

local function th_reset(name)
    if name == nil then
        state.th_answers = {}
        session.dismissed = {}
        uilib.forget(session.ui)
        save_state()
        msg('all cached TH answers cleared')
        return
    end
    local key = answer_key(name)
    if state.th_answers[key] == nil then
        msg('no cached answer for ' .. name)
        return
    end
    state.th_answers[key] = nil
    session.dismissed[name] = nil
    uilib.forget(session.ui, name)
    save_state()
    msg('cleared cached TH answer for ' .. name)
end

local function link_text()
    if state.token ~= nil and state.token ~= '' then
        return 'linked'
    end
    return 'not linked (/pafo login)'
end

local function config_age_text()
    if cfg == nil then
        return 'none'
    end
    if state.config_at == nil or state.config_at == 0 then
        return 'unknown age'
    end
    local age = now() - state.config_at
    if age < 120 then
        return ('%ds old'):format(age)
    end
    if age < 7200 then
        return ('%dm old'):format(math.floor(age / 60))
    end
    return ('%dh old'):format(math.floor(age / 3600))
end

local function queue_text()
    local st = submitlib.status(session.submit)
    local parts = { ('%d queued'):format(st.depth) }
    if st.in_flight then
        parts[#parts + 1] = 'sending'
    end
    if st.halted == 'auth' then
        parts[#parts + 1] = 'halted: login required'
    elseif st.halted == 'outdated' then
        parts[#parts + 1] = 'halted: addon outdated'
    elseif st.retry_in > 0 then
        parts[#parts + 1] = ('retry in %ds (%s)'):format(st.retry_in, tostring(st.last_error))
    end
    return table.concat(parts, ', ')
end

local function print_status()
    local server = active_server()
    local server_text
    if state.server ~= nil and state.server ~= '' then
        server_text = ('%s (detected from %s)'):format(state.server, tostring(session.detected_host))
    elseif session.detected_host ~= nil then
        server_text = ('none: %s is not a supported server; nothing is recorded'):format(session.detected_host)
    else
        server_text = 'none: no --server in the loader command line; nothing is recorded'
    end
    if server and not server.enabled then
        server_text = server_text .. ' [disabled]'
    end
    msg('server: ' .. server_text)
    msg('account: ' .. link_text())
    msg('capture: ' .. (state.capture and 'on' or 'off'))
    msg('queue: ' .. queue_text())
    msg('config: ' .. config_age_text())
end

local function print_help()
    msg('commands:')
    msg('  /pafo login            link this install to a PSXI account')
    msg('  /pafo logout           forget the token')
    msg('  /pafo th reset [name]  clear cached TH answers')
    msg('  /pafo status           queue depth, link state, server, config age')
    msg('  /pafo off | on         pause or resume capture')
    msg('  /pafo config           open the settings window')
end

local function answers_list()
    local prefix = (state.server or '') .. '|'
    local out = {}
    for key, tier in pairs(state.th_answers) do
        if key:sub(1, #prefix) == prefix then
            out[#out + 1] = { name = key:sub(#prefix + 1), tier = tonumber(tier) or 2 }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

ashita.events.register('load', 'pafo_load', function()
    math.randomseed(os.time() + math.floor(os.clock() * 1000000))
    transport.init(addon.path)
    state = store.load_state()
    session.kills = kills.new(now())
    session.submit = submitlib.new({
        now = now,
        context = submit_context,
        send = send_batch,
        notify = msg,
        log = log,
        persist = persist_queue,
        on_auth_lost = on_auth_lost,
        on_server_disabled = on_server_disabled,
        on_outdated = on_outdated,
    })
    session.ui = uilib.new({
        answer = function(name, tier)
            state.th_answers[answer_key(name)] = tier
            save_state()
            msg(tier == 0 and ('%s recorded as not a THF'):format(name) or ('%s recorded as TH%d'):format(name, tier))
        end,
        dismiss = function(name)
            session.dismissed[name] = true
        end,
        remove = function(name)
            th_reset(name)
        end,
        info = function()
            return {
                server = state.server ~= '' and state.server or 'none',
                link = link_text(),
                capture = state.capture and 'on' or 'off',
                queue = queue_text(),
            }
        end,
        answers = answers_list,
    })
    local restored = submitlib.import(session.submit, store.load_queue())
    if restored > 0 then
        log(('restored %d queued events'):format(restored))
    end
    if state.config ~= nil then
        apply_config(state.config, true)
    end
    detect_server()
    fetch_config()
    if state.token == nil or state.token == '' then
        msg('not linked; run /pafo login')
    end
end)

ashita.events.register('unload', 'pafo_unload', function()
    session.login_active = false
    if session.submit then
        pcall(flush_partial_crate)
        persist_queue()
    end
    if state then
        save_state()
    end
end)

ashita.events.register('command', 'pafo_command', function(e)
    local args = e.command:args()
    if #args == 0 or args[1]:lower() ~= '/pafo' then
        return
    end
    e.blocked = true
    local sub = (args[2] or 'help'):lower()
    if sub == 'login' then
        login()
    elseif sub == 'logout' then
        logout()
    elseif sub == 'th' and (args[3] or ''):lower() == 'reset' then
        th_reset(args[4])
    elseif sub == 'status' then
        print_status()
    elseif sub == 'off' then
        state.capture = false
        save_state()
        msg('capture paused')
    elseif sub == 'on' then
        state.capture = true
        save_state()
        msg('capture resumed')
    elseif sub == 'config' then
        uilib.toggle_config(session.ui)
    else
        print_help()
    end
end)

ashita.events.register('packet_in', 'pafo_packet_in', function(e)
    if state == nil then
        return
    end
    if e.id == packets.ID.ZONE_OUT then
        handle_zone_out()
        return
    end
    if e.id == packets.ID.ZONE_IN then
        handle_zone_in()
        return
    end
    if not capture_allowed() then
        return
    end
    if e.id == packets.ID.ACTION then
        handle_action(e.data)
    elseif e.id == packets.ID.ENTITY_UPDATE then
        handle_entity_update(e.data)
    elseif e.id == packets.ID.TROPHY then
        handle_trophy(e.data)
    end
end)

ashita.events.register('packet_out', 'pafo_packet_out', function(e)
    if state == nil or not capture_allowed() then
        return
    end
    if e.id == packets.ID.OUT_ACTION then
        handle_action_out(e.data)
    elseif e.id == packets.ID.OUT_EVENT_END then
        handle_event_end_out(e.data)
    end
end)

ashita.events.register('d3d_present', 'pafo_present', function()
    if state == nil then
        return
    end
    transport.pump()
    local ok, err = pcall(tick)
    if not ok then
        log('tick error: ' .. tostring(err))
    end
    uilib.render(session.ui)
end)
