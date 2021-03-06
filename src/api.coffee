_ = require 'lodash'
FS = require 'fs'
Q = require 'q'
moment = require 'moment'
request = require 'request'
WebSocket = require 'ws'

auth = require './auth'
config = require './config'
errors = require './errors'

# Create the record for use in authenticating the tools client
makeRecord = (cfg) ->
  record =
    access_key: cfg.api_key.access
    client_salt: cfg.client_key.salt
    timestamp: moment.utc().toISOString()

class PushWebSocket
  constructor: (@cfg, @namespace, @attributes, @eventHandler) ->
    @baseUrl = @cfg.base_ws_url
    @sock = null
    @pingerRef = null
    @messageCount = 0
    @lastMessageId = null

  disconnect: ->
    if @pingerRef?
      try
        clearInterval @pingerRef
      catch error
        console.error "Error clearing ping interval: #{error}\n#{error.stack}"
      finally
        @pingerRef = null

    if @sock?
      try
        @sock.close()
      catch error
        console.log "Error while closing WebSocket: #{error}\n#{error.stack}"
      finally
        @sock = null

  # Notify of this event via the optional @eventHandler function
  notify: (event, data = undefined) ->
    try
      if @eventHandler?
        @eventHandler event, data
    catch error
      console.error "Error in user-supplied event handler: #{error}\n#{error.stack}"

  connect: ->
    d = Q.defer()
    if @sock?
      d.resolve()
    else
      record = makeRecord @cfg
      record.namespace = @namespace
      record.attributes = @attributes

      data = auth.signRecord @cfg.client_key.secret, record

      url = "#{@baseUrl}/push"
      options =
        headers:
          'Payload-HMAC': data.hmac
          'JSON-Base64': data.bufferB64
        timeout: @cfg.websocket_connect_timeout

      try
        @sock = new WebSocket(url, options)

        # The WebSocket was closed
        @sock.on 'close', =>
          @notify 'close'

          console.log "Push WebSocket closed for namespace '#{data.record.namespace}' topic [#{_(data.record.attributes).join(",")}]"

        # The WebSocket connection has been established
        @sock.on 'open', =>
          @notify 'open'

          pinger = =>
            @sock.ping()

          # Ping every 15 seconds to keep the connection alive 
          @pingerRef = setInterval pinger, 15000

          d.resolve()

        # An error occurred
        @sock.on 'error', (error) =>
          @notify 'error', error

          console.error "WebSocket error for namespace '#{data.record.namespace}' topic [#{_(data.record.attributes).join(",")}] : #{error}\n#{error.stack}"

        # Received a message
        @sock.on 'message', (msg) =>
          @notify 'message', msg

          try
            @messageCount += 1
            message = JSON.parse msg
            @lastMessageId = message.message_id
            acknowledgement =
              event: "message-received"
              message_id: message.message_id
            @sock.send JSON.stringify(acknowledgement), (error) ->
              if error?
                console.error "Error sending acknowledgement for message '#{message.message_id}': #{error}\n#{error.stack}"
          catch error
            console.error "Invalid push message received: #{error}\n#{error.stack}"

        # WebSocket connection was rejected by the API
        @sock.on 'unexpected-response', (req, res) =>
          @notify 'unexpected-response', [req, res]

          res.on 'data', (raw) ->
            try
              record = JSON.parse json
              json = JSON.stringify record, null, 2
              #console.log "Failed to establish WebSocket: [#{res.statusCode}] #{formatted}"
              d.reject new errors.ApiError("Server rejected the push WebSocket", undefined, res.statusCode, json)
            catch error
              #console.error "Failed to establish push WebSocket", undefined, res.statusCode, json)
              d.reject new errors.ApiError("Server rejected the push WebSocket", undefined, res.statusCode, raw)
            false
          false

      catch error
        d.reject new errors.ApiError("Error creating the push WebSocket", error)

    d.promise

class ApiClient
  constructor: (@cfg) ->
    @baseUrl = @cfg.base_url

  accessKey: -> @cfg?.api_key?.access
  clientSalt: -> @cfg?.client_key?.salt
  clientSecret: -> @cfg?.client_key?.secret

  subscribe: (namespace, attributes, eventHandler) ->
    d = Q.defer()

    try
      ws = new PushWebSocket(@cfg, namespace, attributes, eventHandler)
      ws.connect()
      .then ->
        d.resolve ws
      .catch (error) ->
        d.reject error
    catch error
      d.reject error

    d.promise

  sendEvent: (namespace, eventName, attributes, tags = undefined, debugDirective = undefined) ->
    record = makeRecord @cfg
    record.namespace = namespace
    record.event_name = eventName
    record.attributes = attributes
    record.tags = tags
    record.debug_directive = debugDirective

    data = auth.signRecord @cfg.client_key.secret, record

    @makeRequest 'POST', "/event", data

  getMessage: (namespace, attributes, messageId) ->
    record = makeRecord @cfg
    record.namespace = namespace
    record.attributes = attributes

    data = auth.signRecord @cfg.client_key.secret, record
    
    @makeRequest 'GET', "/message/#{messageId}", data

  makeRequest: (method, path, data) ->
    d = Q.defer()
    
    isGet = method == 'GET'
    contentType = if not isGet then 'application/json' else undefined
    jsonB64Header = if isGet then data.bufferB64 else undefined
    payload = if not isGet then data.buffer else undefined

    url = "#{@baseUrl}#{path}"
    options =
      uri: url
      method: method
      headers:
        'Payload-HMAC': data.hmac
        'Content-Type': contentType
        'JSON-Base64': jsonB64Header
      body: payload
      timeout: @cfg.http_request_timeout

    request options, (error, response) ->
      if error?
        #console.error "Error attempting to send a request to the Cogs server: #{error}\n#{error.stack}"
        d.reject new errors.ApiError("Error attempting to send a request to the Cogs server", error)
      else if response.statusCode != 200
        try
          record = JSON.parse json
          json = JSON.stringify record, null, 2
          d.reject new errors.ApiError("Received an error response from the server", undefined, response.statusCode, json)
        catch error
          d.reject new errors.ApiError("Received an error response from the server", undefined, response.statusCode, response.body)
      else
        try
          d.resolve JSON.parse(response.body)
        catch error
          #console.error "Error parsing response JSON: #{error}\n#{error.stack}"
          d.reject new errors.ApiError("Error parsing response body (expected valid JSON)", error)

    d.promise


# exports
module.exports =
  getClient: (configPath) ->
    config.getConfig configPath
    .then (cfg) ->
      new ApiClient(cfg)

  getClientWithConfig: (cfg) ->
    Q(new ApiClient(cfg))

