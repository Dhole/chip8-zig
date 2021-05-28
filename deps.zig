const std = @import("std");
pub const pkgs = struct {
    pub const clap = std.build.Pkg{
        .name = "clap",
        .path = ".gyro/zig-clap-Hejsil-c7d83fcce1739271e399260b50c5f68aa03c5908/pkg/clap.zig",
    };

    pub fn addAllTo(artifact: *std.build.LibExeObjStep) void {
        @setEvalBranchQuota(1_000_000);
        inline for (std.meta.declarations(pkgs)) |decl| {
            if (decl.is_pub and decl.data == .Var) {
                artifact.addPackage(@field(pkgs, decl.name));
            }
        }
    }
};

pub const base_dirs = struct {
    pub const clap = ".gyro/zig-clap-Hejsil-c7d83fcce1739271e399260b50c5f68aa03c5908/pkg";
};
