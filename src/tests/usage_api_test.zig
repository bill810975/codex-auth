const std = @import("std");
const registry = @import("../registry.zig");
const usage_api = @import("../usage_api.zig");

test "parse usage api response maps live usage windows and plan" {
    const gpa = std.testing.allocator;
    const body =
        \\{
        \\  "user_id": "user-example",
        \\  "account_id": "account-example",
        \\  "email": "team@example.com",
        \\  "plan_type": "team",
        \\  "rate_limit": {
        \\    "allowed": true,
        \\    "limit_reached": false,
        \\    "primary_window": {
        \\      "used_percent": 11,
        \\      "limit_window_seconds": 18000,
        \\      "reset_after_seconds": 16802,
        \\      "reset_at": 1773491460
        \\    },
        \\    "secondary_window": {
        \\      "used_percent": 94,
        \\      "limit_window_seconds": 604800,
        \\      "reset_after_seconds": 274961,
        \\      "reset_at": 1773749620
        \\    }
        \\  },
        \\  "code_review_rate_limit": {
        \\    "allowed": true,
        \\    "limit_reached": false,
        \\    "primary_window": {
        \\      "used_percent": 0,
        \\      "limit_window_seconds": 604800,
        \\      "reset_after_seconds": 604800,
        \\      "reset_at": 1774079459
        \\    },
        \\    "secondary_window": null
        \\  },
        \\  "additional_rate_limits": null,
        \\  "credits": {
        \\    "has_credits": false,
        \\    "unlimited": false,
        \\    "balance": null,
        \\    "approx_local_messages": null,
        \\    "approx_cloud_messages": null
        \\  },
        \\  "promo": null
        \\}
    ;

    const snapshot = (try usage_api.parseUsageResponse(gpa, body)) orelse return error.TestExpectedEqual;
    defer registry.freeRateLimitSnapshot(gpa, &snapshot);

    try std.testing.expectEqual(registry.PlanType.team, snapshot.plan_type.?);
    try std.testing.expectEqual(@as(f64, 11.0), snapshot.primary.?.used_percent);
    try std.testing.expectEqual(@as(?i64, 300), snapshot.primary.?.window_minutes);
    try std.testing.expectEqual(@as(?i64, 10080), snapshot.secondary.?.window_minutes);
    try std.testing.expectEqual(@as(?i64, 1773749620), snapshot.secondary.?.resets_at);
    try std.testing.expect(snapshot.credits != null);
    try std.testing.expect(!snapshot.credits.?.has_credits);
    try std.testing.expect(snapshot.credits.?.balance == null);
}

test "parse usage api response without windows is ignored" {
    const gpa = std.testing.allocator;
    const body =
        \\{
        \\  "plan_type": "plus",
        \\  "rate_limit": null,
        \\  "credits": {
        \\    "has_credits": true,
        \\    "unlimited": false,
        \\    "balance": "1.00"
        \\  }
        \\}
    ;

    const snapshot = try usage_api.parseUsageResponse(gpa, body);
    try std.testing.expect(snapshot == null);
}

test "resolve usage endpoint falls back to default when provider endpoint is empty" {
    const gpa = std.testing.allocator;
    const endpoint = try usage_api.resolveUsageEndpointFromConfig(gpa, "");
    defer gpa.free(endpoint);

    try std.testing.expectEqualStrings(usage_api.default_usage_endpoint, endpoint);
}

test "resolve usage endpoint accepts custom third-party endpoint" {
    const gpa = std.testing.allocator;
    const endpoint = try usage_api.resolveUsageEndpointFromConfig(gpa, "https://proxy.example.com/backend-api/wham/usage");
    defer gpa.free(endpoint);

    try std.testing.expectEqualStrings("https://proxy.example.com/backend-api/wham/usage", endpoint);
}

test "resolve usage endpoint rejects invalid non-https values" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidUsageApiEndpoint,
        usage_api.resolveUsageEndpointFromConfig(gpa, "file:///tmp/usage.json"),
    );
    try std.testing.expectError(
        error.InvalidUsageApiEndpoint,
        usage_api.resolveUsageEndpointFromConfig(gpa, "https:///backend-api/wham/usage"),
    );
    try std.testing.expectError(
        error.InvalidUsageApiEndpoint,
        usage_api.resolveUsageEndpointFromConfig(gpa, "http://proxy.example.com/backend-api/wham/usage"),
    );
    try std.testing.expectError(
        error.InvalidUsageApiEndpoint,
        usage_api.resolveUsageEndpointFromConfig(gpa, "https://..example.com/backend-api/wham/usage"),
    );
    try std.testing.expectError(
        error.InvalidUsageApiEndpoint,
        usage_api.resolveUsageEndpointFromConfig(gpa, "https://example.com./backend-api/wham/usage"),
    );
}

