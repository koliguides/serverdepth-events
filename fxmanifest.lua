fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'ServerDepth'
description 'Dynamic world events engine for QBox/QBCore servers'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'shared/event_registry.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/framework.lua',
    'server/main.lua',
    'server/events/cargo_drop.lua',
    'server/events/armored_truck.lua',
    'server/events/underground_race.lua',
    'server/events/hidden_stash.lua',
    'server/commands.lua'
}

client_scripts {
    'client/main.lua',
    'client/markers.lua',
    'client/nui.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js'
}

dependencies {
    'oxmysql',
    'ox_lib',
    'ox_inventory'
}
