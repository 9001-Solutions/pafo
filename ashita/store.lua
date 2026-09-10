local json = require('json')

local store = {}

-- Deliberately not user-configurable: the config fetched from this host
-- names the ingest url, which receives the stored pafo token. Point it at
-- the mock server only in a local checkout, never in a commit.
store.DEFAULT_BASE_URL = 'https://www.psxi.gg'

local function dir()
    return AshitaCore:GetInstallPath() .. 'config\\addons\\pafo\\'
end

function store.path(name)
    return dir() .. name
end

function store.read(name)
    local f = io.open(store.path(name), 'rb')
    if f == nil then
        return nil
    end
    local raw = f:read('*a')
    f:close()
    if raw == nil or raw == '' then
        return nil
    end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' then
        return nil
    end
    return data
end

function store.write(name, data)
    local d = dir()
    if not ashita.fs.exists(d) then
        ashita.fs.create_directory(d)
    end
    local path = store.path(name)
    local tmp = path .. '.tmp'
    local f, err = io.open(tmp, 'wb')
    if f == nil then
        return false, tostring(err)
    end
    f:write(json.encode(data))
    f:close()
    if ashita.fs.exists(path) then
        ashita.fs.remove(path)
    end
    local ok, rerr = os.rename(tmp, path)
    if not ok then
        return false, tostring(rerr)
    end
    return true
end

function store.defaults()
    return {
        token = '',
        server = '',
        capture = true,
        th_answers = {},
        config = nil,
        config_at = 0,
    }
end

function store.load_state()
    local state = store.defaults()
    local saved = store.read('pafo.json')
    if saved then
        for k, v in pairs(saved) do
            state[k] = v
        end
    end
    if type(state.th_answers) ~= 'table' then
        state.th_answers = {}
    end
    state.base_url = nil
    return state
end

function store.save_state(state)
    return store.write('pafo.json', state)
end

function store.load_queue()
    return store.read('queue.json')
end

function store.save_queue(data)
    return store.write('queue.json', data)
end

return store
