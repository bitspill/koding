jraphical = require 'jraphical'

module.exports = class JGuest extends jraphical.Module

  error =(err)->
    message:
      if 'string' is typeof err
        err
      else
        err.message

  {secure, dash} = require 'bongo'
  
  @share()

  KodingError = require '../error'

  {sharedStaticMethods, sharedInstanceMethods} = require '../models/account/methods'

  # We import instance & static methods from JAccount into JGuest for
  # uniformty of interface
  for method in sharedStaticMethods()
    this[method] ?= (err, callback)->
      callback new KodingError "Access denied"

  for method in sharedInstanceMethods()
    this::[method] ?= (err, callback)->
      callback new KodingError "Access denied"

  staticMethods = sharedStaticMethods()
  staticMethods.push.apply staticMethods, ['obtain', 'resetAllGuests']
  instanceMethods = sharedInstanceMethods()
  instanceMethods.push.apply instanceMethods, ['getDefaultEnvironment', 'fetchStorage']

  @set
    sharedMethods   :
      static        : staticMethods
      instance      : instanceMethods
    indexes         :
      guestId       : ['unique', 'descending']
    schema          :
      guestId       :
        required    : yes
        type        : Number
      status        :
        type        : String
        enum        : ['invalid guest status',['pristine','needs cleanup','in use','leasing']]
        default     : 'pristine'
      clientId      : String
      leaseId       : String
      leasedAt      : Date
      profile       :
        nickname    :
          type      : String
          default   : -> 'Guest'
        firstname   : String
        lastname    : String
        description : String
        avatar      : String
        status      : String

  @_resetAllGuests =(count=1e4)->
    @drop ->
      queue = [0...count].map (guestId)->->
        guest = new JGuest {guestId}
        guest.save (err)->
          console.log 'saved a guest!'
          queue.fin err
      dash queue, ->
        console.log 'done restting guests!'

  @resetAllGuests =(client, callback)->
    {delegate} = client.connection
    @_resetAllGuests() if delegate.can('reset guests')

  @recycle =(guest, callback=->) ->
    guestId = if guest instanceof @ then guest.getId() else guest
    @update {guestId}, $set:{status: 'needs cleanup'}, callback
    @emit 'NeedsCleanup'

  recycle:-> @constructor.recycle this # YAGNI?

  @obtain = do->
    obtaining = {}
    secure (client, clientId, callback)->
      [callback, clientId] = [clientId, callback] unless callback
      JAccount = require './account'
      createId = require 'hat'
      if clientId?
        if obtaining[clientId]
          @once "ready.#{clientId}", (guest)-> console.log 'finally got', clientId; callback null, guest
          return
        obtaining[clientId] = yes
      {delegate} = client?.connection
      if delegate instanceof JAccount
        callback error 'Logged in user cannot obtain a guest account!'
      else
        leaseId = createId()
        @update {status: 'pristine'}, $set:{
          status    : 'leasing'
          leasedAt  : new Date
          leaseId
        }, (err)=>
          if err then callback error err
          else
            @one {leaseId}, (err, guest)=>
              if err then callback error err
              else unless guest?
                callback error "We've reached maximum occupancy for guests.  Please try again later."
              else
                @update {_id:guest.getId()}, {
                  $unset    :
                    leaseId : 1
                  $set      :
                    status  : 'in use'
                }, (err)=>
                  if err then callback error err
                  else
                    @emit "ready.#{clientId}", guest
                    delete obtaining[clientId]
                    callback null, guest

  fetchStorage: secure (client, options, callback)->
    JAppStorage = require './appstorage'
    callback null, new JAppStorage options
