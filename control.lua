--[[ Copyright (c) 2018 Optera
 * Part of LTN Content Reader
 *
 * See LICENSE.md in the project directory for license information.
--]]

require('api')

-- localize often used functions and strings
local content_readers = {
  ["cybersyn-provider-reader"] = {table_name = "cybersyn_provided"},
  ["cybersyn-requester-reader"] = {table_name = "cybersyn_requested"},
  ["cybersyn-delivery-reader"] = {table_name = "cybersyn_deliveries"},
}

local require_same_surface = settings.global["cybersyn_content_reader_same_surface"].value

-- get default network from LTN
local default_network = settings.global["cybersyn-network-flag"].value
script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if not event then return end
  if event.setting == "cybersyn-network-flag" then
    default_network = settings.global["cybersyn-network-flag"].value
  end
  if event.setting == "cybersyn_content_reader_update_interval" then
    storage.update_interval = settings.global["cybersyn_content_reader_update_interval"].value
  end
  if event.setting == "cybersyn_content_reader_same_surface" then
    require_same_surface = settings.global["cybersyn_content_reader_same_surface"].value
  end
end)

function append_item(t, station, item_hash, count, network_name, network_mask)
  if network_name == nil then
    network_name = station.network_name
  end
  if network_mask == nil then
    network_mask = station.network_mask
  end

  if not station.entity_stop or not station.entity_stop.valid then
    return
  end

  local surface = station.entity_stop.surface_index

  if not network_name then
    network_name = "__all"
  end

  if network_name == "signal-each" then
    for network_name, network_mask in pairs(network_mask) do
      append_item(t, station, item_hash, count, network_name, network_mask)
    end
    return
  end

  if not t[surface] then
    t[surface] = {}
  end

  if not t[surface][network_name] then
    t[surface][network_name] = {}
  end

  if not t[surface][network_name][network_mask] then
    t[surface][network_name][network_mask] = {}
  end

  if t[surface][network_name][network_mask][item_hash] == nil then
    t[surface][network_name][network_mask][item_hash] = count
  else
    t[surface][network_name][network_mask][item_hash] = t[surface][network_name][network_mask][item_hash] + count
  end
end

function InitSignals()
  local stations = remote.call("cybersyn", "read_global", "stations")

  local inventory_provided = {}
  local inventory_requested = {}
  local inventory_in_transit = {}

  for _, station in pairs(stations) do
		local comb1_signals, _ = get_signals(station)
		if comb1_signals then
			for _, v in pairs(comb1_signals) do
				local item = v.signal
				local count = v.count
				local item_type = v.signal.type or "item"
				local item_hash = hash_signal(item)

				if item.type ~= "virtual" then
					if station.is_p and count > 0 then
            append_item(inventory_provided, station, item_hash, count)
					end
					if station.is_r and count < 0 then
						local r_threshold = station.item_thresholds and station.item_thresholds[item.name] or
							item_type == "fluid" and station.r_fluid_threshold or
							station.r_threshold
						if station.is_stack and item_type == "item" then
							r_threshold = r_threshold * prototypes.item[item.name].stack_size
						end

						if -count >= r_threshold then
              append_item(inventory_requested, station, item_hash, count)
						end
					end
				end
			end
		end

		local deliveries = station.deliveries
		if deliveries then
			for cc_item_hash, count in pairs(deliveries) do
        -- Need to rehash to ours which includes the item type
        local item_name, quality = unhash_cc_signal(cc_item_hash)
        local type = prototypes.item[item_name] == nil and "fluid" or "item"
        local item_hash = hash_signal({ name = item_name, quality = quality, type = type })
				if count > 0 then
          append_item(inventory_in_transit, station, item_hash, count)
				end
			end
		end
	end

  storage.cybersyn_provided = inventory_provided
  storage.cybersyn_requested = inventory_requested
  storage.cybersyn_deliveries = inventory_in_transit
end

