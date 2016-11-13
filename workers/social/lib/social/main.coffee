process.title = 'koding-socialworker'

require 'coffee-cache'

log = -> console.log arguments...

{ argv } = require 'optimist'

{ exec }           = require 'child_process'
{ extend }         = require 'underscore'
{ join: joinPath } = require 'path'

usertracker = require '../../../usertracker'
datadog     = require '../../../datadog'

process.on 'uncaughtException', (err) ->
  console.log err, err?.stack
  process.exit 1

Bongo = require 'bongo'
Broker = require 'broker'

KONFIG = require 'koding-config-manager'
Object.defineProperty global, 'KONFIG', { value: KONFIG }
{ mq, email, social, mongoReplSet, socialapi } = KONFIG

redisClient = require('redis').createClient(
  KONFIG.monitoringRedis.port
  KONFIG.monitoringRedis.host
  {}
)

mongo = "mongodb://#{KONFIG.mongo}"  if 'string' is typeof KONFIG.mongo

mqOptions = extend {}, mq
mqOptions.login = social.login if social?.login?

broker = new Broker mqOptions

mqConfig = { host: mq.host, port: mq.port, login: mq.login, password: mq.password, vhost: mq.vhost }

# TODO exchange version must be injected here, when we have that support
mqConfig.exchangeName = "#{socialapi.eventExchangeName}:0"


koding = new Bongo {
  verbose     : social.verbose
  root        : __dirname
  mongo       : mongoReplSet or mongo
  models      : './models'
  resourceName: social.queueName
  mq          : broker
  mqConfig    : mqConfig
  metrics     : datadog
  redisClient : redisClient


  kite          :
    name        : 'social'
    environment : argv.environment or KONFIG.environment
    region      : argv.region or KONFIG.region
    version     : KONFIG.version
    username    : 'koding'
    port        : argv['kite-port'] or KONFIG.social.kitePort
    prefix      : 'social'
    kiteKey     : argv['kite-key'] or KONFIG.social.kiteKey

    fetchClient: (name, context, callback) ->
      { JAccount } = koding.models
      [callback, context] = [context, callback] unless callback
      context   ?= { group: 'koding' }
      callback  ?= ->
      JAccount.one { 'profile.nickname': name }, (err, account) ->
        return callback err  if err?

        if account instanceof JAccount
          callback null, { context, connection: { delegate : account } }

  fetchClient: (sessionToken, context, callback) ->

    { JUser, JAccount } = koding.models
    [callback, context] = [context, callback] unless callback
    callback            ?= ->

    return callback null  unless JUser

    JUser.authenticateClient sessionToken, (err, res = {}) ->

      { account, session } = res

      context ?= { group: session?.groupName ? 'koding' }

      if err
        console.error 'bongo.fetchClient', { err, sessionToken, context }
        callback null

      else if account instanceof JAccount

        usertracker.track account.profile.nickname

        { clientIP, clientId: sessionToken, username } = session

        callback {
          sessionToken, context, clientIP, username
          connection: { delegate: account }
        }

      else
        console.error 'this is not a proper account', { sessionToken }
        console.error 'constructor is JAccount', JAccount is account?.constructor
        callback null
}

koding.on 'errFirstDetected', (err) -> console.error err

koding.connect ->
  # create default roles for groups
  JGroupRole = require './models/group/role'

  JGroupRole.createDefaultRoles (err) ->
    if err then console.log err.message
    else console.log 'Default group roles created!'

  { forcedRecipientEmail } = KONFIG.email
  Tracker = require './models/tracker'
  Tracker.identify forcedRecipientEmail  if forcedRecipientEmail


console.info "Koding Social Worker #{process.pid} has started."

express = require 'express'
cors = require 'cors'
helmet = require 'helmet'
app = express()

do ->
  usertracker.start redisClient

  if KONFIG.environment is 'production'
    { NodejsProfiler } = require 'koding-datadog'
    # start monitoring nodejs metrics (memory, gc, cpu etc...)
    nodejsProfiler = new NodejsProfiler 'socialWorker'
    nodejsProfiler.startMonitoring()

  compression = require 'compression'
  bodyParser = require 'body-parser'

  app.use compression()
  app.use bodyParser.json { limit: '2mb' }

  helmet.defaults app
  app.use cors()

  options = { rateLimitOptions : KONFIG.nodejsRateLimiter }

  app.post '/remote.api/:model/:id?', (require './remoteapi') koding

  app.get  '/remote.api', (req, res) ->
    res.send 'REST API is OK'

  app.post '/xhr', koding.expressify options

  app.get '/xhr', (req, res) ->
    res.send 'Socialworker is OK'

  app.get '/version', (req, res) ->
    res.send "#{KONFIG.version}"

  app.get '/healthCheck', (req, res) ->
    res.send "Socialworker is running with version: #{KONFIG.version}"

  app.listen argv.p or KONFIG.social.port
