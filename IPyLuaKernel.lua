--[[
  IPyLua
  
  Copyright (c) 2015 Francisco Zamora-Martinez. Simplified, less deps and making
  it work.

  Original name and copyright: lua_ipython_kernel 
  Copyright (c) 2013 Evan Wies.  All rights reserved.


  Released under the MIT License, see the LICENSE file.

  https://github.com/neomantra/lua_ipython_kernel

  usage: lua ipython_kernel.lua `connection_file`
--]]

if #arg ~= 1 then
  io.stderr:write(('usage: %s CONNECTION_FILENAME\n'):format(arg[0]))
  os.exit(-1)
end

local output_filters = {}
local help_functions = {}
do
  -- Setting IPyLua in the registry allow to extend this implementation with
  -- specifications due to other Lua modules. For instance, APRIL-ANN uses this
  -- variable to configure how to encode images, plots, matrices, ... As well
  -- as introducing a sort of inline documentation.
  --
  -- To extend IPyLua output you need to stack into registry
  -- IPyLua.output_filters new functions which receive an object and return a
  -- data table as expected by IPython, that is, a data table with pairs of {
  -- [mime_type] = representation, ... } followed by the metadata table
  -- (optional).
  local reg = debug.getregistry()
  reg.IPyLua = {
    output_filters = output_filters,
    help_functions = help_functions,
  }
end

local json = require "IPyLua.dkjson"
local zmq  = require 'lzmq'
local zmq_poller = require 'lzmq.poller'
local z_NOBLOCK, z_POLLIN = zmq.NOBLOCK, zmq.POLL_IN
local z_RCVMORE, z_SNDMORE = zmq.RCVMORE, zmq.SNDMORE
local zassert = zmq.assert

local uuid = require 'IPyLua.uuid' -- TODO: randomseed or luasocket or something else

local HMAC = ''
local MSG_DELIM = '<IDS|MSG>'
local username = os.getenv('USER') or "unknown"

-- our kernel's state
local kernel = { execution_count=0 }

-- sockets description
local kernel_sockets

local function next_execution_count()
  kernel.execution_count = kernel.execution_count + 1
  return kernel.execution_count
end

local function current_execution_count()
  return kernel.execution_count
end

-- load connection object info from JSON file
do
  local connection_file = assert( io.open(arg[1]) )
  local connection_json = assert( connection_file:read('*a') )
  kernel.connection_obj = assert( json.decode(connection_json) )
  connection_file:close()
end

-------------------------------------------------------------------------------
-- IPython Message ("ipmsg") functions

