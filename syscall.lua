
-- Linux syscall ABI ffi interface

local function syscall()

local S = {} -- exported functions

local ffi = require "ffi"
local bit = require "bit"

require "include/headers"

local oldsm = setmetatable
local function setmetatable(t, mt)
  assert(mt, "BUG: nil metatable")
  return oldsm(t, mt)
end

S.C = setmetatable({}, {__index = ffi.C})
local C = S.C

local CC = {} -- functions that might not be in C, may use syscalls

local constants = require "include/constants"

for k, v in pairs(constants) do S[k] = v end -- TODO put in k table (need bits_to_speed and speed_to_bits should be metatables)

-- functions we need for metatypes TODO remove once moved to constants

local function split(delimiter, text)
  if delimiter == "" then return {text} end
  if #text == 0 then return {} end
  local list = {}
  local pos = 1
  while true do
    local first, last = text:find(delimiter, pos)
    if first then
      list[#list + 1] = text:sub(pos, first - 1)
      pos = last + 1
    else
      list[#list + 1] = text:sub(pos)
      break
    end
  end
  return list
end

local function trim(s) -- TODO should replace underscore with space
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local t, pt, s, ctypes -- t used below.

-- TODO all metatypes too
function S.mksigset(str)
  if not str then return t.sigset() end
  if type(str) ~= 'string' then return str end
  local f = t.sigset()
  local a = split(",", str)
  for i, v in ipairs(a) do
    local st = trim(v)
    local sig = S.SIG[st]
    if not sig then error("invalid signal: " .. v) end -- don't use this format if you don't want exceptions, better than silent ignore
    local d = bit.rshift(sig - 1, 5) -- always 32 bits
    f.val[d] = bit.bor(f.val[d], bit.lshift(1, (sig - 1) % 32))
  end
  return f
end

-- TODO remove when replaced with metatables
local stringflags, mksigset = S.stringflags, S.mksigset

local types = require("include/types")(S)

S.t, S.pt, S.s, S.ctypes = types.t, types.pt, types.s, types.ctypes -- types, pointer types and sizes tables and ctypes map
t, pt, s, ctypes = S.t, S.pt, S.s, S.ctypes

local mt = {} -- metatables
local meth = {}

-- convenience so user need not require ffi
S.string = ffi.string
S.sizeof = ffi.sizeof
S.cast = ffi.cast
S.copy = ffi.copy
S.fill = ffi.fill
S.istype = ffi.istype

function S.nogc(d) return ffi.gc(d, nil) end

-- reverse lookup tables from constants
local errsyms = {} -- reverse lookup
for k, v in pairs(S.E) do
  errsyms[v] = k
end

-- use 64 bit fileops on 32 bit always
if ffi.abi("32bit") then
  C.truncate = ffi.C.truncate64
  C.ftruncate = ffi.C.ftruncate64
end

-- makes code tidier
local function istype(tp, x)
  if ffi.istype(tp, x) then return x else return false end
end

local function getfd(fd)
  if type(fd) == "number" or ffi.istype(t.int, fd) then return fd end
  return fd:getfd()
end

local function getfd_at(fd)
  if not fd then return S.AT_FDCWD.FDCWD end
  if type(fd) == "string" then return S.AT_FDCWD[fd] end
  return getfd(fd)
end

-- metatables for Lua types not ffi types - convert to ffi types

-- convert to ffi. note missing some macros eg WCOREDUMP()
mt.wait = {
  __index = function(w, k)
    local WTERMSIG = bit.band(w.status, 0x7f)
    local EXITSTATUS = bit.rshift(bit.band(w.status, 0xff00), 8)
    local WIFEXITED = (WTERMSIG == 0)
    local tab = {
      WIFEXITED = WIFEXITED,
      WIFSTOPPED = bit.band(w.status, 0xff) == 0x7f,
      WIFSIGNALED = not WIFEXITED and bit.band(w.status, 0x7f) ~= 0x7f -- I think this is right????? TODO recheck, cleanup
    }
    if tab.WIFEXITED then tab.EXITSTATUS = EXITSTATUS end
    if tab.WIFSTOPPED then tab.WSTOPSIG = EXITSTATUS end
    if tab.WIFSIGNALED then tab.WTERMSIG = WTERMSIG end
    if tab[k] then return tab[k] end
    local uc = 'W' .. k:upper()
    if tab[uc] then return tab[uc] end
  end
}

-- TODO convert to ffi metatype
mt.timex = {
  __index = function(timex, k)
    if S.TIME[k] then return timex.state == S.TIME[k] end
    return nil
  end
}

-- TODO convert to ffi metatype
mt.epoll = {
  __index = function(tab, k)
    if S.EPOLL[k] then return bit.band(tab.events, S.EPOLL[k]) ~= 0 end
  end
}

-- TODO convert to ffi metatype
mt.inotify = {
  __index = function(tab, k)
    if S.IN[k] then return bit.band(tab.mask, S.IN[k]) ~= 0 end
  end
}

-- TODO convert to ffi metatype
mt.dents = {
  __index = function(tab, k)
    if S.DT[k] then return tab.type == S.DT[k] end
    return nil
  end
}

-- misc

-- typed values for pointer comparison
local zeropointer = pt.void(0)
local errpointer = pt.void(-1)

local function div(a, b) return math.floor(tonumber(a) / tonumber(b)) end -- would be nicer if replaced with shifts, as only powers of 2

-- return helpers.

-- straight passthrough, only needed for real 64 bit quantities. Used eg for seek (file might have giant holes!)
local function ret64(ret)
  if ret == t.uint64(-1) then return nil, t.error() end
  return ret
end

local function retnum(ret) -- return Lua number where double precision ok, eg file ops etc
  ret = tonumber(ret)
  if ret == -1 then return nil, t.error() end
  return ret
end

local function retfd(ret)
  if ret == -1 then return nil, t.error() end
  return t.fd(ret)
end

-- used for no return value, return true for use of assert
local function retbool(ret)
  if ret == -1 then return nil, t.error() end
  return true
end

-- used for pointer returns, -1 is failure
local function retptr(ret)
  if ret == errpointer then return nil, t.error() end
  return ret
end

local function retwait(ret, status) -- TODO metatype
  if ret == -1 then return nil, t.error() end
  return setmetatable({pid = ret, status = status}, mt.wait)
end

local function retnume(f, ...) -- for cases where need to explicitly set and check errno, ie signed int return
  ffi.errno(0)
  local ret = f(...)
  local errno = ffi.errno()
  if errno ~= 0 then return nil, t.error() end
  return ret
end

-- TODO add tests
mt.sockaddr_un = {
  __index = function(un, k)
    local sa = un.addr
    if k == 'family' then return tonumber(sa.sun_family) end
    local namelen = un.addrlen - s.sun_family
    if namelen > 0 then
      if sa.sun_path[0] == 0 then
        if k == 'abstract' then return true end
        if k == 'name' then return ffi.string(rets.addr.sun_path, namelen) end -- should we also remove leading \0?
      else
        if k == 'name' then return ffi.string(rets.addr.sun_path) end
      end
    else
      if k == 'unnamed' then return true end
    end
  end
}

local function sa(addr, addrlen)
  local family = addr.family
  if family == S.AF.UNIX then -- we return Lua metatable not metatype, as need length to decode
    local sa = t.sockaddr_un()
    ffi.copy(sa, addr, addrlen)
    return setmetatable({addr = sa, addrlen = addrlen}, mt.sockaddr_un)
  end
  return addr
end

-- functions from section 3 that we use for ip addresses etc

local INET6_ADDRSTRLEN = 46
local INET_ADDRSTRLEN = 16

function S.inet_ntop(af, src)
  af = S.AF[af]
  if af == S.AF.INET then
    local b = pt.uchar(src)
    return tonumber(b[0]) .. "." .. tonumber(b[1]) .. "." .. tonumber(b[2]) .. "." .. tonumber(b[3])
  end
  local len = INET6_ADDRSTRLEN
  local dst = t.buffer(len)
  local ret = C.inet_ntop(af, src, dst, len)
  if ret == nil then return nil, t.error() end
  return ffi.string(dst)
end

function S.inet_pton(af, src, addr)
  af = S.AF[af]
  if not addr then addr = S.addrtype[af]() end
  local ret = C.inet_pton(af, src, addr)
  if ret == -1 then return nil, t.error() end
  if ret == 0 then return nil end -- maybe return string
  return addr
end

function S.inet_aton(s)
  return S.inet_pton(S.AF.INET, s)
end

function S.inet_ntoa(addr)
  return S.inet_ntop(S.AF.INET, addr)
end

-- generic inet name to ip, also with netmask support TODO think of better name?
function S.inet_name(src, netmask)
  local addr
  if not netmask then
    local a, b = src:find("/", 1, true)
    if a then
      netmask = tonumber(src:sub(b + 1))
      src = src:sub(1, a - 1)
    end
  end
  if src:find(":", 1, true) then -- ipv6
    addr = S.inet_pton(S.AF.INET6, src)
    if not addr then return nil end
    if not netmask then netmask = 128 end
  else
    addr = S.inet_pton(S.AF.INET, src)
    if not addr then return nil end
    if not netmask then netmask = 32 end
  end
  return addr, netmask
end

t.i6432 = ffi.typeof("union {int64_t i64; int32_t i32[2];}")
t.u6432 = ffi.typeof("union {uint64_t i64; uint32_t i32[2];}")

if ffi.abi("le") then
  function S.i64(n)
    local u = t.i6432(n)
    return u.i32[1], u.i32[0]
  end
  function S.u64(n)
    local u = t.u6432(n)
    return u.i32[1], u.i32[0]
  end
else
  function S.i64(n)
    local u = t.i6432(n)
    return u.i32[0], u.i32[1]
  end
  function S.u64(n)
    local u = t.u6432(n)
    return u.i32[0], u.i32[1]
  end
end

-- these functions might not be in libc, or are buggy so provide direct syscall fallbacks
local function inlibc(f) return ffi.C[f] end

-- glibc caches pid, but this fails to work eg after clone(). Musl is fine TODO test for this?
function C.getpid()
  return C.syscall(S.SYS.getpid)
end

-- clone interface provided is not same as system one, and is less convenient
function C.clone(flags, signal, stack, ptid, tls, ctid)
  return C.syscall(S.SYS.clone, t.int(flags), pt.void(stack), pt.void(ptid), pt.void(tls), pt.void(ctid))
end

-- getdents is not provided by glibc. Musl has weak alias so not visible.
function C.getdents(fd, buf, size)
  return C.syscall(S.SYS.getdents64, t.int(fd), buf, t.uint(size))
end

-- getcwd will allocate memory, so use syscall
function C.getcwd(buf, size)
  return C.syscall(S.SYS.getcwd, pt.void(buf), t.ulong(size))
end

-- for stat we use the syscall as libc might have a different struct stat for compatibility
-- TODO see if we can avoid this, at least for reasonable libc. Musl returns the right struct.
if ffi.abi("64bit") then
  function C.stat(path, buf)
    return C.syscall(S.SYS.stat, path, pt.void(buf))
  end
  function C.lstat(path, buf)
    return C.syscall(S.SYS.lstat, path, pt.void(buf))
  end
  function C.fstat(fd, buf)
    return C.syscall(S.SYS.fstat, t.int(fd), pt.void(buf))
  end
  function C.fstatat(fd, path, buf, flags)
    return C.syscall(S.SYS.fstatat, t.int(fd), path, pt.void(buf), t.int(flags))
  end
else
  function C.stat(path, buf)
    return C.syscall(S.SYS.stat64, path, pt.void(buf))
  end
  function C.lstat(path, buf)
    return C.syscall(S.SYS.lstat64, path, pt.void(buf))
  end
  function C.fstat(fd, buf)
    return C.syscall(S.SYS.fstat64, t.int(fd), pt.void(buf))
  end
  function C.fstatat(fd, path, buf, flags)
    return C.syscall(S.SYS.fstatat64, t.int(fd), path, pt.void(buf), t.int(flags))
  end
end

-- lseek is a mess in 32 bit, use _llseek syscall to get clean result
if ffi.abi("32bit") then
  function C.lseek(fd, offset, whence)
    local result = t.loff1()
    local off1, off2 = S.u64(offset)
    local ret = C.syscall(S.SYS._llseek, t.int(fd), t.ulong(off1), t.ulong(off2), pt.void(result), t.uint(whence))
    if ret == -1 then return -1 end
    return result[0]
  end
end

-- native Linux aio not generally supported, only posix API TODO these are not working
function C.io_setup(nr_events, ctx)
  return C.syscall(S.SYS.io_setup, t.uint(nr_events), ctx)
end
function C.io_destroy(ctx)
  return C.syscall(S.SYS.io_destroy, ctx)
end
function C.io_cancel(ctx, iocb, result)
  return C.syscall(S.SYS.io_cancel, ctx, iocb, result)
end
function C.io_getevents(ctx, min, nr, events, timeout)
  return C.syscall(S.SYS.io_getevents, ctx, t.long(min), t.long(nr), events, timeout)
end
function C.io_submit(ctx, iocb, nr)
  return C.syscall(S.SYS.io_submit, ctx, t.long(nr), iocb)
end

-- note dev_t not passed as 64 bits to this syscall
function CC.mknod(pathname, mode, dev)
  return C.syscall(S.SYS.mknod, pathname, t.mode(mode), t.long(dev))
end
function CC.mknodat(fd, pathname, mode, dev)
  return C.syscall(S.SYS.mknodat, t.int(fd), pathname, t.mode(mode), t.long(dev))
end
-- pivot_root is not provided by glibc, is provided by Musl
function CC.pivot_root(new_root, put_old)
  return C.syscall(C.SYS.pivot_root, new_root, put_old)
end

--[[ if you need to split 64 bit args on 32 bit syscalls use code like this
if ffi.abi("64bit") then
  function CC.fallocate(fd, mode, offset, len)
    return C.syscall(S.SYS.fallocate, t.int(fd), t.uint(mode), t.loff(offset), t.loff(len))
  end
else -- 32 bit uses splits for 64 bit args
  function CC.fallocate(fd, mode, offset, len)
    local off2, off1 = S.u64(offset)
    local len2, len1 = S.u64(len)
    return C.syscall(S.SYS.fallocate, t.int(fd), t.uint(mode), t.uint32(off1), t.uint32(off2), t.uint32(len1), t.uint32(len2))
  end
end
]]

-- if not in libc replace

-- with glibc in -rt
if not pcall(inlibc, "clock_getres") then
  local rt = ffi.load "rt"
  C.clock_getres = rt.clock_getres
  C.clock_settime = rt.clock_settime
  C.clock_gettime = rt.clock_gettime
  C.clock_nanosleep = rt.clock_nanosleep
end

-- not in eglibc
if not pcall(inlibc, "mknod") then C.mknod = CC.mknod end
if not pcall(inlibc, "mknodat") then C.mknodat = CC.mknodat end
if not pcall(inlibc, "pivot_root") then C.pivot_root = CC.pivot_root end

-- main definitions start here
function S.open(pathname, flags, mode)
  return retfd(C.open(pathname, S.O[flags], S.MODE[mode]))
end

function S.openat(dirfd, pathname, flags, mode)
  return retfd(C.openat(getfd_at(dirfd), pathname, S.O[flags], S.MODE[mode]))
end

-- TODO dup3 can have a race condition (see man page) although Musl fixes, appears eglibc does not
function S.dup(oldfd, newfd, flags)
  if not newfd then return retfd(C.dup(getfd(oldfd))) end
  return retfd(C.dup3(getfd(oldfd), getfd(newfd), flags or 0))
end

mt.pipe = {
  __index = {
    close = function(p)
      local ok1, err1 = p[1]:close()
      local ok2, err2 = p[2]:close()
      if not ok1 then return nil, err1 end
      if not ok2 then return nil, err2 end
      return true
    end,
    read = function(p, ...) return p[1]:read(...) end,
    write = function(p, ...) return p[2]:write(...) end,
    pread = function(p, ...) return p[1]:pread(...) end,
    pwrite = function(p, ...) return p[2]:pwrite(...) end,
    nonblock = function(p)
      local ok, err = p[1]:nonblock()
      if not ok then return nil, err end
      local ok, err = p[2]:nonblock()
      if not ok then return nil, err end
      return true
    end,
    block = function(p)
      local ok, err = p[1]:block()
      if not ok then return nil, err end
      local ok, err = p[2]:block()
      if not ok then return nil, err end
      return true
    end,
    setblocking = function(p, b)
      local ok, err = p[1]:setblocking(b)
      if not ok then return nil, err end
      local ok, err = p[2]:setblocking(b)
      if not ok then return nil, err end
      return true
    end,
    -- TODO many useful methods still missing
  }
}

function S.pipe(flags)
  local fd2 = t.int2()
  local ret = C.pipe2(fd2, S.OPIPE[flags])
  if ret == -1 then return nil, t.error() end
  return setmetatable({t.fd(fd2[0]), t.fd(fd2[1])}, mt.pipe)
end

-- TODO more generic so works with alternate fd structures (call __close?)
function S.close(fd)
  local fileno = getfd(fd)
  if fileno == -1 then return true end -- already closed
  local ret = C.close(fileno)
  if ret == -1 then
    local errno = ffi.errno()
    if ffi.istype(t.fd, fd) and errno ~= S.E.INTR then -- file will still be open if interrupted
      fd.filenum = -1 -- make sure cannot accidentally close this fd object again
    end
    return nil, t.error()
  end
  if ffi.istype(t.fd, fd) then
    fd.filenum = -1 -- make sure cannot accidentally close this fd object again
  end
  return true
end

function S.creat(pathname, mode) return retfd(C.creat(pathname, S.MODE[mode])) end
function S.unlink(pathname) return retbool(C.unlink(pathname)) end
function S.unlinkat(dirfd, path, flags)
  return retbool(C.unlinkat(getfd_at(dirfd), path, S.AT_REMOVEDIR[flags]))
end
function S.rename(oldpath, newpath) return retbool(C.rename(oldpath, newpath)) end
function S.renameat(olddirfd, oldpath, newdirfd, newpath)
  return retbool(C.renameat(getfd_at(olddirfd), oldpath, getfd_at(newdirfd), newpath))
end
function S.chdir(path) return retbool(C.chdir(path)) end
function S.mkdir(path, mode) return retbool(C.mkdir(path, S.MODE[mode])) end
function S.mkdirat(fd, path, mode) return retbool(C.mkdirat(getfd_at(fd), path, S.MODE[mode])) end
function S.rmdir(path) return retbool(C.rmdir(path)) end
function S.acct(filename) return retbool(C.acct(filename)) end
function S.chmod(path, mode) return retbool(C.chmod(path, S.MODE[mode])) end
function S.link(oldpath, newpath) return retbool(C.link(oldpath, newpath)) end
function S.linkat(olddirfd, oldpath, newdirfd, newpath, flags)
  return retbool(C.linkat(getfd_at(olddirfd), oldpath, getfd_at(newdirfd), newpath, S.AT_SYMLINK_FOLLOW[flags]))
end
function S.symlink(oldpath, newpath) return retbool(C.symlink(oldpath, newpath)) end
function S.symlinkat(oldpath, newdirfd, newpath) return retbool(C.symlinkat(oldpath, getfd_at(newdirfd), newpath)) end
function S.pause() return retbool(C.pause()) end

function S.chown(path, owner, group) return retbool(C.chown(path, owner or -1, group or -1)) end
function S.fchown(fd, owner, group) return retbool(C.fchown(getfd(fd), owner or -1, group or -1)) end
function S.lchown(path, owner, group) return retbool(C.lchown(path, owner or -1, group or -1)) end
function S.fchownat(dirfd, path, owner, group, flags)
  return retbool(C.fchownat(getfd_at(dirfd), path, owner or -1, group or -1, S.AT_SYMLINK_NOFOLLOW[flags]))
end

function S.truncate(path, length) return retbool(C.truncate(path, length)) end
function S.ftruncate(fd, length) return retbool(C.ftruncate(getfd(fd), length)) end

function S.access(pathname, mode) return retbool(C.access(pathname, S.OK[mode])) end
function S.faccessat(dirfd, pathname, mode, flags)
  return retbool(C.faccessat(getfd_at(dirfd), pathname, S.OK[mode], S.AT_ACCESSAT[flags]))
end

function S.readlink(path, buffer, size)
  size = size or S.PATH_MAX
  buffer = buffer or t.buffer(size)
  local ret = tonumber(C.readlink(path, buffer, size))
  if ret == -1 then return nil, t.error() end
  return ffi.string(buffer, ret)
end

function S.readlinkat(dirfd, path, buffer, size)
  size = size or S.PATH_MAX
  buffer = buffer or t.buffer(size)
  local ret = tonumber(C.readlinkat(getfd_at(dirfd), path, buffer, size))
  if ret == -1 then return nil, t.error() end
  return ffi.string(buffer, ret)
end

function S.mknod(pathname, mode, dev)
  return retbool(C.mknod(pathname, S.S[mode], dev or 0))
end
function S.mknodat(fd, pathname, mode, dev)
  return retbool(C.mknodat(getfd_at(fd), pathname, S.S[mode], dev or 0))
end

-- mkfifo is from man(3), add for convenience
function S.mkfifo(path, mode) return S.mknod(path, bit.bor(S.S[mode], S.S.IFIFO)) end
function S.mkfifoat(fd, path, mode) return S.mknodat(fd, path, bit.bor(S.S[mode], S.S.IFIFO), 0) end

function S.nice(inc) return retnume(C.nice, inc) end
-- NB glibc is shifting these values from what strace shows, as per man page, kernel adds 20 to make these values positive...
-- might cause issues with other C libraries in which case may shift to using system call
function S.getpriority(which, who) return retnume(C.getpriority, S.PRIO[which], who or 0) end
function S.setpriority(which, who, prio) return retnume(C.setpriority, S.PRIO[which], who or 0, prio) end

 -- we could allocate ptid, ctid, tls if required in flags instead. TODO add signal into flag parsing directly
function S.clone(flags, signal, stack, ptid, tls, ctid)
  flags = S.CLONE[flags] + S.SIG[signal]
  return retnum(C.clone(flags, stack, ptid, tls, ctid))
end

function S.unshare(flags) return retbool(C.unshare(S.CLONE[flags])) end
function S.setns(fd, nstype) return retbool(C.setns(getfd(fd), S.CLONE[nstype])) end

function S.fork() return retnum(C.fork()) end
function S.execve(filename, argv, envp)
  local cargv = t.string_array(#argv + 1, argv)
  cargv[#argv] = nil -- LuaJIT does not zero rest of a VLA
  local cenvp = t.string_array(#envp + 1, envp)
  cenvp[#envp] = nil
  return retbool(C.execve(filename, cargv, cenvp))
end

function S.ioctl(d, request, argp)
  local ret = C.ioctl(getfd(d), request, argp)
  if ret == -1 then return nil, t.error() end
  -- some different return types may need to be handled
  return true
end

function S.reboot(cmd) return retbool(C.reboot(S.LINUX_REBOOT_CMD[cmd])) end

-- ffi metatype on dirent?
function S.getdents(fd, buf, size, noiter) -- default behaviour is to iterate over whole directory, use noiter if you have very large directories
  if not buf then
    size = size or 4096
    buf = t.buffer(size)
  end
  local d = {}
  local ret
  repeat
    ret = C.getdents(getfd(fd), buf, size)
    if ret == -1 then return nil, t.error() end
    local i = 0
    while i < ret do
      local dp = pt.dirent(buf + i)
      local dd = setmetatable({inode = tonumber(dp.d_ino), offset = tonumber(dp.d_off), type = tonumber(dp.d_type)}, mt.dents)
      d[ffi.string(dp.d_name)] = dd -- could calculate length
      i = i + dp.d_reclen
    end
  until noiter or ret == 0
  return d
end

function S.wait()
  local status = t.int1()
  return retwait(C.wait(status), status[0])
end
function S.waitpid(pid, options)
  local status = t.int1()
  return retwait(C.waitpid(pid, status, S.W[options]), status[0])
end
function S.waitid(idtype, id, options, infop) -- note order of args, as usually dont supply infop
  if not infop then infop = t.siginfo() end
  infop.si_pid = 0 -- see notes on man page
  local ret = C.waitid(S.P[idtype], id or 0, infop, S.W[options])
  if ret == -1 then return nil, t.error() end
  return infop -- return table here?
end

function S._exit(status) C._exit(S.EXIT[status]) end
function S.exit(status) C.exit(S.EXIT[status]) end

function S.read(fd, buf, count)
  if buf then return retnum(C.read(getfd(fd), buf, count)) end -- user supplied a buffer, standard usage
  if not count then count = 4096 end
  buf = t.buffer(count)
  local ret = C.read(getfd(fd), buf, count)
  if ret == -1 then return nil, t.error() end
  return ffi.string(buf, tonumber(ret)) -- user gets a string back, can get length from #string
end

function S.write(fd, buf, count) return retnum(C.write(getfd(fd), buf, count or #buf)) end
function S.pread(fd, buf, count, offset) return retnum(C.pread64(getfd(fd), buf, count, offset)) end
function S.pwrite(fd, buf, count, offset) return retnum(C.pwrite64(getfd(fd), buf, count or #buf, offset)) end

function S.lseek(fd, offset, whence)
  return ret64(C.lseek(getfd(fd), offset or 0, S.SEEK[whence]))
end

function S.send(fd, buf, count, flags) return retnum(C.send(getfd(fd), buf, count or #buf, S.MSG[flags])) end
function S.sendto(fd, buf, count, flags, addr, addrlen)
  return retnum(C.sendto(getfd(fd), buf, count or #buf, S.MSG[flags], addr, addrlen or ffi.sizeof(addr)))
end

function S.sendmsg(fd, msg, flags)
  if not msg then -- send a single byte message, eg enough to send credentials
    local buf1 = t.buffer(1)
    local io = t.iovecs{{buf1, 1}}
    msg = t.msghdr{msg_iov = io.iov, msg_iovlen = #io}
  end
  return retbool(C.sendmsg(getfd(fd), msg, S.MSG[flags]))
end

function S.readv(fd, iov)
  iov = istype(t.iovecs, iov) or t.iovecs(iov)
  return retnum(C.readv(getfd(fd), iov.iov, #iov))
end

function S.writev(fd, iov)
  iov = istype(t.iovecs, iov) or t.iovecs(iov)
  return retnum(C.writev(getfd(fd), iov.iov, #iov))
end

function S.preadv(fd, iov, offset)
  iov = istype(t.iovecs, iov) or t.iovecs(iov)
  return retnum(C.preadv64(getfd(fd), iov.iov, #iov, offset))
end

function S.pwritev(fd, iov, offset)
  iov = istype(t.iovecs, iov) or t.iovecs(iov)
  return retnum(C.pwritev64(getfd(fd), iov.iov, #iov, offset))
end

function S.recv(fd, buf, count, flags) return retnum(C.recv(getfd(fd), buf, count or #buf, S.MSG[flags])) end
function S.recvfrom(fd, buf, count, flags, ss, addrlen)
  if not ss then
    ss = t.sockaddr_storage()
    addrlen = t.socklen1(s.sockaddr_storage)
  end
  local ret = C.recvfrom(getfd(fd), buf, count, S.MSG[flags], ss, addrlen)
  if ret == -1 then return nil, t.error() end
  return {count = tonumber(ret), addr = sa(ss, addrlen[0])}
end

function S.setsockopt(fd, level, optname, optval, optlen)
   -- allocate buffer for user, from Lua type if know how, int and bool so far
  if not optlen and type(optval) == 'boolean' then if optval then optval = 1 else optval = 0 end end
  if not optlen and type(optval) == 'number' then
    optval = t.int1(optval)
    optlen = s.int
  end
  return retbool(C.setsockopt(getfd(fd), S.SOL[level], S.SO[optname], optval, optlen))
end

function S.getsockopt(fd, level, optname) -- will need fixing for non int/bool options
  local optval, optlen = t.int1(), t.socklen1()
  optlen[0] = s.int
  local ret = C.getsockopt(getfd(fd), level, optname, optval, optlen)
  if ret == -1 then return nil, t.error() end
  return tonumber(optval[0]) -- no special case for bool
end

function S.fchdir(fd) return retbool(C.fchdir(getfd(fd))) end
function S.fsync(fd) return retbool(C.fsync(getfd(fd))) end
function S.fdatasync(fd) return retbool(C.fdatasync(getfd(fd))) end
function S.fchmod(fd, mode) return retbool(C.fchmod(getfd(fd), S.MODE[mode])) end
function S.fchmodat(dirfd, pathname, mode)
  return retbool(C.fchmodat(getfd_at(dirfd), pathname, S.MODE[mode], 0)) -- no flags actually supported
end
function S.sync_file_range(fd, offset, count, flags)
  return retbool(C.sync_file_range(getfd(fd), offset, count, S.SYNC_FILE_RANGE[flags]))
end

function S.stat(path, buf)
  if not buf then buf = t.stat() end
  local ret = C.stat(path, buf)
  if ret == -1 then return nil, t.error() end
  return buf
end

function S.lstat(path, buf)
  if not buf then buf = t.stat() end
  local ret = C.lstat(path, buf)
  if ret == -1 then return nil, t.error() end
  return buf
end

function S.fstat(fd, buf)
  if not buf then buf = t.stat() end
  local ret = C.fstat(getfd(fd), buf)
  if ret == -1 then return nil, t.error() end
  return buf
end

function S.fstatat(fd, path, buf, flags)
  if not buf then buf = t.stat() end
  local ret = C.fstatat(getfd_at(fd), path, buf, S.AT_FSTATAT[flags])
  if ret == -1 then return nil, t.error() end
  return buf
end

local function gettimespec2(ts)
  if ts and (not ffi.istype(t.timespec2, ts)) then
    local s1, s2 = ts[1], ts[2]
    ts = t.timespec2()
    if type(s1) == 'string' then ts[0].tv_nsec = S.UTIME[s1] else ts[0] = t.timespec(s1) end
    if type(s2) == 'string' then ts[1].tv_nsec = S.UTIME[s2] else ts[1] = t.timespec(s2) end
  end
  return ts
end

function S.futimens(fd, ts)
  return retbool(C.futimens(getfd(fd), gettimespec2(ts)))
end

function S.utimensat(dirfd, path, ts, flags)
  return retbool(C.utimensat(getfd_at(dirfd), path, gettimespec2(ts), S.AT_SYMLINK_NOFOLLOW[flags]))
end

-- because you can just pass floats to all the time functions, just use the same one, but provide different templates
function S.utime(path, actime, modtime)
  local ts
  if not modtime then modtime = actime end
  if actime and modtime then ts = {actime, modtime} end
  return S.utimensat(nil, path, ts)
end

S.utimes = S.utime

function S.chroot(path) return retbool(C.chroot(path)) end

function S.getcwd(buf, size)
  size = size or S.PATH_MAX
  buf = buf or t.buffer(size)
  local ret = C.getcwd(buf, size)
  if ret == -1 then return nil, t.error() end
  return ffi.string(buf)
end

function S.statfs(path)
  local st = t.statfs()
  local ret = C.statfs(path, st)
  if ret == -1 then return nil, t.error() end
  return st
end

function S.fstatfs(fd)
  local st = t.statfs()
  local ret = C.fstatfs(getfd(fd), st)
  if ret == -1 then return nil, t.error() end
  return st
end

function S.nanosleep(req, rem)
  req = istype(t.timespec, req) or t.timespec(req)
  rem = rem or t.timespec()
  local ret = C.nanosleep(req, rem)
  if ret == -1 then
    if ffi.errno() == S.E.INTR then return rem else return nil, t.error() end
  end
  return true
end

function S.sleep(sec) -- standard libc function
  local rem, err = S.nanosleep(sec)
  if not rem then return nil, err end
  if rem == true then return 0 end
  return tonumber(rem.tv_sec)
end

function S.mmap(addr, length, prot, flags, fd, offset)
  return retptr(C.mmap(addr, length, S.PROT[prot], S.MAP[flags], getfd(fd), offset))
end
function S.munmap(addr, length)
  return retbool(C.munmap(addr, length))
end
function S.msync(addr, length, flags) return retbool(C.msync(addr, length, S.MSYNC[flags])) end
function S.mlock(addr, len) return retbool(C.mlock(addr, len)) end
function S.munlock(addr, len) return retbool(C.munlock(addr, len)) end
function S.mlockall(flags) return retbool(C.mlockall(S.MCL[flags])) end
function S.munlockall() return retbool(C.munlockall()) end
function S.mremap(old_address, old_size, new_size, flags, new_address)
  return retptr(C.mremap(old_address, old_size, new_size, S.MREMAP[flags], new_address))
end
function S.madvise(addr, length, advice) return retbool(C.madvise(addr, length, S.MADV[advice])) end
function S.fadvise(fd, advice, offset, len) -- note argument order
  return retbool(C.posix_fadvise(getfd(fd), offset or 0, len or 0, S.POSIX_FADV[advice]))
end
function S.fallocate(fd, mode, offset, len)
  return retbool(C.fallocate(getfd(fd), S.FALLOC_FL[mode], offset or 0, len))
end
function S.posix_fallocate(fd, offset, len) return S.fallocate(fd, 0, offset, len) end
function S.readahead(fd, offset, count) return retbool(C.readahead(getfd(fd), offset, count)) end

local function sproto(domain, protocol) -- helper function to lookup protocol type depending on domain
  if domain == S.AF.NETLINK then return S.NETLINK[protocol] end
  return protocol or 0
end

function S.socket(domain, stype, protocol)
  domain = S.AF[domain]
  local ret = C.socket(domain, S.SOCK[stype], sproto(domain, protocol))
  if ret == -1 then return nil, t.error() end
  return t.fd(ret)
end

mt.socketpair = {
  __index = {
    close = function(s)
      local ok1, err1 = s[1]:close()
      local ok2, err2 = s[2]:close()
      if not ok1 then return nil, err1 end
      if not ok2 then return nil, err2 end
      return true
    end,
    nonblock = function(s)
      local ok, err = s[1]:nonblock()
      if not ok then return nil, err end
      local ok, err = s[2]:nonblock()
      if not ok then return nil, err end
      return true
    end,
    block = function(s)
      local ok, err = s[1]:block()
      if not ok then return nil, err end
      local ok, err = s[2]:block()
      if not ok then return nil, err end
      return true
    end,
    setblocking = function(s, b)
      local ok, err = s[1]:setblocking(b)
      if not ok then return nil, err end
      local ok, err = s[2]:setblocking(b)
      if not ok then return nil, err end
      return true
    end,
  }
}

function S.socketpair(domain, stype, protocol)
  domain = S.AF[domain]
  local sv2 = t.int2()
  local ret = C.socketpair(domain, S.SOCK[stype], sproto(domain, protocol), sv2)
  if ret == -1 then return nil, t.error() end
  return setmetatable({t.fd(sv2[0]), t.fd(sv2[1])}, mt.socketpair)
end

function S.bind(sockfd, addr, addrlen)
  return retbool(C.bind(getfd(sockfd), addr, addrlen or ffi.sizeof(addr)))
end

function S.listen(sockfd, backlog) return retbool(C.listen(getfd(sockfd), backlog or S.SOMAXCONN)) end
function S.connect(sockfd, addr, addrlen)
  return retbool(C.connect(getfd(sockfd), addr, addrlen or ffi.sizeof(addr)))
end

function S.shutdown(sockfd, how) return retbool(C.shutdown(getfd(sockfd), S.SHUT[how])) end

function S.accept(sockfd, flags, addr, addrlen)
  if not addr then addr = t.sockaddr_storage() end
  if not addrlen then addrlen = t.socklen1(addrlen or ffi.sizeof(addr)) end
  local ret
  if not flags
    then ret = C.accept(getfd(sockfd), addr, addrlen)
    else ret = C.accept4(getfd(sockfd), addr, addrlen, S.SOCK[flags])
  end
  if ret == -1 then return nil, t.error() end
  return {fd = t.fd(ret), addr = sa(addr, addrlen[0])}
end

function S.getsockname(sockfd, ss, addrlen)
  if not ss then
    ss = t.sockaddr_storage()
    addrlen = t.socklen1(s.sockaddr_storage)
  end
  local ret = C.getsockname(getfd(sockfd), ss, addrlen)
  if ret == -1 then return nil, t.error() end
  return sa(ss, addrlen[0])
end

function S.getpeername(sockfd, ss, addrlen)
  if not ss then
    ss = t.sockaddr_storage()
    addrlen = t.socklen1(s.sockaddr_storage)
  end
  local ret = C.getpeername(getfd(sockfd), ss, addrlen)
  if ret == -1 then return nil, t.error() end
  return sa(ss, addrlen[0])
end

local function getflock(arg)
  if not arg then arg = t.flock() end
  if not ffi.istype(t.flock, arg) then
    for _, v in pairs {"type", "whence", "start", "len", "pid"} do -- allow use of short names
      if arg[v] then
        arg["l_" .. v] = arg[v] -- TODO cleanup this to use table?
        arg[v] = nil
      end
    end
    arg.l_type = S.FCNTL_LOCK[arg.l_type]
    arg.l_whence = S.SEEK[arg.l_whence]
    arg = t.flock(arg)
  end
  return arg
end

local fcntl_commands = {
  [S.F.SETFL] = function(arg) return S.O[arg] end,
  [S.F.SETFD] = function(arg) return S.FD[arg] end,
  [S.F.GETLK] = getflock,
  [S.F.SETLK] = getflock,
  [S.F.SETLKW] = getflock,
}

local fcntl_ret = {
  [S.F.DUPFD] = function(ret) return t.fd(ret) end,
  [S.F.DUPFD_CLOEXEC] = function(ret) return t.fd(ret) end,
  [S.F.GETFD] = function(ret) return tonumber(ret) end,
  [S.F.GETFL] = function(ret) return tonumber(ret) end,
  [S.F.GETLEASE] = function(ret) return tonumber(ret) end,
  [S.F.GETOWN] = function(ret) return tonumber(ret) end,
  [S.F.GETSIG] = function(ret) return tonumber(ret) end,
  [S.F.GETPIPE_SZ] = function(ret) return tonumber(ret) end,
  [S.F.GETLK] = function(ret, arg) return arg end,
}

function S.fcntl(fd, cmd, arg)
  cmd = S.F[cmd]

  if fcntl_commands[cmd] then arg = fcntl_commands[cmd](arg) end

  local ret = C.fcntl(getfd(fd), cmd, pt.void(arg or 0))
  if ret == -1 then return nil, t.error() end

  if fcntl_ret[cmd] then return fcntl_ret[cmd](ret, arg) end

  return true
end

function S.uname()
  local u = t.utsname()
  local ret = C.uname(u)
  if ret == -1 then return nil, t.error() end
  return {sysname = ffi.string(u.sysname), nodename = ffi.string(u.nodename), release = ffi.string(u.release),
          version = ffi.string(u.version), machine = ffi.string(u.machine), domainname = ffi.string(u.domainname)}
end

function S.gethostname()
  local u, err = S.uname()
  if not u then return nil, err end
  return u.nodename
end

function S.getdomainname()
  local u, err = S.uname()
  if not u then return nil, err end
  return u.domainname
end

function S.sethostname(s) -- only accept Lua string, do not see use case for buffer as well
  return retbool(C.sethostname(s, #s))
end

function S.setdomainname(s)
  return retbool(C.setdomainname(s, #s))
end

-- does not support passing a function as a handler, use sigaction instead
-- actualy glibc does not call the syscall anyway, defines in terms of sigaction; TODO we should too
function S.signal(signum, handler) return retbool(C.signal(S.SIG[signum], S.SIGACT[handler])) end

-- missing siginfo functionality for now, only supports getting signum TODO
-- NOTE I do not think it is safe to call this with a function argument as the jit compiler will not know when it is going to
-- be called, so have removed this functionality again
-- recommend using signalfd to handle signals if you need to do anything complex.
function S.sigaction(signum, handler, mask, flags)
  local sa
  if ffi.istype(t.sigaction, handler) then sa = handler
  else
    if type(handler) == 'string' then
      handler = ffi.cast(t.sighandler, t.int1(S.SIGACT[handler]))
    --elseif
    --  type(handler) == 'function' then handler = ffi.cast(t.sighandler, handler) -- TODO check if gc problem here? need to copy?
    end
    sa = t.sigaction{sa_handler = handler, sa_mask = mksigset(mask), sa_flags = S.SA[flags]}
  end
  local old = t.sigaction()
  local ret = C.sigaction(S.SIG[signum], sa, old)
  if ret == -1 then return nil, t.error() end
  return old
end

function S.kill(pid, sig) return retbool(C.kill(pid, S.SIG[sig])) end
function S.killpg(pgrp, sig) return S.kill(-pgrp, sig) end

function S.gettimeofday(tv)
  if not tv then tv = t.timeval() end -- note it is faster to pass your own tv if you call a lot
  local ret = C.gettimeofday(tv, nil)
  if ret == -1 then return nil, t.error() end
  return tv
end

function S.settimeofday(tv) return retbool(C.settimeofday(tv, nil)) end

function S.time()
  return tonumber(C.time(nil))
end

function S.sysinfo(info)
  if not info then info = t.sysinfo() end
  local ret = C.sysinfo(info)
  if ret == -1 then return nil, t.error() end
  return info
end

local function growattrbuf(f, a, b)
  local len = 512
  local buffer = t.buffer(len)
  local ret
  repeat
    if b then
      ret = tonumber(f(a, b, buffer, len))
    else
      ret = tonumber(f(a, buffer, len))
    end
    if ret == -1 and ffi.errno ~= S.E.ERANGE then return nil, t.error() end
    if ret == -1 then
      len = len * 2
      buffer = t.buffer(len)
    end
  until ret >= 0

  if ret > 0 then ret = ret - 1 end -- has trailing \0

  return ffi.string(buffer, ret)
end

local function lattrbuf(sys, a)
  local s, err = growattrbuf(sys, a)
  if not s then return nil, err end
  return split('\0', s)
end

function S.listxattr(path) return lattrbuf(C.listxattr, path) end
function S.llistxattr(path) return lattrbuf(C.llistxattr, path) end
function S.flistxattr(fd) return lattrbuf(C.flistxattr, getfd(fd)) end

function S.setxattr(path, name, value, flags)
  return retbool(C.setxattr(path, name, value, #value + 1, S.XATTR[flags]))
end
function S.lsetxattr(path, name, value, flags)
  return retbool(C.lsetxattr(path, name, value, #value + 1, S.XATTR[flags]))
end
function S.fsetxattr(fd, name, value, flags)
  return retbool(C.fsetxattr(getfd(fd), name, value, #value + 1, S.XATTR[flags]))
end

function S.getxattr(path, name) return growattrbuf(C.getxattr, path, name) end
function S.lgetxattr(path, name) return growattrbuf(C.lgetxattr, path, name) end
function S.fgetxattr(fd, name) return growattrbuf(C.fgetxattr, getfd(fd), name) end

function S.removexattr(path, name) return retbool(C.removexattr(path, name)) end
function S.lremovexattr(path, name) return retbool(C.lremovexattr(path, name)) end
function S.fremovexattr(fd, name) return retbool(C.fremovexattr(getfd(fd), name)) end

-- helper function to set and return attributes in tables
local function xattr(list, get, set, remove, path, t)
  local l, err = list(path)
  if not l then return nil, err end
  if not t then -- no table, so read
    local r = {}
    for _, name in ipairs(l) do
      r[name] = get(path, name) -- ignore errors
    end
    return r
  end
  -- write
  for _, name in ipairs(l) do
    if t[name] then
      set(path, name, t[name]) -- ignore errors, replace
      t[name] = nil
    else
      remove(path, name)
    end
  end
  for name, value in pairs(t) do
    set(path, name, value) -- ignore errors, create
  end
  return true
end

function S.xattr(path, t) return xattr(S.listxattr, S.getxattr, S.setxattr, S.removexattr, path, t) end
function S.lxattr(path, t) return xattr(S.llistxattr, S.lgetxattr, S.lsetxattr, S.lremovexattr, path, t) end
function S.fxattr(fd, t) return xattr(S.flistxattr, S.fgetxattr, S.fsetxattr, S.fremovexattr, fd, t) end

-- fdset handlers
local function mkfdset(fds, nfds) -- should probably check fd is within range (1024), or just expand structure size
  local set = t.fdset()
  for i, v in ipairs(fds) do
    local fd = tonumber(getfd(v))
    if fd + 1 > nfds then nfds = fd + 1 end
    local fdelt = bit.rshift(fd, 5) -- always 32 bits
    set.fds_bits[fdelt] = bit.bor(set.fds_bits[fdelt], bit.lshift(1, fd % 32)) -- always 32 bit words
  end
  return set, nfds
end

local function fdisset(fds, set)
  local f = {}
  for i, v in ipairs(fds) do
    local fd = tonumber(getfd(v))
    local fdelt = bit.rshift(fd, 5) -- always 32 bits
    if bit.band(set.fds_bits[fdelt], bit.lshift(1, fd % 32)) ~= 0 then table.insert(f, v) end -- careful not to duplicate fd objects
  end
  return f
end

function S.sigprocmask(how, set)
  local oldset = t.sigset()
  local ret = C.sigprocmask(S.SIGPM[how], mksigset(set), oldset)
  if ret == -1 then return nil, t.error() end
  return oldset
end

function S.sigpending()
  local set = t.sigset()
  local ret = C.sigpending(set)
  if ret == -1 then return nil, t.error() end
 return set
end

function S.sigsuspend(mask) return retbool(C.sigsuspend(mksigset(mask))) end

function S.signalfd(set, flags, fd) -- note different order of args, as fd usually empty. See also signalfd_read()
  if fd then fd = getfd(fd) else fd = -1 end
  return retfd(C.signalfd(fd, mksigset(set), S.SFD[flags]))
end

-- TODO convert to metatype?
function S.select(s) -- note same structure as returned
  local r, w, e
  local nfds = 0
  local timeout
  if s.timeout then
    if ffi.istype(t.timeval, s.timeout) then timeout = s.timeout else timeout = t.timeval(s.timeout) end
  end
  r, nfds = mkfdset(s.readfds or {}, nfds or 0)
  w, nfds = mkfdset(s.writefds or {}, nfds)
  e, nfds = mkfdset(s.exceptfds or {}, nfds)
  local ret = C.select(nfds, r, w, e, timeout)
  if ret == -1 then return nil, t.error() end
  return {readfds = fdisset(s.readfds or {}, r), writefds = fdisset(s.writefds or {}, w),
          exceptfds = fdisset(s.exceptfds or {}, e), count = tonumber(ret)}
end

function S.pselect(s) -- note same structure as returned
  local r, w, e
  local nfds = 0
  local timeout, set
  if s.timeout then
    if ffi.istype(t.timespec, s.timeout) then timeout = s.timeout else timeout = t.timespec(s.timeout) end
  end
  if s.sigset then set = mksigset(s.sigset) end
  r, nfds = mkfdset(s.readfds or {}, nfds or 0)
  w, nfds = mkfdset(s.writefds or {}, nfds)
  e, nfds = mkfdset(s.exceptfds or {}, nfds)
  local ret = C.pselect(nfds, r, w, e, timeout, set)
  if ret == -1 then return nil, t.error() end
  return {readfds = fdisset(s.readfds or {}, r), writefds = fdisset(s.writefds or {}, w),
          exceptfds = fdisset(s.exceptfds or {}, e), count = tonumber(ret), sigset = set}
end

function S.poll(fds, timeout)
  fds = istype(t.pollfds, fds) or t.pollfds(fds)
  local ret = C.poll(fds.pfd, #fds, timeout or -1)
  if ret == -1 then return nil, t.error() end
  return fds
end

-- note that syscall does return timeout remaining but libc does not, due to standard prototype
function S.ppoll(fds, timeout, set)
  fds = istype(t.pollfds, fds) or t.pollfds(fds)
  if timeout then timeout = istype(t.timespec, timeout) or t.timespec(timeout) end
  if set then set = mksigset(set) end
  local ret = C.ppoll(fds.pfd, #fds, timeout, set)
  if ret == -1 then return nil, t.error() end
  return fds
end

function S.mount(source, target, filesystemtype, mountflags, data)
  if type(source) == "table" then
    local t = source
    source = t.source
    target = t.target
    filesystemtype = t.type
    mountflags = t.flags
    data = t.data
  end
  return retbool(C.mount(source, target, filesystemtype, S.MS[mountflags], data))
end

function S.umount(target, flags)
  return retbool(C.umount2(target, S.UMOUNT[flags]))
end

-- unlimited value. TODO metatype should return this to Lua.
-- TODO math.huge should be converted to this in __new
S.RLIM_INFINITY = ffi.cast("rlim64_t", -1)

function S.prlimit(pid, resource, new_limit, old_limit)
  if new_limit then new_limit = istype(t.rlimit, new_limit) or t.rlimit(new_limit) end
  old_limit = old_limit or t.rlimit()
  local ret = C.prlimit64(pid or 0, S.RLIMIT[resource], new_limit, old_limit)
  if ret == -1 then return nil, t.error() end
  return old_limit
end

-- old rlimit functions are 32 bit only so now defined using prlimit
function S.getrlimit(resource)
  return S.prlimit(0, resource)
end

function S.setrlimit(resource, rlim)
  local ret, err = S.prlimit(0, resource, rlim)
  if not ret then return nil, err end
  return true
end

function S.epoll_create(flags)
  return retfd(C.epoll_create1(S.EPOLLCREATE[flags]))
end

function S.epoll_ctl(epfd, op, fd, event, data)
  if not ffi.istype(t.epoll_event, event) then
    local events = S.EPOLL[event]
    event = t.epoll_event()
    event.events = events
    if data then event.data.u64 = data else event.data.fd = getfd(fd) end
  end
  return retbool(C.epoll_ctl(getfd(epfd), S.EPOLL_CTL[op], getfd(fd), event))
end

function S.epoll_wait(epfd, events, maxevents, timeout, sigmask) -- includes optional epoll_pwait functionality
  if not maxevents then maxevents = 16 end
  if not events then events = t.epoll_events(maxevents) end
  if sigmask then sigmask = mksigset(sigmask) end
  local ret
  if sigmask then
    ret = C.epoll_pwait(getfd(epfd), events, maxevents, timeout or -1, sigmask)
  else
    ret = C.epoll_wait(getfd(epfd), events, maxevents, timeout or -1)
  end
  if ret == -1 then return nil, t.error() end
  local r = {}
  for i = 1, ret do -- put in Lua array TODO convert to metatype
    local e = events[i - 1]
    local ev = setmetatable({fd = tonumber(e.data.fd), data = t.uint64(e.data.u64), events = e.events}, mt.epoll)
    r[i] = ev
  end
  return r
end

function S.splice(fd_in, off_in, fd_out, off_out, len, flags)
  local offin, offout = off_in, off_out
  if off_in and not ffi.istype(t.loff1, off_in) then
    offin = t.loff1()
    offin[0] = off_in
  end
  if off_out and not ffi.istype(t.loff1, off_out) then
    offout = t.loff1()
    offout[0] = off_out
  end
  return retnum(C.splice(getfd(fd_in), offin, getfd(fd_out), offout, len, S.SPLICE_F[flags]))
end

function S.vmsplice(fd, iov, flags)
  iov = istype(t.iovecs, iov) or t.iovecs(iov)
  return retnum(C.vmsplice(getfd(fd), iov.iov, #iov, S.SPLICE_F[flags]))
end

function S.tee(fd_in, fd_out, len, flags)
  return retnum(C.tee(getfd(fd_in), getfd(fd_out), len, S.SPLICE_F[flags]))
end

function S.inotify_init(flags) return retfd(C.inotify_init1(S.IN_INIT[flags])) end
function S.inotify_add_watch(fd, pathname, mask) return retnum(C.inotify_add_watch(getfd(fd), pathname, S.IN[mask])) end
function S.inotify_rm_watch(fd, wd) return retbool(C.inotify_rm_watch(getfd(fd), wd)) end

-- helper function to read inotify structs as table from inotify fd TODO switch to ffi metatype
function S.inotify_read(fd, buffer, len)
  if not len then len = 1024 end
  if not buffer then buffer = t.buffer(len) end
  local ret, err = S.read(fd, buffer, len)
  if not ret then return nil, err end
  local off, ee = 0, {}
  while off < ret do
    local ev = pt.inotify_event(buffer + off)
    local le = setmetatable({wd = tonumber(ev.wd), mask = tonumber(ev.mask), cookie = tonumber(ev.cookie)}, mt.inotify)
    if ev.len > 0 then le.name = ffi.string(ev.name) end
    ee[#ee + 1] = le
    off = off + ffi.sizeof(t.inotify_event(ev.len))
  end
  return ee
end

function S.sendfile(out_fd, in_fd, offset, count) -- bit odd having two different return types...
  if not offset then return retnum(C.sendfile(getfd(out_fd), getfd(in_fd), nil, count)) end
  local off = t.off1()
  off[0] = offset
  local ret = C.sendfile(getfd(out_fd), getfd(in_fd), off, count)
  if ret == -1 then return nil, t.error() end
  return {count = tonumber(ret), offset = tonumber(off[0])}
end

function S.eventfd(initval, flags) return retfd(C.eventfd(initval or 0, S.EFD[flags])) end
-- eventfd read and write helpers, as in glibc but Lua friendly. Note returns 0 for EAGAIN, as 0 never returned directly
-- returns Lua number - if you need all 64 bits, pass your own value in and use that for the exact result
function S.eventfd_read(fd, value)
  if not value then value = t.uint64_1() end
  local ret = C.read(getfd(fd), value, 8)
  if ret == -1 and ffi.errno() == S.E.EAGAIN then
    value[0] = 0
    return 0
  end
  if ret == -1 then return nil, t.error() end
  return tonumber(value[0])
end
function S.eventfd_write(fd, value)
  if not value then value = 1 end
  if type(value) == "number" then value = t.uint64_1(value) end
  return retbool(C.write(getfd(fd), value, 8))
end

function S.signalfd_read(fd, ss)
  ss = istype(t.siginfos, ss) or t.siginfos(ss or 8)
  local ret, err = S.read(fd, ss.sfd, ss.bytes)
  if ret == 0 or (err and err.EAGAIN) then return {} end
  if not ret then return nil, err end
  ss.count = ret / s.signalfd_siginfo -- may not be full length
  return ss
end

function S.getitimer(which, value)
  if not value then value = t.itimerval() end
  local ret = C.getitimer(S.ITIMER[which], value)
  if ret == -1 then return nil, t.error() end
  return value
end

function S.setitimer(which, it)
  it = istype(t.itimerval, it) or t.itimerval(it)
  local oldtime = t.itimerval()
  local ret = C.setitimer(S.ITIMER[which], it, oldtime)
  if ret == -1 then return nil, t.error() end
  return oldtime
end

function S.timerfd_create(clockid, flags)
  return retfd(C.timerfd_create(S.CLOCK[clockid], S.TFD[flags]))
end

function S.timerfd_settime(fd, flags, it, oldtime)
  oldtime = oldtime or t.itimerspec()
  it = istype(t.itimerspec, it) or t.itimerspec(it)
  local ret = C.timerfd_settime(getfd(fd), S.TFD_TIMER[flags], it, oldtime)
  if ret == -1 then return nil, t.error() end
  return oldtime
end

function S.timerfd_gettime(fd, curr_value)
  if not curr_value then curr_value = t.itimerspec() end
  local ret = C.timerfd_gettime(getfd(fd), curr_value)
  if ret == -1 then return nil, t.error() end
  return curr_value
end

function S.timerfd_read(fd, buffer)
  if not buffer then buffer = t.uint64_1() end
  local ret, err = S.read(fd, buffer, 8)
  if not ret and err.EAGAIN then return 0 end -- will never actually return 0
  if not ret then return nil, err end
  return tonumber(buffer[0])
end

function S.pivot_root(new_root, put_old) return retbool(C.pivot_root(new_root, put_old)) end

-- aio functions
function S.io_setup(nr_events)
  local ctx = t.aio_context()
  local ret = C.io_setup(nr_events, ctx)
  if ret == -1 then return nil, t.error() end
  return ctx
end

function S.io_destroy(ctx)
  if ctx.ctx == 0 then return end
  local ret = retbool(C.io_destroy(ctx.ctx))
  ctx.ctx = 0
  return ret
end

-- TODO replace these functions with metatypes
local function getiocb(ioi, iocb)
  if not iocb then iocb = t.iocb() end
  iocb.aio_lio_opcode = S.IOCB_CMD[ioi.cmd]
  iocb.aio_data = ioi.data or 0
  iocb.aio_reqprio = ioi.reqprio or 0
  iocb.aio_fildes = getfd(ioi.fd)
  iocb.aio_buf = ffi.cast(t.int64, ioi.buf) -- TODO check, looks wrong
  iocb.aio_nbytes = ioi.nbytes
  iocb.aio_offset = ioi.offset
  if ioi.resfd then
    iocb.aio_flags = iocb.aio_flags + S.IOCB_FLAG_RESFD
    iocb.aio_resfd = getfd(ioi.resfd)
  end
  return iocb
end

local function getiocbs(iocb, nr)
  if type(iocb) == "table" then
    local io = iocb
    nr = #io
    iocb = t.iocb_ptrs(nr)
    local iocba = t.iocbs(nr)
    for i = 0, nr - 1 do
      local ioi = io[i + 1]
      iocb[i] = iocba + i
      getiocb(ioi, iocba[i])
    end
  end
  return iocb, nr
end

function S.io_cancel(ctx, iocb, result)
  iocb = getiocb(iocb)
  if not result then result = t.io_event() end
  local ret = C.io_cancel(ctx.ctx, iocb, result)
  if ret == -1 then return nil, t.error() end
  return ret
end

function S.io_getevents(ctx, min, nr, events, timeout)
  events = events or t.io_events(nr)
  timeout = istype(t.timespec, timeout) or t.timespec(timeout)
  local ret = C.io_getevents(ctx.ctx, min, nr, events, timeout)
  if ret == -1 then return nil, t.error() end
  -- need to think more about how to return these, eg metatype for io_event?
  local r = {}
  for i = 0, nr - 1 do
    r[i + 1] = events[i]
  end
  r.timeout = timeout
  r.events = events
  r.count = tonumber(ret)
  return r
end

function S.io_submit(ctx, iocb, nr) -- takes an array of pointers to iocb. note order of args TODO redo like iov so no nr
  iocb, nr = getiocbs(iocb)
  return retnum(C.io_submit(ctx.ctx, iocb, nr))
end

-- map for valid options for arg2
local prctlmap = {
  [S.PR.CAPBSET_READ] = S.CAP,
  [S.PR.CAPBSET_DROP] = S.CAP,
  [S.PR.SET_ENDIAN] = S.PR_ENDIAN,
  [S.PR.SET_FPEMU] = S.PR_FPEMU,
  [S.PR.SET_FPEXC] = S.PR_FP_EXC,
  [S.PR.SET_PDEATHSIG] = S.SIG,
  --[S.PR.SET_SECUREBITS] = S.SECBIT, -- TODO not defined yet
  [S.PR.SET_TIMING] = S.PR_TIMING,
  [S.PR.SET_TSC] = S.PR_TSC,
  [S.PR.SET_UNALIGN] = S.PR_UNALIGN,
  [S.PR.MCE_KILL] = S.PR_MCE_KILL,
  [S.PR.SET_SECCOMP] = S.SECCOMP_MODE,
}

local prctlrint = { -- returns an integer directly TODO add metatables to set names
  [S.PR.GET_DUMPABLE] = true,
  [S.PR.GET_KEEPCAPS] = true,
  [S.PR.CAPBSET_READ] = true,
  [S.PR.GET_TIMING] = true,
  [S.PR.GET_SECUREBITS] = true,
  [S.PR.MCE_KILL_GET] = true,
  [S.PR.GET_SECCOMP] = true,
}

local prctlpint = { -- returns result in a location pointed to by arg2
  [S.PR.GET_ENDIAN] = true,
  [S.PR.GET_FPEMU] = true,
  [S.PR.GET_FPEXC] = true,
  [S.PR.GET_PDEATHSIG] = true,
  [S.PR.GET_UNALIGN] = true,
}

function S.prctl(option, arg2, arg3, arg4, arg5)
  local i, name
  option = S.PR[option]
  local m = prctlmap[option]
  if m then arg2 = m[arg2] end
  if option == S.PR.MCE_KILL and arg2 == S.PR.MCE_KILL_SET then arg3 = S.PR_MCE_KILL_OPT[arg3]
  elseif prctlpint[option] then
    i = t.int1()
    arg2 = ffi.cast(t.ulong, i)
  elseif option == S.PR.GET_NAME then
    name = t.buffer(16)
    arg2 = ffi.cast(t.ulong, name)
  elseif option == S.PR.SET_NAME then
    if type(arg2) == "string" then arg2 = ffi.cast(t.ulong, arg2) end
  end
  local ret = C.prctl(option, arg2 or 0, arg3 or 0, arg4 or 0, arg5 or 0)
  if ret == -1 then return nil, t.error() end
  if prctlrint[option] then return ret end
  if prctlpint[option] then return i[0] end
  if option == S.PR.GET_NAME then
    if name[15] ~= 0 then return ffi.string(name, 16) end -- actually, 15 bytes seems to be longest, aways 0 terminated
    return ffi.string(name)
  end
  return true
end

-- this is the glibc name for the syslog syscall
function S.klogctl(tp, buf, len)
  if not buf and (tp == 2 or tp == 3 or tp == 4) then
    if not len then
      len = C.klogctl(10, nil, 0) -- get size so we can allocate buffer
      if len == -1 then return nil, t.error() end
    end
    buf = t.buffer(len)
  end
  local ret = C.klogctl(tp, buf or nil, len or 0)
  if ret == -1 then return nil, t.error() end
  if tp == 9 or tp == 10 then return tonumber(ret) end
  if tp == 2 or tp == 3 or tp == 4 then return ffi.string(buf, ret) end
  return true
end

function S.adjtimex(a)
  if not a then a = t.timex() end
  if type(a) == 'table' then  -- TODO pull this out to general initialiser for t.timex
    if a.modes then a.modes = tonumber(S.ADJ[a.modes]) end
    if a.status then a.status = tonumber(S.STA[a.status]) end
    a = t.timex(a)
  end
  local ret = C.adjtimex(a)
  if ret == -1 then return nil, t.error() end
  -- we need to return a table, as we need to return both ret and the struct timex. should probably put timex fields in table
  return setmetatable({state = ret, timex = a}, mt.timex)
end

function S.clock_getres(clk_id, ts)
  ts = istype(t.timespec, ts) or t.timespec(ts)
  local ret = C.clock_getres(S.CLOCK[clk_id], ts)
  if ret == -1 then return nil, t.error() end
  return ts
end

function S.clock_gettime(clk_id, ts)
  ts = istype(t.timespec, ts) or t.timespec(ts)
  local ret = C.clock_gettime(S.CLOCK[clk_id], ts)
  if ret == -1 then return nil, t.error() end
  return ts
end

function S.clock_settime(clk_id, ts)
  ts = istype(t.timespec, ts) or t.timespec(ts)
  return retbool(C.clock_settime(S.CLOCK[clk_id], ts))
end

function S.clock_nanosleep(clk_id, flags, req, rem)
  req = istype(t.timespec, req) or t.timespec(req)
  rem = rem or t.timespec()
  local ret = C.clock_nanosleep(S.CLOCK[clk_id], S.TIMER[flags], req, rem)
  if ret == -1 then
    if ffi.errno() == S.E.INTR then return rem else return nil, t.error() end
  end
  return true
end

-- straight passthroughs, no failure possible, still wrap to allow mocking
function S.getuid() return C.getuid() end
function S.geteuid() return C.geteuid() end
function S.getppid() return C.getppid() end
function S.getgid() return C.getgid() end
function S.getegid() return C.getegid() end
function S.sync() return C.sync() end
function S.alarm(s) return C.alarm(s) end

function S.getpid() return C.getpid() end -- note this will use syscall as overridden above

function S.setuid(uid) return retbool(C.setuid(uid)) end
function S.setgid(gid) return retbool(C.setgid(gid)) end
function S.seteuid(uid) return retbool(C.seteuid(uid)) end
function S.setegid(gid) return retbool(C.setegid(gid)) end
function S.setreuid(ruid, euid) return retbool(C.setreuid(ruid, euid)) end
function S.setregid(rgid, egid) return retbool(C.setregid(rgid, egid)) end

function S.getresuid()
  local ruid, euid, suid = t.uid1(), t.uid1(), t.uid1()
  local ret = C.getresuid(ruid, euid, suid)
  if ret == -1 then return nil, t.error() end
  return {ruid = ruid[0], euid = euid[0], suid = suid[0]}
end
function S.getresgid()
  local rgid, egid, sgid = t.gid1(), t.gid1(), t.gid1()
  local ret = C.getresgid(rgid, egid, sgid)
  if ret == -1 then return nil, t.error() end
  return {rgid = rgid[0], egid = egid[0], sgid = sgid[0]}
end
function S.setresuid(ruid, euid, suid)
  if type(ruid) == "table" then
    local t = ruid
    ruid = t.ruid
    euid = t.euid
    suid = t.suid
  end
  return retbool(C.setresuid(ruid, euid, suid))
end
function S.setresgid(rgid, egid, sgid)
  if type(rgid) == "table" then
    local t = rgid
    rgid = t.rgid
    egid = t.egid
    sgid = t.sgid
  end
  return retbool(C.setresgid(rgid, egid, sgid))
end

t.groups = ffi.metatype("struct {int count; gid_t list[?];}", {
  __index = function(g, k)
    return g.list[k - 1]
  end,
  __newindex = function(g, k, v)
    g.list[k - 1] = v
  end,
  __new = function(tp, gs)
    if type(gs) == 'number' then return ffi.new(tp, gs, gs) end
    return ffi.new(tp, #gs, #gs, gs)
  end,
  __len = function(g) return g.count end,
})

function S.getgroups()
  local size = C.getgroups(0, nil)
  if size == -1 then return nil, t.error() end
  local groups = t.groups(size)
  local ret = C.getgroups(size, groups.list)
  if ret == -1 then return nil, t.error() end
  return groups
end

function S.setgroups(groups)
  if type(groups) == "table" then groups = t.groups(groups) end
  return retbool(C.setgroups(groups.count, groups.list))
end

function S.umask(mask) return C.umask(S.MODE[mask]) end

function S.getsid(pid) return retnum(C.getsid(pid or 0)) end
function S.setsid() return retnum(C.setsid()) end

-- handle environment (Lua only provides os.getenv). TODO add metatable to make more Lualike.
function S.environ() -- return whole environment as table
  local environ = ffi.C.environ
  if not environ then return nil end
  local r = {}
  local i = 0
  while environ[i] ~= zeropointer do
    local e = ffi.string(environ[i])
    local eq = e:find('=')
    if eq then
      r[e:sub(1, eq - 1)] = e:sub(eq + 1)
    end
    i = i + 1
  end
  return r
end

function S.getenv(name)
  return S.environ()[name]
end
function S.unsetenv(name) return retbool(C.unsetenv(name)) end
function S.setenv(name, value, overwrite)
  if type(overwrite) == 'boolean' and overwrite then overwrite = 1 end
  return retbool(C.setenv(name, value, overwrite or 0))
end
function S.clearenv() return retbool(C.clearenv()) end

-- 'macros' and helper functions etc
-- TODO from here (approx, some may be in wrong place), move to util library. These are library functions.

function S.major(dev)
  local h, l = S.i64(dev)
  return bit.bor(bit.band(bit.rshift(l, 8), 0xfff), bit.band(h, bit.bnot(0xfff)));
end

function S.minor(dev)
  local h, l = S.i64(dev)
  return bit.bor(bit.band(l, 0xff), bit.band(bit.rshift(l, 12), bit.bnot(0xff)));
end

function S.makedev(major, minor)
  return bit.bor(bit.band(minor, 0xff), bit.lshift(bit.band(major, 0xfff), 8), bit.lshift(bit.band(minor, bit.bnot(0xff)), 12)) + 0x100000000 * bit.band(major, bit.bnot(0xfff))
end

-- cmsg functions, try to hide some of this nasty stuff from the user
local function align(len, a) return bit.band(tonumber(len) + a - 1, bit.bnot(a - 1)) end

local cmsg_align
local cmsg_hdrsize = ffi.sizeof(t.cmsghdr(0))
if ffi.abi('32bit') then
  function cmsg_align(len) return align(len, 4) end
else
  function cmsg_align(len) return align(len, 8) end
end

local cmsg_ahdr = cmsg_align(cmsg_hdrsize)
local function cmsg_space(len) return cmsg_ahdr + cmsg_align(len) end
local function cmsg_len(len) return cmsg_ahdr + len end

-- msg_control is a bunch of cmsg structs, but these are all different lengths, as they have variable size arrays

-- these functions also take and return a raw char pointer to msg_control, to make life easier, as well as the cast cmsg
local function cmsg_firsthdr(msg)
  if tonumber(msg.msg_controllen) < cmsg_hdrsize then return nil end
  local mc = msg.msg_control
  local cmsg = pt.cmsghdr(mc)
  return mc, cmsg
end

local function cmsg_nxthdr(msg, buf, cmsg)
  if tonumber(cmsg.cmsg_len) < cmsg_hdrsize then return nil end -- invalid cmsg
  buf = pt.char(buf)
  local msg_control = pt.char(msg.msg_control)
  buf = buf + cmsg_align(cmsg.cmsg_len) -- find next cmsg
  if buf + cmsg_hdrsize > msg_control + msg.msg_controllen then return nil end -- header would not fit
  cmsg = pt.cmsghdr(buf)
  if buf + cmsg_align(cmsg.cmsg_len) > msg_control + msg.msg_controllen then return nil end -- whole cmsg would not fit
  return buf, cmsg
end

-- if no msg provided, assume want to receive cmsg
function S.recvmsg(fd, msg, flags)
  if not msg then 
    local buf1 = t.buffer(1) -- assume user wants to receive single byte to get cmsg
    local io = t.iovecs{{buf1, 1}}
    local bufsize = 1024 -- sane default, build your own structure otherwise
    local buf = t.buffer(bufsize)
    msg = t.msghdr{msg_iov = io.iov, msg_iovlen = #io, msg_control = buf, msg_controllen = bufsize}
  end
  local ret = C.recvmsg(getfd(fd), msg, S.MSG[flags])
  if ret == -1 then return nil, t.error() end
  local ret = {count = ret, iovec = msg.msg_iov} -- thats the basic return value, and the iovec
  local mc, cmsg = cmsg_firsthdr(msg)
  while cmsg do
    if cmsg.cmsg_level == S.SOL.SOCKET then
      if cmsg.cmsg_type == S.SCM.CREDENTIALS then
        local cred = pt.ucred(cmsg + 1) -- cmsg_data
        ret.pid = cred.pid
        ret.uid = cred.uid
        ret.gid = cred.gid
      elseif cmsg.cmsg_type == S.SCM.RIGHTS then
        local fda = pt.int(cmsg + 1) -- cmsg_data
        local fdc = div(tonumber(cmsg.cmsg_len) - cmsg_ahdr, s.int)
        ret.fd = {}
        for i = 1, fdc do ret.fd[i] = t.fd(fda[i - 1]) end
      end -- add other SOL.SOCKET messages
    end -- add other processing for different types
    mc, cmsg = cmsg_nxthdr(msg, mc, cmsg)
  end
  return ret
end

-- helper functions
function S.sendcred(fd, pid, uid, gid) -- only needed for root to send incorrect credentials?
  if not pid then pid = C.getpid() end
  if not uid then uid = C.getuid() end
  if not gid then gid = C.getgid() end
  local ucred = t.ucred()
  ucred.pid = pid
  ucred.uid = uid
  ucred.gid = gid
  local buf1 = t.buffer(1) -- need to send one byte
  local io = t.iovecs{{buf1, 1}}
  local bufsize = cmsg_space(s.ucred)
  local buflen = cmsg_len(s.ucred)
  local buf = t.buffer(bufsize) -- this is our cmsg buffer
  local msg = t.msghdr() -- assume socket connected and so does not need address
  msg.msg_iov = io.iov
  msg.msg_iovlen = #io
  msg.msg_control = buf
  msg.msg_controllen = bufsize
  local mc, cmsg = cmsg_firsthdr(msg)
  cmsg.cmsg_level = S.SOL.SOCKET
  cmsg.cmsg_type = S.SCM.CREDENTIALS
  cmsg.cmsg_len = buflen
  ffi.copy(cmsg.cmsg_data, ucred, s.ucred)
  msg.msg_controllen = cmsg.cmsg_len -- set to sum of all controllens
  return S.sendmsg(fd, msg, 0)
end

function S.sendfds(fd, ...)
  local buf1 = t.buffer(1) -- need to send one byte
  local io = t.iovecs{{buf1, 1}}
  local fds = {}
  for i, v in ipairs{...} do fds[i] = getfd(v) end
  local fa = t.ints(#fds, fds)
  local fasize = ffi.sizeof(fa)
  local bufsize = cmsg_space(fasize)
  local buflen = cmsg_len(fasize)
  local buf = t.buffer(bufsize) -- this is our cmsg buffer
  local msg = t.msghdr() -- assume socket connected and so does not need address
  msg.msg_iov = io.iov
  msg.msg_iovlen = #io
  msg.msg_control = buf
  msg.msg_controllen = bufsize
  local mc, cmsg = cmsg_firsthdr(msg)
  cmsg.cmsg_level = S.SOL.SOCKET
  cmsg.cmsg_type = S.SCM.RIGHTS
  cmsg.cmsg_len = buflen -- could set from a constructor
  ffi.copy(cmsg + 1, fa, fasize) -- cmsg_data
  msg.msg_controllen = cmsg.cmsg_len -- set to sum of all controllens
  return S.sendmsg(fd, msg, 0)
end

function S.nonblock(fd)
  local fl, err = S.fcntl(fd, S.F.GETFL)
  if not fl then return nil, err end
  fl, err = S.fcntl(fd, S.F.SETFL, bit.bor(fl, S.O.NONBLOCK))
  if not fl then return nil, err end
  return true
end

function S.block(fd)
  local fl, err = S.fcntl(fd, S.F.GETFL)
  if not fl then return nil, err end
  fl, err = S.fcntl(fd, S.F.SETFL, bit.band(fl, bit.bnot(S.O.NONBLOCK)))
  if not fl then return nil, err end
  return true
end

-- TODO fix short reads, add a loop
function S.readfile(name, buffer, length) -- convenience for reading short files into strings, eg for /proc etc, silently ignores short reads
  local f, err = S.open(name, "rdonly")
  if not f then return nil, err end
  local r, err = f:read(buffer, length or 4096)
  if not r then return nil, err end
  local ok, err = f:close()
  if not ok then return nil, err end
  return r
end

function S.writefile(name, str, mode) -- write string to named file. specify mode if want to create file, silently ignore short writes
  local f, err
  if mode then f, err = S.creat(name, mode) else f, err = S.open(name, "wronly") end
  if not f then return nil, err end
  local n, err = f:write(str)
  if not n then return nil, err end
  local ok, err = f:close()
  if not ok then return nil, err end
  return true
end

function S.dirfile(name, nodots) -- return the directory entries in a file, remove . and .. if nodots true
  local fd, d, ok, err
  fd, err = S.open(name, "directory, rdonly")
  if err then return nil, err end
  d, err = fd:getdents()
  if err then return nil, err end
  if nodots then
    d["."] = nil
    d[".."] = nil
  end
  ok, err = fd:close()
  if not ok then return nil, err end
  return d
end

mt.ls = {
  __tostring = function(t)
    table.sort(t)
    return table.concat(t, "\n")
    end
}

function S.ls(name, nodots) -- return just the list, no other data, cwd if no directory specified
  if not name then name = S.getcwd() end
  local ds = S.dirfile(name, nodots)
  local l = {}
  for k, _ in pairs(ds) do l[#l + 1] = k end
  return setmetatable(l, mt.ls)
end

local function if_nametoindex(name, s) -- internal version when already have socket for ioctl
  local ifr = t.ifreq()
  local len = #name + 1
  if len > IFNAMSIZ then len = IFNAMSIZ end
  ffi.copy(ifr.ifr_ifrn.ifrn_name, name, len)
  local ret, err = S.ioctl(s, S.SIOCGIFINDEX, ifr)
  if not ret then return nil, err end
  return ifr.ifr_ifru.ifru_ivalue
end

function S.if_nametoindex(name) -- standard function in some libc versions
  local s, err = S.socket(S.AF.LOCAL, S.SOCK.STREAM, 0)
  if not s then return nil, err end
  local i, err = if_nametoindex(name, s)
  if not i then return nil, err end
  local ok, err = s:close()
  if not ok then return nil, err end
  return i
end

-- bridge functions, could be in utility library. in error cases use gc to close file.
local function bridge_ioctl(io, name)
  local s, err = S.socket(S.AF.LOCAL, S.SOCK.STREAM, 0)
  if not s then return nil, err end
  local ret, err = S.ioctl(s, io, pt.char(name))
  if not ret then return nil, err end
  local ok, err = s:close()
  if not ok then return nil, err end
  return true
end

function S.bridge_add(name) return bridge_ioctl(S.SIOCBRADDBR, name) end
function S.bridge_del(name) return bridge_ioctl(S.SIOCBRDELBR, name) end

local function bridge_if_ioctl(io, bridge, dev)
  local err, s, ifr, len, ret, ok
  s, err = S.socket(S.AF.LOCAL, S.SOCK.STREAM, 0)
  if not s then return nil, err end
  if type(dev) == "string" then
    dev, err = if_nametoindex(dev, s)
    if not dev then return nil, err end
  end
  ifr = t.ifreq()
  len = #bridge + 1
  if len > IFNAMSIZ then len = IFNAMSIZ end
  ffi.copy(ifr.ifr_ifrn.ifrn_name, bridge, len) -- note not using the short forms as no metatable defined yet...
  ifr.ifr_ifru.ifru_ivalue = dev
  ret, err = S.ioctl(s, io, ifr);
  if not ret then return nil, err end
  ok, err = s:close()
  if not ok then return nil, err end
  return true
end

function S.bridge_add_interface(bridge, dev) return bridge_if_ioctl(S.SIOCBRADDIF, bridge, dev) end
function S.bridge_add_interface(bridge, dev) return bridge_if_ioctl(S.SIOCBRDELIF, bridge, dev) end

-- should probably have constant for "/sys/class/net"

local function brinfo(d) -- can be used as subpart of general interface info
  local bd = "/sys/class/net/" .. d .. "/" .. S.SYSFS_BRIDGE_ATTR
  if not S.stat(bd) then return nil end
  local bridge = {}
  local fs = S.dirfile(bd, true)
  if not fs then return nil end
  for f, _ in pairs(fs) do
    local s = S.readfile(bd .. "/" .. f)
    if s then
      s = s:sub(1, #s - 1) -- remove newline at end
      if f == "group_addr" or f == "root_id" or f == "bridge_id" then -- string values
        bridge[f] = s
      elseif f == "stp_state" then -- bool
        bridge[f] = s == 1
      else
        bridge[f] = tonumber(s) -- not quite correct, most are timevals TODO
      end
    end
  end

  local brif, err = S.ls("/sys/class/net/" .. d .. "/" .. S.SYSFS_BRIDGE_PORT_SUBDIR, true)
  if not brif then return nil end

  local fdb = "/sys/class/net/" .. d .. "/" .. S.SYSFS_BRIDGE_FDB
  if not S.stat(fdb) then return nil end
  local sl = 2048
  local buffer = t.buffer(sl)
  local fd = S.open(fdb, "rdonly")
  if not fd then return nil end
  local brforward = {}

  repeat
    local n = fd:read(buffer, sl)
    if not n then return nil end

    local fdbs = pt.fdb_entry(buffer)

    for i = 1, n / s.fdb_entry do
      local fdb = fdbs[i - 1]
      local mac = t.macaddr()
      ffi.copy(mac, fdb.mac_addr, IFHWADDRLEN)

      -- TODO ageing_timer_value is not an int, time, float
      brforward[#brforward + 1] = {
        mac_addr = mac, port_no = tonumber(fdb.port_no),
        is_local = fdb.is_local ~= 0,
        ageing_timer_value = tonumber(fdb.ageing_timer_value)
      }
    end

  until n == 0
  if not fd:close() then return nil end

  return {bridge = bridge, brif = brif, brforward = brforward}
end

function S.bridge_list()
  local dir, err = S.dirfile("/sys/class/net", true)
  if not dir then return nil, err end
  local b = {}
  for d, _ in pairs(dir) do
    b[d] = brinfo(d)
  end
  return b
end

mt.proc = {
  __index = function(p, k)
    local name = p.dir .. k
    local st, err = S.lstat(name)
    if not st then return nil, err end
    if st.isreg then
      local fd, err = S.open(p.dir .. k, "rdonly")
      if not fd then return nil, err end
      local ret, err = fd:read() -- read defaults to 4k, sufficient?
      if not ret then return nil, err end
      fd:close()
      return ret -- TODO many could usefully do with some parsing
    end
    if st.islnk then
      local ret, err = S.readlink(name)
      if not ret then return nil, err end
      return ret
    end
    -- TODO directories
  end,
  __tostring = function(p) -- TODO decide what to print
    local c = p.cmdline
    if c then
      if #c == 0 then
        local comm = p.comm
        if comm and #comm > 0 then
          c = '[' .. comm:sub(1, -2) .. ']'
        end
      end
      return p.pid .. '  ' .. c
    end
  end
}

function S.proc(pid)
  if not pid then pid = S.getpid() end
  return setmetatable({pid = pid, dir = "/proc/" .. pid .. "/"}, mt.proc)
end

mt.ps = {
  __tostring = function(ps)
    local s = {}
    for i = 1, #ps do
      s[#s + 1] = tostring(ps[i])
    end
    return table.concat(s, '\n')
  end
}

function S.ps()
  local ls, err = S.ls("/proc")
  if not ls then return nil, err end
  local ps = {}
  for i = 1, #ls do
    if not string.match(ls[i], '[^%d]') then
      local p = S.proc(tonumber(ls[i]))
      if p then ps[#ps + 1] = p end
    end
  end
  table.sort(ps, function(a, b) return a.pid < b.pid end)
  return setmetatable(ps, mt.ps)
end

function S.mounts(file)
  local mf, err = S.readfile(file or "/proc/mounts")
  if not mf then return nil, err end
  local mounts = {}
  for line in mf:gmatch("[^\r\n]+") do
    local l = {}
    local parts = {"source", "target", "type", "flags", "freq", "passno"}
    local p = 1
    for word in line:gmatch("%S+") do
      l[parts[p]] = word
      p = p + 1
    end
    mounts[#mounts + 1] = l
  end
  -- TODO some of the options you get in /proc/mounts are file system specific and should be moved to l.data
  -- idea is you can round-trip this data
  -- a lot of the fs specific options are key=value so easier to recognise
  return mounts
end

-- these functions are all just ioctls can do natively
function S.cfmakeraw(termios)
  C.cfmakeraw(termios)
  return true
end

function S.cfgetispeed(termios)
  local bits = C.cfgetispeed(termios)
  if bits == -1 then return nil, t.error() end
  return S.bits_to_speed(bits)
end

function S.cfgetospeed(termios)
  local bits = C.cfgetospeed(termios)
  if bits == -1 then return nil, t.error() end
  return S.bits_to_speed(bits)
end

function S.cfsetispeed(termios, speed)
  return retbool(C.cfsetispeed(termios, S.speed_to_bits(speed)))
end

function S.cfsetospeed(termios, speed)
  return retbool(C.cfsetospeed(termios, S.speed_to_bits(speed)))
end

function S.cfsetspeed(termios, speed)
  return retbool(C.cfsetspeed(termios, S.speed_to_bits(speed)))
end

t.termios = ffi.metatype("struct termios", {
  __index = {
    cfmakeraw = S.cfmakeraw,
    cfgetispeed = S.cfgetispeed,
    cfgetospeed = S.cfgetospeed,
    cfsetispeed = S.cfsetispeed,
    cfsetospeed = S.cfsetospeed,
    cfsetspeed = S.cfsetspeed
  }
})

function S.tcgetattr(fd)
  local termios = t.termios()
  local ret = C.tcgetattr(getfd(fd), termios)
  if ret == -1 then return nil, t.error() end
  return termios
end

function S.isatty(fd)
  local tc = S.tcgetattr(fd)
  if tc then return true else return false end
end

function S.tcsetattr(fd, optional_actions, termios)
  return retbool(C.tcsetattr(getfd(fd), S.TCSA[optional_actions], termios))
end

function S.tcsendbreak(fd, duration)
  return retbool(C.tcsendbreak(getfd(fd), duration))
end

function S.tcdrain(fd)
  return retbool(C.tcdrain(getfd(fd)))
end

function S.tcflush(fd, queue_selector)
  return retbool(C.tcflush(getfd(fd), S.TCFLUSH[queue_selector]))
end

function S.tcflow(fd, action)
  return retbool(C.tcflow(getfd(fd), S.TCFLOW[action]))
end

function S.tcgetsid(fd)
  return retnum(C.tcgetsid(getfd(fd)))
end

function S.posix_openpt(flags)
  return S.open("/dev/ptmx", flags);
end

function S.grantpt(fd) -- I don't think we need to do anything here (eg Musl libc does not)
  return true
end

function S.unlockpt(fd)
  local unlock = t.int1()
  local ret, err = S.ioctl(fd, S.TIOCSPTLCK, pt.void(unlock)) -- TODO make sure this returns true instead?
  if not ret then return nil, err end
  return true
end

function S.ptsname(fd)
  local pts = t.int1()
  local ret, error = S.ioctl(fd, S.TIOCGPTN, pt.void(pts))
  if not ret then return nil, err end
  return "/dev/pts/" .. tostring(pts[0])
end

function S.vhangup() return retbool(C.vhangup()) end

-- Nixio compatibility to make porting easier, and useful functions (often man 3). Incomplete.
function S.setblocking(s, b) if b then return s:block() else return s:nonblock() end end
function S.tell(fd) return fd:lseek(0, S.SEEK.CUR) end

function S.lockf(fd, cmd, len)
  cmd = S.LOCKF[cmd]
  if cmd == S.LOCKF.LOCK then
    return S.fcntl(fd, S.F.SETLKW, {l_type = S.FCNTL_LOCK.WRLCK, l_whence = S.SEEK.CUR, l_start = 0, l_len = len})
  elseif cmd == S.LOCKF.TLOCK then
    return S.fcntl(fd, S.F.SETLK, {l_type = S.FCNTL_LOCK.WRLCK, l_whence = S.SEEK.CUR, l_start = 0, l_len = len})
  elseif cmd == S.LOCKF.ULOCK then
    return S.fcntl(fd, S.F.SETLK, {l_type = S.FCNTL_LOCK.UNLCK, l_whence = S.SEEK.CUR, l_start = 0, l_len = len})
  elseif cmd == S.LOCKF.TEST then
    local ret, err = S.fcntl(fd, S.F.GETLK, {l_type = S.FCNTL_LOCK.WRLCK, l_whence = S.SEEK.CUR, l_start = 0, l_len = len})
    if not ret then return nil, err end
    return ret.l_type == S.FCNTL_LOCK.UNLCK
  end
end

-- constants TODO move to table
S.INADDR_ANY = t.in_addr()
S.INADDR_LOOPBACK = t.in_addr("127.0.0.1")
S.INADDR_BROADCAST = t.in_addr("255.255.255.255")
-- ipv6 versions
S.in6addr_any = t.in6_addr()
S.in6addr_loopback = t.in6_addr("::1")

-- methods on an fd
-- note could split, so a socket does not have methods only appropriate for a file
local fdmethods = {'nogc', 'nonblock', 'block', 'setblocking', 'sendfds', 'sendcred',
                   'close', 'dup', 'read', 'write', 'pread', 'pwrite', 'tell', 'lockf',
                   'lseek', 'fchdir', 'fsync', 'fdatasync', 'fstat', 'fcntl', 'fchmod',
                   'bind', 'listen', 'connect', 'accept', 'getsockname', 'getpeername',
                   'send', 'sendto', 'recv', 'recvfrom', 'readv', 'writev', 'sendmsg',
                   'recvmsg', 'setsockopt', 'epoll_ctl', 'epoll_wait', 'sendfile', 'getdents',
                   'eventfd_read', 'eventfd_write', 'ftruncate', 'shutdown', 'getsockopt',
                   'inotify_add_watch', 'inotify_rm_watch', 'inotify_read', 'flistxattr',
                   'fsetxattr', 'fgetxattr', 'fremovexattr', 'fxattr', 'splice', 'vmsplice', 'tee',
                   'signalfd_read', 'timerfd_gettime', 'timerfd_settime', 'timerfd_read',
                   'fadvise', 'fallocate', 'posix_fallocate', 'readahead',
                   'tcgetattr', 'tcsetattr', 'tcsendbreak', 'tcdrain', 'tcflush', 'tcflow', 'tcgetsid',
                   'grantpt', 'unlockpt', 'ptsname', 'sync_file_range', 'fstatfs', 'futimens',
                   'fstatat', 'unlinkat', 'mkdirat', 'mknodat', 'faccessat', 'fchmodat', 'fchown',
                   'fchownat', 'readlinkat', 'mkfifoat', 'isatty', 'setns', 'openat',
                   'preadv', 'pwritev'
                   }
local fmeth = {}
for _, v in ipairs(fdmethods) do fmeth[v] = S[v] end

-- allow calling without leading f
fmeth.stat = S.fstat
fmeth.chdir = S.fchdir
fmeth.sync = S.fsync
fmeth.datasync = S.fdatasync
fmeth.chmod = S.fchmod
fmeth.setxattr = S.fsetxattr
fmeth.getxattr = S.gsetxattr
fmeth.truncate = S.ftruncate
fmeth.statfs = S.fstatfs
fmeth.utimens = S.futimens
fmeth.utime = S.futimens
fmeth.seek = S.lseek
fmeth.lock = S.lockf
fmeth.chown = S.fchown

-- sequence number used by netlink messages
fmeth.seq = function(fd)
  fd.sequence = fd.sequence + 1
  return fd.sequence
end

fmeth.getfd = function(fd) return fd.filenum end

t.fd = ffi.metatype("struct {int filenum; int sequence;}", {
  __index = fmeth,
  __gc = S.close,
  __new = function(tp, i)
    return istype(tp, i) or ffi.new(tp, i)
  end
})

-- TODO note a new fd implementation would have to redefine as these set at init time. Document or fix.
S.stdin = t.fd(S.STD.IN):nogc()
S.stdout = t.fd(S.STD.OUT):nogc()
S.stderr = t.fd(S.STD.ERR):nogc()

t.aio_context = ffi.metatype("struct {aio_context_t ctx;}", {
  __index = {destroy = S.io_destroy, submit = S.io_submit, getevents = S.io_getevents, cancel = S.io_cancel, nogc = S.nogc},
  __gc = S.io_destroy
})

return S

end

return syscall()


