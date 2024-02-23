const c = @import("c.zig");
const cc = @import("cc.zig");
const log = @import("log.zig");
const net = @import("net.zig");
const co = @import("co.zig");
const Rc = @import("Rc.zig");
const g = @import("g.zig");
const root = @import("root");
const std = @import("std");
const trait = std.meta.trait;
const assert = std.debug.assert;

const EvLoop = @This();

/// epoll instance (fd)
epfd: c_int,

/// avoid touching freed ptr, see evloop.run()
destroyed: std.AutoHashMapUnmanaged(*const Fd, void) = .{},

/// cache fd's add/del operation (reducing epoll_ctl calls)
change_list: std.AutoHashMapUnmanaged(*const Fd, Change.Set) = .{},

// =============================================================

const Change = opaque {
    pub const T = u8;

    pub const ADD_READ: T = 1 << 0;
    pub const DEL_READ: T = 1 << 1;
    pub const ADD_WRITE: T = 1 << 2;
    pub const DEL_WRITE: T = 1 << 3;

    /// wrapper for T
    pub const Set = struct {
        set: T = 0,

        pub fn is_empty(self: Set) bool {
            return self.set == 0;
        }

        /// has all
        pub fn has(self: Set, v: T) bool {
            return self.set & v == v;
        }

        pub fn has_any(self: Set, v: T) bool {
            return self.set & v != 0;
        }

        pub fn del(self: *Set, v: T) void {
            self.set &= ~v;
        }

        pub fn add(self: *Set, v: T) void {
            self.set |= v;

            if (self.has(ADD_READ | DEL_READ))
                self.del(ADD_READ | DEL_READ);

            if (self.has(ADD_WRITE | DEL_WRITE))
                self.del(ADD_WRITE | DEL_WRITE);
        }

        pub fn equal(self: Set, events: u32) bool {
            if (self.has_any(DEL_READ | DEL_WRITE))
                return false;

            var my_events: u32 = 0;

            if (self.has(ADD_READ))
                my_events |= EVENTS.read;

            if (self.has(ADD_WRITE))
                my_events |= EVENTS.write;

            return my_events == events;
        }
    };
};

// =============================================================

/// wrap the raw fd to work with evloop
pub const Fd = struct {
    read_frame: ?anyframe = null, // waiting for readable event
    write_frame: ?anyframe = null, // waiting for writable event
    fd: c_int,
    rc: Rc = .{},

    /// ownership of `fd` is transferred to `fdobj`
    pub fn new(fd: c_int) *Fd {
        const self = g.allocator.create(Fd) catch unreachable;
        self.* = .{ .fd = fd };
        return self;
    }

    pub fn ref(self: *Fd) *Fd {
        self.rc.ref();
        return self;
    }

    pub const unref = free;

    pub fn free(self: *Fd) void {
        if (self.rc.unref() > 0) return;

        assert(self.read_frame == null);
        assert(self.write_frame == null);

        g.evloop.on_close_fd(self);
        _ = c.close(self.fd);

        g.allocator.destroy(self);

        // record to the destroyed list, see `evloop.run()`
        g.evloop.destroyed.put(g.allocator, self, {}) catch unreachable;
    }

    pub fn interest_events(self: *const Fd) u32 {
        var events: u32 = 0;

        if (self.read_frame != null)
            events |= EVENTS.read;

        if (self.write_frame != null)
            events |= EVENTS.write;

        return events;
    }
};

// =============================================================

/// epoll_event is a packed struct and need to be wrapped
const Ev = opaque {
    /// raw type
    pub const Raw = c.struct_epoll_event;

    pub const SIZE = @sizeOf(Raw);
    pub const ALIGN = @alignOf(Raw);

    /// value type
    pub const V = Array(1);

    /// array type
    pub fn Array(comptime N: comptime_int) type {
        // it is currently not possible to directly return an array type with the align attribute
        // https://github.com/ziglang/zig/issues/7465
        return struct {
            buf: [N * SIZE]u8 align(ALIGN),

            // ======================= for Array =======================

            const Self = @This();

            pub inline fn at(self: *Self, i: usize) *Ev {
                return from(&self.buf[i * SIZE]);
            }

            /// return N
            pub inline fn len(_: *const Self) usize {
                return N;
            }

            // ======================= for Value =======================

            pub inline fn init(events: u32, fdobj: *const Fd) V {
                var v: V = undefined;
                v.ptr().set_events(events);
                v.ptr().set_fdobj(fdobj);
                return v;
            }

            pub inline fn ptr(v: *V) *Ev {
                return v.at(0);
            }
        };
    }

    pub inline fn from(ptr: anytype) if (trait.isConstPtr(@TypeOf(ptr))) *const Ev else *Ev {
        return if (comptime trait.isConstPtr(@TypeOf(ptr)))
            @ptrCast(*const Ev, ptr)
        else
            @ptrCast(*Ev, ptr);
    }

    pub inline fn get_events(self: *const Ev) u32 {
        return c.epev_get_events(self);
    }

    pub inline fn get_fdobj(self: *const Ev) *Fd {
        return cc.ptrcast(*Fd, c.epev_get_ptrdata(self));
    }

    pub inline fn set_events(self: *Ev, events: u32) void {
        return c.epev_set_events(self, events);
    }

    pub inline fn set_fdobj(self: *Ev, fdobj: *const Fd) void {
        return c.epev_set_ptrdata(self, fdobj);
    }
};

