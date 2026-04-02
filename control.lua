local ROOT_NAME = "quality_control_relative_gui_root"
local CHECKBOX_NAME = "quality_control_checkbox"
local TAG_KEY = "quality_control_set_filters"
local QUALITY_PROXY_PREFIX = "ccqf-quality-"
local FAST_REPLACE_WINDOW_TICKS = 6

local BATCH_SIZE = 50

local function update_batch_size()
    local s = settings.global["ccqf-batch-size"]
    local v = (s and s.value) or 50
    BATCH_SIZE = v
end

local function state()
    storage.quality_filter_control = storage.quality_filter_control or {}
    local s = storage.quality_filter_control
    s.enabled_by_unit = s.enabled_by_unit or {} -- [unit_number] = LuaEntity
    s.open_entity_by_player = s.open_entity_by_player or {} -- [player_index] = LuaEntity
    s.recent_replace_by_pos = s.recent_replace_by_pos or {} -- [pos_key] = { enabled=bool, tick=uint }
    s.enabled_unit_array = s.enabled_unit_array or {}
    s.enabled_index = s.enabled_index or 1
    s.gui_type_by_player = s.gui_type_by_player or {}
    return s
end

local function get_entity_type(entity)
    if not (entity and entity.valid) then
        return nil
    end
    if entity.type == "entity-ghost" then
        return entity.ghost_type
    end
    return entity.type
end

local function ensure_correct_filter_settings_inserter(entity)
    if not (entity and entity.valid and entity.type == "inserter") then
        return
    end
    if (entity.filter_slot_count or 0) == 0 then
        return
    end
    local control_behavior = entity.get_control_behavior()
    if control_behavior and control_behavior.valid and control_behavior.circuit_set_filters then
        control_behavior.circuit_set_filters = false
    end
    if not entity.use_filters then
        entity.use_filters = true
    end
    if entity.inserter_filter_mode ~= "whitelist" then
        entity.inserter_filter_mode = "whitelist"
    end
end

local function ensure_correct_filter_settings_splitter(entity)
    if not (entity and entity.valid and entity.type == "splitter") then
        return
    end
    local control_behavior = entity.get_control_behavior()
    if control_behavior and control_behavior.valid and control_behavior.set_filter then
        control_behavior.set_filter = false
    end
end

local ENTITY_CONFIG = {
    inserter = {
        gui = defines.relative_gui_type.inserter_gui,
        ensure_settings = ensure_correct_filter_settings_inserter,
        get_max_filters = function(entity)
            return entity.filter_slot_count or 0
        end,
        get_filter = function(entity, index)
            return entity.get_filter(index)
        end,
        set_filter = function(entity, index, value)
            entity.set_filter(index, value)
        end,
        allow_quality_only = true,
        allow_item_quality = true
    },
    splitter = {
        gui = defines.relative_gui_type.splitter_gui,
        ensure_settings = ensure_correct_filter_settings_splitter,
        get_max_filters = function(_)
            return 1
        end,
        get_filter = function(entity, index)
            if index == 1 then
                return entity.splitter_filter
            end
            return nil
        end,
        set_filter = function(entity, index, value)
            if index == 1 then
                entity.splitter_filter = value
            end
        end,
        allow_quality_only = true,
        allow_item_quality = true
    }
}

local function get_entity_config(entity)
    local entity_type = get_entity_type(entity)
    if not entity_type then
        return nil
    end
    return ENTITY_CONFIG[entity_type]
end

local function get_max_filters(entity)
    local cfg = get_entity_config(entity)
    if not cfg or not cfg.get_max_filters then
        return 0
    end
    return cfg.get_max_filters(entity) or 0
end

local function get_filter_at(entity, index)
    local cfg = get_entity_config(entity)
    if not cfg or not cfg.get_filter then
        return nil
    end
    return cfg.get_filter(entity, index)
end

local function set_filter_at(entity, index, value)
    local cfg = get_entity_config(entity)
    if not cfg or not cfg.set_filter then
        return
    end
    cfg.set_filter(entity, index, value)
end

