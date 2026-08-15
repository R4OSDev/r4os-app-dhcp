const r4os = @import("r4os");

const Action = enum {
    acquire,
    renew,
    release,
    status,
};

const App = struct {
    sys: r4os.r4sys.Context,
    net: r4os.r4net.Context,

    fn init(r4_app: *r4os.App) ?App {
        return .{
            .sys = r4_app.system(),
            .net = r4_app.networkLowLevel() orelse return null,
        };
    }

    fn argsRaw(self: *const App) [*:0]const u8 {
        return self.sys.argsRaw();
    }

    fn write(self: *const App, value: []const u8) void {
        self.sys.write(value);
    }

    fn putc(self: *const App, ch: u8) void {
        self.sys.putc(ch);
    }

    fn printU64(self: *const App, value: u64) void {
        self.sys.printU64(value);
    }

    fn netDhcpAcquireService(self: *const App) i32 {
        return self.net.netDhcpAcquireService();
    }

    fn netDhcpRenewService(self: *const App) i32 {
        return self.net.netDhcpRenewService();
    }

    fn netDhcpReleaseService(self: *const App) i32 {
        return self.net.netDhcpReleaseService();
    }

    fn netDhcpServiceStatus(self: *const App, out: *r4os.abi.DhcpStatus) i32 {
        return self.net.netDhcpServiceStatus(out);
    }

    fn netTxResultName(self: *const App, result: i32) []const u8 {
        return self.net.netTxResultName(result);
    }
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    const ctx = App.init(r4_app) orelse return r4os.abi.err_no_group;
    const args = trim(zSlice(ctx.argsRaw()));
    const action = parseAction(args) orelse {
        usage(&ctx);
        return 1;
    };

    var result: i32 = r4os.abi.net_tx_ok;
    switch (action) {
        .acquire => {
            result = ctx.netDhcpAcquireService();
            ctx.write("DHCP live acquire: ");
            ctx.write(ctx.netTxResultName(result));
            ctx.write("\r\n");
        },
        .renew => {
            result = ctx.netDhcpRenewService();
            ctx.write("DHCP renew: ");
            ctx.write(ctx.netTxResultName(result));
            ctx.write("\r\n");
        },
        .release => {
            result = ctx.netDhcpReleaseService();
            ctx.write("DHCP release: ");
            ctx.write(ctx.netTxResultName(result));
            ctx.write("\r\n");
        },
        .status => {},
    }

    var status: r4os.abi.DhcpStatus = .{};
    if (ctx.netDhcpServiceStatus(&status) <= 0) {
        ctx.write("DHCP status: unavailable\r\n");
        return 1;
    }
    printStatus(&ctx, status);
    return if (result == r4os.abi.net_tx_ok) 0 else 1;
}

fn parseAction(args: []const u8) ?Action {
    if (args.len == 0) return .acquire;
    if (equalsIgnoreCase(args, "ACQUIRE") or equalsIgnoreCase(args, "REQUEST")) return .acquire;
    if (equalsIgnoreCase(args, "RENEW")) return .renew;
    if (equalsIgnoreCase(args, "RELEASE")) return .release;
    if (equalsIgnoreCase(args, "STATUS") or equalsIgnoreCase(args, "STAT")) return .status;
    return null;
}

fn usage(ctx: *const App) void {
    ctx.write("Usage: DHCP [ACQUIRE|RENEW|RELEASE|STATUS]\r\n");
}

