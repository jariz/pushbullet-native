os = require 'os'
fs = require 'fs'
npath = require 'path'
readline = require 'readline'

PushBullet = require 'pushbullet'
notifier = require 'node-notifier'
clor = require 'clor'
persist = require 'node-persist'
forever = require 'forever'
meow = require 'meow'

module.exports = class PushbulletNative
  pusher: undefined
  rl: undefined
  isMaster: process.env.PBN_SLAVE isnt "true"
  cli: undefined

  constructor: ->
    @cmd()
    mode = @cli.input[0]

    @rl = readline.createInterface
      input: process.stdin
      output: process.stdout

    persist.initSync()

    switch mode
      when 'start', undefined
        if @isMaster then @welcome()
        @auth (token) =>
          @daemonize =>
            @listen token

      when 'remove-token'
        persist.removeItemSync('token')
        clor.green("✓ Done").log()
        process.exit()

      when "sound"
        if parseInt @cli.input[1]
          clor.green("✓ Sound enabled").log()
          persist.setItemSync "sound", true
        else
          clor.green("✓ Sound disabled").log()
          persist.removeItemSync "sound"
        process.exit()

      when "subtitle"
        if os.type() is not "Darwin" then clor.red("⨉ This setting only works on OSX").log()
        if parseInt @cli.input[1]
          clor.green("✓ Subtitle enabled").log()
          persist.setItemSync "sound", true
        else
          clor.green("✓ Subtitle disabled").log()
          persist.removeItemSync "sound"
        process.exit()

      when "timeout"
        if os.type() is not "Linux" then clor.red("⨉ This setting only works on linux").log()
        if parseInt @cli.input[1]
          console.log clor.green("✓ Timeout set to ")+clor.yellow(parseInt @cli.input[1])
          persist.setItemSync "timeout", parseInt @cli.input[1]
        else
          clor.green("✓ Timeout disabled").log()
          persist.removeItemSync "timeout"
        process.exit()

      else
        @cli.showHelp()
        process.exit()

  cmd: ->
    #require('sudo-block')()

    appname = clor.blue('pushbullet-native').toString()
    @cli = meow
      help: [
        'Usage',
        '  ' + appname
        '     Start pushbullet-native'
        '  ' + appname + ' ' + clor.yellow('stop'),
        '     Stop pushbullet-native',
        '  ' + appname + ' ' + clor.yellow('remove-token'),
        '     Remove token (if it exists).',
        '     Run the program again normally afterwards to enter new token.',
        '  ' + appname + ' ' + clor.yellow('sound ') + clor.green('0/1'),
        '     Enable disable notification sounds (multiplatform). Default: 1',
        '  ' + appname + ' ' + clor.yellow('subtitle ') + clor.green('0/1'),
        '     Use app name as notification subtitle. (mac only). Default: 0',
        '  ' + appname + ' ' + clor.yellow('timeout ') + clor.green('10000'),
        '     Amount of time to show. (linux only). 0 to disable. Default: 0',
        '',
        'Flags',
        '  '+clor.yellow('--foreground'),
        '     Force pushbullet-native to run in foreground',
      ]

    if 'help' in @cli.flags or @cli.input[0] is 'help'
      @cli.showHelp()
      process.exit()

  daemonize: (cb) ->
    #todo on windows: create service with node-windows

    if @cli.flags.foreground
      @isMaster = false
      console.log clor.yellow.bold("WARNING") + clor.yellow(": pushbullet-native is running in the foreground.\r\nQuit this program and your notifications will cease.")

    if @isMaster
      forever.startDaemon "index.js",
        uid: 'pbn'
        env:
          PBN_SLAVE: 'true'

    #todo check if uid pbn is already running

    if not @isMaster then cb()
    else
      #explain to user that pbn is gonna run in the background now
      clor.green('PushBullet Native is now running in the background.').log()
      process.exit()

  # returns the path to the written image for use in notification middleware
  writeIcon: (data) ->
    buffer = new Buffer data, 'base64'
    path = npath.join os.tmpdir(), 'psn-' + Math.round(Math.random() * 100000000) + '.jpg'
    fs.writeFileSync path, buffer
    console.log 'wrote image to ' + path
    path

  getNotificationIdentifier: (push) ->
    (push.package_name + push.source_user_iden + push.notification_id)#.replace /\.\-/i

  notify: (push) ->
    notification =
      title: if os.type() == "Darwin" and not persist.getItemSync "subtitle" then push.title else push.application_name + " - " + push.title
      'message': push.body
      icon: @writeIcon push.icon
      wait: false

    if persist.getItem "sound" then notification.sound = true;

    notify = ->
      console.log notification
      notifier.notify notification, (err, response) ->
        console.log err, response

    switch os.type()
      when "Darwin"
        notification.subtitle = push.application_name
        if persist.getItem "sound" then notification.sound = 'Ping'
        notification.group = @getNotificationIdentifier push

        console.log notification
        center = new notifier.NotificationCenter
          customPath: npath.join __dirname, 'bin/Pushbullet.app/Contents/MacOS/Pushbullet'
        notify = ->
          center.notify notification, (err, response) ->
            console.log err, response
      when "Linux"
        console.log 'linux. timeout =', persist.getItemSync "timeout"
        if persist.getItemSync "timeout" then notification['expire-time'] = persist.getItemSync "timeout"

    # Don't let your dreams be dreams.
    # DO IT!
    notify()

  listen: (token) ->
    @pusher = new PushBullet token
    stream = @pusher.stream()
    stream.connect()

    stream.on 'push', (push) =>
      console.log push.type
      switch push.type
        when "mirror"
          @notify push
        when "dismissal"
          switch os.type()
            when "Darwin"

              #BROKEN: mikaelbr/node-notifier#60

              console.log 'remove', @getNotificationIdentifier push
              new notifier.NotificationCenter({}).notify
                remove: @getNotificationIdentifier push
              , (err, response) ->
                  debugger
                  console.log err, response

    stream.on 'connect', ->
      clor.green('stream connected').log()

    reconnect = (error) ->
      # if error then clor.red(error.message).log()
      clor.blue('stream closed. reconnect in 2 secs').log()
      setTimeout ->
        clor.blue('retrying...')
        stream.connect()
      , 2000

    # stream.on 'error', reconnect
    stream.on 'close', reconnect

  welcome: ->
    emoji = if os.type() == 'Darwin' then ' 🔄 ' else ''
    console.log emoji.substring(1) + clor.bold("PushBullet Native") + emoji
    clor.italic("Build by Jari Zwarts").log()
    console.log()

  auth: (cb) ->
    if not persist.getItemSync "token"
      clor.bold.red("No PushBullet account found!").log()
      clor.blue("Please enter a access token. (see https://www.pushbullet.com/#settings/account )").log()
      @rl.question "Access token: ", (answer) =>
        #todo test token?
        clor.green("✓ Alright\r\n").log()
        persist.setItemSync "token", answer
        cb(answer)
    else cb persist.getItemSync "token"
