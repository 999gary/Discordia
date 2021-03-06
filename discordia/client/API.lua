local json = require('json')
local http = require('coro-http')
local package = require('../package')
local RateLimiter = require('../utils/RateLimiter')

local format = string.format
local request = http.request
local max, random = math.max, math.random
local encode, decode = json.encode, json.decode
local insert, concat = table.insert, table.concat
local date, time, difftime = os.date, os.time, os.difftime
local info, warning, failure = console.info, console.warning, console.failure

local months = {
	Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
	Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12
}

local function parseDate(str)
	local wday, day, month, year, hour, min, sec = str:match(
		'(%a-), (%d-) (%a-) (%d-) (%d-):(%d-):(%d-) GMT'
	)
	local serverDate = {
		day = day, month = months[month], year = year,
		hour = hour, min = min, sec = sec,
	}
	local clientDate = date('!*t')
	clientDate.isdst = date('*t').isdst
	local serverTime = difftime(time(serverDate), time(clientDate)) + time()
	local calculated = date('!%a, %d %b %Y %H:%M:%S GMT', serverTime)
	if str ~= calculated then warning.time(str, calculated) end
	return serverTime
end

local function attachQuery(endpoint, query)
	if not query or not next(query) then return endpoint end
	local buffer = {}
	for k, v in pairs(query) do
		insert(buffer, format('%s=%s', k, v))
	end
	return format('%s?%s', endpoint, concat(buffer, '&'))
end

local API = class('API')

function API:__init(client)
	self._client = client
	self._route_delay = client._options.routeDelay
	self._global_delay = client._options.globalDelay
	self._global_limiter = RateLimiter()
	self._route_limiter = {}
	self._headers = {
		['Content-Type'] = 'application/json',
		['User-Agent'] = format('DiscordBot (%s, %s)', package.homepage, package.version),
	}
end

function API:setToken(token)
	self._headers['Authorization'] = token
end

