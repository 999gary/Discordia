local Cache = require('../../../utils/Cache')
local Invite = require('../../Invite')
local Channel = require('../Channel')
local PermissionOverwrite = require('../PermissionOverwrite')

local wrap, yield = coroutine.wrap, coroutine.yield

local GuildChannel, get, set = class('GuildChannel', Channel)

function GuildChannel:__init(data, parent)
	Channel.__init(self, data, parent)
	self._permission_overwrites = Cache({}, PermissionOverwrite, '_id', self)
	-- abstract class, don't call update
end

get('name', '_name')
get('guild', '_parent')
get('position', '_position')

function GuildChannel:_update(data)
	Channel._update(self, data)
	local overwrites = self._permission_overwrites
	if #data.permission_overwrites > 0 then
		local updated = {}
		for _, data in ipairs(data.permission_overwrites) do
			updated[data.id] = true
			local overwrite = overwrites:get(data.id)
			if overwrite then
				overwrite:_update(data)
			else
				overwrite = overwrites:new(data)
			end
		end
		for overwrite in overwrites:iter() do
			if not updated[overwrite._id] then
				overwrites:remove(overwrite)
			end
		end
	end
end

set('name', function(self, name)
	local success, data = self._parent._parent._api:modifyChannel(self._id, {name = name})
	if success then self._name = data.name end
	return success
end)

set('position', function(self, position) -- will probably need more abstraction
	local success, data = self._parent._parent._api:modifyChannel(self._id, {position = position})
	if success then self._position = data.position end
	return success
end)

function GuildChannel:getPermissionOverwriteFor(object)
	local type = type(object) == 'table' and object.__name:lower() or nil
	if type ~= 'role' and type ~= 'member' then return end
	local id = object._id
	return self._permission_overwrites:get(id) or self._permission_overwrites:new({
		id = id, allow = 0, deny = 0, type = type
	})
end

get('invites', function(self)
	local client = self._parent._parent
	local success, data = client._api:getChannelInvites(self._id)
	if not success then return function() end end
	return wrap(function()
		for _, inviteData in ipairs(data) do
			yield(Invite(inviteData, client))
		end
	end)
end)

function GuildChannel:createInvite(maxAge, maxUses, temporary, unique)
	local client = self._parent._parent
	local success, data = client._api:createChannelInvite(self._id, {
		max_age = maxAge,
		max_uses = maxUses,
		temporary = temporary,
		unique = unique
	})
	if success then return Invite(data, client) end
end

-- permission overwrite --

get('permissionOverwriteCount', function(self, key, value)
	return self._permission_overwrites._count
end)

get('permissionOverwrites', function(self, key, value)
	return self._permission_overwrites:getAll(key, value)
end)

function GuildChannel:getPermissionOverwrite(key, value)
	return self._permission_overwrites:get(key, value)
end

function GuildChannel:findPermissionOverwrite(predicate)
	return self._permission_overwrites:find(predicate)
end

function GuildChannel:findPermissionOverwrites(predicate)
	return self._permission_overwrites:findAll(predicate)
end

return GuildChannel