local function is_supported_entity(entity)
    if not (entity and entity.valid and entity.unit_number and entity.type ~= "entity-ghost") then
        return false
    end
    if not get_entity_config(entity) then
        return false
    end
    if get_max_filters(entity) == 0 then
        return false
    end
    return true
end

local function is_supported_or_ghost(entity)
    if not (entity and entity.valid) then
        return false
    end
    if entity.type == "entity-ghost" then
        return ENTITY_CONFIG[entity.ghost_type] ~= nil
    end
    return is_supported_entity(entity)
end

local function set_enabled(entity, enabled)
    local s = state()
    if entity.type == "entity-ghost" then
        local tags = entity.tags or {}
        tags[TAG_KEY] = enabled and true or nil
        entity.tags = tags
        return
    end
    if not is_supported_entity(entity) then
        return
    end
    local cfg = get_entity_config(entity)
    if not cfg then
        return
    end
    local unit = entity.unit_number
    local was_enabled = (s.enabled_by_unit[unit] ~= nil)
    local now_enabled = (enabled == true)
    if now_enabled then
        if not was_enabled then
            table.insert(s.enabled_unit_array, unit)
        end
        -- Store entity reference directly; game.get_entity_by_unit_number fails
        -- for some surfaces (e.g. Fulgora turbo-splitters), so we avoid it entirely
        s.enabled_by_unit[unit] = entity
        if cfg.ensure_settings then
            cfg.ensure_settings(entity)
        end
    else
        s.enabled_by_unit[unit] = nil
    end
end

local function get_enabled(entity)
    local s = state()
    if entity.type == "entity-ghost" then
        local tags = entity.tags
        return tags and tags[TAG_KEY] == true or false
    end
    if not is_supported_entity(entity) then
        return false
    end
    return s.enabled_by_unit[entity.unit_number] ~= nil
end

local function get_checkbox(player)
    local root = player.gui.relative and player.gui.relative[ROOT_NAME]
    if not (root and root.valid) then
        return nil
    end
    local checkbox = root[CHECKBOX_NAME]
    if checkbox and checkbox.valid then
        return checkbox
    end
    return nil
end

local function destroy_gui(player)
    local relative = player.gui.relative
    if not relative then
        return
    end
    local root = relative[ROOT_NAME]
    if root and root.valid then
        root.destroy()
    end
    local s = state()
    s.gui_type_by_player[player.index] = nil
end

local function ensure_gui(player, entity)
    local relative = player.gui.relative
    local cfg = get_entity_config(entity)
    if not cfg then
        destroy_gui(player)
        return
    end
    local s = state()
    local root = relative[ROOT_NAME]
    if root and root.valid then
        if s.gui_type_by_player[player.index] == cfg.gui then
            return
        end
        root.destroy()
    end
    local frame = relative.add {
        type = "frame",
        name = ROOT_NAME,
        direction = "vertical",
        caption = {"", ""},
        anchor = {
            gui = cfg.gui,
            position = defines.relative_gui_position.right,
            ghost_mode = "both"
        }
    }
    s.gui_type_by_player[player.index] = cfg.gui
    frame.add {
        type = "checkbox",
        name = CHECKBOX_NAME,
        caption = {"", "Set filters with quality signals"},
        state = false
    }
end

local function destroy_gui_for_all_players()
    for _, player in pairs(game.players) do
        destroy_gui(player)
    end
end

local function rebuild_enabled_unit_array(s)
    local array = {}
    for unit, _ in pairs(s.enabled_by_unit) do
        table.insert(array, unit)
    end
    s.enabled_unit_array = array
    local after_length = #array
    if after_length == 0 or s.enabled_index > after_length then
        s.enabled_index = 1
    end
end

script.on_init(function()
    update_batch_size()
    local s = state()
    s.open_entity_by_player = {}
    destroy_gui_for_all_players()
    rebuild_enabled_unit_array(s)
end)

script.on_configuration_changed(function()
    update_batch_size()
    local s = state()
    s.open_entity_by_player = {}
    destroy_gui_for_all_players()
    rebuild_enabled_unit_array(s)
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(e)
    if e.setting == "ccqf-batch-size" then
        update_batch_size()
    end
end)