// =============================================================

extern fn epoll_create1(flags: c_int) c_int;
extern fn epoll_ctl(epfd: c_int, op: c_int, fd: c_int, ev: ?*const anyopaque) c_int;
extern fn epoll_wait(epfd: c_int, evs: *anyopaque, n_evs: c_int, timeout: c_int) c_int;

// =============================================================

pub fn init() EvLoop {
    const epfd = epoll_create1(c.EPOLL_CLOEXEC);
    if (epfd < 0) {
        log.err(@src(), "failed to create epoll: (%d) %m", .{cc.errno()});
        c.exit(1);
    }
    return .{ .epfd = epfd };
}

/// return true if ok (internal api)
fn ctl(self: *EvLoop, op: c_int, fd: c_int, ev: ?*const Ev) bool {
    if (epoll_ctl(self.epfd, op, fd, ev) < 0) {
        const op_name = switch (op) {
            c.EPOLL_CTL_ADD => "ADD",
            c.EPOLL_CTL_MOD => "MOD",
            c.EPOLL_CTL_DEL => "DEL",
            else => unreachable,
        };
        const events = if (ev) |e| cc.to_ulong(e.get_events()) else 0;
        log.err(@src(), "epoll_ctl(%d, %s, %d, events:%lu) failed: (%d) %m", .{ self.epfd, op_name, fd, events, cc.errno() });
        return false;
    }
    return true;
}

/// return true if ok
fn add(self: *EvLoop, fdobj: *const Fd, events: u32) bool {
    return self.ctl(c.EPOLL_CTL_ADD, fdobj.fd, Ev.V.init(events, fdobj).ptr());
}

/// return true if ok
fn mod(self: *EvLoop, fdobj: *const Fd, events: u32) bool {
    return self.ctl(c.EPOLL_CTL_MOD, fdobj.fd, Ev.V.init(events, fdobj).ptr());
}

/// return true if ok
fn del(self: *EvLoop, fdobj: *const Fd) bool {
    return self.ctl(c.EPOLL_CTL_DEL, fdobj.fd, null);
}

// ======================================================================

fn set_frame(fdobj: *Fd, comptime field_name: []const u8, frame: anyframe) void {
    assert(@field(fdobj, field_name) == null);
    @field(fdobj, field_name) = frame;
}

/// `frame` used for assert() check
fn unset_frame(fdobj: *Fd, comptime field_name: []const u8, frame: anyframe) void {
    assert(@field(fdobj, field_name) == frame);
    @field(fdobj, field_name) = null;
}

/// before suspend {}
fn add_readable(self: *EvLoop, fdobj: *Fd, frame: anyframe) void {
    set_frame(fdobj, "read_frame", frame);
    return self.cache_change(fdobj, Change.ADD_READ);
}

/// after suspend {}
fn del_readable(self: *EvLoop, fdobj: *Fd, frame: anyframe) void {
    unset_frame(fdobj, "read_frame", frame);
    return self.cache_change(fdobj, Change.DEL_READ);
}

/// before suspend {}
fn add_writable(self: *EvLoop, fdobj: *Fd, frame: anyframe) void {
    set_frame(fdobj, "write_frame", frame);
    return self.cache_change(fdobj, Change.ADD_WRITE);
}

/// after suspend {}
fn del_writable(self: *EvLoop, fdobj: *Fd, frame: anyframe) void {
    unset_frame(fdobj, "write_frame", frame);
    return self.cache_change(fdobj, Change.DEL_WRITE);
}

