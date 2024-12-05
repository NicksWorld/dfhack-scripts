-- Module for enable/disable command completion
--@ module = true
local helpdb = require('helpdb');

completions = {
    subcommands = {}
}

local plugins = helpdb.search_entries({type = 'plugin'}, {})

for _,v in pairs(plugins) do
    completions.subcommands[v] = {}
end