script.on_nth_tick(600, function()
    local s = state()
    local current_tick = game.tick
    for key, rec in pairs(s.recent_replace_by_pos) do
        if (current_tick - rec.tick) > FAST_REPLACE_WINDOW_TICKS then
            s.recent_replace_by_pos[key] = nil
        end
    end
    rebuild_enabled_unit_array(s)
end)

script.on_event(defines.events.on_player_created, function(e)
    local player = game.get_player(e.player_index)
    if player then
        destroy_gui(player)
    end
end)

script.on_event(defines.events.on_gui_opened, function(e)
    local player = game.get_player(e.player_index)
    if not player then return end
    local s = state()
    local entity = e.entity
    if is_supported_or_ghost(entity) then
        ensure_gui(player, entity)
        s.open_entity_by_player[e.player_index] = entity
        local checkbox = get_checkbox(player)
        if checkbox then
            checkbox.state = get_enabled(entity)
        end
    else
        s.open_entity_by_player[e.player_index] = nil
        destroy_gui(player)
    end
end)

-- Fix: only clear open entity reference when the tracked entity's own GUI closes,
-- not on every GUI close event. Circuit panel close events were clearing the
-- splitter reference prematurely, preventing checkbox state from saving.
if defines.events.on_gui_closed then
    script.on_event(defines.events.on_gui_closed, function(e)
        local s = state()
        local open_entity = s.open_entity_by_player[e.player_index]
        if open_entity and open_entity.valid and e.entity == open_entity then
            s.open_entity_by_player[e.player_index] = nil
        end
    end)
end

script.on_event(defines.events.on_gui_checked_state_changed, function(e)
    local element = e.element
    if not (element and element.valid and element.name == CHECKBOX_NAME) then
        return
    end
    local s = state()
    local entity = s.open_entity_by_player[e.player_index]
    if not is_supported_or_ghost(entity) then
        return
    end
    set_enabled(entity, element.state)
end)

local function cleanup_entity(entity)
    if not (entity and entity.valid and entity.unit_number) then
        return
    end
    local s = state()
    s.enabled_by_unit[entity.unit_number] = nil
end

local function pos_key(entity)
    local pos = entity.position
    return string.format("%d:%d:%.3f:%.3f", entity.surface.index, entity.force.index, pos.x, pos.y)
end

local destroy_events = {
    defines.events.on_player_mined_entity,
    defines.events.on_robot_mined_entity,
    defines.events.on_entity_died,
    defines.events.script_raised_destroy
}

script.on_event(destroy_events, function(e)
    local entity = e.entity
    if is_supported_entity(entity) then
        if get_enabled(entity) then
            local s = state()
            s.recent_replace_by_pos[pos_key(entity)] = {
                enabled = true,
                tick = game.tick
            }
        end
    end
    cleanup_entity(entity)
end)

local build_events = {
    defines.events.on_built_entity,
    defines.events.on_robot_built_entity,
    defines.events.on_space_platform_built_entity,
    defines.events.script_raised_built,
    defines.events.script_raised_revive
}

script.on_event(build_events, function(e)
    local entity = e.entity
    if not is_supported_entity(entity) then
        return
    end
    local s = state()
    if e.tags and e.tags[TAG_KEY] == true then
        set_enabled(entity, true)
        s.recent_replace_by_pos[pos_key(entity)] = nil
        return
    end
    local key = pos_key(entity)
    local rec = s.recent_replace_by_pos[key]
    if rec and (game.tick - rec.tick) <= FAST_REPLACE_WINDOW_TICKS then
        set_enabled(entity, rec.enabled)
        s.recent_replace_by_pos[key] = nil
    end
end)

local function sync_checkbox_for_entity(changed_entity)
    local s = state()
    for player_index, open_entity in pairs(s.open_entity_by_player) do
        if not (open_entity and open_entity.valid) then
            s.open_entity_by_player[player_index] = nil
        else
            if open_entity == changed_entity or
               ((open_entity.unit_number ~= nil) and
                (changed_entity.unit_number ~= nil) and
                open_entity.unit_number == changed_entity.unit_number) then
                local player = game.get_player(player_index)
                if player then
                    ensure_gui(player, open_entity)
                    local checkbox = get_checkbox(player)
                    if checkbox then
                        checkbox.state = get_enabled(changed_entity)
                    end
                end
            end
        end
    end