function API:request(method, route, endpoint, payload)

	local url = "https://discordapp.com/api" .. endpoint

	local reqHeaders = {}
	for k, v in pairs(self._headers) do
		insert(reqHeaders, {k, v})
	end

	if method:find('P') then
		payload = payload and encode(payload) or '{}'
		insert(reqHeaders, {'Content-Length', #payload})
	end

	local routeLimiter = self._route_limiter[route] or RateLimiter()
	self._route_limiter[route] = routeLimiter

	return self:commit(method, url, reqHeaders, payload, routeLimiter, 1)

end

function API:commit(method, url, reqHeaders, payload, routeLimiter, attempts)

	local isRetry = attempts > 1
	local routeDelay = self._route_delay
	local globalDelay = self._global_delay
	local globalLimiter = self._global_limiter

	routeLimiter:start(isRetry)
	globalLimiter:start(isRetry)

	local res, data = request(method, url, reqHeaders, payload)

	local resHeaders = {}
	for i, v in ipairs(res) do
		resHeaders[v[1]] = v[2]
		res[i] = nil
	end

	local reset = tonumber(resHeaders['X-RateLimit-Reset'])
	local remaining = tonumber(resHeaders['X-RateLimit-Remaining'])

	if reset and remaining == 0 then
		local dt = difftime(reset, parseDate(resHeaders['Date']))
		routeDelay = max(1000 * dt, routeDelay)
	end

	local success, data = res.code < 300, decode(data)
	local shouldRetry = false

	if not success then
		warning.http(method, url, res, data)
		if res.code == 429 then
			if data.global then
				globalDelay = data.retry_after
			end
			routeDelay = data.retry_after
			shouldRetry = attempts < 5
		elseif res.code == 502 then
			routeDelay = routeDelay + random(2000)
			shouldRetry = attempts < 5
		end
	end

	routeLimiter:stop(routeDelay)
	globalLimiter:stop(globalDelay)

	if shouldRetry then
		return self:commit(method, url, reqHeaders, payload, routeLimiter, attempts + 1)
	end

	return success, data

end

-- endpoint methods auto-generated from Discord documentation --

function API:getChannel(channel_id) -- not exposed, use cache
	local route = format("/channels/%s", channel_id)
	return self:request("GET", route, route)
end

function API:modifyChannel(channel_id, payload) -- various channel methods
	local route = format("/channels/%s", channel_id)
	return self:request("PATCH", route, route, payload)
end

function API:deleteChannel(channel_id) -- Channel:delete
	local route = format("/channels/%s", channel_id)
	return self:request("DELETE", route, route)
end

function API:getChannelMessages(channel_id, query) -- TextChannel:getMessageHistory[Before|After|Around]
	local route = format("/channels/%s/messages", channel_id)
	return self:request("GET", route, attachQuery(route, query))
end

function API:getChannelMessage(channel_id, message_id) -- not exposed, use cache
	local route = format("/channels/%s/messages/%%s", channel_id)
	return self:request("GET", route, format(route, message_id))
end

function API:createMessage(channel_id, payload) -- TextChannel:[create|send]Message
	local route = format("/channels/%s/messages", channel_id)
	return self:request("POST", route, route, payload)
end

function API:uploadFile(channel_id, payload) -- TODO
	local route = format("/channels/%s/messages", channel_id)
	return self:request("POST", route, route, payload)
end

function API:editMessage(channel_id, message_id, payload) -- Message:setContent
	local route = format("/channels/%s/messages/%%s", channel_id)
	return self:request("PATCH", route, format(route, message_id), payload)
end

function API:deleteMessage(channel_id, message_id) -- Message:delete
	local route = format("/channels/%s/messages/%%s", channel_id)
	return self:request("DELETE", route, format(route, message_id))
end

function API:bulkDeleteMessages(channel_id, payload) -- TextChannel:bulkDelete
	local route = format("/channels/%s/messages/bulk-delete", channel_id)
	return self:request("POST", route, route, payload)
end

function API:editChannelPermissions(channel_id, overwrite_id, payload) -- various overwrite methods
	local route = format("/channels/%s/permissions/%%s", channel_id)
	return self:request("PUT", route, format(route, overwrite_id), payload)
end

function API:getChannelInvites(channel_id) -- GuildChannel:getInvites
	local route = format("/channels/%s/invites", channel_id)
	return self:request("GET", route, route)
end

function API:createChannelInvite(channel_id, payload) -- GuildChannel:createInvite
	local route = format("/channels/%s/invites", channel_id)
	return self:request("POST", route, route, payload)
end

function API:deleteChannelPermission(channel_id, overwrite_id) -- PermissionOverwrite:delete
	local route = format("/channels/%s/permissions/%%s", channel_id)
	return self:request("DELETE", route, format(route, overwrite_id))
end

function API:triggerTypingIndicator(channel_id, payload) -- TextChannel:broadcastTyping
	local route = format("/channels/%s/typing", channel_id)
	return self:request("POST", route, route, payload)
end

function API:getPinnedMessages(channel_id) -- TextChannel:getPinnedMessages
	local route = format("/channels/%s/pins", channel_id)
	return self:request("GET", route, route)
end

function API:addPinnedChannelMessage(channel_id, message_id, payload) -- Message:pin
	local route = format("/channels/%s/pins/%%s", channel_id)
	return self:request("PUT", route, format(route, message_id), payload)
end

function API:deletePinnedChannelMessage(channel_id, message_id) -- Message:unpin
	local route = format("/channels/%s/pins/%%s", channel_id)
	return self:request("DELETE", route, format(route, message_id))
end

function API:groupDMAddRecipient(channel_id, user_id, payload) -- not exposed, maybe in the future
	local route = format("/channels/%s/recipients/%%s", channel_id)
	return self:request("PUT", route, format(route, user_id), payload)
end

function API:groupDMRemoveRecipient(channel_id, user_id) -- not exposed, maybe in the future
	local route = format("/channels/%s/recipients/%%s", channel_id)
	return self:request("DELETE", route, format(route, user_id))
end

function API:createGuild(payload) -- Client:createGuild
	local route = "/guilds"
	return self:request("POST", route, route, payload)
end

function API:getGuild(guild_id) -- not exposed, use cache
	local route = format("/guilds/%s", guild_id)
	return self:request("GET", route, route)
end

function API:modifyGuild(guild_id, payload) -- various guild methods
	local route = format("/guilds/%s", guild_id)
	return self:request("PATCH", route, route, payload)
end

function API:deleteGuild(guild_id) -- Guild:delete
	local route = format("/guilds/%s", guild_id)
	return self:request("DELETE", route, route)
end

function API:getGuildChannels(guild_id) -- not exposed, use cache
	local route = format("/guilds/%s/channels", guild_id)
	return self:request("GET", route, route)
end

function API:createGuildChannel(guild_id, payload) -- Guild:create[Text|Voice]Channel
	local route = format("/guilds/%s/channels", guild_id)
	return self:request("POST", route, route, payload)
end

function API:modifyGuildChannelPosition(guild_id, payload) -- not exposed, see modifyChannel
	local route = format("/guilds/%s/channels", guild_id)
	return self:request("PATCH", route, route, payload)
end

function API:getGuildMember(guild_id, user_id) -- User:getMembership fallback
	local route = format("/guilds/%s/members/%%s", guild_id)
	return self:request("GET", route, format(route, user_id))
end

function API:listGuildMembers(guild_id) -- not exposed, use cache or Guild:requestMembers
	local route = format("/guilds/%s/members", guild_id)
	return self:request("GET", route, route)
end

function API:addGuildMember(guild_id, user_id, payload) -- Guild:addMember (limited use, requires guild.join scope)
	local route = format("/guilds/%s/members/%%s", guild_id)
	return self:request("PUT", route, format(route, user_id), payload)
end

function API:modifyGuildMember(guild_id, user_id, payload) -- various member methods
	local route = format("/guilds/%s/members/%%s", guild_id)
	return self:request("PATCH", route, format(route, user_id), payload)
end

function API:removeGuildMember(guild_id, user_id) -- Guild:kickUser, User:kick, Member:kick
	local route = format("/guilds/%s/members/%%s", guild_id)
	return self:request("DELETE", route, format(route, user_id))
end

function API:getGuildBans(guild_id) -- Guild:getBans
	local route = format("/guilds/%s/bans", guild_id)
	return self:request("GET", route, route)
end

function API:createGuildBan(guild_id, user_id, payload, query) -- Guild:banUser, User:ban, Member:ban
	local route = format("/guilds/%s/bans/%%s", guild_id)
	return self:request("PUT", route, attachQuery(format(route, user_id), query), payload)
end

function API:removeGuildBan(guild_id, user_id) -- Guild:unbanUser, User:unban, Member:unban
	local route = format("/guilds/%s/bans/%%s", guild_id)
	return self:request("DELETE", route, format(route, user_id))
end

function API:getGuildRoles(guild_id) -- not exposed, use cache
	local route = format("/guilds/%s/roles", guild_id)
	return self:request("GET", route, route)
end

function API:createGuildRole(guild_id, payload) -- Guild:createRole
	local route = format("/guilds/%s/roles", guild_id)
	return self:request("POST", route, route, payload)
end

function API:batchModifyGuildRole(guild_id, payload) -- not exposed, maybe in the future
	local route = format("/guilds/%s/roles", guild_id)
	return self:request("PATCH", route, route, payload)
end

function API:modifyGuildRole(guild_id, role_id, payload) -- various role methods
	local route = format("/guilds/%s/roles/%%s", guild_id)
	return self:request("PATCH", route, format(route, role_id), payload)
end

function API:deleteGuildRole(guild_id, role_id) -- Role:delete
	local route = format("/guilds/%s/roles/%%s", guild_id)
	return self:request("DELETE", route, format(route, role_id))
end

function API:getGuildPruneCount(guild_id, query) -- Guild:getPruneCount
	local route = format("/guilds/%s/prune", guild_id)
	return self:request("GET", route, attachQuery(route, query))
end

function API:beginGuildPrune(guild_id, payload) -- Guild:pruneMembers
	local route = format("/guilds/%s/prune", guild_id)
	return self:request("POST", route, route, payload)
end

function API:getGuildVoiceRegions(guild_id) -- Guild:listVoiceRegions
	local route = format("/guilds/%s/regions", guild_id)
	return self:request("GET", route, route)
end

function API:getGuildInvites(guild_id) -- Guild:getInvites
	local route = format("/guilds/%s/invites", guild_id)
	return self:request("GET", route, route)
end

function API:getGuildIntegrations(guild_id) -- not exposed, maybe in the future
	local route = format("/guilds/%s/integrations", guild_id)
	return self:request("GET", route, route)
end

function API:createGuildIntegration(guild_id, payload) -- not exposed, maybe in the future
	local route = format("/guilds/%s/integrations", guild_id)
	return self:request("POST", route, route, payload)
end

function API:modifyGuildIntegration(guild_id, integration_id, payload) -- not exposed, maybe in the future
	local route = format("/guilds/%s/integrations/%%s", guild_id)
	return self:request("PATCH", route, format(route, integration_id), payload)
end

function API:deleteGuildIntegration(guild_id, integration_id) -- not exposed, maybe in the future
	local route = format("/guilds/%s/integrations/%%s", guild_id)
	return self:request("DELETE", route, format(route, integration_id))
end

function API:syncGuildIntegration(guild_id, integration_id, payload) -- not exposed, maybe in the future
	local route = format("/guilds/%s/integrations/%%s/sync", guild_id)
	return self:request("POST", route, format(route, integration_id), payload)
end

function API:getGuildEmbed(guild_id) -- not exposed, maybe in the future
	local route = format("/guilds/%s/embed", guild_id)
	return self:request("GET", route, route)
end

function API:modifyGuildEmbed(guild_id, payload) -- not exposed, maybe in the future
	local route = format("/guilds/%s/embed", guild_id)
	return self:request("PATCH", route, route, payload)
end

function API:getInvite(invite_code) -- Client:getInviteByCode
	local route = "/invites/%s"
	return self:request("GET", route, format(route, invite_code))
end

function API:deleteInvite(invite_code) -- Invite:delete
	local route = "/invites/%s"
	return self:request("DELETE", route, format(route, invite_code))
end

function API:acceptInvite(invite_code, payload) -- Invite:accept, Client:acceptInviteByCode
	local route = "/invites/%s"
	return self:request("POST", route, format(route, invite_code), payload)
end

function API:getCurrentUser() -- not exposed, use cache (Client.user)
	local route = "/users/@me"
	return self:request("GET", route, route)
end

function API:getUser(user_id) -- not exposed, use cache
	local route = "/users/%s"
	return self:request("GET", route, format(route, user_id))
end

function API:modifyCurrentUser(payload) -- various client methods
	local route = "/users/@me"
	return self:request("PATCH", route, route, payload)
end

function API:getCurrentUserGuilds() -- not exposed, use cache
	local route = "/users/@me/guilds"
	return self:request("GET", route, route)
end

function API:leaveGuild(guild_id) -- Guild:leave
	local route = "/users/@me/guilds/%s"
	return self:request("DELETE", route, format(route, guild_id))
end

function API:getUserDMs() -- not exposed, use cache
	local route = "/users/@me/channels"
	return self:request("GET", route, route)
end

function API:createDM(payload) -- User:sendMessage
	local route = "/users/@me/channels"
	return self:request("POST", route, route, payload)
end

function API:createGroupDM(payload) -- not exposed, maybe in the future
	local route = "/users/@me/channels"
	return self:request("POST", route, route, payload)
end

function API:getUsersConnections() -- not exposed, maybe in the future
	local route = "/users/@me/connections"
	return self:request("GET", route, route)
end

function API:listVoiceRegions() -- Client:listVoiceRegions
	local route = "/voice/regions"
	return self:request("GET", route, route)
end

function API:createWebhook(channel_id, payload) -- not exposed, maybe in the future
	local route = format("/channels/%s/webhooks", channel_id)
	return self:request("POST", route, route, payload)
end

function API:getChannelWebhooks(channel_id) -- not exposed, maybe in the future
	local route = format("/channels/%s/webhooks", channel_id)
	return self:request("GET", route, route)
end

function API:getGuildWebhooks(guild_id) -- not exposed, maybe in the future
	local route = format("/guilds/%s/webhooks", guild_id)
	return self:request("GET", route, route)
end

function API:getWebhook(webhook_id) -- not exposed, maybe in the future
	local route = "/webhooks/%s"
	return self:request("GET", route, format(route, webhook_id))
end

function API:getWebhookwithToken(webhook_id, webhook_token) -- not exposed, maybe in the future
	local route = "/webhooks/%s/%s"
	return self:request("GET", route, format(route, webhook_id, webhook_token))
end

function API:modifyWebhook(webhook_id, payload) -- not exposed, maybe in the future
	local route = "/webhooks/%s"
	return self:request("PATCH", route, format(route, webhook_id), payload)
end

function API:modifyWebhookwithToken(webhook_id, webhook_token, payload) -- not exposed, maybe in the future
	local route = "/webhooks/%s/%s"
	return self:request("PATCH", route, format(route, webhook_id, webhook_token), payload)
end

function API:deleteWebhook(webhook_id) -- not exposed, maybe in the future
	local route = "/webhooks/%s"
	return self:request("DELETE", route, format(route, webhook_id))
end

function API:deleteWebhookwithToken(webhook_id, webhook_token) -- not exposed, maybe in the future
	local route = "/webhooks/%s/%s"
	return self:request("DELETE", route, format(route, webhook_id, webhook_token))
end

function API:executeWebhook(webhook_id, webhook_token, payload) -- not exposed, maybe in the future
	local route = "/webhooks/%s/%s"
	return self:request("POST", route, format(route, webhook_id, webhook_token), payload)
end

function API:executeSlackCompatibleWebhook(webhook_id, webhook_token, payload) -- not exposed, maybe in the future
	local route = "/webhooks/%s/%s/slack"
	return self:request("POST", route, format(route, webhook_id, webhook_token), payload)
end

function API:executeGitHubCompatibleWebhook(webhook_id, webhook_token, payload) -- not exposed, maybe in the future
	local route = "/webhooks/%s/%s/github"
	return self:request("POST", route, format(route, webhook_id, webhook_token), payload)
end

function API:getGateway() -- Client:_connectToGateway (cached)
	local route = "/gateway"
	return self:request("GET", route, route)
end

function API:getGatewayBot() -- not exposed, maybe in the future
	local route = "/gateway/bot"
	return self:request("GET", route, route)
end

function API:getCurrentApplicationInformation() -- not exposed, maybe in the future
	local route = "/oauth2/applications/@me"
	return self:request("GET", route, route)
end

-- end of auto-generated methods --

function API:getToken(payload) -- Client:run
	local route = "/auth/login"
	return self:request('POST', route, route, payload)
end

function API:modifyCurrentUserNickname(guild_id, payload) -- Client:setNickname
	local route = format("/guilds/%s/members/@me/nick", guild_id)
	return self:request('PATCH', route, route, payload)
end

return API