local function ipmsg_to_table(parts)
  local msg = { ids = {}, blobs = {} }

  local i = 1
  while i <= #parts and parts[i] ~= MSG_DELIM do
    msg.ids[#msg.ids + 1] = parts[i]
    i = i + 1
  end
  i = i + 1
  msg.hmac          = parts[i] ; i = i + 1 
  msg.header        = parts[i] ; i = i + 1 
  msg.parent_header = parts[i] ; i = i + 1 
  msg.metadata      = parts[i] ; i = i + 1 
  msg.content       = parts[i] ; i = i + 1 

  while i <= #parts do
    msg.blobs[#msg.blobs + 1] = parts[i]
    i = i + 1
  end
  
  return msg
end

local session_id = uuid.new()
local function ipmsg_header(msg_type)
  return {
    msg_id = uuid.new(),   -- TODO: randomness warning: uuid.new()
    msg_type = msg_type,
    username = username,
    session = session_id,
    version = '5.0',
    date = os.date("%Y-%m-%dT%H:%M:%S"),
  }
end


local function ipmsg_send(sock, params)
  local parent  = params.parent or {header={}}
  local ids     = parent.ids or {}
  local hdr     = json.encode(assert( params.header ))
  local meta    = json.encode(params.meta or {})
  local content = json.encode(params.content or {})
  local blobs   = params.blob
  -- print("IPMSG_SEND")
  -- print("\tHEADER", hdr)
  -- print("\tCONTENT", content)
  --
  local hmac  = HMAC
  local p_hdr = json.encode(parent.header)
  --
  if type(ids) == 'table' then
    for _, v in ipairs(ids) do
      sock:send(v, z_SNDMORE)
    end
  else
    sock:send(ids, z_SNDMORE)
  end
  sock:send(MSG_DELIM, z_SNDMORE)
  sock:send(hmac,  z_SNDMORE)
  sock:send(hdr,   z_SNDMORE)
  sock:send(p_hdr, z_SNDMORE)
  sock:send(meta,  z_SNDMORE)
  if blobs then
    sock:send(content, z_SNDMORE)
    if type(blobs) == 'table' then
      for i, v in ipairs(blobs) do
        if i == #blobs then
          sock:send(v)
        else
          sock:send(v, z_SNDMORE)
        end
      end
    else
      sock:send(blobs)
    end
  else
    sock:send(content)
  end
end



-------------------------------------------------------------------------------

local function help(str)
  if #str == 0 then str = nil end
  for i=#help_functions,1,-1 do
    local data,metadata = help_functions[i](str)
    if data then pyout(data,metadata) return true end
  end
  return nil,("Documentation not found%s"):format(str and " for object: "..str or "")
end

-- environment where all code is executed
local new_environment
local env_session
local env_parent
local env_source
do
  local pyout = function(data, metadata)
    local header = ipmsg_header( 'pyout' )
    local content = {
      data = assert( data ),
      execution_count = current_execution_count(),
      metadata = metadata or {},
    }
    ipmsg_send(kernel.iopub_sock, {
                 session = env_session,
                 parent = env_parent,
                 header = header,
                 content = content
    })
  end
  
  local stringfy = function(v)
    local v_str = tostring(v)
    return not v_str:find("\n") and v_str or type(v)
  end
  
  local MAX = 10
  table.insert(output_filters,
               function(obj, MAX)
                 local tt,footer = type(obj)
                 if tt == "table" then
                   local tbl = {}
                   do
                     local max = false
                     for k,v in ipairs(obj) do
                       table.insert(tbl, ("\t[%d] = %s,"):format(k,stringfy(v)))
                       if k >= MAX then max=true break end
                     end
                     if max then table.insert(tbl, "\t...") end
                   end
                   do
                     local max = false
                     local keys = {}
                     for k,v in pairs(obj) do
                       if type(k) ~= "number" then keys[#keys+1] = k end
                     end
                     table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)
                     for i,k in ipairs(keys) do
                       table.insert(tbl, ("\t[%q] = %s,"):format(stringfy(k),
                                                                 stringfy(obj[k])))
                       if i >= MAX then max=true break end
                     end
                     if max then table.insert(tbl, "\t...") end
                     footer = ("# %s with %d array part, %d hash part"):format(tostring(obj), #obj, #keys)
                   end
                   table.insert(tbl, footer)
                   return { ["text/plain"]=table.concat(tbl, "\n").."\n" }
                 else
                   return { ["text/plain"]=tostring(obj).."\n" }
                 end
  end)
  
  local function print_obj(obj, MAX)
    for i=#output_filters,1,-1 do
      local data,metadata = output_filters[i](obj, MAX)
      if data then pyout(data,metadata) return true end
    end
    return false
  end
  
  function new_environment()
    local env_G,env = {},{}
    for k,v in pairs(_G) do env_G[k] = v end
    env_G.args = nil
    env_G._G   = env_G
    env_G._ENV = env
    local env_G = setmetatable(env_G, { __index = _G })
    local env = setmetatable(env, { __index = env_G })
    
    env_G.print = function(...)
      if select('#',...) == 1 then
        if print_obj(..., MAX) then return end
      end
      local args = table.pack(...)
      for i=1,#args do args[i]=stringfy(args[i]) end
      local str = table.concat(args,"\t")
      pyout({ ["text/plain"] = str.."\n" })
    end

    env_G.io.write = function(...)
      local args = table.pack(...)
      for i=1,#args do args[i]=stringfy(args[i]) end
      local str = table.concat(table.pack(...))
      pyout({ ["text/plain"] = str.."\n" })
    end
    
    env_G.vars = function()
      print_obj(env, math.huge)
    end

    env_G.help = function(str) help(str) end
    
    env_G["%quickref"] = function()
      local tbl = {
        "?            -> Introduction and overview.",
        "%quickref    -> This guide.",
        "help(object) -> Help about a given object.",
        "object?      -> Help about a given object.",
        "print(...)   -> Print a list of objects using \\t as separator.",
        "                If only one object is given, it would be printed",
        "                in a fancy way when possible. If more than one",
        "                object is given, the fancy version will be used",
        "                only if it fits in one line, otherwise the type",
        "                of the object will be shown.",
        "vars()       -> Shows all global variables declared by the user.",
      }
      print_obj(table.concat(tbl,"\n"))
    end

    env_G["%guiref"] = function()
      local tbl = {
        "GUI reference not written.",
      }
    end
    
    return env,env_G
  end
end
local env,env_G = new_environment()

local function add_return(code)
  return code
end

-------------------------------------------------------------------------------

local function send_execute_reply(sock, parent, count, status, err)
  local session = parent.header.session
  local header = ipmsg_header( 'execute_reply' )
  local content = {
    status = status or 'ok',
    execution_count = count,
    payload = {},
    user_expresions = {},
  }
  if status=="error" then
    content.ename = err
    content.evalue = ''
    content.traceback = {err}
  end
  ipmsg_send(sock, {
               session = session,
               parent = parent,
               header = header,
               content = content,
  })
end

local function send_busy_message(sock, parent)
  local session = parent.header.session
  local header  = ipmsg_header( 'status' )
  local content = { execution_state='busy' }
  ipmsg_send(sock, {
               session = session,
               parent = parent,
               header = header,
               content = content,
  })
end

local function send_idle_message(sock, parent)
  local session = parent.header.session
  local header  = ipmsg_header( 'status' )
  local content = { execution_state='idle' }
  ipmsg_send(sock, {
               session = session,
               parent = parent,
               header = header,
               content = content,
  })
end

local function execute_code(parent)
  local session = parent.header.session
  local code = parent.content.code
  if not code or #code==0 then return end
  env_parent  = parent
  env_session = session
  env_source  = code
  if code:find("%?+\n?$") or code:find("^%?+") then
    return help(code:match("^%?*([^?\n]*)%?*\n?$"))
  else
    if code:sub(1,1) == "%" then
      code = ("_G[%q]()"):format(code:gsub("\n",""))
    end
    if code:sub(1,1) == "=" then code = "return " .. code:sub(2) end
    local ok,err = true,nil
    local f,msg = load(code, nil, nil, env)
    if f then
      local out = table.pack(xpcall(f, debug.traceback))
      if not out[1] then
        ok,err = nil,out[2]
      elseif #out > 1 then
        env.print(table.unpack(out, 2))
      end
    else
      ok,err = nil,msg
    end
    return ok,err
  end
end

local function send_pyin_message(sock, parent, count)
  local session = parent.header.session
  local header  = ipmsg_header( 'pyin' )
  local content = { code=parent.content.code,
                    execution_count = count, }
  ipmsg_send(sock, {
               session = session,
               parent = parent,
               header = header,
               content = content,
  }) 
end

local function send_pyerr_message(sock, parent, count, err)
  local session = parent.header.session
  local header  = ipmsg_header( 'pyerr' )
  local content = { ename = err, evalue = '', traceback = {err},
                    execution_count = count, }
  ipmsg_send(sock, {
               session = session,
               parent = parent,
               header = header,
               content = content,
  }) 
end

-- implemented routes
local shell_routes = {
  kernel_info_request = function(sock, parent)
    local session = parent.header.session
    local header = ipmsg_header( 'kernel_info_reply' )
    local major,minor = _VERSION:match("(%d+)%.(%d+)")
    local content = {
      protocol_version = {4, 0},
      language_version = {tonumber(major), tonumber(minor)},
      language = 'IPyLua',
    }
    ipmsg_send(sock, {
                 session=session,
                 parent=parent,
                 header=header,
                 content=content,
    })
  end,

  execute_request = function(sock, parent)
    local count = next_execution_count()
    parent.content = json.decode(parent.content)
    --
    send_busy_message(kernel.iopub_sock, parent)
    
    local ok,err = execute_code(parent)
    send_pyin_message(kernel.iopub_sock, parent, count)
    if ok then
      send_execute_reply(sock, parent, count)
    else
      err = err or "Unknown error"
      send_pyerr_message(kernel.iopub_sock, parent, count, err)
      send_execute_reply(sock, parent, count, "error", err)
    end
    send_idle_message(kernel.iopub_sock, parent)
  end,

  shutdown_request = function(sock, parent)
    parent.content = json.decode(parent.content)
    --
    send_busy_message(sock, parent)
    local session = parent.header.session
    local header  = ipmsg_header( 'shutdown_reply' )
    local content = parent.content
    ipmsg_send(sock, {
                 session=session,
                 parent=parent,
                 header=header,
                 content=content,
    })
    send_idle_message(kernel.iopub_sock, parent)
    for _, v in ipairs(kernel_sockets) do
      kernel[v.name]:close()
    end
    os.exit()
  end,
}

do
  local function dummy_function() end
  setmetatable(shell_routes, {
                 __index = function(self, key)
                   return rawget(self,key) or dummy_function
                 end,
  })
end

-------------------------------------------------------------------------------
-- ZMQ Read Handlers

local function on_hb_read( sock )
  -- read the data and send a pong
  local data = zassert( sock:recv(zmq.NOBLOCK) )
  -- TODO: handle 'timeout' error
  sock:send('pong')
end

local function on_control_read( sock )
  local data = zassert( sock:recv(zmq.NOBLOCK) )
  -- TODO: handle 'timeout' error
end

local function on_stdin_read( sock )
  local data = zassert( sock:recv(zmq.NOBLOCK) )
  -- TODO: handle 'timeout' error
end

local function on_shell_read( sock )
  -- TODO: error handling
  local ipmsg = zassert( sock:recv_all() )  
  local msg = ipmsg_to_table(ipmsg)
  -- for k, v in pairs(msg) do print(k,v) end
  msg.header = json.decode(msg.header)
  -- print("REQUEST FOR KEY", msg.header.msg_type)
  shell_routes[msg.header.msg_type](sock, msg)
end

-------------------------------------------------------------------------------
-- SETUP

kernel_sockets = {
  { name = 'heartbeat_sock', sock_type = zmq.REP,    port = 'hb',      handler = on_hb_read },
  { name = 'control_sock',   sock_type = zmq.ROUTER, port = 'control', handler = on_control_read },
  { name = 'stdin_sock',     sock_type = zmq.ROUTER, port = 'stdin',   handler = on_stdin_read },
  { name = 'shell_sock',     sock_type = zmq.ROUTER, port = 'shell',   handler = on_shell_read },
  { name = 'iopub_sock',     sock_type = zmq.PUB,    port = 'iopub',   handler = on_iopub_read },
}

local z_ctx = zmq.context()
local z_poller = zmq_poller(#kernel_sockets)
for _, v in ipairs(kernel_sockets) do
  -- TODO: error handling in here
  local sock = zassert( z_ctx:socket(v.sock_type) )

  local conn_obj = kernel.connection_obj
  local addr = string.format('%s://%s:%s',
                             conn_obj.transport,
                             conn_obj.ip,
                             conn_obj[v.port..'_port'])

  zassert( sock:bind(addr) )
  
  if v.name ~= 'iopub_sock' then -- avoid polling from iopub
    z_poller:add(sock, zmq.POLLIN, v.handler)
  end

  kernel[v.name] = sock
end

-------------------------------------------------------------------------------
-- POLL then SHUTDOWN

--print("Starting poll")
z_poller:start()

for _, v in ipairs(kernel_sockets) do
  kernel[v.name]:close()
end
z_ctx:term()