fn printStatus(ctx: *const App, status: r4os.abi.DhcpStatus) void {
    ctx.write("DHCP status\r\n");
    ctx.write("State . . . . . . . . . . : ");
    ctx.write(dhcpRuntimeStateName(status.runtime_state));
    ctx.write("\r\n");

    ctx.write("Mode/Task/Link . . . . . . : ");
    ctx.write(if ((status.flags & r4os.abi.dhcp_status_flag_desired) != 0) "dhcp" else "static");
    ctx.write("/");
    ctx.write(if ((status.flags & r4os.abi.dhcp_status_flag_task_started) != 0) "running" else "stopped");
    ctx.write("/");
    ctx.write(if ((status.flags & r4os.abi.dhcp_status_flag_link_up) != 0) "up" else "down");
    ctx.write("\r\n");

    ctx.write("Client IP . . . . . . . . : ");
    writeIpv4(ctx, status.offered_ip);
    ctx.write("\r\n");
    ctx.write("Server IP . . . . . . . . : ");
    writeIpv4(ctx, status.server_ip);
    ctx.write("\r\n");
    ctx.write("Subnet Mask . . . . . . . : ");
    writeIpv4(ctx, status.netmask);
    ctx.write("\r\n");
    ctx.write("Gateway . . . . . . . . . : ");
    writeIpv4(ctx, status.gateway_ip);
    ctx.write("\r\n");
    ctx.write("DNS Server . . . . . . . . : ");
    if ((status.flags & r4os.abi.dhcp_status_flag_dns_configured) != 0) {
        writeIpv4(ctx, status.dns_ip);
    } else {
        ctx.write("not configured");
    }
    ctx.write("\r\n");

    ctx.write("XID . . . . . . . . . . . : 0x");
    writeHex32(ctx, status.xid);
    ctx.write("\r\n");
    ctx.write("Lease/Renew/Rebind . . . : ");
    ctx.printU64(status.lease_seconds);
    ctx.write("/");
    ctx.printU64(status.renew_seconds);
    ctx.write("/");
    ctx.printU64(status.rebind_seconds);
    ctx.write(" seconds\r\n");

    ctx.write("Discover/Offer . . . . . : ");
    ctx.printU64(status.discover_tx);
    ctx.write("/");
    ctx.printU64(status.offer_rx);
    ctx.write("\r\n");
    ctx.write("Request/Ack/Nak . . . . . : ");
    ctx.printU64(status.request_tx);
    ctx.write("/");
    ctx.printU64(status.ack_rx);
    ctx.write("/");
    ctx.printU64(status.nak_rx);
    ctx.write("\r\n");
    ctx.write("Release . . . . . . . . . : ");
    ctx.printU64(status.release_tx);
    ctx.write("\r\n");
    ctx.write("Retries/Timeouts . . . . : ");
    ctx.printU64(status.retries);
    ctx.write("/");
    ctx.printU64(status.timeouts);
    ctx.write("\r\n");
    ctx.write("Release Errors . . . . . : ");
    ctx.printU64(status.release_errors);
    ctx.write("\r\n");
    ctx.write("Malformed/Selftests . . . : ");
    ctx.printU64(status.malformed);
    ctx.write("/");
    ctx.printU64(status.self_tests);
    ctx.write("\r\n");
    ctx.write("Last Attempt/Type . . . . : ");
    ctx.printU64(status.last_attempt);
    ctx.write("/");
    ctx.printU64(status.last_type);
    ctx.write("\r\n");
    ctx.write("Last Error . . . . . . . : ");
    writeZOr(ctx, status.last_error[0..], "none");
    ctx.write("\r\n");
}

fn dhcpRuntimeStateName(value: u16) []const u8 {
    return switch (value) {
        0 => "disabled",
        1 => "static",
        2 => "wait-adapter",
        3 => "wait-link",
        4 => "acquire",
        5 => "retry-wait",
        6 => "bound",
        7 => "renew",
        8 => "rebind",
        9 => "lease-lost",
        else => "unknown",
    };
}

fn writeIpv4(ctx: *const App, ip: [4]u8) void {
    ctx.printU64(ip[0]);
    ctx.putc('.');
    ctx.printU64(ip[1]);
    ctx.putc('.');
    ctx.printU64(ip[2]);
    ctx.putc('.');
    ctx.printU64(ip[3]);
}

fn writeHex32(ctx: *const App, value: u32) void {
    var shift: u5 = 28;
    while (true) {
        writeHexNibble(ctx, @intCast((value >> shift) & 0x0F));
        if (shift == 0) break;
        shift -= 4;
    }
}

fn writeHexNibble(ctx: *const App, value: u8) void {
    const digits = "0123456789ABCDEF";
    ctx.putc(digits[value & 0x0F]);
}

fn writeZOr(ctx: *const App, value: []const u8, fallback: []const u8) void {
    const text = spanZ(value);
    if (text.len == 0) {
        ctx.write(fallback);
    } else {
        ctx.write(text);
    }
}

fn spanZ(value: []const u8) []const u8 {
    var end: usize = 0;
    while (end < value.len and value[end] != 0) : (end += 1) {}
    return value[0..end];
}

fn zSlice(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn trim(value: []const u8) []const u8 {
    var start: usize = 0;
    var end = value.len;
    while (start < end and isSpace(value[start])) : (start += 1) {}
    while (end > start and isSpace(value[end - 1])) : (end -= 1) {}
    return value[start..end];
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var index: usize = 0;
    while (index < a.len) : (index += 1) {
        if (asciiUpper(a[index]) != asciiUpper(b[index])) return false;
    }
    return true;
}

fn asciiUpper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - 32;
    return ch;
}
