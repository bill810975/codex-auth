const std = @import("std");
const builtin = @import("builtin");
const auth = @import("auth.zig");
const registry = @import("registry.zig");

pub const default_usage_endpoint = "https://chatgpt.com/backend-api/wham/usage";
pub const usage_endpoint_env_name = "CODEX_AUTH_USAGE_API_ENDPOINT";
pub const usage_fallback_endpoint_env_name = "CODEX_AUTH_USAGE_API_FALLBACK_ENDPOINT";
const request_timeout_secs: []const u8 = "5";

pub fn fetchActiveUsage(allocator: std.mem.Allocator, codex_home: []const u8) !?registry.RateLimitSnapshot {
    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    const info = try auth.parseAuthInfo(allocator, auth_path);
    defer info.deinit(allocator);

    if (info.auth_mode != .chatgpt) return null;
    const access_token = info.access_token orelse return null;
    const chatgpt_account_id = info.chatgpt_account_id orelse return null;

    const endpoint = try resolveUsageEndpoint(allocator);
    defer allocator.free(endpoint);
    const fallback_endpoint = try resolveFallbackUsageEndpoint(allocator, endpoint);
    defer if (fallback_endpoint) |value| allocator.free(value);
    return try fetchUsageForTokenWithFallback(
        allocator,
        endpoint,
        fallback_endpoint,
        access_token,
        chatgpt_account_id,
    );
}

pub fn resolveUsageEndpoint(allocator: std.mem.Allocator) ![]u8 {
    const configured = std.process.getEnvVarOwned(allocator, usage_endpoint_env_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return resolveUsageEndpointFromConfig(allocator, null),
        else => return err,
    };
    defer allocator.free(configured);
    return resolveUsageEndpointFromConfig(allocator, configured);
}

pub fn resolveUsageEndpointFromConfig(allocator: std.mem.Allocator, configured: ?[]const u8) ![]u8 {
    const raw = configured orelse return allocator.dupe(u8, default_usage_endpoint);
    if (raw.len == 0) return allocator.dupe(u8, default_usage_endpoint);
    if (!isSupportedUsageEndpoint(raw)) return error.InvalidUsageApiEndpoint;
    return allocator.dupe(u8, raw);
}

pub fn resolveFallbackUsageEndpoint(allocator: std.mem.Allocator, primary_endpoint: []const u8) !?[]u8 {
    const configured = std.process.getEnvVarOwned(allocator, usage_fallback_endpoint_env_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    defer allocator.free(configured);
    return resolveFallbackUsageEndpointFromConfig(allocator, primary_endpoint, configured);
}

pub fn resolveFallbackUsageEndpointFromConfig(
    allocator: std.mem.Allocator,
    primary_endpoint: []const u8,
    configured: ?[]const u8,
) !?[]u8 {
    const raw = configured orelse return null;
    if (raw.len == 0) return null;
    if (!isSupportedUsageEndpoint(raw)) return error.InvalidUsageApiEndpoint;
    if (std.mem.eql(u8, primary_endpoint, raw)) return null;
    return try allocator.dupe(u8, raw);
}

pub fn fetchUsageForToken(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) !?registry.RateLimitSnapshot {
    const body = try runUsageCommand(allocator, endpoint, access_token, account_id);
    defer allocator.free(body);
    if (body.len == 0) return null;

    return parseUsageResponse(allocator, body);
}

pub fn fetchUsageForTokenWithFallback(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    fallback_endpoint: ?[]const u8,
    access_token: []const u8,
    account_id: []const u8,
) !?registry.RateLimitSnapshot {
    return fetchUsageForTokenWithFallbackUsingFetcher(
        allocator,
        endpoint,
        fallback_endpoint,
        access_token,
        account_id,
        fetchUsageForToken,
    );
}

pub fn fetchUsageForTokenWithFallbackUsingFetcher(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    fallback_endpoint: ?[]const u8,
    access_token: []const u8,
    account_id: []const u8,
    fetcher: anytype,
) !?registry.RateLimitSnapshot {
    const primary = fetcher(allocator, endpoint, access_token, account_id) catch |primary_err| blk: {
        if (fallback_endpoint) |fallback| {
            break :blk fetcher(allocator, fallback, access_token, account_id) catch return primary_err;
        }
        return primary_err;
    };
    if (primary != null) return primary;

    if (fallback_endpoint) |fallback| {
        return fetcher(allocator, fallback, access_token, account_id);
    }
    return null;
}

pub fn parseUsageResponse(allocator: std.mem.Allocator, body: []const u8) !?registry.RateLimitSnapshot {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return null,
    };

    var snapshot = registry.RateLimitSnapshot{
        .primary = null,
        .secondary = null,
        .credits = null,
        .plan_type = null,
    };

    if (root_obj.get("plan_type")) |plan_type| {
        snapshot.plan_type = parsePlanType(plan_type);
    }
    if (root_obj.get("credits")) |credits| {
        snapshot.credits = try parseCredits(allocator, credits);
    }
    if (root_obj.get("rate_limit")) |rate_limit| {
        switch (rate_limit) {
            .object => |obj| {
                if (obj.get("primary_window")) |window| {
                    snapshot.primary = parseWindow(window);
                }
                if (obj.get("secondary_window")) |window| {
                    snapshot.secondary = parseWindow(window);
                }
            },
            else => {},
        }
    }

    if (snapshot.primary == null and snapshot.secondary == null) {
        if (snapshot.credits) |*credits| {
            if (credits.balance) |balance| allocator.free(balance);
        }
        return null;
    }

    return snapshot;
}

