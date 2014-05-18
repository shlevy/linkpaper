fs = require 'fs'
path = require 'path'
http = require 'http'
child_process = require 'child_process'
url = require 'url'
googleapis = require 'googleapis'

CLIENT_ID = "676208100409-dekk51tr5u8ba9325l2ji9o98qgi5icd.apps.googleusercontent.com"
CLIENT_SECRET = "5CRgxDSrw3vSYn3DFzOPnBf3"

if process.argv.length != 4
  console.error "usage: #{process.argv[1]} local-path drive-path"
  process.exit 1

file = path.basename process.argv[2]

listener = null
try
  listener = fs.watch path.dirname process.argv[2]
catch error
  if error.errno is "ENOENT"
    console.error "Parent directory of #{process.argv[2]} does not exist"
    process.exit 2
  else
    throw error

needsUpdate = false
ready = false
authClient = null
client = null

update = do ->
  id = null
  -> fs.readFile process.argv[2], encoding: 'utf8', (err, data) ->
    if err?
      if err.errno isnt 'ENOENT'
        console.error "Error reading #{process.argv[2]}", err
        process.exit 5
      ready = true
      maybeUpdate()
    else if id?
      client.drive.files.update(fileId: id)
        .withMedia('text/plain', data)
        .withAuthClient(authClient)
        .execute (err, result) ->
          if err?
            console.error "Error uploading to #{process.argv[3]}", err
            process.exit 6
          ready = true
          maybeUpdate()
    else
      client.drive.files.list(
        q: "title = \"#{process.argv[3]}\" and trashed = false"
        fields: "items/id"
      ).withAuthClient(authClient)
        .execute (err, result) ->
          if err?
            console.error "Error searching for #{process.argv[3]}", err
            process.exit 7
          else if result.items.length is 0
            client.drive.files.insert({ convert: true }, title: process.argv[3])
              .withMedia('text/plain', data)
              .withAuthClient(authClient)
              .execute (err, result) ->
                if err?
                  console.error "Error uploading to #{process.argv[3]}", err
                  process.exit 8
                ready = true
                id = result.id
                maybeUpdate()
          else if result.items.length is 1
            id = result.items[0].id
            update()
          else
            console.error "Multiple files named #{process.argv[3]} in drive"
            process.exit 9

maybeUpdate = ->
  if ready and needsUpdate
    ready = false
    needsUpdate = false
    update()

listener.on 'change', (event, filename) ->
  if filename is file
    needsUpdate = true
    maybeUpdate()

server = http.createServer()
port = 1025

authenticate = ->
  authClient = new googleapis.auth.OAuth2(
    CLIENT_ID,
    CLIENT_SECRET,
    "http://localhost:#{port}"
  )
  u = authClient.generateAuthUrl(
    scope: "https://www.googleapis.com/auth/drive"
  )
  child = child_process.spawn "open", [ u ], stdio: 'ignore'
  child.once 'error', (error) ->
    if error.errno is "ENOENT"
      child = child_process.spawn "open", [ u ], stdio: 'ignore'
      child.once 'error', (error) ->
        if error.errno is "ENOENT"
          console.error(
            "Please go to #{u} and authorize linkpaper to access your drive"
          )
        else
          child.emit 'error', error
    else
      child.emit 'error', error

  server.once 'request', (request, response) ->
    server.close()
    authClient.getToken url.parse(request.url, true).query.code, (err, creds) ->
      if err
        console.error "Error trying to retrieve access token", err
        process.exit 3
      else
        authClient.credentials = creds
        ready = client?
        maybeUpdate()
    response.statusCode = 200
    response.setHeader "Content-Type", "text/html"
    response.end """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Authenticated successfully, please close this window</title>
      <script>window.open('','_self').close()</script>
    </head>
    <body>
      Authenticated successfully, please close this window
    </body>
    </html>
    """

findPort = ->
  server.listen port
  server.once 'error', (error) ->
    if error.errno is "EADDRINUSE"
      port += 1
      server = http.createServer()
      findPort()
    else
      server.emit 'error', error

  server.once 'listening', authenticate

googleapis.discover('drive', 'v2')
  .withOpts(cache: path: "#{process.env['HOME']}/.linkpaper")
  .execute (err, c) ->
    if err
      console.error "Error while loading the google drive API", err
      process.exit 4
    client = c
    ready = authClient?
    maybeUpdate()

findPort()