fn cache_change(self: *EvLoop, fdobj: *const Fd, change: Change.T) void {
    const v = self.change_list.getOrPut(g.allocator, fdobj) catch unreachable;
    const change_set = v.value_ptr;
    if (v.found_existing) {
        change_set.add(change);
        if (change_set.is_empty())
            assert(self.change_list.remove(fdobj));
    } else {
        change_set.* = .{};
        change_set.add(change);
        assert(!change_set.is_empty());
    }
}

fn apply_change(self: *EvLoop) void {
    var it = self.change_list.iterator();
    while (it.next()) |v| {
        const fdobj = v.key_ptr.*;
        const change_set = v.value_ptr.*;

        const events = fdobj.interest_events();
        assert(!change_set.is_empty());

        if (events == 0) {
            // del
            assert(change_set.has_any(Change.DEL_READ | Change.DEL_WRITE));
            assert(self.del(fdobj));
        } else {
            // add or mod
            if (change_set.equal(events))
                assert(self.add(fdobj, events | c.EPOLLET))
            else
                assert(self.mod(fdobj, events | c.EPOLLET));
        }
    }
    self.change_list.clearRetainingCapacity();
}

fn on_close_fd(self: *EvLoop, fdobj: *const Fd) void {
    if (self.change_list.fetchRemove(fdobj)) |v| {
        if (v.value.has_any(Change.DEL_READ | Change.DEL_WRITE))
            assert(self.del(fdobj));
    }
}

// ========================================================================

const EVENTS = opaque {
    pub const read: u32 = c.EPOLLIN | c.EPOLLRDHUP | c.EPOLLPRI;
    pub const write: u32 = c.EPOLLOUT;
    pub const err: u32 = c.EPOLLERR | c.EPOLLHUP;
};

/// check for timeout events and handles them, then return the next timeout interval (ms)
fn check_timeout() c_int {
    // if there are other timer requirements in the future,
    // a general-purpose manager for timer objects is needed,
    // featuring the ability to sort and store timer objects by timeout duration.
    return root.check_timeout();
}

pub fn run(self: *EvLoop) void {
    var evs: Ev.Array(64) = undefined;

    while (true) {
        // handling timeout events and get the next interval
        const timeout = check_timeout();

        // empty the list before starting a new epoll_wait
        self.destroyed.clearRetainingCapacity();

        // apply the event changes (epoll_ctl)
        self.apply_change();

        // waiting for I/O events
        const n = epoll_wait(self.epfd, evs.at(0), cc.to_int(evs.len()), timeout);
        if (n < 0 and cc.errno() != c.EINTR) {
            log.err(@src(), "epoll_wait(%d) failed: (%d) %m", .{ self.epfd, cc.errno() });
            c.exit(1);
        }

        // handling I/O events
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const ev = evs.at(cc.to_usize(i));

            const revents = ev.get_events();
            const fdobj = ev.get_fdobj();

            // check if `fdobj` has been destroyed
            if (self.destroyed.contains(fdobj))
                continue;

            // add ref count
            _ = fdobj.ref();
            defer fdobj.unref();

            if (fdobj.read_frame != null and revents & (EVENTS.read | EVENTS.err) != 0)
                co.do_resume(fdobj.read_frame.?);

            if (fdobj.write_frame != null and revents & (EVENTS.write | EVENTS.err) != 0)
                co.do_resume(fdobj.write_frame.?);
        }
    }
}

// ========================================================================

// socket API (non-blocking + async)

comptime {
    assert(c.EAGAIN == c.EWOULDBLOCK);
}

pub fn connect(self: *EvLoop, fdobj: *Fd, addr: *const net.Addr) ?void {
    const res = c.connect(fdobj.fd, &addr.sa, addr.len());
    if (res == 0)
        return;

    if (cc.errno() != c.EINPROGRESS)
        return null;

    self.add_writable(fdobj, @frame());
    suspend {}
    self.del_writable(fdobj, @frame());

    if (net.getsockopt(fdobj.fd, c.SOL_SOCKET, c.SO_ERROR, "SO_ERROR")) |err| {
        if (err == 0) return;
        cc.set_errno(err);
        return null;
    } else {
        // getsockopt failed
        return null;
    }
}