end

local copy_events = {defines.events.on_entity_settings_pasted, defines.events.on_entity_cloned}

script.on_event(copy_events, function(e)
    local source = e.source
    local destination = e.destination
    if not (is_supported_or_ghost(source) and is_supported_or_ghost(destination)) then
        return
    end
    local enabled = get_enabled(source)
    set_enabled(destination, enabled)
    sync_checkbox_for_entity(destination)
end)

local function stamp_tags_to_blueprint(player_index, blueprint_stack, mapping_lazy)
    if not (blueprint_stack and blueprint_stack.valid_for_read and blueprint_stack.is_blueprint) then
        return
    end
    if not (mapping_lazy and mapping_lazy.valid) then
        return
    end
    local mapping = mapping_lazy:get()
    if not mapping then
        return
    end
    local entities = blueprint_stack.get_blueprint_entities()
    if not entities then
        return
    end
    for _, be in ipairs(entities) do
        local source = mapping[be.entity_number]
        if source and source.valid and is_supported_or_ghost(source) then
            blueprint_stack.set_blueprint_entity_tag(be.entity_number, TAG_KEY, get_enabled(source) and true or nil)
        end
    end
end

script.on_event(defines.events.on_player_setup_blueprint, function(e)
    local player = game.get_player(e.player_index)
    if not player then
        return
    end
    local bp = e.stack
    if not (bp and bp.valid_for_read and bp.is_blueprint) then
        bp = player.cursor_stack
    end
    if not (bp and bp.valid_for_read and bp.is_blueprint) then
        return
    end
    stamp_tags_to_blueprint(e.player_index, bp, e.mapping)
end)

local function read_signal(entity, signal_id)
    local signal = entity.get_signal(signal_id, defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green)
    return signal or 0
end

