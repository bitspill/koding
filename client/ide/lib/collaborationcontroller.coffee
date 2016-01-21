_                             = require 'lodash'
remote                        = require('app/remote').getInstance()
dateFormat                    = require 'dateformat'
sinkrow                       = require 'sinkrow'
globals                       = require 'globals'
kd                            = require 'kd'
KDNotificationView            = kd.NotificationView
KDModalView                   = kd.ModalView
nick                          = require 'app/util/nick'
getCollaborativeChannelPrefix = require 'app/util/getCollaborativeChannelPrefix'
showError                     = require 'app/util/showError'
isTeamReactSide               = require 'app/util/isTeamReactSide'
whoami                        = require 'app/util/whoami'
RealtimeManager               = require './realtimemanager'
IDEChatView                   = require './views/chat/idechatview'
IDEMetrics                    = require './idemetrics'
doXhrRequest                  = require 'app/util/doXhrRequest'
realtimeHelpers               = require './collaboration/helpers/realtime'
socialHelpers                 = require './collaboration/helpers/social'
envHelpers                    = require './collaboration/helpers/environment'
CollaborationStateMachine     = require './collaboration/collaborationstatemachine'
environmentDataProvider       = require 'app/userenvironmentdataprovider'
IDELayoutManager              = require './workspace/idelayoutmanager'
IDEView                       = require './views/tabview/ideview'
BaseModalView                 = require 'app/providers/views/basemodalview'
actionTypes                   = require 'app/flux/environment/actiontypes'

{warn} = kd

# Attn!!
#
# This object is designed to be a mixin for IDEAppController.
#
# @see `IDEAppController`