pub fn accept(self: *EvLoop, fdobj: *Fd, src_addr: ?*net.Addr) ?c_int {
    while (true) {
        const addr = if (src_addr) |addr| &addr.sa else null;
        var addrlen: c.socklen_t = @sizeOf(net.Addr);
        const p_addrlen = if (src_addr != null) &addrlen else null;

        const res = c.accept4(fdobj.fd, addr, p_addrlen, c.SOCK_NONBLOCK | c.SOCK_CLOEXEC);
        if (res >= 0)
            return res;

        if (cc.errno() != c.EAGAIN)
            return null;

        self.add_readable(fdobj, @frame());
        suspend {}
        self.del_readable(fdobj, @frame());
    }
}

pub fn read(self: *EvLoop, fdobj: *Fd, buf: []u8) ?usize {
    while (true) {
        const res = c.read(fdobj.fd, buf.ptr, buf.len);
        if (res >= 0)
            return cc.to_usize(res);

        if (cc.errno() != c.EAGAIN)
            return null;

        self.add_readable(fdobj, @frame());
        suspend {}
        self.del_readable(fdobj, @frame());
    }
}

pub fn recvfrom(self: *EvLoop, fdobj: *Fd, buf: []u8, flags: c_int, src_addr: ?*net.Addr) ?usize {
    while (true) {
        const addr = if (src_addr) |addr| &addr.sa else null;
        var addrlen: c.socklen_t = @sizeOf(net.Addr);
        const p_addrlen = if (src_addr != null) &addrlen else null;

        const res = c.recvfrom(fdobj.fd, buf.ptr, buf.len, flags, addr, p_addrlen);
        if (res >= 0)
            return cc.to_usize(res);

        if (cc.errno() != c.EAGAIN)
            return null;

        self.add_readable(fdobj, @frame());
        suspend {}
        self.del_readable(fdobj, @frame());
    }
}

/// length 0 means EOF
pub fn recv(self: *EvLoop, fdobj: *Fd, buf: []u8, flags: c_int) ?usize {
    while (true) {
        const res = c.recv(fdobj.fd, buf.ptr, buf.len, flags);
        if (res >= 0)
            return cc.to_usize(res);

        if (cc.errno() != c.EAGAIN)
            return null;

        self.add_readable(fdobj, @frame());
        suspend {}
        self.del_readable(fdobj, @frame());
    }
}

/// read exactly `buf.len` bytes (res:null and errno:0 means EOF)
pub fn recv_exactly(self: *EvLoop, fdobj: *Fd, buf: []u8, flags: c_int) ?void {
    var nread: usize = 0;
    while (nread < buf.len) {
        const n = self.recv(fdobj, buf[nread..], flags) orelse return null;
        if (n == 0) {
            cc.set_errno(0); // EOF
            return null;
        }
        nread += n;
        // https://man7.org/linux/man-pages/man7/epoll.7.html
        if (nread < buf.len) {
            self.add_readable(fdobj, @frame());
            suspend {}
            self.del_readable(fdobj, @frame());
        }
    }
}

pub fn send(self: *EvLoop, fdobj: *Fd, data: []const u8, flags: c_int) ?void {
    var nsend: usize = 0;
    while (nsend < data.len) {
        const buf = data[nsend..];
        const n = c.send(fdobj.fd, buf.ptr, buf.len, flags);
        if (n >= 0) {
            nsend += n;
        } else if (cc.errno() != c.EAGAIN) {
            return null;
        }
        // https://man7.org/linux/man-pages/man7/epoll.7.html
        if (nsend < data.len) {
            self.add_writable(fdobj, @frame());
            suspend {}
            self.del_writable(fdobj, @frame());
        }
    }
}

/// the `iov` struct will be modified
pub fn sendmsg(self: *EvLoop, fdobj: *Fd, msg: *const net.msghdr_t, flags: c_int) ?void {
    var remain_len: usize = msg.calc_len();
    while (remain_len > 0) {
        const n = net.sendmsg(fdobj.fd, msg, flags);
        if (n >= 0) {
            remain_len -= cc.to_usize(n);
            if (n > 0) msg.skip_iov(cc.to_usize(n));
        } else if (cc.errno() != c.EAGAIN) {
            return null;
        }
        // https://man7.org/linux/man-pages/man7/epoll.7.html
        if (remain_len > 0) {
            self.add_writable(fdobj, @frame());
            suspend {}
            self.del_writable(fdobj, @frame());
        }
    }
}

// =====================================================================

pub fn @"test: evloop api"() !void {
    _ = add;
    _ = mod;
    _ = del;
    _ = Ev.get_events;
    _ = Ev.get_fdobj;
    _ = Ev.set_events;
    _ = Ev.set_fdobj;
}