-- spread out updating combinators
function OnTick(event)
  -- global.update_interval LTN update interval are synchronized in OnDispatcherUpdated
  local offset = event.tick % storage.update_interval
  local cc_count = #storage.content_combinators
  if offset == 0 then
    InitSignals()
  end
  for i=cc_count - offset, 1, -1 * storage.update_interval do
    -- log( "("..tostring(event.tick)..") on_tick updating "..i.."/"..cc_count )
    local combinator = storage.content_combinators[i]
    if combinator.valid then
      Update_Combinator(combinator)
    else
      table.remove(storage.content_combinators, i)
      if #storage.content_combinators == 0 then
        script.on_event(defines.events.on_tick, nil)
      end
    end
  end
end

---@param combinator LuaEntity
function Update_Combinator(combinator)
  -- get network id from combinator parameters
  local first_signal = get_first_signal(combinator)
  local selected_network_id = default_network
  local selected_network_name = "__all"

  if first_signal and first_signal.value then
    selected_network_name = first_signal.value.name
    selected_network_id = first_signal.min
  end

  ---@type LogisticFilter[]
  local signals = {}
  local index = 1

  -- for many signals performance is better to aggregate first instead of letting factorio do it
  local items = {}
  local reader = content_readers[combinator.name]
  if reader then
    for surface_index, surface_data in pairs(storage[reader.table_name]) do
      if not require_same_surface or combinator.surface_index == surface_index then
        for network_name, network_data in pairs(surface_data) do
          if selected_network_name == "__all" or network_name == selected_network_name then
            for network_mask, item_data in pairs(network_data) do
              if bit32.btest(selected_network_id, network_mask) then
                for item, count in pairs(item_data) do
                  items[item] = (items[item] or 0) + count
                end
              end
            end
          end
        end
      end
    end
  end

  -- generate signals from aggregated item list
  for item, count in pairs(items) do
    local itype, iname, iquality = unhash_signal(item)
    if itype and iname and (itype == "item" and prototypes.item[iname] or itype == "fluid" and prototypes.fluid[iname]) then
      if count >  2147483647 then count =  2147483647 end
      if count < -2147483648 then count = -2147483648 end
      signals[#signals+1] = {
        value = { type=itype, quality=iquality, name=iname },
        min = count
      }
      index = index+1
    end
  end

  ---@type LuaConstantCombinatorControlBehavior
  local b = combinator.get_control_behavior()

  while b.sections_count < 2 do
    b.add_section()
  end

  b.get_section(2).filters = signals
end

-- add/remove event handlers
--- @param event EventData.on_built_entity
function OnEntityCreated(event)
  local entity = event.entity
  if content_readers[entity.name] then
    table.insert(storage.content_combinators, entity)

    if #storage.content_combinators == 1 then
      script.on_event(defines.events.on_tick, OnTick)
    end
  end
end

function OnEntityRemoved(event)
  local entity = event.entity
  if content_readers[entity.name] then
    for i=#storage.content_combinators, 1, -1 do
      if storage.content_combinators[i].unit_number == entity.unit_number then
        table.remove(storage.content_combinators, i)
      end
    end

    if #storage.content_combinators == 0 then
			script.on_event(defines.events.on_tick, nil)
    end
  end
end

---- Initialisation  ----
do
local function init_globals()
  storage.cybersyn_stops = storage.cybersyn_stops or {}
  storage.cybersyn_provided = storage.cybersyn_provided or {}
  storage.cybersyn_requested = storage.cybersyn_requested or {}
  storage.cybersyn_deliveries = storage.cybersyn_deliveries or {}
  storage.content_combinators = storage.content_combinators or {}
  storage.update_interval = settings.global["cybersyn_content_reader_update_interval"].value
end

local function register_events()
  -- register game events
  script.on_event({defines.events.on_built_entity, defines.events.on_robot_built_entity}, OnEntityCreated)
  script.on_event({defines.events.on_pre_player_mined_item, defines.events.on_robot_pre_mined, defines.events.on_entity_died}, OnEntityRemoved)
  if #storage.content_combinators > 0 then
    script.on_event(defines.events.on_tick, OnTick)
  end
end


script.on_init(function()
  init_globals()
  register_events()
end)

script.on_configuration_changed(function(data)
  init_globals()
  register_events()
end)

script.on_load(function(data)
  register_events()
end)
end