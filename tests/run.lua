package.path = './?.lua;./?/init.lua;' .. package.path

local harness = require('tests.harness')

local all = {
    'bytes_test',
    'packets_test',
    'envelope_test',
    'queue_test',
    'ingest_test',
    'config_test',
    'device_test',
    'http_test',
    'netio_test',
    'th_test',
    'kills_test',
    'steal_test',
    'battlefield_test',
    'submit_test',
}

local selected = {}
if #arg > 0 then
    for _, name in ipairs(arg) do
        selected[#selected + 1] = name:gsub('%.lua$', ''):gsub('^tests[/\\]', '')
    end
else
    selected = all
end

for _, name in ipairs(selected) do
    print('== ' .. name)
    require('tests.' .. name)
end

harness.finish()