module.exports = CollaborationController =

  # social related

  setSocialChannel: (channel) ->
    @socialChannel = channel
    @bindSocialChannelEvents()

    return  unless isTeamReactSide()

    { reactor } = kd.singletons

    reactor.dispatch actionTypes.UPDATE_WORKSPACE_CHANNEL_ID, {
      workspaceId : @workspaceData._id
      channelId   : @getSocialChannelId()
    }


  fetchSocialChannel: (callback) ->

    if @socialChannel
      return callback null, @socialChannel

    unless id = @getSocialChannelId()
      return callback()

    socialHelpers.fetchChannel id, (err, channel) =>
      return callback err  if err

      @setSocialChannel channel
      callback null, channel


  getSocialChannelId: ->

    return @socialChannel?.id or @channelId or @workspaceData.channelId


  unsetSocialChannel: ->

    @channelId = @socialChannel = null


  deletePrivateMessage: (callback = kd.noop) ->

    socialHelpers.destroyChannel @socialChannel, (err) =>
      return callback err  if err

      envHelpers.detachSocialChannel @workspaceData, (err) =>
        return callback err  if err
        @unsetSocialChannel()


  # FIXME: This method is called more than once. It should cache the result and
  # return if result set exists.
  listChatParticipants: (callback) ->

    id = @getSocialChannelId()

    socialHelpers.fetchParticipants id, (err, accounts) =>
      return throwError err  if err

      callback accounts


  getRealtimeFileName: (id) ->

    id or= @getSocialChannelId()

    unless id
      return showError 'social channel id is not provided'

    hostName = @getCollaborationHost()

    return "#{hostName}.#{id}"


  whenRealtimeReady: (callback) ->

    if @rtm?.isReady
    then callback()
    else @once 'RTMIsReady', callback


  kickParticipant: (account) ->

    return  unless @amIHost

    target = account.profile.nickname

    # this object is used to follow the same pattern as other
    # methods. IMO, it makes it easier to read. ~Umut
    callbacks =
      success: =>
        @broadcastMessage { target, type: 'ParticipantKicked' }
        @handleParticipantKicked target
      error: (err) ->
        # TODO: better error handling.
        showError err
        throwError err

    @removeWorkspaceSnapshot target

    socialHelpers.kickParticipants @socialChannel, [account], (err, result) ->
      return callbacks.error err  if err
      callbacks.success()


  handleParticipantKicked: (username) ->

    @chat.emit 'ParticipantLeft', username
    @statusBar.removeParticipantAvatar username
    @removeParticipantCursorWidget username
    # remove participant's all data persisted in realtime appInfo
    @removeParticipant username
    @removeWorkspaceSnapshot username

    options = {
      username
      machineUId : @mountedMachineUId
    }

    # Check collaboration sessions of participant.
    # If participant has 2 or more active collaboration sessions,  don't remove access from machine
    envHelpers.isUserStillParticipantOnMachine options, (status) =>
      @removeParticipantFromMachine username  unless status


  # Remove leaved / kicked participants from the mounted machine
  removeParticipantFromMachine: (username) ->

    @setMachineUser [username], no, (err) ->
      throwError err  if err


  handleParticipantAction: (actionType, changeData) ->

    kd.utils.wait 2000, =>

      switch actionType
        when 'join' then @onRealtimeParticipantJoined changeData
        when 'left' then @onRealtimeParticipantLeft changeData


  onRealtimeParticipantJoined: (data) ->

    return  unless @stateMachine?.state is 'Active'

    { sessionId }  = data.collaborator
    { targetUser } = realtimeHelpers.getTargetUser @participants, 'sessionId', sessionId

    unless targetUser
      return kd.warn 'Unknown user in collaboration, we should handle this case...'

    @chat.emit 'ParticipantJoined', targetUser
    @statusBar.emit 'ParticipantJoined', targetUser

    if @amIHost and targetUser isnt nick()
      @ensureMachineShare [targetUser], (err) =>
        return throwError err  if err


  onRealtimeParticipantLeft: (data) ->

    return  unless @stateMachine?.state is 'Active'

    {sessionId} = data.collaborator

    {targetUser, targetIndex} =
      realtimeHelpers.getTargetUser @participants, 'sessionId', sessionId

    unless targetUser
      return kd.warn 'Unknown user in collaboration, we should handle this case...'

    @chat?.emit 'ParticipantLeft', targetUser
    @statusBar.emit 'ParticipantLeft', targetUser
    @removeParticipantCursorWidget targetUser

    realtimeHelpers.ensureParticipantLeft @participants, targetUser, targetIndex


  # realtime related stuff


  broadcastMessage: (options = {}) ->

    message = _.assign {}, options, { origin: nick() }
    @broadcastMessages.push message


  activateRealtimeManager: (doc) ->

    @rtm.setRealtimeDoc doc
    @bindRealtimeErrorEvents()

    @setCollaborativeReferences()
    @addParticipant whoami()
    @setWatchMap()
    @registerCollaborationSessionId()

    if @amIHost
    then @activateRealtimeManagerForHost()
    else @activateRealtimeManagerForParticipant()

    @rtm.isReady = yes
    @emit 'RTMIsReady'


  setWatchMap: ->

    if @myWatchMap.values().length
      @emit 'WatchMapIsReady'
      return

    @listChatParticipants (accounts) =>
      accounts.forEach (account) =>
        { nickname } = account.profile
        @myWatchMap.set nickname, nickname

      @emit 'WatchMapIsReady'


  activateRealtimeManagerForHost: ->

    @getView().setClass 'host'
    @startHeartbeat()


  activateRealtimeManagerForParticipant: ->

    @startRealtimePolling()
    @resurrectParticipantSnapshot()

    if @permissions.get(nick()) is 'read'
      @makeReadOnly()


  setCollaborativeReferences: ->

    refs = realtimeHelpers.getReferences @rtm, @getSocialChannelId(), @getWorkspaceSnapshot()

    # for backwards compatibility.
    # TODO: keep this until CollaborationModel abstraction. ~Umut
    @participants      = refs.participants
    @changes           = refs.changes
    @settings          = refs.settings
    @permissions       = refs.permissions
    @broadcastMessages = refs.broadcastMessages
    @myWatchMap        = refs.watchMap
    @mySnapshot        = refs.snapshot

    @rtm.once 'RealtimeManagerDidDispose', =>
      @participants      = null
      @changes           = null
      @settings          = null
      @permissions       = null
      @broadcastMessages = null
      @myWatchMap        = null
      @mySnapshot        = null


  registerCollaborationSessionId: ->

    realtimeHelpers.registerCollaborationSessionId @rtm, @participants


  addParticipant: (account) ->

    {hash, nickname} = account.profile

    val = {nickname, hash}
    index = @participants.indexOf val, (a, b) -> a.nickname is b.nickname
    @participants.push val  if index is -1


  watchParticipant: (nickname) -> @myWatchMap.set nickname, nickname


  unwatchParticipant: (nickname) -> @myWatchMap.delete nickname


  ###*
   * Show confirm modal to sync layout to host's layout.
   *
   * @param {string} nickname
  ###
  showConfirmToSyncLayout: (nickname) ->

    isHostWatched = nickname is @collaborationHost
    return  if not isHostWatched or @amIHost

    modal = new KDModalView
      title         : "Host's layout is updated since you last watched his changes."
      cssClass      : "modal-with-text layout-changed-modal"
      content       : """
        If you click yes below we'll change your tabs layout to match host's layout.
        You won't lose your changes, if you have any.<br/><br/>
        Would you like to proceed?
      """
      overlay       : yes
      buttons       :
        "Yes"       :
          cssClass  : "solid medium red"
          callback  : =>
            modal.destroy()
            @applyHostLayoutToParticipant()
        "Cancel"    :
          cssClass  : "solid medium light-gray"
          callback  : => modal.destroy()


  applyHostLayoutToParticipant: ->

    @getHostSnapshot (snapshot) =>

      remainingPanes = @layoutManager.clearLayout yes # Recover opened panes
      @layoutManager.resurrectSnapshot snapshot, yes

      return  unless remainingPanes.length

      kd.utils.defer =>
        for pane in remainingPanes
          isAdded = no

          @forEachSubViewInIDEViews_ (p) ->
            isAdded = yes  if p.hash is pane.view.hash

          @activeTabView.addPane pane  unless isAdded

        @doResize()


  bindSocialChannelEvents: ->

    @socialChannel
      .on 'AddedToChannel', @bound 'participantAdded'
      .on 'MessageAdded',   @bound 'channelMessageAdded'
      .on 'ChannelDeleted', => @stopCollaborationSession()  # Don't pass any arguments.
      .on 'RemovedFromChannel', @bound 'participantRemoved'


  participantRemoved: (participant) ->

    socialHelpers.fetchAccount participant, (err, account) =>

      return throwError err  if err
      return  unless account

      { nickname } = account.profile

      @statusBar.removeParticipantAvatar nickname
      @unwatchParticipant nickname
      @removeParticipantPermissions nickname


  participantAdded: (participant) ->

    socialHelpers.fetchAccount participant, (err, account) =>

      return throwError err  if err
      return  unless account

      {nickname} = account.profile

      return  if nickname is nick()

      @statusBar.createParticipantAvatar nickname, no
      @watchParticipant nickname

      @setParticipantPermission nickname  if @amIHost


  channelMessageAdded: (message) ->

    return  unless message.payload

    { systemType } = message.payload
    systemType   or= message.payload['system-message']

    if systemType is 'start'
      if @stateMachine.state is 'NotStarted'
        @stateMachine.transition 'Loading'


  bindRealtimeEvents: ->

    @rtm.on 'CollaboratorJoined', (doc, participant) =>
      return  unless @stateMachine.state is 'Active'
      @handleParticipantAction 'join', participant

    @rtm.on 'CollaboratorLeft', (doc, participant) =>
      return  unless @stateMachine.state is 'Active'
      @handleParticipantAction 'left', participant

    @rtm.on 'ValuesAddedToList', (list, event) =>
      [value] = event.values

      switch list
        when @changes           then @handleChange value
        when @broadcastMessages then @handleBroadcastMessage value

    @rtm.on 'ValuesRemovedFromList', (list, event) =>
      @handleChange event.values[0]  if list is @changes

    @rtm.on 'MapValueChanged', (map, event) =>
      if map is @myWatchMap
        @handleWatchMapChange event

      else if map is @permissions
        @handlePermissionMapChange event


  bindRealtimeErrorEvents: ->

    @on 'ErrorRealtimeFileMissing',   throwError
    @on 'ErrorRealtimeServer',        throwError
    @on 'ErrorRealtimeUserForbidden', throwError
    @on 'ErrorRealtimeTokenExpired',  throwError
    @on 'ErrorGoogleDriveApiClient',  throwError
    @on 'ErrorHappened',              throwError


  removeParticipant: (nickname) ->

    refs = { @participants, @permissions }

    realtimeHelpers.removeFromManager @rtm, refs, nickname


  setRealtimeManager: (object) ->

    callback = =>
      object.rtm = @rtm
      object.emit 'RealtimeManagerSet'

    @whenRealtimeReady callback


  isRealtimeSessionActive: (id, callback) ->

    title = @getRealtimeFileName id

    @rtm or= new RealtimeManager
    @rtm.ready => realtimeHelpers.isSessionActive @rtm, title, callback


  getCollaborationData: (callback = kd.noop) ->

    host     = @collaborationHost
    settings = @getSettings()
    watchMap = @myWatchMap?.values()

    callback {
      @amIHost
      host
      settings
      watchMap
      @permissions
    }


  startHeartbeat: ->

    interval = 1000 * 15
    @sendPing() # send the first ping
    @pingInterval = kd.utils.repeat interval, @bound 'sendPing'
    @on 'RealtimeManagerWillDispose', => kd.utils.killRepeat @pingInterval


  sendPing: ->

    {channelId} = @workspaceData

    doXhrRequest
      endPoint : '/api/social/collaboration/ping'
      type     : 'POST'
      async    : yes
      data:
        fileId    : @rtmFileId
        channelId : channelId
    , (err, response) ->

      return  if not err

      if err.code is 400
        kd.utils.killRepeat @pingInterval # graceful stop
        throwError "bad request, err: %s", err.message
      else
        throwError "#{err}: %s", JSON.stringify response


  startRealtimePolling: ->

    interval = 15 * 1000
    @pollInterval = kd.utils.repeat interval, @bound 'pollRealtimeDocument'


  pollRealtimeDocument: ->

    channelId = @getSocialChannelId()

    unless @rtm and channelId
      kd.utils.killRepeat @pollInterval
      return

    @isRealtimeSessionActive channelId, (isActive) =>

      return  if isActive

      kd.utils.killRepeat @pollInterval
      @showSessionEndedModal()


  handleBroadcastMessage: (data) ->

    {origin, type} = data

    if origin is nick()
      switch type
        when 'ParticipantKicked'
          return @handleParticipantKicked data.target
        else return

    switch type

      when 'SessionEnded'

        return  unless origin is @collaborationHost

        @showSessionEndedModal()

      when 'ParticipantWantsToLeave'

        @handleParticipantKicked data.origin

      when 'ParticipantKicked'

        return  unless data.origin is @collaborationHost

        if data.target is nick()
          @once 'IDEDidQuit', @bound 'showKickedModal'
          @quit()
        else
          @handleParticipantKicked data.target

      when 'SetMachineUser'

        return  if data.participants.indexOf(nick()) is -1

        @handleSharedMachine()


  handlePermissionMapChange: (event) ->

    @chat.settingsPane.emit 'PermissionChanged', event

    {property, newValue} = event

    return  unless property is nick()

    if      newValue is 'edit' then @makeEditable()
    else if newValue is 'read' then @makeReadOnly()


  handleWatchMapChange: (event) ->

    {property, newValue, oldValue} = event

    if newValue is property
      @statusBar.emit 'ParticipantWatched', property

    else unless newValue
      @statusBar.emit 'ParticipantUnwatched', property


  broadcastMachineUserChange: (participants, state) ->

    type = "#{if state then 'Set' else 'Unset'}MachineUser"

    @broadcastMessage {type, participants}


  handleSharedMachine: ->

    @unmountMachine @mountedMachine
    @mountedMachine.getBaseKite().reconnect()
    @mountMachine @mountedMachine


  ###*
   * Resurrect snapshot for participant
  ###
  resurrectParticipantSnapshot: ->

    doResurrection_ = =>
      @removeInitialViews()

      if @amIWatchingChangeOwner @collaborationHost
        @getHostSnapshot (snapshot) =>
          @layoutManager.resurrectSnapshot snapshot, yes  if snapshot
      else
        @fetchSnapshot (snapshot) =>
          @layoutManager.resurrectSnapshot snapshot, yes  if snapshot


    @whenRealtimeReady =>

      if @myWatchMap.values()?.length
        doResurrection_()
      else
        @once 'WatchMapIsReady', doResurrection_


  showShareButton: ->

    @ready =>
      @statusBar.handleCollaborationLoading()
      @statusBar.share.show()


  collectButtonShownMetric: ->

    IDEMetrics.collect 'StatusBar.collaboration_button', 'shown'


  initCollaborationStateMachine: ->

    @stateMachine = new CollaborationStateMachine
      stateHandlers:
        Initial       : @bound 'onCollaborationInitial'
        Loading       : @bound 'onCollaborationLoading'
        Resuming      : @bound 'onCollaborationResuming'
        NotStarted    : @bound 'onCollaborationNotStarted'
        Preparing     : @bound 'onCollaborationPreparing'
        Prepared      : @bound 'onCollaborationPrepared'
        Creating      : @bound 'onCollaborationCreating'
        Active        : @bound 'onCollaborationActive'
        Ending        : @bound 'onCollaborationEnding'
        Created       : @bound 'onCollaborationCreated'
        ErrorCreating : @bound 'onCollaborationErrorCreating'


  onCollaborationInitial: ->

    if @mountedMachine.isMine()
      @showShareButton()
    else if @mountedMachine.isPermanent()
      @attendWorkspaceChannel()

    kd.utils.defer => @stateMachine.transition 'Loading'


  onCollaborationLoading: ->

    @statusBar.emit 'CollaborationLoading'

    @checkSessionActivity
      error      : => @stateMachine.transition 'ErrorLoading'
      active     : => @stateMachine.transition 'Resuming'
      notStarted : => @stateMachine.transition 'NotStarted'


  checkSessionActivity: (callbacks) ->

    { channelId } = @workspaceData
    machine       = @mountedMachine

    callMethod = (name, args...) -> callbacks[name] args...

    unless @workspaceData.channelId
      return callMethod 'notStarted'

    checkRealtimeSession = (channel) =>
      @isRealtimeSessionActive channel.id, (isActive, file) =>
        if isActive
          callMethod 'active', channel, file
          @updateSessionStartingProgress 40
        else
          callMethod 'notStarted'

    if not machine.isMine() and machine.isApproved() and not machine.isPermanent()
      @showSessionStartingModal()

    @fetchSocialChannel (err, channel) =>
      if err
        throwError err
        return callMethod 'notStarted'

      @updateSessionStartingProgress 20

      if channel.isParticipant then checkRealtimeSession channel
      else
        socialHelpers.acceptChannel channel, (err) =>
          if err
            @destroySessionStartingModal()
            return callMethod 'error', err

          @updateSessionStartingProgress 30
          checkRealtimeSession channel


  onCollaborationNotStarted: ->

    @statusBar.emit 'CollaborationEnded'
    @destroySessionStartingModal()

    owned = @mountedMachine.isMine()
    approved = @mountedMachine.isApproved()

    if (not owned) and approved
      @statusBar.share.hide()

    @collectButtonShownMetric()


  prepareChatSession: (callbacks) ->

    socialHelpers.initChannel (err, channel) =>
      return callbacks.error err  if err

      @setSocialChannel channel
      @createChatPaneView channel

      envHelpers.updateWorkspace @workspaceData, { channelId : channel.id }
        .then =>
          @workspaceData.channelId = channel.id
          @chat.ready => callbacks.success()
        .error (err) => callbacks.error err


  onCollaborationErrorCreating: ->

    showError 'Session could not start.'
    @stateMachine.transition 'Prepared'


  onCollaborationPreparing: ->

    @prepareChatSession
      success : => @stateMachine.transition 'Prepared'
      error   : => @stateMachine.transition 'ErrorPreparing'


  onCollaborationPrepared: ->

    @chat.emit 'CollaborationNotInitialized'


  startCollaborationSession: ->

    switch @stateMachine.state
      when 'Prepared' then @stateMachine.transition 'Creating'


  onCollaborationCreating: ->

    @createCollaborationSession
      success : (doc) =>
        @whenRealtimeReady => @stateMachine.transition 'Created'
        @activateRealtimeManager doc
      error: =>
        @stateMachine.transition 'ErrorCreating'


  onCollaborationCreated: ->

    @setInitialSettings()

    @chat.settingsPane.startSession.updateProgress 100

    kd.utils.wait 500, => @stateMachine.transition 'Active'


  createCollaborationSession: (callbacks) ->

    fileName = @getRealtimeFileName()

    realtimeHelpers.createCollaborationFile @rtm, fileName, (err, file) =>
      return callbacks.error err  if err

      realtimeHelpers.loadCollaborationFile @rtm, file.id, (err, doc) =>
        return callbacks.error err  if err

        @rtmFileId = file.id

        socialHelpers.sendActivationMessage @socialChannel, kd.noop

        @setMachineSharingStatus on, (err) =>
          return callbacks.error err  if err
          callbacks.success doc


  showSessionStartingModal: ->

    @sessionStartingModal = modal = new BaseModalView
      cssClass  : 'env-machine-state session-starting'
      width     : 440
      container : @getView()

    modal.addSubView modal.container = new kd.CustomHTMLView
      cssClass: 'content-container'

    modal.container.addSubView new kd.CustomHTMLView
      tagName  : 'p'
      partial  : "<span class='icon'></span> Joining to collaboration session..."
      cssClass : "state-label running"

    modal.container.addSubView modal.progressBar = new kd.ProgressBarView { initial: 10 }

    modal.show()


  updateSessionStartingProgress: (percentage) ->

    @sessionStartingModal?.progressBar.updateBar percentage


  destroySessionStartingModal: ->

    @sessionStartingModal?.destroy()
    @sessionStartingModal = null


  onCollaborationResuming: ->

    @showShareButton()

    successCb = (channel, doc) =>
      @whenRealtimeReady =>
        @setSocialChannel channel
        @createChatPaneView channel
        @chat.ready =>

          @stateMachine.transition 'Active'
          @updateSessionStartingProgress 90

          kd.utils.wait 2000, =>
            @updateSessionStartingProgress 100
            kd.utils.wait 500, @bound 'destroySessionStartingModal'

      @activateRealtimeManager doc

    errorCb = => # @stateMachine.transition 'ErrorResuming'
      @destroySessionStartingModal()

    @resumeCollaborationSession
      success : successCb
      error   : errorCb


  resumeCollaborationSession: (callbacks) ->

    title = @getRealtimeFileName()

    realtimeHelpers.fetchCollaborationFile @rtm, title, (err, file) =>
      return callbacks.error err  if err

      @updateSessionStartingProgress 50

      realtimeHelpers.loadCollaborationFile @rtm, file.id, (err, doc) =>
        return callbacks.error err  if err

        @updateSessionStartingProgress 70
        @rtmFileId = file.id
        callbacks.success @socialChannel, doc


  onCollaborationActive: ->

    @showChatPane()

    @transitionViewsToActive()
    @collectButtonShownMetric()
    @bindRealtimeEvents()

    # this method comes from VideoCollaborationController.
    # It's mixed into IDEAppController after CollaborationController.
    # This is probably an anti pattern, we need to look into this again. ~Umut
    @prepareVideoCollaboration()

    # attach RTM instance to already in-screen panes.
    @forEachSubViewInIDEViews_ @bound 'setRealtimeManager'

    # attach realtime manager when a new editor pane is opened.
    @on 'EditorPaneDidOpen', @bound 'setRealtimeManager'

    @on 'SetMachineUser',   @bound 'broadcastMachineUserChange'
    @on 'SnapshotUpdated',  @bound 'handleSnapshotUpdated'

    openFolders = @rtm.getFromModel('commonStore').get 'openFolders'

    if openFolders and not @amIHost
      for path in openFolders
        @finderPane.finderController.expandFolder path


  transitionViewsToActive: ->

    @listChatParticipants (accounts) =>
      @chat.settingsPane.createParticipantsList accounts

    {settingsPane} = @chat
    settingsPane.on 'ParticipantKicked', @bound 'handleParticipantKicked'

    @chat.emit 'CollaborationStarted'
    @statusBar.emit 'CollaborationStarted'

    { onboarding } = kd.singletons
    onboarding.run 'CollaborationStarted'
    @chat.on ['ViewBecameHidden', 'ViewBecameVisible'], ->
      onboarding.refresh 'CollaborationStarted'


  onCollaborationEnding: ->

    @chat.settingsPane.endSession.disable()

    @off 'SetMachineUser'

    if @amIHost
      @endCollaborationForHost =>
        @modal?.destroy()
        @handleCollaborationEndedForHost()
    else
      @endCollaborationForParticipant =>
        @silent = yes
        @modal?.destroy()
        @handleCollaborationEndedForParticipant()

    kd.singletons.onboarding.stop 'CollaborationStarted'


  endCollaborationForHost: (callback) ->

    @broadcastMessage { type: 'SessionEnded' }

    # Simply put, this timeout implementation was improved to prevent to clear race condition.
    # If you want to receive further information about this, you can visit the PR
    # https://github.com/koding/IDE/pull/499
    kd.utils.wait 2000, =>

      fileName = @getRealtimeFileName()

      realtimeHelpers.deleteCollaborationFile @rtm, fileName, (err) ->
        throwError err  if err

      @setMachineSharingStatus off, (err) ->
        throwError err  if err

      @clearParticipantsWorkspaces()

      socialHelpers.destroyChannel @socialChannel, (err) ->
        throwError err  if err

      envHelpers.detachSocialChannel @workspaceData, (err) ->
        throwError err  if err

      callback()


  clearParticipantsWorkspaces: ->

    { users } = @mountedMachine.data

    @listChatParticipants (accounts) =>
      accounts.forEach (account) =>
        { nickname } = account.profile

        machineUser  = _.find users, {
          username  : nickname
          owner     : no # Don't remove host's workspace
          approved  : yes
        }

        @removeWorkspaceSnapshot nickname  if machineUser


  handleCollaborationEndedForHost: ->

    return  unless @stateMachine.state in ['Ending']

    @rtm.once 'RealtimeManagerWillDispose', =>
      @chat.emit 'CollaborationEnded'
      @chat.destroy()
      @chat = null
      @statusBar.emit 'CollaborationEnded'

    @rtm.once 'RealtimeManagerDidDispose', =>
      kd.utils.defer @bound 'prepareCollaboration'

    @cleanupCollaboration()


  endCollaborationForParticipant: (callback) ->

    socialHelpers.leaveChannel @socialChannel, (err) ->
      throwError err  if err

    @removeWorkspaceSnapshot()
    @broadcastMessage type: 'ParticipantWantsToLeave'
    callback()


  handleCollaborationEndedForParticipant: ->

    # TODO: fix explicit state checks.
    return  unless @stateMachine.state in ['Active', 'Ending']

    { reactor } = kd.singletons

    if isTeamReactSide() # Remove the machine from sidebar.
      reactor.dispatch actionTypes.COLLABORATION_INVITATION_REJECTED, @mountedMachine._id
      reactor.dispatch actionTypes.WORKSPACE_DELETED, {
        workspaceId : @workspaceData._id
        machineId   : @mountedMachine._id
      }

    # TODO: fix implicit emit.
    @rtm.once 'RealtimeManagerWillDispose', =>
      @chat.emit 'CollaborationEnded'
      @chat.destroy()
      @chat = null
      @statusBar.emit 'CollaborationEnded'
      @removeParticipant nick()
      @removeMachineNode()  if not @mountedMachine.isPermanent() and not isTeamReactSide()

    @rtm.once 'RealtimeManagerDidDispose', =>
      method = switch
        when @mountedMachine.isPermanent() then 'prepareCollaboration'
        else 'quit'

      kd.utils.defer @bound method

    @cleanupCollaboration()


  showChat: ->

    # Show this message while "@stateMachine" is preparing when a session is over just now.
    # It will be ready in a few seconds.
    return showError 'Please wait a few seconds.'  unless @stateMachine

    switch @stateMachine.state
      when 'Active'     then @showChatPane()
      when 'Prepared'   then @chat.show()
      when 'NotStarted' then @stateMachine.transition 'Preparing'


  stopCollaborationSession: (callback = kd.noop) ->

    return callback()  unless @stateMachine

    @once 'CollaborationDidCleanup', callback

    switch @stateMachine.state
      when 'Active' then @stateMachine.transition 'Ending'


  showChatPane: ->

    @chat.showChatPane()
    @chat.start()


  createChatPaneView: (channel) ->

    unless @rtm
      @destroySessionStartingModal()
      return throwError 'RealtimeManager is not set'

    chatViewOptions = { @rtm, @isInSession, @mountedMachineUId }
    @chat           = new IDEChatView chatViewOptions, channel

    @getView().addSubView @chat


  prepareCollaboration: ->

    @rtm = new RealtimeManager

    @rtm.ready @bound 'initCollaborationStateMachine'


  getCollaborationHost: -> if @amIHost then nick() else @collaborationHost


  cleanupCollaboration: (options = {}) ->

    @unsetSocialChannel()

    # TODO: remove Active session from here,
    # we will deffo need a leaving state.
    return  unless @stateMachine.state in ['Ending', 'Active']

    @rtm.once 'RealtimeManagerWillDispose', =>
      kd.utils.killRepeat @pingInterval

    @rtm.once 'RealtimeManagerDidDispose', =>
      @rtm = null
      delete @stateMachine

    @rtm.dispose()
    @emit 'CollaborationDidCleanup'


  # environment related


  removeMachineNode: ->

    { activitySidebar } = kd.singletons.mainView

    machineBox = activitySidebar.getMachineBoxByMachineUId @mountedMachineUId

    if machineBox?.listController.getItemCount() > 1
      machineBox.removeWorkspace @workspaceData.getId()
    else
      activitySidebar.removeMachineNode @mountedMachine

    environmentDataProvider.removeCollaborationMachine @mountedMachine


  ensureMachineShare: (usernames, callback) ->

    {fetchMissingParticipants} = envHelpers

    fetchMissingParticipants @mountedMachine, usernames, (err, missing) =>
      return callback err  if err

      @setMachineUser missing, yes, callback


  setMachineSharingStatus: (status, callback) ->

    getUsernames = (accounts) ->

      accounts
        .map ({profile: {nickname}}) -> nickname
        .filter (nickname) -> nickname isnt nick()

    if @amIHost
      @listChatParticipants (accounts) =>
        usernames = getUsernames accounts
        @setMachineUser usernames, status, callback
    else
      @setMachineUser [nick()], status, callback


  setMachineUser: (usernames, share = yes, callback = kd.noop) ->

    # TODO: needs an investigation here.
    # if this usernames length check would be done
    # via helper method, the broadcastMessage
    # lines would be executed as well. attn to @szkl.
    return callback null  unless usernames.length

    {setMachineUser} = envHelpers

    setMachineUser @mountedMachine, @workspaceData, usernames, share, (err) =>
      return callback err  if err

      @emit 'SetMachineUser', usernames, share

      callback null


  # collab related modals (should be its own mixin)


  showEndCollaborationModal: (callback) ->

    modalOptions =
      title      : 'Are you sure?'
      content    : 'This will end your session and all participants will be removed from this session.'

    @showModal modalOptions, => @stopCollaborationSession callback


  showKickedModal: ->
    options        =
      title        : 'Your session has been closed'
      content      : "You have been removed from the session by @#{@collaborationHost}."
      blocking     : yes
      buttons      :
        ok         :
          title    : 'OK'
          style    : 'solid green medium'
          callback : =>
            @modal.destroy()

    @chat?.end()
    @showModal options


  showSessionEndedModal: (content) ->

    content ?= "This collaboration session has been terminated by the host @#{@collaborationHost}."

    options        =
      title        : 'Session ended'
      content      : content
      blocking     : yes
      buttons      :
        quit       :
          style    : 'solid light-gray medium'
          title    : 'LEAVE'
          callback : =>
            @modal.destroy()

    @chat?.end()
    @showModal options
    @handleCollaborationEndedForParticipant()


  handleParticipantLeaveAction: ->

    options   =
      title   : 'Are you sure?'
      content : "If you leave this session you won't be able to return back."

    @showModal options, => @stateMachine.transition 'Ending'


  throwError: throwError = (err, args...) ->

    format = JSON.stringify \
      switch typeof err
        when 'string' then err
        when 'object' then err.message or err.description
        else args.join ' '

    argIndex = 0
    console.error """
      IDE.CollaborationController:
      #{ format.replace /%s/g, -> JSON.stringify(args[argIndex++]) or '%s' }
    """


  onWorkspaceChannelChanged: ->

    return  unless @stateMachine

    {channelId} = @workspaceData

    if channelId and typeof channelId is 'string' and channelId.length
      return  unless @stateMachine.state is 'NotStarted'
      @stateMachine.transition 'Loading'

    else if @stateMachine.state is 'Active'
      @stateMachine.transition 'Ending'


  attendWorkspaceChannel: ->

    {notificationController} = kd.singletons

    notificationController.on 'AddedToChannel', (update) =>

      {channelId} = @workspaceData

      return  unless update.channel.id is channelId

      if update.isParticipant
      then @stateMachine.transition 'Loading'


  setInitialSessionSetting: (name, value) ->

    @initialSettings ?= {}
    @initialSettings[name] = value


  setInitialSettings: ->

    for own key, value of @initialSettings
      @settings.set key, value


  getSettings: ->

    rval = {}
    rval[key] = value  for [key, value] in @settings.items()
    return rval


  setParticipantPermission: (nickname, permission) ->

    return  if (not permission?) and @permissions.get nickname

    permission ?= if @settings.get 'readOnly' then 'read' else 'edit'
    @permissions.set nickname, permission


  removeParticipantPermissions: (nickname) ->

    return  unless @permissions.get nickname

    @permissions.delete nickname


  getMyWatchers: ->

    participants = []

    for user in @participants.asArray() when user.nickname isnt nick()

      map = realtimeHelpers.getParticipantWatchMap @rtm, user.nickname

      if map.keys().indexOf(nick()) > -1
        participants.push user.nickname

    return participants


  getHostSnapshot: (callback = kd.noop) ->

    @fetchSnapshot (snapshot) =>
      callback snapshot
    ,@getCollaborationHost()


  handleSnapshotUpdated: ->

    @mySnapshot.set 'layout', @getWorkspaceSnapshot()  if @rtm?.isReady


  getSnapshotFromDrive: (username = nick(), isFlat = no) ->

    layout = @mySnapshot?.get 'layout'

    if layout and isFlat
      return IDELayoutManager.convertSnapshotToFlatArray layout

    return layout


  saveOpenFoldersToDrive: ->

    openFolders = @finderPane.getOpenFolders()
    @rtm.getFromModel('commonStore').set 'openFolders', openFolders