const std = @import("std");
const Step = std.Build.Step;
const LazyPath = std.Build.LazyPath;
const InstallDir = std.Build.InstallDir;
const InstallFile = @This();
const assert = std.debug.assert;

pub const base_id: Step.Id = .install_file;

step: Step,
source: LazyPath,
dir: InstallDir,
dest_rel_path: []const u8,

pub fn create(
    owner: *std.Build,
    source: LazyPath,
    dir: InstallDir,
    dest_rel_path: []const u8,
) *InstallFile {
    assert(dest_rel_path.len != 0);
<<<<<<< HEAD
    assert(owner.phase == .configure);
    owner.pushInstalledFile(dir, dest_rel_path);
    const self = owner.allocator.create(InstallFile) catch @panic("OOM");
    self.* = .{
=======
    const install_file = owner.allocator.create(InstallFile) catch @panic("OOM");
    install_file.* = .{
>>>>>>> 54d0ba418375a4665cf1b4ee876d6c750bb9c079
        .step = Step.init(.{
            .id = base_id,
            .name = owner.fmt("install {s} to {s}", .{ source.getDisplayName(), dest_rel_path }),
            .owner = owner,
            .makeFn = make,
        }),
        .source = source.dupe(owner),
        .dir = dir.dupe(owner),
        .dest_rel_path = owner.dupePath(dest_rel_path),
    };
    source.addStepDependencies(&install_file.step);
    return install_file;
}

<<<<<<< HEAD
fn make(step: *Step, prog_node: *std.Progress.Node) !void {
    _ = prog_node;
    const src_builder = step.owner;
    assert(src_builder.phase == .make);
    const self = @fieldParentPtr(InstallFile, "step", step);
    const dest_builder = self.dest_builder;
    const full_src_path = self.source.getPath2(src_builder, step);
    const full_dest_path = dest_builder.getInstallPath(self.dir, self.dest_rel_path);
=======
fn make(step: *Step, options: Step.MakeOptions) !void {
    _ = options;
    const b = step.owner;
    const install_file: *InstallFile = @fieldParentPtr("step", step);
    try step.singleUnchangingWatchInput(install_file.source);

    const full_src_path = install_file.source.getPath2(b, step);
    const full_dest_path = b.getInstallPath(install_file.dir, install_file.dest_rel_path);
>>>>>>> 54d0ba418375a4665cf1b4ee876d6c750bb9c079
    const cwd = std.fs.cwd();
    const prev = std.fs.Dir.updateFile(cwd, full_src_path, cwd, full_dest_path, .{}) catch |err| {
        return step.fail("unable to update file from '{s}' to '{s}': {s}", .{
            full_src_path, full_dest_path, @errorName(err),
        });
    };
    step.result_cached = prev == .fresh;
}