test "resolve fallback endpoint ignores empty or same-as-primary values" {
    const gpa = std.testing.allocator;
    const primary = "https://chatgpt.com/backend-api/wham/usage";

    const empty = try usage_api.resolveFallbackUsageEndpointFromConfig(gpa, primary, "");
    try std.testing.expect(empty == null);

    const same = try usage_api.resolveFallbackUsageEndpointFromConfig(gpa, primary, primary);
    try std.testing.expect(same == null);
}

test "resolve fallback endpoint accepts distinct third-party endpoint" {
    const gpa = std.testing.allocator;
    const primary = "https://chatgpt.com/backend-api/wham/usage";
    const fallback = try usage_api.resolveFallbackUsageEndpointFromConfig(
        gpa,
        primary,
        "https://proxy.example.com/backend-api/wham/usage",
    );
    defer if (fallback) |value| gpa.free(value);

    try std.testing.expect(fallback != null);
    try std.testing.expectEqualStrings("https://proxy.example.com/backend-api/wham/usage", fallback.?);
}

fn fakeFetchWithPrimaryFailure(
    _: std.mem.Allocator,
    endpoint: []const u8,
    _: []const u8,
    _: []const u8,
) !?registry.RateLimitSnapshot {
    if (std.mem.eql(u8, endpoint, "https://chatgpt.com/backend-api/wham/usage")) {
        return error.UsageCommandFailed;
    }
    return .{
        .primary = .{
            .used_percent = 42.0,
            .window_minutes = 300,
            .resets_at = 1773749620,
        },
        .secondary = null,
        .credits = null,
        .plan_type = null,
    };
}

fn fakeFetchPrimaryNull(
    _: std.mem.Allocator,
    endpoint: []const u8,
    _: []const u8,
    _: []const u8,
) !?registry.RateLimitSnapshot {
    if (std.mem.eql(u8, endpoint, "https://chatgpt.com/backend-api/wham/usage")) {
        return null;
    }
    return .{
        .primary = .{
            .used_percent = 18.0,
            .window_minutes = 300,
            .resets_at = 1773749620,
        },
        .secondary = null,
        .credits = null,
        .plan_type = null,
    };
}

fn fakeFetchAlwaysFails(
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: []const u8,
) !?registry.RateLimitSnapshot {
    return error.UsageCommandFailed;
}

test "fetch with fallback uses third-party endpoint when primary fails" {
    const gpa = std.testing.allocator;
    const snapshot = try usage_api.fetchUsageForTokenWithFallbackUsingFetcher(
        gpa,
        "https://chatgpt.com/backend-api/wham/usage",
        "https://proxy.example.com/backend-api/wham/usage",
        "token",
        "account",
        fakeFetchWithPrimaryFailure,
    );
    try std.testing.expect(snapshot != null);
    try std.testing.expectEqual(@as(f64, 42.0), snapshot.?.primary.?.used_percent);
}

test "fetch with fallback uses third-party endpoint when primary has no data" {
    const gpa = std.testing.allocator;
    const snapshot = try usage_api.fetchUsageForTokenWithFallbackUsingFetcher(
        gpa,
        "https://chatgpt.com/backend-api/wham/usage",
        "https://proxy.example.com/backend-api/wham/usage",
        "token",
        "account",
        fakeFetchPrimaryNull,
    );
    try std.testing.expect(snapshot != null);
    try std.testing.expectEqual(@as(f64, 18.0), snapshot.?.primary.?.used_percent);
}

test "fetch with fallback keeps primary error when no fallback is configured" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.UsageCommandFailed,
        usage_api.fetchUsageForTokenWithFallbackUsingFetcher(
            gpa,
            "https://chatgpt.com/backend-api/wham/usage",
            null,
            "token",
            "account",
            fakeFetchAlwaysFails,
        ),
    );
}
