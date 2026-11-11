const std = @import("std");
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

    fn init(r4_app: *r4os.App2) ?App {
        return .{
            .sys = r4_app.system(),
            .net = r4_app.networkLowLevel() orelse return null,
        };
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

    fn netTxResultName(self: *const App, result: i32) []const u8 {
        return self.net.netTxResultName(result);
    }
};

pub fn r4_app_main(r4_app: *r4os.App2) i32 {
    const ctx = App.init(r4_app) orelse return r4os.abi.err_no_group;
    var failure: r4os.arguments.Failure = .{};
    var cursor = r4_app.argCursor(.{ .switches = 0 }, &failure) catch {
        usage(&ctx);
        return 1;
    };
    const token = cursor.next() catch return 1;
    const argument = if (token) |value| value.bytes(r4_app.args()) catch return 1 else "";
    const action = parseAction(argument) orelse {
        usage(&ctx);
        return 1;
    };
    if ((cursor.next() catch return 1) != null) {
        usage(&ctx);
        return 1;
    }
    const clock = r4_app.clock() catch return r4os.abi.err_no_fn;
    var budget = r4os.rpc_budget.Budget.fromTimeout(clock.read, .{ .kind = r4os.abi.timeout_kind_finite, .nanoseconds = 5_000_000_000 }) catch |err| return r4os.rpc_budget.code(err);
    var client: r4os.network_family.Dhcp = undefined;
    const opened = r4os.network_family.Dhcp.open(ctx.sys, &client);
    if (opened != 0) {
        ctx.write("DHCP status: unavailable (unknown lease)\r\n");
        return 1;
    }
    const result = run(&ctx, action, &client, &budget);
    if (client.close() < 0) {
        ctx.write("DHCP connection close unconfirmed\r\n");
        return 1;
    }
    return result;
}

fn run(ctx: *const App, action: Action, client: *r4os.network_family.Dhcp, budget: *r4os.rpc_budget.Budget) i32 {
    var result: i32 = r4os.abi.net_tx_ok;
    if (action != .status) {
        const op: u16 = switch (action) {
            .acquire => r4os.abi.net_service_op_dhcp_acquire_result,
            .renew => r4os.abi.net_service_op_dhcp_renew_result,
            .release => r4os.abi.net_service_op_dhcp_release_result,
            .status => unreachable,
        };
        var response: r4os.abi.NetServiceDhcpResult = .{};
        const rc = client.action(op, budget, &response);
        if (rc != 0) {
            ctx.write("DHCP action unconfirmed, code=");
            ctx.sys.printI32(rc);
            ctx.write("\r\n");
            return 1;
        }
        result = response.result;
        ctx.write(switch (action) {
            .acquire => "DHCP live acquire: ",
            .renew => "DHCP renew: ",
            .release => "DHCP release: ",
            .status => unreachable,
        });
        ctx.write(ctx.netTxResultName(result));
        ctx.write("\r\n");
    }
    var status: r4os.abi.NetServiceDhcpStatus = .{};
    if (client.status(budget, &status) != 0) {
        ctx.write("DHCP status: unavailable (unknown lease)\r\n");
        return 1;
    }
    printStatus(ctx, status);
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

fn printStatus(ctx: *const App, status: r4os.abi.NetServiceDhcpStatus) void {
    ctx.write("DHCP status\r\n");
    ctx.write("State . . . . . . . . . . : ");
    ctx.write(dhcpRuntimeStateName(status.runtime_state));
    ctx.write("\r\n");

    ctx.write("Mode/Task/Link . . . . . . : ");
    ctx.write(if ((status.flags & r4os.abi.net_service_dhcp_flag_desired) != 0) "dhcp" else "static");
    ctx.write("/");
    ctx.write(if ((status.flags & r4os.abi.net_service_dhcp_flag_task_started) != 0) "running" else "stopped");
    ctx.write("/");
    ctx.write(if ((status.flags & r4os.abi.net_service_dhcp_flag_link_up) != 0) "up" else "down");
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
    if ((status.flags & r4os.abi.net_service_dhcp_flag_dns_configured) != 0) {
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

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