local function gather_signals(entity)
    local totals = {}

    local function key_for(id)
        local k = tostring(id.type) .. ":" .. tostring(id.name)
        if id.quality ~= nil then
            k = k .. ":" .. tostring(id.quality)
        end
        return k
    end

    local function add_from(connector_id)
        local signals = entity.get_signals(connector_id)
        if not signals then
            return
        end
        for _, s in ipairs(signals) do
            local id = s.signal
            local c = s.count or 0
            if id and c > 0 then
                local k = key_for(id)
                local existing = totals[k]
                if existing then
                    existing.count = existing.count + c
                else
                    totals[k] = { signal = id, count = c }
                end
            end
        end
    end

    add_from(defines.wire_connector_id.circuit_red)
    add_from(defines.wire_connector_id.circuit_green)

    local combined = {}
    for _, v in pairs(totals) do
        combined[#combined + 1] = v
    end
    return combined
end

local function extract_quality_signals_sorted(combined_signals)
    local present = {}
    for _, s in ipairs(combined_signals or {}) do
        local id = s.signal
        local c = s.count or 0
        if id and c > 0 then
            local qname = nil
            if id.type == "quality" then
                qname = id.name
            elseif id.type == "virtual" and type(id.name) == "string" and id.name:sub(1, #QUALITY_PROXY_PREFIX) == QUALITY_PROXY_PREFIX then
                qname = id.name:sub(#QUALITY_PROXY_PREFIX + 1)
            end
            if qname then
                local q = prototypes.quality[qname]
                if q then
                    present[#present + 1] = { quality = qname, value = c, level = q.level or 0 }
                end
            end
        end
    end
    table.sort(present, function(a, b)
        if a.value ~= b.value then return a.value > b.value end
        if a.level ~= b.level then return a.level > b.level end
        return a.quality < b.quality
    end)
    return present
end

local function is_item_signal(id)
    if not id or not id.name then
        return false
    end
    if id.type == "item" or id.type == "item-with-quality" then
        return true
    end
    return prototypes.item[id.name] ~= nil
end

local function extract_item_signals_sorted(combined_signals)
    local by_name = {}
    for _, s in ipairs(combined_signals or {}) do
        local id = s.signal
        local c = s.count or 0
        if is_item_signal(id) and c > 0 then
            local entry = by_name[id.name]
            if entry then
                entry.value = entry.value + c
            else
                local proto = prototypes.item[id.name]
                by_name[id.name] = { name = id.name, value = c, order = proto and proto.order or "" }
            end
        end
    end
    local present = {}
    for _, v in pairs(by_name) do
        present[#present + 1] = v
    end
    table.sort(present, function(a, b)
        if a.value ~= b.value then return a.value > b.value end
        if a.order ~= b.order then return a.order < b.order end
        return a.name < b.name
    end)
    return present
end

local function extract_comparator_signal(signals)
    local MAP = {
        ["signal-greater-than"] = ">",
        ["signal-less-than"] = "<",
        ["signal-equal"] = "=",
        ["signal-greater-than-or-equal-to"] = ">=",
        ["signal-less-than-or-equal-to"] = "<=",
        ["signal-not-equal"] = "!="
    }
    local best = "="
    local best_count = 0
    local conflict = false
    for _, s in ipairs(signals or {}) do
        local id = s.signal
        local c = s.count or 0
        if id and id.type == "virtual" and c > 0 then
            local comparator = MAP[id.name]
            if comparator then
                if c > best_count then
                    best = comparator
                    best_count = c
                    conflict = false
                elseif c == best_count and comparator ~= best then
                    conflict = true
                end
            end
        end
    end
    if best_count == 0 then return "=", false end
    if conflict then return nil, true end
    return best, false
end

local function are_filters_equal(a, b)
    if a == nil and b == nil then return true end
    if a == nil or b == nil then return false end
    if type(a) == "string" or type(b) == "string" then return a == b end
    return a.name == b.name and a.quality == b.quality and a.comparator == b.comparator
end

local function apply_entity_filters(entity, desired_filters)
    if not is_supported_entity(entity) then return end
    local cfg = get_entity_config(entity)
    if not cfg then return end
    if cfg.ensure_settings then
        cfg.ensure_settings(entity)
    end
    local max_slots = get_max_filters(entity)
    for i = 1, max_slots do
        local want = desired_filters[i]
        local current = get_filter_at(entity, i)
        if not are_filters_equal(current, want) then
            set_filter_at(entity, i, want)
        end
    end
end

local function process_enabled_entity(entity)
    if not is_supported_entity(entity) then return end
    local cfg = get_entity_config(entity)
    if not cfg then return end
    local max_slots = get_max_filters(entity)
    if max_slots == 0 then return end
    local signals = gather_signals(entity)
    local qualities = extract_quality_signals_sorted(signals)
    local items = extract_item_signals_sorted(signals)
    local comparator, conflict = extract_comparator_signal(signals)
    local filters = {}
    if conflict then
        apply_entity_filters(entity, filters)
        return
    end
    if not cfg.allow_item_quality then
        items = {}
    end
    if #items > 0 and qualities[1] then
        local slot = 1
        for _, q in ipairs(qualities) do
            for _, it in ipairs(items) do
                filters[slot] = { name = it.name, quality = q.quality, comparator = comparator }
                slot = slot + 1
                if slot > max_slots then break end
            end
            if slot > max_slots then break end
        end
    else
        if not cfg.allow_quality_only then return end
        for i, entry in ipairs(qualities) do
            filters[i] = { quality = entry.quality, comparator = comparator }
        end
    end
    apply_entity_filters(entity, filters)
end

script.on_event(defines.events.on_tick, function()
    local s = state()
    local list = s.enabled_unit_array
    local n = #list
    if n == 0 then return end

    for _ = 1, math.min(BATCH_SIZE, n) do
        if s.enabled_index > n then
            s.enabled_index = 1
        end
        local unit = list[s.enabled_index]
        s.enabled_index = s.enabled_index + 1

        if unit and s.enabled_by_unit[unit] then
            local entity = s.enabled_by_unit[unit]
            -- Handle legacy boolean entries from older storage format
            if type(entity) ~= "userdata" or not entity.valid or not is_supported_entity(entity) then
                s.enabled_by_unit[unit] = nil
            else
                process_enabled_entity(entity)
            end
        end
    end
end)
