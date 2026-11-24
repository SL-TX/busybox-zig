//! Tests for signal-name lookup and signal-aware polling (Task 15).

const std = @import("std");
const bb = @import("libbb_zig");
const sm = bb.signals_more;
const proc = bb.process;
const io = bb.io;
const linux = std.os.linux;

test "signalByName accepts numbers, names and SIG-prefixed names" {
    try std.testing.expectEqual(@as(c_int, 15), try sm.signalByName("TERM"));
    try std.testing.expectEqual(@as(c_int, 9), try sm.signalByName("SIGKILL"));
    try std.testing.expectEqual(@as(c_int, 2), try sm.signalByName("sigint"));
    try std.testing.expectEqual(@as(c_int, 9), try sm.signalByName("9"));
    try std.testing.expectEqual(@as(c_int, 0), try sm.signalByName("0"));
    try std.testing.expectEqual(@as(c_int, 17), try sm.signalByName("CHLD"));
    try std.testing.expectEqual(@as(c_int, 17), try sm.signalByName("CLD"));
    try std.testing.expectEqual(@as(c_int, 29), try sm.signalByName("IO"));
    try std.testing.expectEqual(@as(c_int, 29), try sm.signalByName("POLL"));
    try std.testing.expectEqual(@as(c_int, 29), try sm.signalByName("SIGPOLL"));
    try std.testing.expectEqual(@as(c_int, 6), try sm.signalByName("IOT"));
}

test "signalByName handles RTMIN/RTMAX offsets" {
    try std.testing.expectEqual(@as(c_int, 32), try sm.signalByName("RTMIN"));
    try std.testing.expectEqual(@as(c_int, 34), try sm.signalByName("RTMIN+2"));
    try std.testing.expectEqual(@as(c_int, 64), try sm.signalByName("RTMAX"));
    try std.testing.expectEqual(@as(c_int, 63), try sm.signalByName("RTMAX-1"));
    _ = sm.signalByName("RTMIN+999") catch |e| {
        try std.testing.expectEqual(sm.Error.UnknownSignal, e);
        return;
    };
    try std.testing.expect(false);
}

test "signalByName rejects unknown names" {
    _ = sm.signalByName("NOTASIGNAL") catch |e| {
        try std.testing.expectEqual(sm.Error.UnknownSignal, e);
        return;
    };
    try std.testing.expect(false);
}

test "signalName is the inverse of signalByName for table entries" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("TERM", sm.signalName(15, &buf));
    try std.testing.expectEqualStrings("KILL", sm.signalName(9, &buf));
    try std.testing.expectEqualStrings("EXIT", sm.signalName(0, &buf));
    try std.testing.expectEqualStrings("RTMIN", sm.signalName(32, &buf));
    // BusyBox's signals[] uses SIGPOLL as the canonical name for signal 29.
    try std.testing.expectEqualStrings("POLL", sm.signalName(29, &buf));
    try std.testing.expectEqualStrings("123", sm.signalName(123, &buf));
}

const MockState = struct {
    calls: usize = 0,
    timeouts: [8]i32 = std.mem.zeroes([8]i32),
};

var sm_test_state = MockState{};

fn eintrThenSuccess(fds: [*]linux.pollfd, n: linux.nfds_t, timeout: i32) i32 {
    _ = n;
    sm_test_state.timeouts[sm_test_state.calls] = timeout;
    sm_test_state.calls += 1;
    if (sm_test_state.calls < 3) {
        proc.errno = @backingInt(linux.E.INTR);
        return -1;
    }
    fds[0].revents = linux.POLL.IN;
    return 1;
}

test "safePoll retries EINTR and inches the timeout towards completion" {
    sm_test_state = .{};
    var fds = [_]linux.pollfd{.{ .fd = 0, .events = linux.POLL.IN }};
    const n = sm.safePollWith(&fds, 100, eintrThenSuccess);
    try std.testing.expectEqual(@as(i32, 1), n);
    try std.testing.expectEqual(@as(usize, 3), sm_test_state.calls);
    try std.testing.expectEqual(@as(i32, 100), sm_test_state.timeouts[0]);
    try std.testing.expectEqual(@as(i32, 99), sm_test_state.timeouts[1]);
    try std.testing.expectEqual(@as(i32, 98), sm_test_state.timeouts[2]);
    try std.testing.expectEqual(@as(i16, linux.POLL.IN), fds[0].revents);
}

fn badFdPoll(fds: [*]linux.pollfd, n: linux.nfds_t, timeout: i32) i32 {
    _ = fds;
    _ = n;
    _ = timeout;
    sm_test_state.calls += 1;
    proc.errno = @backingInt(linux.E.BADF);
    return -1;
}

test "safePoll does not retry hard errors" {
    sm_test_state = .{};
    var fds = [_]linux.pollfd{.{ .fd = -1, .events = linux.POLL.IN }};
    try std.testing.expectEqual(@as(i32, -1), sm.safePollWith(&fds, 50, badFdPoll));
    try std.testing.expectEqual(@as(usize, 1), sm_test_state.calls);
    try std.testing.expectEqual(@as(c_int, @backingInt(linux.E.BADF)), proc.errno);
}

test "safePoll polls a real pipe" {
    var fds: [2]linux.fd_t = undefined;
    try proc.pipe(&fds);
    defer proc.close(fds[0]) catch {};
    defer proc.close(fds[1]) catch {};

    var pfds = [_]linux.pollfd{.{ .fd = fds[0], .events = linux.POLL.IN }};
    try std.testing.expectEqual(@as(i32, 0), sm.safePoll(&pfds, 10));
    try io.writeAll(fds[1], "x");
    try std.testing.expectEqual(@as(i32, 1), sm.safePoll(&pfds, 1000));
    try std.testing.expect((pfds[0].revents & linux.POLL.IN) != 0);
}

test "gotSignalHandler records that a signal arrived" {
    const old = sm.got_signal;
    defer sm.got_signal = old;
    sm.got_signal = false;
    sm.gotSignalHandler(.USR1);
    try std.testing.expect(sm.got_signal);
}

test "pollWithSignals returns EINTR immediately when a signal was caught" {
    const old = sm.got_signal;
    defer sm.got_signal = old;
    sm.got_signal = true;
    var pfds = [_]linux.pollfd{.{ .fd = -1, .events = linux.POLL.IN }};
    try std.testing.expectEqual(@as(i32, -1), sm.pollWithSignals(&pfds, 0));
    try std.testing.expectEqual(@as(c_int, @backingInt(linux.E.INTR)), proc.errno);
}

test "pollWithSignals waits on a pipe and times out" {
    const old = sm.got_signal;
    defer sm.got_signal = old;
    sm.got_signal = false;
    var fds: [2]linux.fd_t = undefined;
    try proc.pipe(&fds);
    defer proc.close(fds[0]) catch {};
    defer proc.close(fds[1]) catch {};
    var pfds = [_]linux.pollfd{.{ .fd = fds[0], .events = linux.POLL.IN }};
    try std.testing.expectEqual(@as(i32, 0), sm.pollWithSignals(&pfds, 10));
    try io.writeAll(fds[1], "z");
    try std.testing.expectEqual(@as(i32, 1), sm.pollWithSignals(&pfds, 1000));
}