fn parseWindow(v: std.json.Value) ?registry.RateLimitWindow {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };

    const used_percent = if (obj.get("used_percent")) |used| switch (used) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return null,
    } else return null;

    const window_minutes = if (obj.get("limit_window_seconds")) |seconds| switch (seconds) {
        .integer => |value| ceilMinutes(value),
        else => null,
    } else null;
    const resets_at = if (obj.get("reset_at")) |reset_at| switch (reset_at) {
        .integer => |value| value,
        else => null,
    } else null;

    return .{
        .used_percent = used_percent,
        .window_minutes = window_minutes,
        .resets_at = resets_at,
    };
}

fn parseCredits(allocator: std.mem.Allocator, v: std.json.Value) !?registry.CreditsSnapshot {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };

    const has_credits = if (obj.get("has_credits")) |value| switch (value) {
        .bool => |b| b,
        else => false,
    } else false;
    const unlimited = if (obj.get("unlimited")) |value| switch (value) {
        .bool => |b| b,
        else => false,
    } else false;
    const balance = if (obj.get("balance")) |value| switch (value) {
        .string => |s| if (s.len == 0) null else try allocator.dupe(u8, s),
        else => null,
    } else null;

    return .{
        .has_credits = has_credits,
        .unlimited = unlimited,
        .balance = balance,
    };
}

fn parsePlanType(v: std.json.Value) ?registry.PlanType {
    const plan_name = switch (v) {
        .string => |s| s,
        else => return null,
    };

    if (std.ascii.eqlIgnoreCase(plan_name, "free")) return .free;
    if (std.ascii.eqlIgnoreCase(plan_name, "plus")) return .plus;
    if (std.ascii.eqlIgnoreCase(plan_name, "pro")) return .pro;
    if (std.ascii.eqlIgnoreCase(plan_name, "team")) return .team;
    if (std.ascii.eqlIgnoreCase(plan_name, "business")) return .business;
    if (std.ascii.eqlIgnoreCase(plan_name, "enterprise")) return .enterprise;
    if (std.ascii.eqlIgnoreCase(plan_name, "edu")) return .edu;
    return .unknown;
}

fn isSupportedUsageEndpoint(endpoint: []const u8) bool {
    if (std.mem.indexOfAny(u8, endpoint, " \r\n\t") != null) return false;

    const scheme_delimiter = "://";
    const scheme_end = std.mem.indexOf(u8, endpoint, scheme_delimiter) orelse return false;
    const scheme = endpoint[0..scheme_end];
    if (!std.mem.eql(u8, scheme, "https")) return false;

    const rest = endpoint[scheme_end + scheme_delimiter.len ..];
    if (rest.len == 0) return false;
    const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    if (host_end == 0) return false;
    const host = rest[0..host_end];
    return isValidUsageHost(host);
}

fn isValidUsageHost(host: []const u8) bool {
    if (host.len == 0) return false;
    if (std.mem.indexOfAny(u8, host, " \r\n\t@[]") != null) return false;
    if (host[0] == '.' or host[host.len - 1] == '.') return false;
    if (std.mem.indexOf(u8, host, "..") != null) return false;
    return true;
}

fn ceilMinutes(seconds: i64) ?i64 {
    if (seconds <= 0) return null;
    return @divTrunc(seconds + 59, 60);
}

fn runUsageCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) ![]u8 {
    return if (builtin.os.tag == .windows)
        runPowerShellUsageCommand(allocator, endpoint, access_token, account_id)
    else
        runCurlUsageCommand(allocator, endpoint, access_token, account_id);
}

fn runCurlUsageCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) ![]u8 {
    const authorization = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{access_token});
    defer allocator.free(authorization);
    const account_header = try std.fmt.allocPrint(allocator, "ChatGPT-Account-Id: {s}", .{account_id});
    defer allocator.free(account_header);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "curl",
            "--silent",
            "--show-error",
            "--fail",
            "--location",
            "--connect-timeout",
            request_timeout_secs,
            "--max-time",
            request_timeout_secs,
            "-H",
            authorization,
            "-H",
            account_header,
            "-H",
            "User-Agent: codex-auth",
            "-H",
            "Accept-Encoding: identity",
            endpoint,
        },
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code == 0) return result.stdout;
        },
        else => {},
    }
    allocator.free(result.stdout);
    return error.UsageCommandFailed;
}

fn runPowerShellUsageCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) ![]u8 {
    const escaped_token = try escapePowerShellSingleQuoted(allocator, access_token);
    defer allocator.free(escaped_token);
    const escaped_account_id = try escapePowerShellSingleQuoted(allocator, account_id);
    defer allocator.free(escaped_account_id);
    const escaped_endpoint = try escapePowerShellSingleQuoted(allocator, endpoint);
    defer allocator.free(escaped_endpoint);

    const script = try std.fmt.allocPrint(
        allocator,
        "$headers = @{{ Authorization = 'Bearer {s}'; 'ChatGPT-Account-Id' = '{s}'; 'User-Agent' = 'codex-auth'; 'Accept-Encoding' = 'identity' }}; (Invoke-WebRequest -UseBasicParsing -TimeoutSec {s} -Headers $headers -Uri '{s}').Content",
        .{ escaped_token, escaped_account_id, request_timeout_secs, escaped_endpoint },
    );
    defer allocator.free(script);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "powershell.exe",
            "-NoLogo",
            "-NoProfile",
            "-Command",
            script,
        },
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code == 0) return result.stdout;
        },
        else => {},
    }
    allocator.free(result.stdout);
    return error.UsageCommandFailed;
}

fn escapePowerShellSingleQuoted(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, input, "'", "''");
}
