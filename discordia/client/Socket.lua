local jit = require('jit')
local json = require('json')
local timer = require('timer')
local websocket = require('coro-websocket')
local EventHandler = require('./EventHandler')

local format = string.format
local min, max = math.min, math.max
local encode, decode = json.encode, json.decode
local wrap, yield = coroutine.wrap, coroutine.yield
local parseUrl, connect = websocket.parseUrl, websocket.connect
local info, warning, failure = console.info, console.warning, console.failure
local sleep, setInterval, clearInterval = timer.sleep, timer.setInterval, timer.clearInterval

local ignore = {
	['MESSAGE_ACK'] = true,
	['CHANNEL_PINS_UPDATE'] = true,
	['GUILD_EMOJIS_UPDATE'] = true,
	['GUILD_INTEGRATIONS_UPDATE'] = true,
	['MESSAGE_REACTION_ADD'] = true,
	['MESSAGE_REACTION_REMOVE'] = true,
}

local Socket = class('Socket')

function Socket:__init(client)
	self._client = client
	self._backoff = 1024
end

local function incrementReconnectTime(self)
	self._backoff = min(self._backoff * 2, 65536)
end

local function decrementReconnectTime(self)
	self._backoff = max(self._backoff / 2, 1024)
end

function Socket:connect(gateway)
	local options = parseUrl(gateway .. '/')
	options.pathname = options.pathname .. '?v=5'
	self._res, self._read, self._write = connect(options)
	self._connected = self._res and self._res.code == 101
	return self._connected
end

function Socket:reconnect(token)
	if self._connected then self:disconnect() end
	return self._client:_connectToGateway(token)
end

function Socket:disconnect()
	if not self._connected then return end
	self._connected = false
	self:stopHeartbeat()
	self._write()
	self._res, self._read, self._write = nil, nil, nil
end

local function handleUnexpectedDisconnect(self, token)
	warning(format('Attemping to reconnect after %i ms...', self._backoff))
	sleep(self._backoff)
	incrementReconnectTime(self)
	if not pcall(self.reconnect, self, token) then
		return handleUnexpectedDisconnect(self, token)
	end
end

function Socket:handlePayloads(token)

	local client = self._client

	for data in self._read do

		local string = data.payload
		local payload = decode(string)

		client:emit('raw', payload, string)

		local op = payload.op

		if op == 0 then
			self._seq = payload.s
			if not ignore[payload.t] then
				local handler = EventHandler[payload.t]
				if handler then
					handler(payload.d, client)
				else
					warning('Unhandled event: ' .. payload.t)
				end
			end
		elseif op == 1 then
			self:heartbeat()
		elseif op == 7 then
			self:reconnect()
		elseif op == 9 then
			warning('Invalid session, attempting to re-identify...')
			self:identify(token)
		elseif op == 10 then
			self:startHeartbeat(payload.d.heartbeat_interval)
			if self._session_id then
				self:resume(token)
			else
				self:identify(token)
			end
		elseif op == 11 then
			-- heartbeat acknowledged
		else
			warning('Unhandled payload: ' .. op)
		end

	end

	if self._connected then
		self._connected = false
		self:stopHeartbeat()
		warning('Disconnected from gateway unexpectedly')
		return handleUnexpectedDisconnect(self, token)
	end

end

function Socket:startHeartbeat(interval)
	self._heartbeatInterval = setInterval(interval, wrap(function()
		while true do
			decrementReconnectTime(self)
			yield(self:heartbeat())
		end
	end))
end

function Socket:stopHeartbeat()
	if not self._heartbeatInterval then return end
	clearInterval(self._heartbeatInterval)
	self._heartbeatInterval = nil
end

local function send(self, payload)
	return self._write({
		opcode = 1,
		payload = encode(payload)
	})
end

function Socket:heartbeat()
	return send(self, {
		op = 1,
		d = self._seq
	})
end

function Socket:identify(token)
	return send(self, {
		op = 2,
		d = {
			token = token,
			properties = {
				['$os'] = jit.os,
				['$browser'] = 'Discordia',
				['$device'] = 'Discordia',
				['$referrer'] = '',
				['$referring_domain'] = ''
			},
			large_threshold = self._client._options.largeThreshold,
			compress = false,
		}
	})
end

function Socket:statusUpdate(idleSince, gameName)
	return send(self, {
		op = 3,
		d = {
			idle_since = idleSince or json.null,
			game = {name = gameName or json.null},
		}
	})
end

function Socket:resume(token)
	return send(self, {
		op = 6,
		d = {
			token = token,
			session_id = self._session_id,
			seq = self._seq
		}
	})
end

function Socket:requestGuildMembers(guild_id)
	return send(self, {
		op = 8,
		d = {
			guild_id = guild_id,
			query = '',
			limit = 0
		}
	})
end

function Socket:syncGuilds(guild_ids)
	return send(self, {
		op = 12,
		d = guild_ids
	})
end

return Socket
