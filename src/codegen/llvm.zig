const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.codegen);
const math = std.math;
const native_endian = builtin.cpu.arch.endian();
const DW = std.dwarf;

const Builder = @import("llvm/Builder.zig");
const llvm = @import("llvm/bindings.zig");
const link = @import("../link.zig");
const Compilation = @import("../Compilation.zig");
const build_options = @import("build_options");
const Module = @import("../Module.zig");
const InternPool = @import("../InternPool.zig");
const Package = @import("../Package.zig");
const TypedValue = @import("../TypedValue.zig");
const Air = @import("../Air.zig");
const Liveness = @import("../Liveness.zig");
const Value = @import("../value.zig").Value;
const Type = @import("../type.zig").Type;
const LazySrcLoc = Module.LazySrcLoc;
const x86_64_abi = @import("../arch/x86_64/abi.zig");
const wasm_c_abi = @import("../arch/wasm/abi.zig");
const aarch64_c_abi = @import("../arch/aarch64/abi.zig");
const arm_c_abi = @import("../arch/arm/abi.zig");
const riscv_c_abi = @import("../arch/riscv64/abi.zig");

const target_util = @import("../target.zig");
const libcFloatPrefix = target_util.libcFloatPrefix;
const libcFloatSuffix = target_util.libcFloatSuffix;
const compilerRtFloatAbbrev = target_util.compilerRtFloatAbbrev;
const compilerRtIntAbbrev = target_util.compilerRtIntAbbrev;

const Error = error{ OutOfMemory, CodegenFail };

pub fn targetTriple(allocator: Allocator, target: std.Target) ![:0]u8 {
    var llvm_triple = std.ArrayList(u8).init(allocator);
    defer llvm_triple.deinit();

    const llvm_arch = switch (target.cpu.arch) {
        .arm => "arm",
        .armeb => "armeb",
        .aarch64 => "aarch64",
        .aarch64_be => "aarch64_be",
        .aarch64_32 => "aarch64_32",
        .arc => "arc",
        .avr => "avr",
        .bpfel => "bpfel",
        .bpfeb => "bpfeb",
        .csky => "csky",
        .dxil => "dxil",
        .hexagon => "hexagon",
        .loongarch32 => "loongarch32",
        .loongarch64 => "loongarch64",
        .m68k => "m68k",
        .mips => "mips",
        .mipsel => "mipsel",
        .mips64 => "mips64",
        .mips64el => "mips64el",
        .msp430 => "msp430",
        .powerpc => "powerpc",
        .powerpcle => "powerpcle",
        .powerpc64 => "powerpc64",
        .powerpc64le => "powerpc64le",
        .r600 => "r600",
        .amdgcn => "amdgcn",
        .riscv32 => "riscv32",
        .riscv64 => "riscv64",
        .sparc => "sparc",
        .sparc64 => "sparc64",
        .sparcel => "sparcel",
        .s390x => "s390x",
        .tce => "tce",
        .tcele => "tcele",
        .thumb => "thumb",
        .thumbeb => "thumbeb",
        .x86 => "i386",
        .x86_64 => "x86_64",
        .xcore => "xcore",
        .xtensa => "xtensa",
        .nvptx => "nvptx",
        .nvptx64 => "nvptx64",
        .le32 => "le32",
        .le64 => "le64",
        .amdil => "amdil",
        .amdil64 => "amdil64",
        .hsail => "hsail",
        .hsail64 => "hsail64",
        .spir => "spir",
        .spir64 => "spir64",
        .spirv32 => "spirv32",
        .spirv64 => "spirv64",
        .kalimba => "kalimba",
        .shave => "shave",
        .lanai => "lanai",
        .wasm32 => "wasm32",
        .wasm64 => "wasm64",
        .renderscript32 => "renderscript32",
        .renderscript64 => "renderscript64",
        .ve => "ve",
        .spu_2 => return error.@"LLVM backend does not support SPU Mark II",
    };
    try llvm_triple.appendSlice(llvm_arch);
    try llvm_triple.appendSlice("-unknown-");

    const llvm_os = switch (target.os.tag) {
        .freestanding => "unknown",
        .ananas => "ananas",
        .cloudabi => "cloudabi",
        .dragonfly => "dragonfly",
        .freebsd => "freebsd",
        .fuchsia => "fuchsia",
        .kfreebsd => "kfreebsd",
        .linux => "linux",
        .lv2 => "lv2",
        .netbsd => "netbsd",
        .openbsd => "openbsd",
        .solaris => "solaris",
        .windows => "windows",
        .zos => "zos",
        .haiku => "haiku",
        .minix => "minix",
        .rtems => "rtems",
        .nacl => "nacl",
        .aix => "aix",
        .cuda => "cuda",
        .nvcl => "nvcl",
        .amdhsa => "amdhsa",
        .ps4 => "ps4",
        .ps5 => "ps5",
        .elfiamcu => "elfiamcu",
        .mesa3d => "mesa3d",
        .contiki => "contiki",
        .amdpal => "amdpal",
        .hermit => "hermit",
        .hurd => "hurd",
        .wasi => "wasi",
        .emscripten => "emscripten",
        .uefi => "windows",
        .macos => "macosx",
        .ios => "ios",
        .tvos => "tvos",
        .watchos => "watchos",
        .driverkit => "driverkit",
        .shadermodel => "shadermodel",
        .opencl,
        .glsl450,
        .vulkan,
        .plan9,
        .other,
        => "unknown",
    };
    try llvm_triple.appendSlice(llvm_os);

    if (target.os.tag.isDarwin()) {
        const min_version = target.os.version_range.semver.min;
        try llvm_triple.writer().print("{d}.{d}.{d}", .{
            min_version.major,
            min_version.minor,
            min_version.patch,
        });
    }
    try llvm_triple.append('-');

    const llvm_abi = switch (target.abi) {
        .none => "unknown",
        .gnu => "gnu",
        .gnuabin32 => "gnuabin32",
        .gnuabi64 => "gnuabi64",
        .gnueabi => "gnueabi",
        .gnueabihf => "gnueabihf",
        .gnuf32 => "gnuf32",
        .gnuf64 => "gnuf64",
        .gnusf => "gnusf",
        .gnux32 => "gnux32",
        .gnuilp32 => "gnuilp32",
        .code16 => "code16",
        .eabi => "eabi",
        .eabihf => "eabihf",
        .android => "android",
        .musl => "musl",
        .musleabi => "musleabi",
        .musleabihf => "musleabihf",
        .muslx32 => "muslx32",
        .msvc => "msvc",
        .itanium => "itanium",
        .cygnus => "cygnus",
        .coreclr => "coreclr",
        .simulator => "simulator",
        .macabi => "macabi",
        .pixel => "pixel",
        .vertex => "vertex",
        .geometry => "geometry",
        .hull => "hull",
        .domain => "domain",
        .compute => "compute",
        .library => "library",
        .raygeneration => "raygeneration",
        .intersection => "intersection",
        .anyhit => "anyhit",
        .closesthit => "closesthit",
        .miss => "miss",
        .callable => "callable",
        .mesh => "mesh",
        .amplification => "amplification",
    };
    try llvm_triple.appendSlice(llvm_abi);

    return llvm_triple.toOwnedSliceSentinel(0);
}

pub fn targetOs(os_tag: std.Target.Os.Tag) llvm.OSType {
    return switch (os_tag) {
        .freestanding, .other, .opencl, .glsl450, .vulkan, .plan9 => .UnknownOS,
        .windows, .uefi => .Win32,
        .ananas => .Ananas,
        .cloudabi => .CloudABI,
        .dragonfly => .DragonFly,
        .freebsd => .FreeBSD,
        .fuchsia => .Fuchsia,
        .ios => .IOS,
        .kfreebsd => .KFreeBSD,
        .linux => .Linux,
        .lv2 => .Lv2,
        .macos => .MacOSX,
        .netbsd => .NetBSD,
        .openbsd => .OpenBSD,
        .solaris => .Solaris,
        .zos => .ZOS,
        .haiku => .Haiku,
        .minix => .Minix,
        .rtems => .RTEMS,
        .nacl => .NaCl,
        .aix => .AIX,
        .cuda => .CUDA,
        .nvcl => .NVCL,
        .amdhsa => .AMDHSA,
        .ps4 => .PS4,
        .ps5 => .PS5,
        .elfiamcu => .ELFIAMCU,
        .tvos => .TvOS,
        .watchos => .WatchOS,
        .mesa3d => .Mesa3D,
        .contiki => .Contiki,
        .amdpal => .AMDPAL,
        .hermit => .HermitCore,
        .hurd => .Hurd,
        .wasi => .WASI,
        .emscripten => .Emscripten,
        .driverkit => .DriverKit,
        .shadermodel => .ShaderModel,
    };
}

pub fn targetArch(arch_tag: std.Target.Cpu.Arch) llvm.ArchType {
    return switch (arch_tag) {
        .arm => .arm,
        .armeb => .armeb,
        .aarch64 => .aarch64,
        .aarch64_be => .aarch64_be,
        .aarch64_32 => .aarch64_32,
        .arc => .arc,
        .avr => .avr,
        .bpfel => .bpfel,
        .bpfeb => .bpfeb,
        .csky => .csky,
        .dxil => .dxil,
        .hexagon => .hexagon,
        .loongarch32 => .loongarch32,
        .loongarch64 => .loongarch64,
        .m68k => .m68k,
        .mips => .mips,
        .mipsel => .mipsel,
        .mips64 => .mips64,
        .mips64el => .mips64el,
        .msp430 => .msp430,
        .powerpc => .ppc,
        .powerpcle => .ppcle,
        .powerpc64 => .ppc64,
        .powerpc64le => .ppc64le,
        .r600 => .r600,
        .amdgcn => .amdgcn,
        .riscv32 => .riscv32,
        .riscv64 => .riscv64,
        .sparc => .sparc,
        .sparc64 => .sparcv9, // In LLVM, sparc64 == sparcv9.
        .sparcel => .sparcel,
        .s390x => .systemz,
        .tce => .tce,
        .tcele => .tcele,
        .thumb => .thumb,
        .thumbeb => .thumbeb,
        .x86 => .x86,
        .x86_64 => .x86_64,
        .xcore => .xcore,
        .xtensa => .xtensa,
        .nvptx => .nvptx,
        .nvptx64 => .nvptx64,
        .le32 => .le32,
        .le64 => .le64,
        .amdil => .amdil,
        .amdil64 => .amdil64,
        .hsail => .hsail,
        .hsail64 => .hsail64,
        .spir => .spir,
        .spir64 => .spir64,
        .kalimba => .kalimba,
        .shave => .shave,
        .lanai => .lanai,
        .wasm32 => .wasm32,
        .wasm64 => .wasm64,
        .renderscript32 => .renderscript32,
        .renderscript64 => .renderscript64,
        .ve => .ve,
        .spu_2, .spirv32, .spirv64 => .UnknownArch,
    };
}

pub fn supportsTailCall(target: std.Target) bool {
    switch (target.cpu.arch) {
        .wasm32, .wasm64 => return std.Target.wasm.featureSetHas(target.cpu.features, .tail_call),
        // Although these ISAs support tail calls, LLVM does not support tail calls on them.
        .mips, .mipsel, .mips64, .mips64el => return false,
        .powerpc, .powerpcle, .powerpc64, .powerpc64le => return false,
        else => return true,
    }
}

const DataLayoutBuilder = struct {
    target: std.Target,

    pub fn format(
        self: DataLayoutBuilder,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        const is_aarch64_windows = self.target.cpu.arch == .aarch64 and self.target.os.tag == .windows;
        try writer.print("{c}-m:{c}", .{
            @as(u8, switch (self.target.cpu.arch.endian()) {
                .Little => 'e',
                .Big => 'E',
            }),
            @as(u8, if (self.target.cpu.arch.isMIPS())
                'm' // Mips mangling: Private symbols get a $ prefix.
            else switch (self.target.ofmt) {
                .elf => 'e', // ELF mangling: Private symbols get a `.L` prefix.
                //.goff => 'l', // GOFF mangling: Private symbols get a `@` prefix.
                .macho => 'o', // Mach-O mangling: Private symbols get `L` prefix.
                // Other symbols get a `_` prefix.
                .coff => switch (self.target.os.tag) {
                    .windows => switch (self.target.cpu.arch) {
                        .x86 => 'x', // Windows x86 COFF mangling: Private symbols get the usual prefix.
                        // Regular C symbols get a `_` prefix. Functions with `__stdcall`, `__fastcall`,
                        // and `__vectorcall` have custom mangling that appends `@N` where N is the
                        // number of bytes used to pass parameters. C++ symbols starting with `?` are
                        // not mangled in any way.
                        else => 'w', // Windows COFF mangling: Similar to x, except that normal C
                        // symbols do not receive a `_` prefix.
                    },
                    else => 'e',
                },
                //.xcoff => 'a', // XCOFF mangling: Private symbols get a `L..` prefix.
                else => 'e',
            }),
        });
        var any_non_integral = false;
        const ptr_bit_width = self.target.ptrBitWidth();
        var default_info = struct { size: u16, abi: u16, pref: u16, idx: u16 }{
            .size = 64,
            .abi = 64,
            .pref = 64,
            .idx = 64,
        };
        const addr_space_info = llvmAddrSpaceInfo(self.target);
        for (addr_space_info, 0..) |info, i| {
            assert((info.llvm == .default) == (i == 0));
            if (info.non_integral) {
                assert(info.llvm != .default);
                any_non_integral = true;
            }
            const size = info.size orelse ptr_bit_width;
            const abi = info.abi orelse ptr_bit_width;
            const pref = info.pref orelse abi;
            const idx = info.idx orelse size;
            const matches_default =
                size == default_info.size and
                abi == default_info.abi and
                pref == default_info.pref and
                idx == default_info.idx;
            if (info.llvm == .default) default_info = .{
                .size = size,
                .abi = abi,
                .pref = pref,
                .idx = idx,
            };
            if (!info.force_in_data_layout and matches_default and
                self.target.cpu.arch != .riscv64 and !is_aarch64_windows) continue;
            try writer.writeAll("-p");
            if (info.llvm != .default) try writer.print("{d}", .{@intFromEnum(info.llvm)});
            try writer.print(":{d}:{d}", .{ size, abi });
            if (pref != abi or idx != size) {
                try writer.print(":{d}", .{pref});
                if (idx != size) try writer.print(":{d}", .{idx});
            }
        }
        if (self.target.cpu.arch.isARM() or self.target.cpu.arch.isThumb())
            try writer.writeAll("-Fi8"); // for thumb interwork
        try self.typeAlignment(.integer, 8, 8, 8, false, writer);
        try self.typeAlignment(.integer, 16, 16, 16, false, writer);
        try self.typeAlignment(.integer, 32, if (is_aarch64_windows) 0 else 32, 32, false, writer);
        try self.typeAlignment(.integer, 64, 32, 64, false, writer);
        try self.typeAlignment(.integer, 128, 32, 64, false, writer);
        if (backendSupportsF16(self.target)) try self.typeAlignment(.float, 16, 16, 16, false, writer);
        try self.typeAlignment(.float, 32, 32, 32, false, writer);
        try self.typeAlignment(.float, 64, 64, 64, false, writer);
        if (backendSupportsF80(self.target)) try self.typeAlignment(.float, 80, 0, 0, false, writer);
        try self.typeAlignment(.float, 128, 128, 128, false, writer);
        try self.typeAlignment(.vector, 64, 64, 64, false, writer);
        try self.typeAlignment(.vector, 128, 128, 128, false, writer);
        if (self.target.os.tag != .windows) try self.typeAlignment(.aggregate, 0, 0, 64, false, writer);
        for (@as([]const u24, switch (self.target.cpu.arch) {
            .aarch64_32,
            .arm,
            .armeb,
            .mips,
            .mipsel,
            .powerpc,
            .powerpcle,
            .thumb,
            .thumbeb,
            .riscv32,
            => &.{32},
            .aarch64,
            .aarch64_be,
            .mips64,
            .mips64el,
            .powerpc64,
            .powerpc64le,
            .riscv64,
            .wasm32,
            .wasm64,
            => &.{ 32, 64 },
            .x86 => &.{ 8, 16, 32 },
            .x86_64 => &.{ 8, 16, 32, 64 },
            else => &.{},
        }), 0..) |natural, index| switch (index) {
            0 => try writer.print("-n{d}", .{natural}),
            else => try writer.print(":{d}", .{natural}),
        };
        if (self.target.os.tag == .windows) try self.typeAlignment(.aggregate, 0, 0, 64, false, writer);
        const stack_abi = self.target.stackAlignment() * 8;
        if (self.target.os.tag == .windows or stack_abi != ptr_bit_width)
            try writer.print("-S{d}", .{stack_abi});
        try self.typeAlignment(.vector, 256, 128, 128, true, writer);
        try self.typeAlignment(.vector, 512, 128, 128, true, writer);
        if (any_non_integral) {
            try writer.writeAll("-ni");
            for (addr_space_info) |info| if (info.non_integral)
                try writer.print(":{d}", .{@intFromEnum(info.llvm)});
        }
    }

    fn typeAlignment(
        self: DataLayoutBuilder,
        kind: enum { integer, vector, float, aggregate },
        size: u24,
        default_abi: u24,
        default_pref: u24,
        force_pref: bool,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        var abi = default_abi;
        var pref = default_pref;
        if (kind == .float and size == 80) {
            abi = 128;
            pref = 128;
        }
        for (@as([]const std.Target.CType, switch (kind) {
            .integer => &.{ .char, .short, .int, .long, .longlong },
            .float => &.{ .float, .double, .longdouble },
            .vector, .aggregate => &.{},
        })) |cty| {
            if (self.target.c_type_bit_size(cty) != size) continue;
            abi = self.target.c_type_alignment(cty) * 8;
            pref = self.target.c_type_preferred_alignment(cty) * 8;
            break;
        }
        switch (kind) {
            .integer => {
                abi = @min(abi, self.target.maxIntAlignment() * 8);
                switch (self.target.os.tag) {
                    .linux => switch (self.target.cpu.arch) {
                        .aarch64, .aarch64_be, .mips, .mipsel => pref = @max(pref, 32),
                        else => {},
                    },
                    else => {},
                }
                switch (self.target.cpu.arch) {
                    .aarch64, .aarch64_be, .riscv64 => switch (size) {
                        128 => {
                            abi = size;
                            pref = size;
                        },
                        else => {},
                    },
                    else => {},
                }
            },
            .vector => if (self.target.cpu.arch.isARM() or self.target.cpu.arch.isThumb()) {
                switch (size) {
                    128 => abi = 64,
                    else => {},
                }
            } else if (self.target.cpu.arch.isPPC64()) {
                abi = size;
                pref = size;
            },
            .float => {},
            .aggregate => if (self.target.os.tag == .windows or
                self.target.cpu.arch.isARM() or self.target.cpu.arch.isThumb())
            {
                pref = @min(pref, self.target.ptrBitWidth());
            },
        }
        if (abi == default_abi and pref == default_pref) return;
        try writer.print("-{c}", .{@tagName(kind)[0]});
        if (size != 0) try writer.print("{d}", .{size});
        try writer.print(":{d}", .{abi});
        if (pref != abi or force_pref) try writer.print(":{d}", .{pref});
    }
};

/// TODO can this be done with simpler logic / different API binding?
fn deleteLlvmGlobal(llvm_global: *llvm.Value) void {
    if (llvm_global.globalGetValueType().getTypeKind() == .Function) {
        llvm_global.deleteFunction();
        return;
    }
    return llvm_global.deleteGlobal();
}

pub const Object = struct {
    gpa: Allocator,
    builder: Builder,

    module: *Module,
    llvm_module: *llvm.Module,
    di_builder: ?*llvm.DIBuilder,
    /// One of these mappings:
    /// - *Module.File => *DIFile
    /// - *Module.Decl (Fn) => *DISubprogram
    /// - *Module.Decl (Non-Fn) => *DIGlobalVariable
    di_map: std.AutoHashMapUnmanaged(*const anyopaque, *llvm.DINode),
    di_compile_unit: ?*llvm.DICompileUnit,
    context: *llvm.Context,
    target_machine: *llvm.TargetMachine,
    target_data: *llvm.TargetData,
    target: std.Target,
    /// Ideally we would use `llvm_module.getNamedFunction` to go from *Decl to LLVM function,
    /// but that has some downsides:
    /// * we have to compute the fully qualified name every time we want to do the lookup
    /// * for externally linked functions, the name is not fully qualified, but when
    ///   a Decl goes from exported to not exported and vice-versa, we would use the wrong
    ///   version of the name and incorrectly get function not found in the llvm module.
    /// * it works for functions not all globals.
    /// Therefore, this table keeps track of the mapping.
    decl_map: std.AutoHashMapUnmanaged(Module.Decl.Index, Builder.Global.Index),
    /// Serves the same purpose as `decl_map` but only used for the `is_named_enum_value` instruction.
    named_enum_map: std.AutoHashMapUnmanaged(Module.Decl.Index, Builder.Function.Index),
    /// Maps Zig types to LLVM types. The table memory is backed by the GPA of
    /// the compiler.
    /// TODO when InternPool garbage collection is implemented, this map needs
    /// to be garbage collected as well.
    type_map: TypeMap,
    di_type_map: DITypeMap,
    /// The LLVM global table which holds the names corresponding to Zig errors.
    /// Note that the values are not added until flushModule, when all errors in
    /// the compilation are known.
    error_name_table: ?*llvm.Value,
    /// This map is usually very close to empty. It tracks only the cases when a
    /// second extern Decl could not be emitted with the correct name due to a
    /// name collision.
    extern_collisions: std.AutoArrayHashMapUnmanaged(Module.Decl.Index, void),

    /// Memoizes a null `?usize` value.
    null_opt_addr: ?*llvm.Value,

    pub const TypeMap = std.AutoHashMapUnmanaged(InternPool.Index, Builder.Type);

    /// This is an ArrayHashMap as opposed to a HashMap because in `flushModule` we
    /// want to iterate over it while adding entries to it.
    pub const DITypeMap = std.AutoArrayHashMapUnmanaged(InternPool.Index, AnnotatedDITypePtr);

    pub fn create(gpa: Allocator, options: link.Options) !*Object {
        const obj = try gpa.create(Object);
        errdefer gpa.destroy(obj);
        obj.* = try Object.init(gpa, options);
        return obj;
    }

    pub fn init(gpa: Allocator, options: link.Options) !Object {
        var builder = Builder{
            .gpa = gpa,
            .use_lib_llvm = options.use_lib_llvm,

            .llvm_context = llvm.Context.create(),
            .llvm_module = undefined,
        };
        errdefer builder.llvm_context.dispose();

        builder.initializeLLVMTarget(options.target.cpu.arch);

        builder.llvm_module = llvm.Module.createWithName(options.root_name.ptr, builder.llvm_context);
        errdefer builder.llvm_module.dispose();

        const llvm_target_triple = try targetTriple(gpa, options.target);
        defer gpa.free(llvm_target_triple);

        var error_message: [*:0]const u8 = undefined;
        var target: *llvm.Target = undefined;
        if (llvm.Target.getFromTriple(llvm_target_triple.ptr, &target, &error_message).toBool()) {
            defer llvm.disposeMessage(error_message);

            log.err("LLVM failed to parse '{s}': {s}", .{ llvm_target_triple, error_message });
            return error.InvalidLlvmTriple;
        }

        builder.llvm_module.setTarget(llvm_target_triple.ptr);
        var opt_di_builder: ?*llvm.DIBuilder = null;
        errdefer if (opt_di_builder) |di_builder| di_builder.dispose();

        var di_compile_unit: ?*llvm.DICompileUnit = null;

        if (!options.strip) {
            switch (options.target.ofmt) {
                .coff => builder.llvm_module.addModuleCodeViewFlag(),
                else => builder.llvm_module.addModuleDebugInfoFlag(options.dwarf_format == std.dwarf.Format.@"64"),
            }
            const di_builder = builder.llvm_module.createDIBuilder(true);
            opt_di_builder = di_builder;

            // Don't use the version string here; LLVM misparses it when it
            // includes the git revision.
            const producer = try std.fmt.allocPrintZ(gpa, "zig {d}.{d}.{d}", .{
                build_options.semver.major,
                build_options.semver.minor,
                build_options.semver.patch,
            });
            defer gpa.free(producer);

            // We fully resolve all paths at this point to avoid lack of source line info in stack
            // traces or lack of debugging information which, if relative paths were used, would
            // be very location dependent.
            // TODO: the only concern I have with this is WASI as either host or target, should
            // we leave the paths as relative then?
            var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const compile_unit_dir = blk: {
                const path = d: {
                    const mod = options.module orelse break :d ".";
                    break :d mod.root_pkg.root_src_directory.path orelse ".";
                };
                if (std.fs.path.isAbsolute(path)) break :blk path;
                break :blk std.os.realpath(path, &buf) catch path; // If realpath fails, fallback to whatever path was
            };
            const compile_unit_dir_z = try gpa.dupeZ(u8, compile_unit_dir);
            defer gpa.free(compile_unit_dir_z);

            di_compile_unit = di_builder.createCompileUnit(
                DW.LANG.C99,
                di_builder.createFile(options.root_name, compile_unit_dir_z),
                producer,
                options.optimize_mode != .Debug,
                "", // flags
                0, // runtime version
                "", // split name
                0, // dwo id
                true, // emit debug info
            );
        }

        const opt_level: llvm.CodeGenOptLevel = if (options.optimize_mode == .Debug)
            .None
        else
            .Aggressive;

        const reloc_mode: llvm.RelocMode = if (options.pic)
            .PIC
        else if (options.link_mode == .Dynamic)
            llvm.RelocMode.DynamicNoPIC
        else
            .Static;

        const code_model: llvm.CodeModel = switch (options.machine_code_model) {
            .default => .Default,
            .tiny => .Tiny,
            .small => .Small,
            .kernel => .Kernel,
            .medium => .Medium,
            .large => .Large,
        };

        // TODO handle float ABI better- it should depend on the ABI portion of std.Target
        const float_abi: llvm.ABIType = .Default;

        const target_machine = llvm.TargetMachine.create(
            target,
            llvm_target_triple.ptr,
            if (options.target.cpu.model.llvm_name) |s| s.ptr else null,
            options.llvm_cpu_features,
            opt_level,
            reloc_mode,
            code_model,
            options.function_sections,
            float_abi,
            if (target_util.llvmMachineAbi(options.target)) |s| s.ptr else null,
        );
        errdefer target_machine.dispose();

        const target_data = target_machine.createTargetDataLayout();
        errdefer target_data.dispose();

        builder.llvm_module.setModuleDataLayout(target_data);

        if (options.pic) builder.llvm_module.setModulePICLevel();
        if (options.pie) builder.llvm_module.setModulePIELevel();
        if (code_model != .Default) builder.llvm_module.setModuleCodeModel(code_model);

        if (options.opt_bisect_limit >= 0) {
            builder.llvm_context.setOptBisectLimit(std.math.lossyCast(c_int, options.opt_bisect_limit));
        }

        try builder.init();
        errdefer builder.deinit();
        builder.source_filename = try builder.string(options.root_name);
        builder.data_layout = try builder.fmt("{}", .{DataLayoutBuilder{ .target = options.target }});
        builder.target_triple = try builder.string(llvm_target_triple);

        if (std.debug.runtime_safety) {
            const rep = target_data.stringRep();
            defer llvm.disposeMessage(rep);
            std.testing.expectEqualStrings(
                std.mem.span(rep),
                builder.data_layout.toSlice(&builder).?,
            ) catch unreachable;
        }

        return Object{
            .gpa = gpa,
            .builder = builder,
            .module = options.module.?,
            .llvm_module = builder.llvm_module,
            .di_map = .{},
            .di_builder = opt_di_builder,
            .di_compile_unit = di_compile_unit,
            .context = builder.llvm_context,
            .target_machine = target_machine,
            .target_data = target_data,
            .target = options.target,
            .decl_map = .{},
            .named_enum_map = .{},
            .type_map = .{},
            .di_type_map = .{},
            .error_name_table = null,
            .extern_collisions = .{},
            .null_opt_addr = null,
        };
    }

    pub fn deinit(self: *Object, gpa: Allocator) void {
        if (self.di_builder) |dib| {
            dib.dispose();
            self.di_map.deinit(gpa);
            self.di_type_map.deinit(gpa);
        }
        self.target_data.dispose();
        self.target_machine.dispose();
        self.llvm_module.dispose();
        self.context.dispose();
        self.decl_map.deinit(gpa);
        self.named_enum_map.deinit(gpa);
        self.type_map.deinit(gpa);
        self.extern_collisions.deinit(gpa);
        self.builder.deinit();
        self.* = undefined;
    }

    pub fn destroy(self: *Object, gpa: Allocator) void {
        self.deinit(gpa);
        gpa.destroy(self);
    }

    fn locPath(
        arena: Allocator,
        opt_loc: ?Compilation.EmitLoc,
        cache_directory: Compilation.Directory,
    ) !?[*:0]u8 {
        const loc = opt_loc orelse return null;
        const directory = loc.directory orelse cache_directory;
        const slice = try directory.joinZ(arena, &[_][]const u8{loc.basename});
        return slice.ptr;
    }

    fn genErrorNameTable(o: *Object) !void {
        // If o.error_name_table is null, there was no instruction that actually referenced the error table.
        const error_name_table_ptr_global = o.error_name_table orelse return;

        const mod = o.module;

        // TODO: Address space
        const llvm_usize_ty = try o.lowerType(Type.usize);
        const llvm_slice_ty = (try o.builder.structType(.normal, &.{ .ptr, llvm_usize_ty })).toLlvm(&o.builder);
        const slice_ty = Type.slice_const_u8_sentinel_0;
        const slice_alignment = slice_ty.abiAlignment(mod);

        const error_name_list = mod.global_error_set.keys();
        const llvm_errors = try mod.gpa.alloc(*llvm.Value, error_name_list.len);
        defer mod.gpa.free(llvm_errors);

        llvm_errors[0] = llvm_slice_ty.getUndef();
        for (llvm_errors[1..], error_name_list[1..]) |*llvm_error, name_nts| {
            const name = mod.intern_pool.stringToSlice(name_nts);
            const str_init = o.context.constString(name.ptr, @as(c_uint, @intCast(name.len)), .False);
            const str_global = o.llvm_module.addGlobal(str_init.typeOf(), "");
            str_global.setInitializer(str_init);
            str_global.setLinkage(.Private);
            str_global.setGlobalConstant(.True);
            str_global.setUnnamedAddr(.True);
            str_global.setAlignment(1);

            const slice_fields = [_]*llvm.Value{
                str_global,
                (try o.builder.intConst(llvm_usize_ty, name.len)).toLlvm(&o.builder),
            };
            llvm_error.* = llvm_slice_ty.constNamedStruct(&slice_fields, slice_fields.len);
        }

        const error_name_table_init = llvm_slice_ty.constArray(llvm_errors.ptr, @as(c_uint, @intCast(error_name_list.len)));

        const error_name_table_global = o.llvm_module.addGlobal(error_name_table_init.typeOf(), "");
        error_name_table_global.setInitializer(error_name_table_init);
        error_name_table_global.setLinkage(.Private);
        error_name_table_global.setGlobalConstant(.True);
        error_name_table_global.setUnnamedAddr(.True);
        error_name_table_global.setAlignment(slice_alignment); // TODO: Dont hardcode

        const error_name_table_ptr = error_name_table_global;
        error_name_table_ptr_global.setInitializer(error_name_table_ptr);
    }

    fn genCmpLtErrorsLenFunction(object: *Object) !void {
        // If there is no such function in the module, it means the source code does not need it.
        const llvm_fn = object.llvm_module.getNamedFunction(lt_errors_fn_name) orelse return;
        const mod = object.module;
        const errors_len = mod.global_error_set.count();

        // Delete previous implementation. We replace it with every flush() because the
        // total number of errors may have changed.
        while (llvm_fn.getFirstBasicBlock()) |bb| {
            bb.deleteBasicBlock();
        }

        const builder = object.context.createBuilder();

        const entry_block = object.context.appendBasicBlock(llvm_fn, "Entry");
        builder.positionBuilderAtEnd(entry_block);
        builder.clearCurrentDebugLocation();

        // Example source of the following LLVM IR:
        // fn __zig_lt_errors_len(index: u16) bool {
        //     return index < total_errors_len;
        // }

        const lhs = llvm_fn.getParam(0);
        const rhs = try object.builder.intConst(Builder.Type.err_int, errors_len);
        const is_lt = builder.buildICmp(.ULT, lhs, rhs.toLlvm(&object.builder), "");
        _ = builder.buildRet(is_lt);
    }

    fn genModuleLevelAssembly(object: *Object) !void {
        const mod = object.module;
        if (mod.global_assembly.count() == 0) return;
        var buffer = std.ArrayList(u8).init(mod.gpa);
        defer buffer.deinit();
        var it = mod.global_assembly.iterator();
        while (it.next()) |kv| {
            try buffer.appendSlice(kv.value_ptr.*);
            try buffer.append('\n');
        }
        object.llvm_module.setModuleInlineAsm2(buffer.items.ptr, buffer.items.len - 1);
    }

    fn resolveExportExternCollisions(object: *Object) !void {
        const mod = object.module;

        // This map has externs with incorrect symbol names.
        for (object.extern_collisions.keys()) |decl_index| {
            const global = object.decl_map.get(decl_index) orelse continue;
            const llvm_global = global.toLlvm(&object.builder);
            // Same logic as below but for externs instead of exports.
            const decl_name = object.builder.stringIfExists(mod.intern_pool.stringToSlice(mod.declPtr(decl_index).name)) orelse continue;
            const other_global = object.builder.getGlobal(decl_name) orelse continue;
            const other_llvm_global = other_global.toLlvm(&object.builder);
            if (other_llvm_global == llvm_global) continue;

            llvm_global.replaceAllUsesWith(other_llvm_global);
            deleteLlvmGlobal(llvm_global);
            object.builder.llvm_globals.items[@intFromEnum(global)] = other_llvm_global;
        }
        object.extern_collisions.clearRetainingCapacity();

        for (mod.decl_exports.keys(), mod.decl_exports.values()) |decl_index, export_list| {
            const global = object.decl_map.get(decl_index) orelse continue;
            const llvm_global = global.toLlvm(&object.builder);
            for (export_list.items) |exp| {
                // Detect if the LLVM global has already been created as an extern. In such
                // case, we need to replace all uses of it with this exported global.
                const exp_name = object.builder.stringIfExists(mod.intern_pool.stringToSlice(exp.opts.name)) orelse continue;

                const other_global = object.builder.getGlobal(exp_name) orelse continue;
                const other_llvm_global = other_global.toLlvm(&object.builder);
                if (other_llvm_global == llvm_global) continue;

                other_llvm_global.replaceAllUsesWith(llvm_global);
                try global.takeName(&object.builder, other_global);
                deleteLlvmGlobal(other_llvm_global);
                object.builder.llvm_globals.items[@intFromEnum(other_global)] = llvm_global;
                // Problem: now we need to replace in the decl_map that
                // the extern decl index points to this new global. However we don't
                // know the decl index.
                // Even if we did, a future incremental update to the extern would then
                // treat the LLVM global as an extern rather than an export, so it would
                // need a way to check that.
                // This is a TODO that needs to be solved when making
                // the LLVM backend support incremental compilation.
            }
        }
    }

    pub fn flushModule(self: *Object, comp: *Compilation, prog_node: *std.Progress.Node) !void {
        var sub_prog_node = prog_node.start("LLVM Emit Object", 0);
        sub_prog_node.activate();
        sub_prog_node.context.refresh();
        defer sub_prog_node.end();

        try self.resolveExportExternCollisions();
        try self.genErrorNameTable();
        try self.genCmpLtErrorsLenFunction();
        try self.genModuleLevelAssembly();

        if (self.di_builder) |dib| {
            // When lowering debug info for pointers, we emitted the element types as
            // forward decls. Now we must go flesh those out.
            // Here we iterate over a hash map while modifying it but it is OK because
            // we never add or remove entries during this loop.
            var i: usize = 0;
            while (i < self.di_type_map.count()) : (i += 1) {
                const value_ptr = &self.di_type_map.values()[i];
                const annotated = value_ptr.*;
                if (!annotated.isFwdOnly()) continue;
                const entry: Object.DITypeMap.Entry = .{
                    .key_ptr = &self.di_type_map.keys()[i],
                    .value_ptr = value_ptr,
                };
                _ = try self.lowerDebugTypeImpl(entry, .full, annotated.toDIType());
            }

            dib.finalize();
        }

        if (comp.verbose_llvm_ir) |path| {
            if (std.mem.eql(u8, path, "-")) {
                self.llvm_module.dump();

                const writer = std.io.getStdErr().writer();
                try writer.writeAll("\n" ++ "-" ** 200 ++ "\n\n");
                try self.builder.dump(writer);
            } else {
                const path_z = try comp.gpa.dupeZ(u8, path);
                defer comp.gpa.free(path_z);

                var error_message: [*:0]const u8 = undefined;

                if (self.llvm_module.printModuleToFile(path_z, &error_message).toBool()) {
                    defer llvm.disposeMessage(error_message);

                    log.err("dump LLVM module failed ir={s}: {s}", .{
                        path, error_message,
                    });
                }
            }
        }

        if (comp.verbose_llvm_bc) |path| {
            const path_z = try comp.gpa.dupeZ(u8, path);
            defer comp.gpa.free(path_z);

            const error_code = self.llvm_module.writeBitcodeToFile(path_z);
            if (error_code != 0) {
                log.err("dump LLVM module failed bc={s}: {d}", .{
                    path, error_code,
                });
            }
        }

        var arena_allocator = std.heap.ArenaAllocator.init(comp.gpa);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        const mod = comp.bin_file.options.module.?;
        const cache_dir = mod.zig_cache_artifact_directory;

        if (std.debug.runtime_safety) {
            var error_message: [*:0]const u8 = undefined;
            // verifyModule always allocs the error_message even if there is no error
            defer llvm.disposeMessage(error_message);

            if (self.llvm_module.verify(.ReturnStatus, &error_message).toBool()) {
                std.debug.print("\n{s}\n", .{error_message});

                if (try locPath(arena, comp.emit_llvm_ir, cache_dir)) |emit_llvm_ir_path| {
                    _ = self.llvm_module.printModuleToFile(emit_llvm_ir_path, &error_message);
                }

                @panic("LLVM module verification failed");
            }
        }

        var emit_bin_path: ?[*:0]const u8 = if (comp.bin_file.options.emit) |emit|
            try emit.basenamePath(arena, try arena.dupeZ(u8, comp.bin_file.intermediary_basename.?))
        else
            null;

        const emit_asm_path = try locPath(arena, comp.emit_asm, cache_dir);
        var emit_llvm_ir_path = try locPath(arena, comp.emit_llvm_ir, cache_dir);
        const emit_llvm_bc_path = try locPath(arena, comp.emit_llvm_bc, cache_dir);

        const emit_asm_msg = emit_asm_path orelse "(none)";
        const emit_bin_msg = emit_bin_path orelse "(none)";
        const emit_llvm_ir_msg = emit_llvm_ir_path orelse "(none)";
        const emit_llvm_bc_msg = emit_llvm_bc_path orelse "(none)";
        log.debug("emit LLVM object asm={s} bin={s} ir={s} bc={s}", .{
            emit_asm_msg, emit_bin_msg, emit_llvm_ir_msg, emit_llvm_bc_msg,
        });

        // Unfortunately, LLVM shits the bed when we ask for both binary and assembly.
        // So we call the entire pipeline multiple times if this is requested.
        var error_message: [*:0]const u8 = undefined;
        if (emit_asm_path != null and emit_bin_path != null) {
            if (self.target_machine.emitToFile(
                self.llvm_module,
                &error_message,
                comp.bin_file.options.optimize_mode == .Debug,
                comp.bin_file.options.optimize_mode == .ReleaseSmall,
                comp.time_report,
                comp.bin_file.options.tsan,
                comp.bin_file.options.lto,
                null,
                emit_bin_path,
                emit_llvm_ir_path,
                null,
            )) {
                defer llvm.disposeMessage(error_message);

                log.err("LLVM failed to emit bin={s} ir={s}: {s}", .{
                    emit_bin_msg, emit_llvm_ir_msg, error_message,
                });
                return error.FailedToEmit;
            }
            emit_bin_path = null;
            emit_llvm_ir_path = null;
        }

        if (self.target_machine.emitToFile(
            self.llvm_module,
            &error_message,
            comp.bin_file.options.optimize_mode == .Debug,
            comp.bin_file.options.optimize_mode == .ReleaseSmall,
            comp.time_report,
            comp.bin_file.options.tsan,
            comp.bin_file.options.lto,
            emit_asm_path,
            emit_bin_path,
            emit_llvm_ir_path,
            emit_llvm_bc_path,
        )) {
            defer llvm.disposeMessage(error_message);

            log.err("LLVM failed to emit asm={s} bin={s} ir={s} bc={s}: {s}", .{
                emit_asm_msg,  emit_bin_msg, emit_llvm_ir_msg, emit_llvm_bc_msg,
                error_message,
            });
            return error.FailedToEmit;
        }
    }

    pub fn updateFunc(
        o: *Object,
        mod: *Module,
        func_index: Module.Fn.Index,
        air: Air,
        liveness: Liveness,
    ) !void {
        const func = mod.funcPtr(func_index);
        const decl_index = func.owner_decl;
        const decl = mod.declPtr(decl_index);
        const target = mod.getTarget();

        var dg: DeclGen = .{
            .object = o,
            .decl_index = decl_index,
            .decl = decl,
            .err_msg = null,
        };

        const function_index = try o.resolveLlvmFunction(decl_index);
        const function = function_index.ptr(&o.builder);
        const llvm_func = function.global.toLlvm(&o.builder);

        if (mod.align_stack_fns.get(func_index)) |align_info| {
            o.addFnAttrInt(llvm_func, "alignstack", align_info.alignment.toByteUnitsOptional().?);
            o.addFnAttr(llvm_func, "noinline");
        } else {
            Object.removeFnAttr(llvm_func, "alignstack");
            if (!func.is_noinline) Object.removeFnAttr(llvm_func, "noinline");
        }

        if (func.is_cold) {
            o.addFnAttr(llvm_func, "cold");
        } else {
            Object.removeFnAttr(llvm_func, "cold");
        }

        if (func.is_noinline) {
            o.addFnAttr(llvm_func, "noinline");
        } else {
            Object.removeFnAttr(llvm_func, "noinline");
        }

        // TODO: disable this if safety is off for the function scope
        const ssp_buf_size = mod.comp.bin_file.options.stack_protector;
        if (ssp_buf_size != 0) {
            var buf: [12]u8 = undefined;
            const arg = std.fmt.bufPrintZ(&buf, "{d}", .{ssp_buf_size}) catch unreachable;
            o.addFnAttr(llvm_func, "sspstrong");
            o.addFnAttrString(llvm_func, "stack-protector-buffer-size", arg);
        }

        // TODO: disable this if safety is off for the function scope
        if (mod.comp.bin_file.options.stack_check) {
            o.addFnAttrString(llvm_func, "probe-stack", "__zig_probe_stack");
        } else if (target.os.tag == .uefi) {
            o.addFnAttrString(llvm_func, "no-stack-arg-probe", "");
        }

        if (mod.intern_pool.stringToSliceUnwrap(decl.@"linksection")) |section|
            llvm_func.setSection(section);

        // Remove all the basic blocks of a function in order to start over, generating
        // LLVM IR from an empty function body.
        while (llvm_func.getFirstBasicBlock()) |bb| {
            bb.deleteBasicBlock();
        }

        const builder = o.context.createBuilder();

        function.body = {};
        const entry_block = o.context.appendBasicBlock(llvm_func, "Entry");
        builder.positionBuilderAtEnd(entry_block);

        // This gets the LLVM values from the function and stores them in `dg.args`.
        const fn_info = mod.typeToFunc(decl.ty).?;
        const sret = firstParamSRet(fn_info, mod);
        const ret_ptr = if (sret) llvm_func.getParam(0) else null;
        const gpa = o.gpa;

        if (ccAbiPromoteInt(fn_info.cc, mod, fn_info.return_type.toType())) |s| switch (s) {
            .signed => o.addAttr(llvm_func, 0, "signext"),
            .unsigned => o.addAttr(llvm_func, 0, "zeroext"),
        };

        const err_return_tracing = fn_info.return_type.toType().isError(mod) and
            mod.comp.bin_file.options.error_return_tracing;

        const err_ret_trace = if (err_return_tracing)
            llvm_func.getParam(@intFromBool(ret_ptr != null))
        else
            null;

        // This is the list of args we will use that correspond directly to the AIR arg
        // instructions. Depending on the calling convention, this list is not necessarily
        // a bijection with the actual LLVM parameters of the function.
        var args = std.ArrayList(*llvm.Value).init(gpa);
        defer args.deinit();

        {
            var llvm_arg_i = @as(c_uint, @intFromBool(ret_ptr != null)) + @intFromBool(err_return_tracing);
            var it = iterateParamTypes(o, fn_info);
            while (try it.next()) |lowering| switch (lowering) {
                .no_bits => continue,
                .byval => {
                    assert(!it.byval_attr);
                    const param_index = it.zig_index - 1;
                    const param_ty = fn_info.param_types[param_index].toType();
                    const param = llvm_func.getParam(llvm_arg_i);
                    try args.ensureUnusedCapacity(1);

                    if (isByRef(param_ty, mod)) {
                        const alignment = param_ty.abiAlignment(mod);
                        const param_llvm_ty = param.typeOf();
                        const arg_ptr = try o.buildAllocaInner(builder, llvm_func, false, param_llvm_ty, alignment, target);
                        const store_inst = builder.buildStore(param, arg_ptr);
                        store_inst.setAlignment(alignment);
                        args.appendAssumeCapacity(arg_ptr);
                    } else {
                        args.appendAssumeCapacity(param);

                        o.addByValParamAttrs(llvm_func, param_ty, param_index, fn_info, llvm_arg_i);
                    }
                    llvm_arg_i += 1;
                },
                .byref => {
                    const param_ty = fn_info.param_types[it.zig_index - 1].toType();
                    const param_llvm_ty = try o.lowerType(param_ty);
                    const param = llvm_func.getParam(llvm_arg_i);
                    const alignment = param_ty.abiAlignment(mod);

                    o.addByRefParamAttrs(llvm_func, llvm_arg_i, alignment, it.byval_attr, param_llvm_ty);
                    llvm_arg_i += 1;

                    try args.ensureUnusedCapacity(1);

                    if (isByRef(param_ty, mod)) {
                        args.appendAssumeCapacity(param);
                    } else {
                        const load_inst = builder.buildLoad(param_llvm_ty.toLlvm(&o.builder), param, "");
                        load_inst.setAlignment(alignment);
                        args.appendAssumeCapacity(load_inst);
                    }
                },
                .byref_mut => {
                    const param_ty = fn_info.param_types[it.zig_index - 1].toType();
                    const param_llvm_ty = (try o.lowerType(param_ty)).toLlvm(&o.builder);
                    const param = llvm_func.getParam(llvm_arg_i);
                    const alignment = param_ty.abiAlignment(mod);

                    o.addArgAttr(llvm_func, llvm_arg_i, "noundef");
                    llvm_arg_i += 1;

                    try args.ensureUnusedCapacity(1);

                    if (isByRef(param_ty, mod)) {
                        args.appendAssumeCapacity(param);
                    } else {
                        const load_inst = builder.buildLoad(param_llvm_ty, param, "");
                        load_inst.setAlignment(alignment);
                        args.appendAssumeCapacity(load_inst);
                    }
                },
                .abi_sized_int => {
                    assert(!it.byval_attr);
                    const param_ty = fn_info.param_types[it.zig_index - 1].toType();
                    const param = llvm_func.getParam(llvm_arg_i);
                    llvm_arg_i += 1;

                    const param_llvm_ty = (try o.lowerType(param_ty)).toLlvm(&o.builder);
                    const abi_size = @as(c_uint, @intCast(param_ty.abiSize(mod)));
                    const int_llvm_ty = (try o.builder.intType(@intCast(abi_size * 8))).toLlvm(&o.builder);
                    const alignment = @max(
                        param_ty.abiAlignment(mod),
                        o.target_data.abiAlignmentOfType(int_llvm_ty),
                    );
                    const arg_ptr = try o.buildAllocaInner(builder, llvm_func, false, param_llvm_ty, alignment, target);
                    const store_inst = builder.buildStore(param, arg_ptr);
                    store_inst.setAlignment(alignment);

                    try args.ensureUnusedCapacity(1);

                    if (isByRef(param_ty, mod)) {
                        args.appendAssumeCapacity(arg_ptr);
                    } else {
                        const load_inst = builder.buildLoad(param_llvm_ty, arg_ptr, "");
                        load_inst.setAlignment(alignment);
                        args.appendAssumeCapacity(load_inst);
                    }
                },
                .slice => {
                    assert(!it.byval_attr);
                    const param_ty = fn_info.param_types[it.zig_index - 1].toType();
                    const ptr_info = param_ty.ptrInfo(mod);

                    if (math.cast(u5, it.zig_index - 1)) |i| {
                        if (@as(u1, @truncate(fn_info.noalias_bits >> i)) != 0) {
                            o.addArgAttr(llvm_func, llvm_arg_i, "noalias");
                        }
                    }
                    if (param_ty.zigTypeTag(mod) != .Optional) {
                        o.addArgAttr(llvm_func, llvm_arg_i, "nonnull");
                    }
                    if (ptr_info.flags.is_const) {
                        o.addArgAttr(llvm_func, llvm_arg_i, "readonly");
                    }
                    const elem_align = ptr_info.flags.alignment.toByteUnitsOptional() orelse
                        @max(ptr_info.child.toType().abiAlignment(mod), 1);
                    o.addArgAttrInt(llvm_func, llvm_arg_i, "align", elem_align);
                    const ptr_param = llvm_func.getParam(llvm_arg_i);
                    llvm_arg_i += 1;
                    const len_param = llvm_func.getParam(llvm_arg_i);
                    llvm_arg_i += 1;

                    const slice_llvm_ty = (try o.lowerType(param_ty)).toLlvm(&o.builder);
                    const partial = builder.buildInsertValue(slice_llvm_ty.getUndef(), ptr_param, 0, "");
                    const aggregate = builder.buildInsertValue(partial, len_param, 1, "");
                    try args.append(aggregate);
                },
                .multiple_llvm_types => {
                    assert(!it.byval_attr);
                    const field_types = it.types_buffer[0..it.types_len];
                    const param_ty = fn_info.param_types[it.zig_index - 1].toType();
                    const param_llvm_ty = (try o.lowerType(param_ty)).toLlvm(&o.builder);
                    const param_alignment = param_ty.abiAlignment(mod);
                    const arg_ptr = try o.buildAllocaInner(builder, llvm_func, false, param_llvm_ty, param_alignment, target);
                    const llvm_ty = (try o.builder.structType(.normal, field_types)).toLlvm(&o.builder);
                    for (0..field_types.len) |field_i_usize| {
                        const field_i = @as(c_uint, @intCast(field_i_usize));
                        const param = llvm_func.getParam(llvm_arg_i);
                        llvm_arg_i += 1;
                        const field_ptr = builder.buildStructGEP(llvm_ty, arg_ptr, field_i, "");
                        const store_inst = builder.buildStore(param, field_ptr);
                        store_inst.setAlignment(target.ptrBitWidth() / 8);
                    }

                    const is_by_ref = isByRef(param_ty, mod);
                    const loaded = if (is_by_ref) arg_ptr else l: {
                        const load_inst = builder.buildLoad(param_llvm_ty, arg_ptr, "");
                        load_inst.setAlignment(param_alignment);
                        break :l load_inst;
                    };
                    try args.append(loaded);
                },
                .as_u16 => {
                    assert(!it.byval_attr);
                    const param = llvm_func.getParam(llvm_arg_i);
                    llvm_arg_i += 1;
                    const casted = builder.buildBitCast(param, Builder.Type.half.toLlvm(&o.builder), "");
                    try args.ensureUnusedCapacity(1);
                    args.appendAssumeCapacity(casted);
                },
                .float_array => {
                    const param_ty = fn_info.param_types[it.zig_index - 1].toType();
                    const param_llvm_ty = (try o.lowerType(param_ty)).toLlvm(&o.builder);
                    const param = llvm_func.getParam(llvm_arg_i);
                    llvm_arg_i += 1;

                    const alignment = param_ty.abiAlignment(mod);
                    const arg_ptr = try o.buildAllocaInner(builder, llvm_func, false, param_llvm_ty, alignment, target);
                    _ = builder.buildStore(param, arg_ptr);

                    if (isByRef(param_ty, mod)) {
                        try args.append(arg_ptr);
                    } else {
                        const load_inst = builder.buildLoad(param_llvm_ty, arg_ptr, "");
                        load_inst.setAlignment(alignment);
                        try args.append(load_inst);
                    }
                },
                .i32_array, .i64_array => {
                    const param_ty = fn_info.param_types[it.zig_index - 1].toType();
                    const param_llvm_ty = (try o.lowerType(param_ty)).toLlvm(&o.builder);
                    const param = llvm_func.getParam(llvm_arg_i);
                    llvm_arg_i += 1;

                    const alignment = param_ty.abiAlignment(mod);
                    const arg_ptr = try o.buildAllocaInner(builder, llvm_func, false, param_llvm_ty, alignment, target);
                    _ = builder.buildStore(param, arg_ptr);

                    if (isByRef(param_ty, mod)) {
                        try args.append(arg_ptr);
                    } else {
                        const load_inst = builder.buildLoad(param_llvm_ty, arg_ptr, "");
                        load_inst.setAlignment(alignment);
                        try args.append(load_inst);
                    }
                },
            };
        }

        var di_file: ?*llvm.DIFile = null;
        var di_scope: ?*llvm.DIScope = null;

        if (o.di_builder) |dib| {
            di_file = try o.getDIFile(gpa, mod.namespacePtr(decl.src_namespace).file_scope);

            const line_number = decl.src_line + 1;
            const is_internal_linkage = decl.val.getExternFunc(mod) == null and
                !mod.decl_exports.contains(decl_index);
            const noret_bit: c_uint = if (fn_info.return_type == .noreturn_type)
                llvm.DIFlags.NoReturn
            else
                0;
            const decl_di_ty = try o.lowerDebugType(decl.ty, .full);
            const subprogram = dib.createFunction(
                di_file.?.toScope(),
                mod.intern_pool.stringToSlice(decl.name),
                llvm_func.getValueName(),
                di_file.?,
                line_number,
                decl_di_ty,
                is_internal_linkage,
                true, // is definition
                line_number + func.lbrace_line, // scope line
                llvm.DIFlags.StaticMember | noret_bit,
                mod.comp.bin_file.options.optimize_mode != .Debug,
                null, // decl_subprogram
            );
            try o.di_map.put(gpa, decl, subprogram.toNode());

            llvm_func.fnSetSubprogram(subprogram);

            di_scope = subprogram.toScope();
        }

        var fg: FuncGen = .{
            .gpa = gpa,
            .air = air,
            .liveness = liveness,
            .context = o.context,
            .dg = &dg,
            .builder = builder,
            .ret_ptr = ret_ptr,
            .args = args.items,
            .arg_index = 0,
            .func_inst_table = .{},
            .llvm_func = llvm_func,
            .blocks = .{},
            .single_threaded = mod.comp.bin_file.options.single_threaded,
            .di_scope = di_scope,
            .di_file = di_file,
            .base_line = dg.decl.src_line,
            .prev_dbg_line = 0,
            .prev_dbg_column = 0,
            .err_ret_trace = err_ret_trace,
        };
        defer fg.deinit();

        fg.genBody(air.getMainBody()) catch |err| switch (err) {
            error.CodegenFail => {
                decl.analysis = .codegen_failure;
                try mod.failed_decls.put(mod.gpa, decl_index, dg.err_msg.?);
                dg.err_msg = null;
                return;
            },
            else => |e| return e,
        };

        try o.updateDeclExports(mod, decl_index, mod.getDeclExports(decl_index));
    }

    pub fn updateDecl(self: *Object, module: *Module, decl_index: Module.Decl.Index) !void {
        const decl = module.declPtr(decl_index);
        var dg: DeclGen = .{
            .object = self,
            .decl = decl,
            .decl_index = decl_index,
            .err_msg = null,
        };
        dg.genDecl() catch |err| switch (err) {
            error.CodegenFail => {
                decl.analysis = .codegen_failure;
                try module.failed_decls.put(module.gpa, decl_index, dg.err_msg.?);
                dg.err_msg = null;
                return;
            },
            else => |e| return e,
        };
        try self.updateDeclExports(module, decl_index, module.getDeclExports(decl_index));
    }

    pub fn updateDeclExports(
        self: *Object,
        mod: *Module,
        decl_index: Module.Decl.Index,
        exports: []const *Module.Export,
    ) !void {
        const gpa = mod.gpa;
        // If the module does not already have the function, we ignore this function call
        // because we call `updateDeclExports` at the end of `updateFunc` and `updateDecl`.
        const global_index = self.decl_map.get(decl_index) orelse return;
        const llvm_global = global_index.toLlvm(&self.builder);
        const decl = mod.declPtr(decl_index);
        if (decl.isExtern(mod)) {
            const decl_name = decl_name: {
                const decl_name = mod.intern_pool.stringToSlice(decl.name);

                if (mod.getTarget().isWasm() and try decl.isFunction(mod)) {
                    if (mod.intern_pool.stringToSliceUnwrap(decl.getOwnedExternFunc(mod).?.lib_name)) |lib_name| {
                        if (!std.mem.eql(u8, lib_name, "c")) {
                            break :decl_name try self.builder.fmt("{s}|{s}", .{ decl_name, lib_name });
                        }
                    }
                }

                break :decl_name try self.builder.string(decl_name);
            };

            if (self.builder.getGlobal(decl_name)) |other_global| {
                if (other_global.toLlvm(&self.builder) != llvm_global) {
                    try self.extern_collisions.put(gpa, decl_index, {});
                }
            }

            try global_index.rename(&self.builder, decl_name);
            const decl_name_slice = decl_name.toSlice(&self.builder).?;
            const global = global_index.ptr(&self.builder);
            global.unnamed_addr = .default;
            llvm_global.setUnnamedAddr(.False);
            global.linkage = .external;
            llvm_global.setLinkage(.External);
            if (mod.wantDllExports()) {
                global.dll_storage_class = .default;
                llvm_global.setDLLStorageClass(.Default);
            }
            if (self.di_map.get(decl)) |di_node| {
                if (try decl.isFunction(mod)) {
                    const di_func = @as(*llvm.DISubprogram, @ptrCast(di_node));
                    const linkage_name = llvm.MDString.get(self.context, decl_name_slice.ptr, decl_name_slice.len);
                    di_func.replaceLinkageName(linkage_name);
                } else {
                    const di_global = @as(*llvm.DIGlobalVariable, @ptrCast(di_node));
                    const linkage_name = llvm.MDString.get(self.context, decl_name_slice.ptr, decl_name_slice.len);
                    di_global.replaceLinkageName(linkage_name);
                }
            }
            if (decl.val.getVariable(mod)) |variable| {
                if (variable.is_threadlocal) {
                    llvm_global.setThreadLocalMode(.GeneralDynamicTLSModel);
                } else {
                    llvm_global.setThreadLocalMode(.NotThreadLocal);
                }
                if (variable.is_weak_linkage) {
                    llvm_global.setLinkage(.ExternalWeak);
                }
            }
        } else if (exports.len != 0) {
            const exp_name = try self.builder.string(mod.intern_pool.stringToSlice(exports[0].opts.name));
            try global_index.rename(&self.builder, exp_name);
            llvm_global.setUnnamedAddr(.False);
            if (mod.wantDllExports()) llvm_global.setDLLStorageClass(.DLLExport);
            if (self.di_map.get(decl)) |di_node| {
                const exp_name_slice = exp_name.toSlice(&self.builder).?;
                if (try decl.isFunction(mod)) {
                    const di_func = @as(*llvm.DISubprogram, @ptrCast(di_node));
                    const linkage_name = llvm.MDString.get(self.context, exp_name_slice.ptr, exp_name_slice.len);
                    di_func.replaceLinkageName(linkage_name);
                } else {
                    const di_global = @as(*llvm.DIGlobalVariable, @ptrCast(di_node));
                    const linkage_name = llvm.MDString.get(self.context, exp_name_slice.ptr, exp_name_slice.len);
                    di_global.replaceLinkageName(linkage_name);
                }
            }
            switch (exports[0].opts.linkage) {
                .Internal => unreachable,
                .Strong => llvm_global.setLinkage(.External),
                .Weak => llvm_global.setLinkage(.WeakODR),
                .LinkOnce => llvm_global.setLinkage(.LinkOnceODR),
            }
            switch (exports[0].opts.visibility) {
                .default => llvm_global.setVisibility(.Default),
                .hidden => llvm_global.setVisibility(.Hidden),
                .protected => llvm_global.setVisibility(.Protected),
            }
            if (mod.intern_pool.stringToSliceUnwrap(exports[0].opts.section)) |section| {
                llvm_global.setSection(section);
            }
            if (decl.val.getVariable(mod)) |variable| {
                if (variable.is_threadlocal) {
                    llvm_global.setThreadLocalMode(.GeneralDynamicTLSModel);
                }
            }

            // If a Decl is exported more than one time (which is rare),
            // we add aliases for all but the first export.
            // TODO LLVM C API does not support deleting aliases.
            // The planned solution to this is https://github.com/ziglang/zig/issues/13265
            // Until then we iterate over existing aliases and make them point
            // to the correct decl, or otherwise add a new alias. Old aliases are leaked.
            for (exports[1..]) |exp| {
                const exp_name_z = mod.intern_pool.stringToSlice(exp.opts.name);

                if (self.llvm_module.getNamedGlobalAlias(exp_name_z.ptr, exp_name_z.len)) |alias| {
                    alias.setAliasee(llvm_global);
                } else {
                    _ = self.llvm_module.addAlias(
                        llvm_global.globalGetValueType(),
                        0,
                        llvm_global,
                        exp_name_z,
                    );
                }
            }
        } else {
            const fqn = try self.builder.string(mod.intern_pool.stringToSlice(try decl.getFullyQualifiedName(mod)));
            try global_index.rename(&self.builder, fqn);
            llvm_global.setLinkage(.Internal);
            if (mod.wantDllExports()) llvm_global.setDLLStorageClass(.Default);
            llvm_global.setUnnamedAddr(.True);
            if (decl.val.getVariable(mod)) |variable| {
                const single_threaded = mod.comp.bin_file.options.single_threaded;
                if (variable.is_threadlocal and !single_threaded) {
                    llvm_global.setThreadLocalMode(.GeneralDynamicTLSModel);
                } else {
                    llvm_global.setThreadLocalMode(.NotThreadLocal);
                }
            }
        }
    }

    pub fn freeDecl(self: *Object, decl_index: Module.Decl.Index) void {
        const global = self.decl_map.get(decl_index) orelse return;
        global.toLlvm(&self.builder).deleteGlobal();
    }

    fn getDIFile(o: *Object, gpa: Allocator, file: *const Module.File) !*llvm.DIFile {
        const gop = try o.di_map.getOrPut(gpa, file);
        errdefer assert(o.di_map.remove(file));
        if (gop.found_existing) {
            return @as(*llvm.DIFile, @ptrCast(gop.value_ptr.*));
        }
        const dir_path_z = d: {
            var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const dir_path = file.pkg.root_src_directory.path orelse ".";
            const resolved_dir_path = if (std.fs.path.isAbsolute(dir_path))
                dir_path
            else
                std.os.realpath(dir_path, &buffer) catch dir_path; // If realpath fails, fallback to whatever dir_path was
            break :d try std.fs.path.joinZ(gpa, &.{
                resolved_dir_path, std.fs.path.dirname(file.sub_file_path) orelse "",
            });
        };
        defer gpa.free(dir_path_z);
        const sub_file_path_z = try gpa.dupeZ(u8, std.fs.path.basename(file.sub_file_path));
        defer gpa.free(sub_file_path_z);
        const di_file = o.di_builder.?.createFile(sub_file_path_z, dir_path_z);
        gop.value_ptr.* = di_file.toNode();
        return di_file;
    }

    const DebugResolveStatus = enum { fwd, full };

    /// In the implementation of this function, it is required to store a forward decl
    /// into `gop` before making any recursive calls (even directly).
    fn lowerDebugType(
        o: *Object,
        ty: Type,
        resolve: DebugResolveStatus,
    ) Allocator.Error!*llvm.DIType {
        const gpa = o.gpa;
        // Be careful not to reference this `gop` variable after any recursive calls
        // to `lowerDebugType`.
        const gop = try o.di_type_map.getOrPut(gpa, ty.toIntern());
        if (gop.found_existing) {
            const annotated = gop.value_ptr.*;
            const di_type = annotated.toDIType();
            if (!annotated.isFwdOnly() or resolve == .fwd) {
                return di_type;
            }
            const entry: Object.DITypeMap.Entry = .{
                .key_ptr = gop.key_ptr,
                .value_ptr = gop.value_ptr,
            };
            return o.lowerDebugTypeImpl(entry, resolve, di_type);
        }
        errdefer assert(o.di_type_map.orderedRemove(ty.toIntern()));
        const entry: Object.DITypeMap.Entry = .{
            .key_ptr = gop.key_ptr,
            .value_ptr = gop.value_ptr,
        };
        return o.lowerDebugTypeImpl(entry, resolve, null);
    }

    /// This is a helper function used by `lowerDebugType`.
    fn lowerDebugTypeImpl(
        o: *Object,
        gop: Object.DITypeMap.Entry,
        resolve: DebugResolveStatus,
        opt_fwd_decl: ?*llvm.DIType,
    ) Allocator.Error!*llvm.DIType {
        const ty = gop.key_ptr.toType();
        const gpa = o.gpa;
        const target = o.target;
        const dib = o.di_builder.?;
        const mod = o.module;
        switch (ty.zigTypeTag(mod)) {
            .Void, .NoReturn => {
                const di_type = dib.createBasicType("void", 0, DW.ATE.signed);
                gop.value_ptr.* = AnnotatedDITypePtr.initFull(di_type);
                return di_type;
            },
            .Int => {
                const info = ty.intInfo(mod);
                assert(info.bits != 0);
                const name = try o.allocTypeName(ty);
                defer gpa.free(name);
                const dwarf_encoding: c_uint = switch (info.signedness) {
                    .signed => DW.ATE.signed,
                    .unsigned => DW.ATE.unsigned,
                };
                const di_bits = ty.abiSize(mod) * 8; // lldb cannot handle non-byte sized types
                const di_type = dib.createBasicType(name, di_bits, dwarf_encoding);
                gop.value_ptr.* = AnnotatedDITypePtr.initFull(di_type);
                return di_type;
            },
            .Enum => {
                const owner_decl_index = ty.getOwnerDecl(mod);
                const owner_decl = o.module.declPtr(owner_decl_index);

                if (!ty.hasRuntimeBitsIgnoreComptime(mod)) {
                    const enum_di_ty = try o.makeEmptyNamespaceDIType(owner_decl_index);
                    // The recursive call to `lowerDebugType` via `makeEmptyNamespaceDIType`
                    // means we can't use `gop` anymore.
                    try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.initFull(enum_di_ty));
                    return enum_di_ty;
                }

                const ip = &mod.intern_pool;
                const enum_type = ip.indexToKey(ty.toIntern()).enum_type;

                const enumerators = try gpa.alloc(*llvm.DIEnumerator, enum_type.names.len);
                defer gpa.free(enumerators);

                const int_ty = enum_type.tag_ty.toType();
                const int_info = ty.intInfo(mod);
                assert(int_info.bits != 0);

                for (enum_type.names, 0..) |field_name_ip, i| {
                    const field_name_z = ip.stringToSlice(field_name_ip);

                    var bigint_space: Value.BigIntSpace = undefined;
                    const bigint = if (enum_type.values.len != 0)
                        enum_type.values[i].toValue().toBigInt(&bigint_space, mod)
                    else
                        std.math.big.int.Mutable.init(&bigint_space.limbs, i).toConst();

                    if (bigint.limbs.len == 1) {
                        enumerators[i] = dib.createEnumerator(field_name_z, bigint.limbs[0], int_info.signedness == .unsigned);
                        continue;
                    }
                    if (@sizeOf(usize) == @sizeOf(u64)) {
                        enumerators[i] = dib.createEnumerator2(
                            field_name_z,
                            @as(c_uint, @intCast(bigint.limbs.len)),
                            bigint.limbs.ptr,
                            int_info.bits,
                            int_info.signedness == .unsigned,
                        );
                        continue;
                    }
                    @panic("TODO implement bigint debug enumerators to llvm int for 32-bit compiler builds");
                }

                const di_file = try o.getDIFile(gpa, mod.namespacePtr(owner_decl.src_namespace).file_scope);
                const di_scope = try o.namespaceToDebugScope(owner_decl.src_namespace);

                const name = try o.allocTypeName(ty);
                defer gpa.free(name);

                const enum_di_ty = dib.createEnumerationType(
                    di_scope,
                    name,
                    di_file,
                    owner_decl.src_node + 1,
                    ty.abiSize(mod) * 8,
                    ty.abiAlignment(mod) * 8,
                    enumerators.ptr,
                    @as(c_int, @intCast(enumerators.len)),
                    try o.lowerDebugType(int_ty, .full),
                    "",
                );
                // The recursive call to `lowerDebugType` means we can't use `gop` anymore.
                try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.initFull(enum_di_ty));
                return enum_di_ty;
            },
            .Float => {
                const bits = ty.floatBits(target);
                const name = try o.allocTypeName(ty);
                defer gpa.free(name);
                const di_type = dib.createBasicType(name, bits, DW.ATE.float);
                gop.value_ptr.* = AnnotatedDITypePtr.initFull(di_type);
                return di_type;
            },
            .Bool => {
                const di_bits = 8; // lldb cannot handle non-byte sized types
                const di_type = dib.createBasicType("bool", di_bits, DW.ATE.boolean);
                gop.value_ptr.* = AnnotatedDITypePtr.initFull(di_type);
                return di_type;
            },
            .Pointer => {
                // Normalize everything that the debug info does not represent.
                const ptr_info = ty.ptrInfo(mod);

                if (ptr_info.sentinel != .none or
                    ptr_info.flags.address_space != .generic or
                    ptr_info.packed_offset.bit_offset != 0 or
                    ptr_info.packed_offset.host_size != 0 or
                    ptr_info.flags.vector_index != .none or
                    ptr_info.flags.is_allowzero or
                    ptr_info.flags.is_const or
                    ptr_info.flags.is_volatile or
                    ptr_info.flags.size == .Many or ptr_info.flags.size == .C or
                    !ptr_info.child.toType().hasRuntimeBitsIgnoreComptime(mod))
                {
                    const bland_ptr_ty = try mod.ptrType(.{
                        .child = if (!ptr_info.child.toType().hasRuntimeBitsIgnoreComptime(mod))
                            .anyopaque_type
                        else
                            ptr_info.child,
                        .flags = .{
                            .alignment = ptr_info.flags.alignment,
                            .size = switch (ptr_info.flags.size) {
                                .Many, .C, .One => .One,
                                .Slice => .Slice,
                            },
                        },
                    });
                    const ptr_di_ty = try o.lowerDebugType(bland_ptr_ty, resolve);
                    // The recursive call to `lowerDebugType` means we can't use `gop` anymore.
                    try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.init(ptr_di_ty, resolve));
                    return ptr_di_ty;
                }

                if (ty.isSlice(mod)) {
                    const ptr_ty = ty.slicePtrFieldType(mod);
                    const len_ty = Type.usize;

                    const name = try o.allocTypeName(ty);
                    defer gpa.free(name);
                    const di_file: ?*llvm.DIFile = null;
                    const line = 0;
                    const compile_unit_scope = o.di_compile_unit.?.toScope();

                    const fwd_decl = opt_fwd_decl orelse blk: {
                        const fwd_decl = dib.createReplaceableCompositeType(
                            DW.TAG.structure_type,
                            name.ptr,
                            compile_unit_scope,
                            di_file,
                            line,
                        );
                        gop.value_ptr.* = AnnotatedDITypePtr.initFwd(fwd_decl);
                        if (resolve == .fwd) return fwd_decl;
                        break :blk fwd_decl;
                    };

                    const ptr_size = ptr_ty.abiSize(mod);
                    const ptr_align = ptr_ty.abiAlignment(mod);
                    const len_size = len_ty.abiSize(mod);
                    const len_align = len_ty.abiAlignment(mod);

                    var offset: u64 = 0;
                    offset += ptr_size;
                    offset = std.mem.alignForward(u64, offset, len_align);
                    const len_offset = offset;

                    const fields: [2]*llvm.DIType = .{
                        dib.createMemberType(
                            fwd_decl.toScope(),
                            "ptr",
                            di_file,
                            line,
                            ptr_size * 8, // size in bits
                            ptr_align * 8, // align in bits
                            0, // offset in bits
                            0, // flags
                            try o.lowerDebugType(ptr_ty, .full),
                        ),
                        dib.createMemberType(
                            fwd_decl.toScope(),
                            "len",
                            di_file,
                            line,
                            len_size * 8, // size in bits
                            len_align * 8, // align in bits
                            len_offset * 8, // offset in bits
                            0, // flags
                            try o.lowerDebugType(len_ty, .full),
                        ),
                    };

                    const full_di_ty = dib.createStructType(
                        compile_unit_scope,
                        name.ptr,
                        di_file,
                        line,
                        ty.abiSize(mod) * 8, // size in bits
                        ty.abiAlignment(mod) * 8, // align in bits
                        0, // flags
                        null, // derived from
                        &fields,
                        fields.len,
                        0, // run time lang
                        null, // vtable holder
                        "", // unique id
                    );
                    dib.replaceTemporary(fwd_decl, full_di_ty);
                    // The recursive call to `lowerDebugType` means we can't use `gop` anymore.
                    try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.initFull(full_di_ty));
                    return full_di_ty;
                }

                const elem_di_ty = try o.lowerDebugType(ptr_info.child.toType(), .fwd);
                const name = try o.allocTypeName(ty);
                defer gpa.free(name);
                const ptr_di_ty = dib.createPointerType(
                    elem_di_ty,
                    target.ptrBitWidth(),
                    ty.ptrAlignment(mod) * 8,
                    name,
                );
                // The recursive call to `lowerDebugType` means we can't use `gop` anymore.
                try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.initFull(ptr_di_ty));
                return ptr_di_ty;
            },
            .Opaque => {
                if (ty.toIntern() == .anyopaque_type) {
                    const di_ty = dib.createBasicType("anyopaque", 0, DW.ATE.signed);
                    gop.value_ptr.* = AnnotatedDITypePtr.initFull(di_ty);
                    return di_ty;
                }
                const name = try o.allocTypeName(ty);
                defer gpa.free(name);
                const owner_decl_index = ty.getOwnerDecl(mod);
                const owner_decl = o.module.declPtr(owner_decl_index);
                const opaque_di_ty = dib.createForwardDeclType(
                    DW.TAG.structure_type,
                    name,
                    try o.namespaceToDebugScope(owner_decl.src_namespace),
                    try o.getDIFile(gpa, mod.namespacePtr(owner_decl.src_namespace).file_scope),
                    owner_decl.src_node + 1,
                );
                // The recursive call to `lowerDebugType` va `namespaceToDebugScope`
                // means we can't use `gop` anymore.
                try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.initFull(opaque_di_ty));
                return opaque_di_ty;
            },
            .Array => {
                const array_di_ty = dib.createArrayType(
                    ty.abiSize(mod) * 8,
                    ty.abiAlignment(mod) * 8,
                    try o.lowerDebugType(ty.childType(mod), .full),
                    @as(i64, @intCast(ty.arrayLen(mod))),
                );
                // The recursive call to `lowerDebugType` means we can't use `gop` anymore.
                try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.initFull(array_di_ty));
                return array_di_ty;
            },
            .Vector => {
                const elem_ty = ty.elemType2(mod);
                // Vector elements cannot be padded since that would make
                // @bitSizOf(elem) * len > @bitSizOf(vec).
                // Neither gdb nor lldb seem to be able to display non-byte sized
                // vectors properly.
                const elem_di_type = switch (elem_ty.zigTypeTag(mod)) {
                    .Int => blk: {
                        const info = elem_ty.intInfo(mod);
                        assert(info.bits != 0);
                        const name = try o.allocTypeName(ty);
                        defer gpa.free(name);
                        const dwarf_encoding: c_uint = switch (info.signedness) {
                            .signed => DW.ATE.signed,
                            .unsigned => DW.ATE.unsigned,
                        };
                        break :blk dib.createBasicType(name, info.bits, dwarf_encoding);
                    },
                    .Bool => dib.createBasicType("bool", 1, DW.ATE.boolean),
                    else => try o.lowerDebugType(ty.childType(mod), .full),
                };

                const vector_di_ty = dib.createVectorType(
                    ty.abiSize(mod) * 8,
                    ty.abiAlignment(mod) * 8,
                    elem_di_type,
                    ty.vectorLen(mod),
                );
                // The recursive call to `lowerDebugType` means we can't use `gop` anymore.
                try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.initFull(vector_di_ty));
                return vector_di_ty;
            },
            .Optional => {
                const name = try o.allocTypeName(ty);
                defer gpa.free(name);
                const child_ty = ty.optionalChild(mod);
                if (!child_ty.hasRuntimeBitsIgnoreComptime(mod)) {
                    const di_bits = 8; // lldb cannot handle non-byte sized types
                    const di_ty = dib.createBasicType(name, di_bits, DW.ATE.boolean);
                    gop.value_ptr.* = AnnotatedDITypePtr.initFull(di_ty);
                    return di_ty;
                }
                if (ty.optionalReprIsPayload(mod)) {
                    const ptr_di_ty = try o.lowerDebugType(child_ty, resolve);
                    // The recursive call to `lowerDebugType` means we can't use `gop` anymore.
                    try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.init(ptr_di_ty, resolve));
                    return ptr_di_ty;
                }

                const di_file: ?*llvm.DIFile = null;
                const line = 0;
                const compile_unit_scope = o.di_compile_unit.?.toScope();
                const fwd_decl = opt_fwd_decl orelse blk: {
                    const fwd_decl = dib.createReplaceableCompositeType(
                        DW.TAG.structure_type,
                        name.ptr,
                        compile_unit_scope,
                        di_file,
                        line,
                    );
                    gop.value_ptr.* = AnnotatedDITypePtr.initFwd(fwd_decl);
                    if (resolve == .fwd) return fwd_decl;
                    break :blk fwd_decl;
                };

                const non_null_ty = Type.u8;
                const payload_size = child_ty.abiSize(mod);
                const payload_align = child_ty.abiAlignment(mod);
                const non_null_size = non_null_ty.abiSize(mod);
                const non_null_align = non_null_ty.abiAlignment(mod);

                var offset: u64 = 0;
                offset += payload_size;
                offset = std.mem.alignForward(u64, offset, non_null_align);
                const non_null_offset = offset;

                const fields: [2]*llvm.DIType = .{
                    dib.createMemberType(
                        fwd_decl.toScope(),
                        "data",
                        di_file,
                        line,
                        payload_size * 8, // size in bits
                        payload_align * 8, // align in bits
                        0, // offset in bits
                        0, // flags
                        try o.lowerDebugType(child_ty, .full),
                    ),
                    dib.createMemberType(
                        fwd_decl.toScope(),
                        "some",
                        di_file,
                        line,
                        non_null_size * 8, // size in bits
                        non_null_align * 8, // align in bits
                        non_null_offset * 8, // offset in bits
                        0, // flags
                        try o.lowerDebugType(non_null_ty, .full),
                    ),
                };

                const full_di_ty = dib.createStructType(
                    compile_unit_scope,
                    name.ptr,
                    di_file,
                    line,
                    ty.abiSize(mod) * 8, // size in bits
                    ty.abiAlignment(mod) * 8, // align in bits
                    0, // flags
                    null, // derived from
                    &fields,
                    fields.len,
                    0, // run time lang
                    null, // vtable holder
                    "", // unique id
                );
                dib.replaceTemporary(fwd_decl, full_di_ty);
                // The recursive call to `lowerDebugType` means we can't use `gop` anymore.
                try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.initFull(full_di_ty));
                return full_di_ty;
            },
            .ErrorUnion => {
                const payload_ty = ty.errorUnionPayload(mod);
                if (!payload_ty.hasRuntimeBitsIgnoreComptime(mod)) {
                    const err_set_di_ty = try o.lowerDebugType(Type.anyerror, .full);
                    // The recursive call to `lowerDebugType` means we can't use `gop` anymore.
                    try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.initFull(err_set_di_ty));
                    return err_set_di_ty;
                }
                const name = try o.allocTypeName(ty);
                defer gpa.free(name);
                const di_file: ?*llvm.DIFile = null;
                const line = 0;
                const compile_unit_scope = o.di_compile_unit.?.toScope();
                const fwd_decl = opt_fwd_decl orelse blk: {
                    const fwd_decl = dib.createReplaceableCompositeType(
                        DW.TAG.structure_type,
                        name.ptr,
                        compile_unit_scope,
                        di_file,
                        line,
                    );
                    gop.value_ptr.* = AnnotatedDITypePtr.initFwd(fwd_decl);
                    if (resolve == .fwd) return fwd_decl;
                    break :blk fwd_decl;
                };

                const error_size = Type.anyerror.abiSize(mod);
                const error_align = Type.anyerror.abiAlignment(mod);
                const payload_size = payload_ty.abiSize(mod);
                const payload_align = payload_ty.abiAlignment(mod);

                var error_index: u32 = undefined;
                var payload_index: u32 = undefined;
                var error_offset: u64 = undefined;
                var payload_offset: u64 = undefined;
                if (error_align > payload_align) {
                    error_index = 0;
                    payload_index = 1;
                    error_offset = 0;
                    payload_offset = std.mem.alignForward(u64, error_size, payload_align);
                } else {
                    payload_index = 0;
                    error_index = 1;
                    payload_offset = 0;
                    error_offset = std.mem.alignForward(u64, payload_size, error_align);
                }

                var fields: [2]*llvm.DIType = undefined;
                fields[error_index] = dib.createMemberType(
                    fwd_decl.toScope(),
                    "tag",
                    di_file,
                    line,
                    error_size * 8, // size in bits
                    error_align * 8, // align in bits
                    error_offset * 8, // offset in bits
                    0, // flags
                    try o.lowerDebugType(Type.anyerror, .full),
                );
                fields[payload_index] = dib.createMemberType(
                    fwd_decl.toScope(),
                    "value",
                    di_file,
                    line,
                    payload_size * 8, // size in bits
                    payload_align * 8, // align in bits
                    payload_offset * 8, // offset in bits
                    0, // flags
                    try o.lowerDebugType(payload_ty, .full),
                );

                const full_di_ty = dib.createStructType(
                    compile_unit_scope,
                    name.ptr,
                    di_file,
                    line,
                    ty.abiSize(mod) * 8, // size in bits
                    ty.abiAlignment(mod) * 8, // align in bits
                    0, // flags
                    null, // derived from
                    &fields,
                    fields.len,
                    0, // run time lang
                    null, // vtable holder
                    "", // unique id
                );
                dib.replaceTemporary(fwd_decl, full_di_ty);
                // The recursive call to `lowerDebugType` means we can't use `gop` anymore.
                try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.initFull(full_di_ty));
                return full_di_ty;
            },
            .ErrorSet => {
                // TODO make this a proper enum with all the error codes in it.
                // will need to consider how to take incremental compilation into account.
                const di_ty = dib.createBasicType("anyerror", 16, DW.ATE.unsigned);
                gop.value_ptr.* = AnnotatedDITypePtr.initFull(di_ty);
                return di_ty;
            },
            .Struct => {
                const compile_unit_scope = o.di_compile_unit.?.toScope();
                const name = try o.allocTypeName(ty);
                defer gpa.free(name);

                if (mod.typeToStruct(ty)) |struct_obj| {
                    if (struct_obj.layout == .Packed and struct_obj.haveFieldTypes()) {
                        assert(struct_obj.haveLayout());
                        const info = struct_obj.backing_int_ty.intInfo(mod);
                        const dwarf_encoding: c_uint = switch (info.signedness) {
                            .signed => DW.ATE.signed,
                            .unsigned => DW.ATE.unsigned,
                        };
                        const di_bits = ty.abiSize(mod) * 8; // lldb cannot handle non-byte sized types
                        const di_ty = dib.createBasicType(name, di_bits, dwarf_encoding);
                        gop.value_ptr.* = AnnotatedDITypePtr.initFull(di_ty);
                        return di_ty;
                    }
                }

                const fwd_decl = opt_fwd_decl orelse blk: {
                    const fwd_decl = dib.createReplaceableCompositeType(
                        DW.TAG.structure_type,
                        name.ptr,
                        compile_unit_scope,
                        null, // file
                        0, // line
                    );
                    gop.value_ptr.* = AnnotatedDITypePtr.initFwd(fwd_decl);
                    if (resolve == .fwd) return fwd_decl;
                    break :blk fwd_decl;
                };

                switch (mod.intern_pool.indexToKey(ty.toIntern())) {
                    .anon_struct_type => |tuple| {
                        var di_fields: std.ArrayListUnmanaged(*llvm.DIType) = .{};
                        defer di_fields.deinit(gpa);

                        try di_fields.ensureUnusedCapacity(gpa, tuple.types.len);

                        comptime assert(struct_layout_version == 2);
                        var offset: u64 = 0;

                        for (tuple.types, tuple.values, 0..) |field_ty, field_val, i| {
                            if (field_val != .none or !field_ty.toType().hasRuntimeBits(mod)) continue;

                            const field_size = field_ty.toType().abiSize(mod);
                            const field_align = field_ty.toType().abiAlignment(mod);
                            const field_offset = std.mem.alignForward(u64, offset, field_align);
                            offset = field_offset + field_size;

                            const field_name = if (tuple.names.len != 0)
                                mod.intern_pool.stringToSlice(tuple.names[i])
                            else
                                try std.fmt.allocPrintZ(gpa, "{d}", .{i});
                            defer if (tuple.names.len == 0) gpa.free(field_name);

                            try di_fields.append(gpa, dib.createMemberType(
                                fwd_decl.toScope(),
                                field_name,
                                null, // file
                                0, // line
                                field_size * 8, // size in bits
                                field_align * 8, // align in bits
                                field_offset * 8, // offset in bits
                                0, // flags
                                try o.lowerDebugType(field_ty.toType(), .full),
                            ));
                        }

                        const full_di_ty = dib.createStructType(
                            compile_unit_scope,
                            name.ptr,
                            null, // file
                            0, // line
                            ty.abiSize(mod) * 8, // size in bits
                            ty.abiAlignment(mod) * 8, // align in bits
                            0, // flags
                            null, // derived from
                            di_fields.items.ptr,
                            @as(c_int, @intCast(di_fields.items.len)),
                            0, // run time lang
                            null, // vtable holder
                            "", // unique id
                        );
                        dib.replaceTemporary(fwd_decl, full_di_ty);
                        // The recursive call to `lowerDebugType` means we can't use `gop` anymore.
                        try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.initFull(full_di_ty));
                        return full_di_ty;
                    },
                    .struct_type => |struct_type| s: {
                        const struct_obj = mod.structPtrUnwrap(struct_type.index) orelse break :s;

                        if (!struct_obj.haveFieldTypes()) {
                            // This can happen if a struct type makes it all the way to
                            // flush() without ever being instantiated or referenced (even
                            // via pointer). The only reason we are hearing about it now is
                            // that it is being used as a namespace to put other debug types
                            // into. Therefore we can satisfy this by making an empty namespace,
                            // rather than changing the frontend to unnecessarily resolve the
                            // struct field types.
                            const owner_decl_index = ty.getOwnerDecl(mod);
                            const struct_di_ty = try o.makeEmptyNamespaceDIType(owner_decl_index);
                            dib.replaceTemporary(fwd_decl, struct_di_ty);
                            // The recursive call to `lowerDebugType` via `makeEmptyNamespaceDIType`
                            // means we can't use `gop` anymore.
                            try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.initFull(struct_di_ty));
                            return struct_di_ty;
                        }
                    },
                    else => {},
                }

                if (!ty.hasRuntimeBitsIgnoreComptime(mod)) {
                    const owner_decl_index = ty.getOwnerDecl(mod);
                    const struct_di_ty = try o.makeEmptyNamespaceDIType(owner_decl_index);
                    dib.replaceTemporary(fwd_decl, struct_di_ty);
                    // The recursive call to `lowerDebugType` via `makeEmptyNamespaceDIType`
                    // means we can't use `gop` anymore.
                    try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.initFull(struct_di_ty));
                    return struct_di_ty;
                }

                const fields = ty.structFields(mod);
                const layout = ty.containerLayout(mod);

                var di_fields: std.ArrayListUnmanaged(*llvm.DIType) = .{};
                defer di_fields.deinit(gpa);

                try di_fields.ensureUnusedCapacity(gpa, fields.count());

                comptime assert(struct_layout_version == 2);
                var offset: u64 = 0;

                var it = mod.typeToStruct(ty).?.runtimeFieldIterator(mod);
                while (it.next()) |field_and_index| {
                    const field = field_and_index.field;
                    const field_size = field.ty.abiSize(mod);
                    const field_align = field.alignment(mod, layout);
                    const field_offset = std.mem.alignForward(u64, offset, field_align);
                    offset = field_offset + field_size;

                    const field_name = mod.intern_pool.stringToSlice(fields.keys()[field_and_index.index]);

                    try di_fields.append(gpa, dib.createMemberType(
                        fwd_decl.toScope(),
                        field_name,
                        null, // file
                        0, // line
                        field_size * 8, // size in bits
                        field_align * 8, // align in bits
                        field_offset * 8, // offset in bits
                        0, // flags
                        try o.lowerDebugType(field.ty, .full),
                    ));
                }

                const full_di_ty = dib.createStructType(
                    compile_unit_scope,
                    name.ptr,
                    null, // file
                    0, // line
                    ty.abiSize(mod) * 8, // size in bits
                    ty.abiAlignment(mod) * 8, // align in bits
                    0, // flags
                    null, // derived from
                    di_fields.items.ptr,
                    @as(c_int, @intCast(di_fields.items.len)),
                    0, // run time lang
                    null, // vtable holder
                    "", // unique id
                );
                dib.replaceTemporary(fwd_decl, full_di_ty);
                // The recursive call to `lowerDebugType` means we can't use `gop` anymore.
                try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.initFull(full_di_ty));
                return full_di_ty;
            },
            .Union => {
                const compile_unit_scope = o.di_compile_unit.?.toScope();
                const owner_decl_index = ty.getOwnerDecl(mod);

                const name = try o.allocTypeName(ty);
                defer gpa.free(name);

                const fwd_decl = opt_fwd_decl orelse blk: {
                    const fwd_decl = dib.createReplaceableCompositeType(
                        DW.TAG.structure_type,
                        name.ptr,
                        o.di_compile_unit.?.toScope(),
                        null, // file
                        0, // line
                    );
                    gop.value_ptr.* = AnnotatedDITypePtr.initFwd(fwd_decl);
                    if (resolve == .fwd) return fwd_decl;
                    break :blk fwd_decl;
                };

                const union_obj = mod.typeToUnion(ty).?;
                if (!union_obj.haveFieldTypes() or !ty.hasRuntimeBitsIgnoreComptime(mod)) {
                    const union_di_ty = try o.makeEmptyNamespaceDIType(owner_decl_index);
                    dib.replaceTemporary(fwd_decl, union_di_ty);
                    // The recursive call to `lowerDebugType` via `makeEmptyNamespaceDIType`
                    // means we can't use `gop` anymore.
                    try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.initFull(union_di_ty));
                    return union_di_ty;
                }

                const layout = ty.unionGetLayout(mod);

                if (layout.payload_size == 0) {
                    const tag_di_ty = try o.lowerDebugType(union_obj.tag_ty, .full);
                    const di_fields = [_]*llvm.DIType{tag_di_ty};
                    const full_di_ty = dib.createStructType(
                        compile_unit_scope,
                        name.ptr,
                        null, // file
                        0, // line
                        ty.abiSize(mod) * 8, // size in bits
                        ty.abiAlignment(mod) * 8, // align in bits
                        0, // flags
                        null, // derived from
                        &di_fields,
                        di_fields.len,
                        0, // run time lang
                        null, // vtable holder
                        "", // unique id
                    );
                    dib.replaceTemporary(fwd_decl, full_di_ty);
                    // The recursive call to `lowerDebugType` via `makeEmptyNamespaceDIType`
                    // means we can't use `gop` anymore.
                    try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.initFull(full_di_ty));
                    return full_di_ty;
                }

                var di_fields: std.ArrayListUnmanaged(*llvm.DIType) = .{};
                defer di_fields.deinit(gpa);

                try di_fields.ensureUnusedCapacity(gpa, union_obj.fields.count());

                var it = union_obj.fields.iterator();
                while (it.next()) |kv| {
                    const field_name = kv.key_ptr.*;
                    const field = kv.value_ptr.*;

                    if (!field.ty.hasRuntimeBitsIgnoreComptime(mod)) continue;

                    const field_size = field.ty.abiSize(mod);
                    const field_align = field.normalAlignment(mod);

                    const field_di_ty = try o.lowerDebugType(field.ty, .full);
                    di_fields.appendAssumeCapacity(dib.createMemberType(
                        fwd_decl.toScope(),
                        mod.intern_pool.stringToSlice(field_name),
                        null, // file
                        0, // line
                        field_size * 8, // size in bits
                        field_align * 8, // align in bits
                        0, // offset in bits
                        0, // flags
                        field_di_ty,
                    ));
                }

                var union_name_buf: ?[:0]const u8 = null;
                defer if (union_name_buf) |buf| gpa.free(buf);
                const union_name = if (layout.tag_size == 0) name else name: {
                    union_name_buf = try std.fmt.allocPrintZ(gpa, "{s}:Payload", .{name});
                    break :name union_name_buf.?;
                };

                const union_di_ty = dib.createUnionType(
                    compile_unit_scope,
                    union_name.ptr,
                    null, // file
                    0, // line
                    ty.abiSize(mod) * 8, // size in bits
                    ty.abiAlignment(mod) * 8, // align in bits
                    0, // flags
                    di_fields.items.ptr,
                    @as(c_int, @intCast(di_fields.items.len)),
                    0, // run time lang
                    "", // unique id
                );

                if (layout.tag_size == 0) {
                    dib.replaceTemporary(fwd_decl, union_di_ty);
                    // The recursive call to `lowerDebugType` means we can't use `gop` anymore.
                    try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.initFull(union_di_ty));
                    return union_di_ty;
                }

                var tag_offset: u64 = undefined;
                var payload_offset: u64 = undefined;
                if (layout.tag_align >= layout.payload_align) {
                    tag_offset = 0;
                    payload_offset = std.mem.alignForward(u64, layout.tag_size, layout.payload_align);
                } else {
                    payload_offset = 0;
                    tag_offset = std.mem.alignForward(u64, layout.payload_size, layout.tag_align);
                }

                const tag_di = dib.createMemberType(
                    fwd_decl.toScope(),
                    "tag",
                    null, // file
                    0, // line
                    layout.tag_size * 8,
                    layout.tag_align * 8, // align in bits
                    tag_offset * 8, // offset in bits
                    0, // flags
                    try o.lowerDebugType(union_obj.tag_ty, .full),
                );

                const payload_di = dib.createMemberType(
                    fwd_decl.toScope(),
                    "payload",
                    null, // file
                    0, // line
                    layout.payload_size * 8, // size in bits
                    layout.payload_align * 8, // align in bits
                    payload_offset * 8, // offset in bits
                    0, // flags
                    union_di_ty,
                );

                const full_di_fields: [2]*llvm.DIType =
                    if (layout.tag_align >= layout.payload_align)
                    .{ tag_di, payload_di }
                else
                    .{ payload_di, tag_di };

                const full_di_ty = dib.createStructType(
                    compile_unit_scope,
                    name.ptr,
                    null, // file
                    0, // line
                    ty.abiSize(mod) * 8, // size in bits
                    ty.abiAlignment(mod) * 8, // align in bits
                    0, // flags
                    null, // derived from
                    &full_di_fields,
                    full_di_fields.len,
                    0, // run time lang
                    null, // vtable holder
                    "", // unique id
                );
                dib.replaceTemporary(fwd_decl, full_di_ty);
                // The recursive call to `lowerDebugType` means we can't use `gop` anymore.
                try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.initFull(full_di_ty));
                return full_di_ty;
            },
            .Fn => {
                const fn_info = mod.typeToFunc(ty).?;

                var param_di_types = std.ArrayList(*llvm.DIType).init(gpa);
                defer param_di_types.deinit();

                // Return type goes first.
                if (fn_info.return_type.toType().hasRuntimeBitsIgnoreComptime(mod)) {
                    const sret = firstParamSRet(fn_info, mod);
                    const di_ret_ty = if (sret) Type.void else fn_info.return_type.toType();
                    try param_di_types.append(try o.lowerDebugType(di_ret_ty, .full));

                    if (sret) {
                        const ptr_ty = try mod.singleMutPtrType(fn_info.return_type.toType());
                        try param_di_types.append(try o.lowerDebugType(ptr_ty, .full));
                    }
                } else {
                    try param_di_types.append(try o.lowerDebugType(Type.void, .full));
                }

                if (fn_info.return_type.toType().isError(mod) and
                    o.module.comp.bin_file.options.error_return_tracing)
                {
                    const ptr_ty = try mod.singleMutPtrType(try o.getStackTraceType());
                    try param_di_types.append(try o.lowerDebugType(ptr_ty, .full));
                }

                for (0..mod.typeToFunc(ty).?.param_types.len) |i| {
                    const param_ty = mod.typeToFunc(ty).?.param_types[i].toType();
                    if (!param_ty.hasRuntimeBitsIgnoreComptime(mod)) continue;

                    if (isByRef(param_ty, mod)) {
                        const ptr_ty = try mod.singleMutPtrType(param_ty);
                        try param_di_types.append(try o.lowerDebugType(ptr_ty, .full));
                    } else {
                        try param_di_types.append(try o.lowerDebugType(param_ty, .full));
                    }
                }

                const fn_di_ty = dib.createSubroutineType(
                    param_di_types.items.ptr,
                    @as(c_int, @intCast(param_di_types.items.len)),
                    0,
                );
                // The recursive call to `lowerDebugType` means we can't use `gop` anymore.
                try o.di_type_map.put(gpa, ty.toIntern(), AnnotatedDITypePtr.initFull(fn_di_ty));
                return fn_di_ty;
            },
            .ComptimeInt => unreachable,
            .ComptimeFloat => unreachable,
            .Type => unreachable,
            .Undefined => unreachable,
            .Null => unreachable,
            .EnumLiteral => unreachable,

            .Frame => @panic("TODO implement lowerDebugType for Frame types"),
            .AnyFrame => @panic("TODO implement lowerDebugType for AnyFrame types"),
        }
    }

    fn namespaceToDebugScope(o: *Object, namespace_index: Module.Namespace.Index) !*llvm.DIScope {
        const mod = o.module;
        const namespace = mod.namespacePtr(namespace_index);
        if (namespace.parent == .none) {
            const di_file = try o.getDIFile(o.gpa, namespace.file_scope);
            return di_file.toScope();
        }
        const di_type = try o.lowerDebugType(namespace.ty, .fwd);
        return di_type.toScope();
    }

    /// This is to be used instead of void for debug info types, to avoid tripping
    /// Assertion `!isa<DIType>(Scope) && "shouldn't make a namespace scope for a type"'
    /// when targeting CodeView (Windows).
    fn makeEmptyNamespaceDIType(o: *Object, decl_index: Module.Decl.Index) !*llvm.DIType {
        const mod = o.module;
        const decl = mod.declPtr(decl_index);
        const fields: [0]*llvm.DIType = .{};
        const di_scope = try o.namespaceToDebugScope(decl.src_namespace);
        return o.di_builder.?.createStructType(
            di_scope,
            mod.intern_pool.stringToSlice(decl.name), // TODO use fully qualified name
            try o.getDIFile(o.gpa, mod.namespacePtr(decl.src_namespace).file_scope),
            decl.src_line + 1,
            0, // size in bits
            0, // align in bits
            0, // flags
            null, // derived from
            undefined, // TODO should be able to pass &fields,
            fields.len,
            0, // run time lang
            null, // vtable holder
            "", // unique id
        );
    }

    fn getStackTraceType(o: *Object) Allocator.Error!Type {
        const mod = o.module;

        const std_pkg = mod.main_pkg.table.get("std").?;
        const std_file = (mod.importPkg(std_pkg) catch unreachable).file;

        const builtin_str = try mod.intern_pool.getOrPutString(mod.gpa, "builtin");
        const std_namespace = mod.namespacePtr(mod.declPtr(std_file.root_decl.unwrap().?).src_namespace);
        const builtin_decl = std_namespace.decls
            .getKeyAdapted(builtin_str, Module.DeclAdapter{ .mod = mod }).?;

        const stack_trace_str = try mod.intern_pool.getOrPutString(mod.gpa, "StackTrace");
        // buffer is only used for int_type, `builtin` is a struct.
        const builtin_ty = mod.declPtr(builtin_decl).val.toType();
        const builtin_namespace = builtin_ty.getNamespace(mod).?;
        const stack_trace_decl_index = builtin_namespace.decls
            .getKeyAdapted(stack_trace_str, Module.DeclAdapter{ .mod = mod }).?;
        const stack_trace_decl = mod.declPtr(stack_trace_decl_index);

        // Sema should have ensured that StackTrace was analyzed.
        assert(stack_trace_decl.has_tv);
        return stack_trace_decl.val.toType();
    }

    fn allocTypeName(o: *Object, ty: Type) Allocator.Error![:0]const u8 {
        var buffer = std.ArrayList(u8).init(o.gpa);
        errdefer buffer.deinit();
        try ty.print(buffer.writer(), o.module);
        return buffer.toOwnedSliceSentinel(0);
    }

    fn getNullOptAddr(o: *Object) !*llvm.Value {
        if (o.null_opt_addr) |global| return global;

        const mod = o.module;
        const target = mod.getTarget();
        const ty = try mod.intern(.{ .opt_type = .usize_type });
        const null_opt_usize = try mod.intern(.{ .opt = .{
            .ty = ty,
            .val = .none,
        } });

        const llvm_init = try o.lowerValue(.{
            .ty = ty.toType(),
            .val = null_opt_usize.toValue(),
        });
        const llvm_wanted_addrspace = toLlvmAddressSpace(.generic, target);
        const llvm_actual_addrspace = toLlvmGlobalAddressSpace(.generic, target);
        const global = o.llvm_module.addGlobalInAddressSpace(
            llvm_init.typeOf(),
            "",
            @intFromEnum(llvm_actual_addrspace),
        );
        global.setLinkage(.Internal);
        global.setUnnamedAddr(.True);
        global.setAlignment(ty.toType().abiAlignment(mod));
        global.setInitializer(llvm_init);

        const addrspace_casted_global = if (llvm_wanted_addrspace != llvm_actual_addrspace)
            global.constAddrSpaceCast(o.context.pointerType(@intFromEnum(llvm_wanted_addrspace)))
        else
            global;

        o.null_opt_addr = addrspace_casted_global;
        return addrspace_casted_global;
    }

    /// If the llvm function does not exist, create it.
    /// Note that this can be called before the function's semantic analysis has
    /// completed, so if any attributes rely on that, they must be done in updateFunc, not here.
    fn resolveLlvmFunction(o: *Object, decl_index: Module.Decl.Index) !Builder.Function.Index {
        const mod = o.module;
        const gpa = o.gpa;
        const decl = mod.declPtr(decl_index);
        const zig_fn_type = decl.ty;
        const gop = try o.decl_map.getOrPut(gpa, decl_index);
        if (gop.found_existing) return gop.value_ptr.ptr(&o.builder).kind.function;

        assert(decl.has_tv);
        const fn_info = mod.typeToFunc(zig_fn_type).?;
        const target = mod.getTarget();
        const sret = firstParamSRet(fn_info, mod);

        const fn_type = try o.lowerType(zig_fn_type);

        const fqn = try o.builder.string(mod.intern_pool.stringToSlice(try decl.getFullyQualifiedName(mod)));

        const llvm_addrspace = toLlvmAddressSpace(decl.@"addrspace", target);
        const llvm_fn = o.llvm_module.addFunctionInAddressSpace(fqn.toSlice(&o.builder).?, fn_type.toLlvm(&o.builder), @intFromEnum(llvm_addrspace));

        var global = Builder.Global{
            .type = fn_type,
            .kind = .{ .function = @enumFromInt(o.builder.functions.items.len) },
        };
        var function = Builder.Function{
            .global = @enumFromInt(o.builder.globals.count()),
        };

        const is_extern = decl.isExtern(mod);
        if (!is_extern) {
            llvm_fn.setLinkage(.Internal);
            llvm_fn.setUnnamedAddr(.True);
        } else {
            if (target.isWasm()) {
                o.addFnAttrString(llvm_fn, "wasm-import-name", mod.intern_pool.stringToSlice(decl.name));
                if (mod.intern_pool.stringToSliceUnwrap(decl.getOwnedExternFunc(mod).?.lib_name)) |lib_name| {
                    if (!std.mem.eql(u8, lib_name, "c")) {
                        o.addFnAttrString(llvm_fn, "wasm-import-module", lib_name);
                    }
                }
            }
        }

        if (sret) {
            o.addArgAttr(llvm_fn, 0, "nonnull"); // Sret pointers must not be address 0
            o.addArgAttr(llvm_fn, 0, "noalias");

            const raw_llvm_ret_ty = (try o.lowerType(fn_info.return_type.toType())).toLlvm(&o.builder);
            llvm_fn.addSretAttr(raw_llvm_ret_ty);
        }

        const err_return_tracing = fn_info.return_type.toType().isError(mod) and
            mod.comp.bin_file.options.error_return_tracing;

        if (err_return_tracing) {
            o.addArgAttr(llvm_fn, @intFromBool(sret), "nonnull");
        }

        switch (fn_info.cc) {
            .Unspecified, .Inline => {
                llvm_fn.setFunctionCallConv(.Fast);
            },
            .Naked => {
                o.addFnAttr(llvm_fn, "naked");
            },
            .Async => {
                llvm_fn.setFunctionCallConv(.Fast);
                @panic("TODO: LLVM backend lower async function");
            },
            else => {
                llvm_fn.setFunctionCallConv(toLlvmCallConv(fn_info.cc, target));
            },
        }

        if (fn_info.alignment.toByteUnitsOptional()) |a| {
            llvm_fn.setAlignment(@as(c_uint, @intCast(a)));
        }

        // Function attributes that are independent of analysis results of the function body.
        o.addCommonFnAttributes(llvm_fn);

        if (fn_info.return_type == .noreturn_type) {
            o.addFnAttr(llvm_fn, "noreturn");
        }

        // Add parameter attributes. We handle only the case of extern functions (no body)
        // because functions with bodies are handled in `updateFunc`.
        if (is_extern) {
            var it = iterateParamTypes(o, fn_info);
            it.llvm_index += @intFromBool(sret);
            it.llvm_index += @intFromBool(err_return_tracing);
            while (try it.next()) |lowering| switch (lowering) {
                .byval => {
                    const param_index = it.zig_index - 1;
                    const param_ty = fn_info.param_types[param_index].toType();
                    if (!isByRef(param_ty, mod)) {
                        o.addByValParamAttrs(llvm_fn, param_ty, param_index, fn_info, it.llvm_index - 1);
                    }
                },
                .byref => {
                    const param_ty = fn_info.param_types[it.zig_index - 1];
                    const param_llvm_ty = try o.lowerType(param_ty.toType());
                    const alignment = param_ty.toType().abiAlignment(mod);
                    o.addByRefParamAttrs(llvm_fn, it.llvm_index - 1, alignment, it.byval_attr, param_llvm_ty);
                },
                .byref_mut => {
                    o.addArgAttr(llvm_fn, it.llvm_index - 1, "noundef");
                },
                // No attributes needed for these.
                .no_bits,
                .abi_sized_int,
                .multiple_llvm_types,
                .as_u16,
                .float_array,
                .i32_array,
                .i64_array,
                => continue,

                .slice => unreachable, // extern functions do not support slice types.

            };
        }

        try o.builder.llvm_globals.append(o.gpa, llvm_fn);
        gop.value_ptr.* = try o.builder.addGlobal(fqn, global);
        try o.builder.functions.append(o.gpa, function);
        return global.kind.function;
    }

    fn addCommonFnAttributes(o: *Object, llvm_fn: *llvm.Value) void {
        const comp = o.module.comp;

        if (!comp.bin_file.options.red_zone) {
            o.addFnAttr(llvm_fn, "noredzone");
        }
        if (comp.bin_file.options.omit_frame_pointer) {
            o.addFnAttrString(llvm_fn, "frame-pointer", "none");
        } else {
            o.addFnAttrString(llvm_fn, "frame-pointer", "all");
        }
        o.addFnAttr(llvm_fn, "nounwind");
        if (comp.unwind_tables) {
            o.addFnAttrInt(llvm_fn, "uwtable", 2);
        }
        if (comp.bin_file.options.skip_linker_dependencies or
            comp.bin_file.options.no_builtin)
        {
            // The intent here is for compiler-rt and libc functions to not generate
            // infinite recursion. For example, if we are compiling the memcpy function,
            // and llvm detects that the body is equivalent to memcpy, it may replace the
            // body of memcpy with a call to memcpy, which would then cause a stack
            // overflow instead of performing memcpy.
            o.addFnAttr(llvm_fn, "nobuiltin");
        }
        if (comp.bin_file.options.optimize_mode == .ReleaseSmall) {
            o.addFnAttr(llvm_fn, "minsize");
            o.addFnAttr(llvm_fn, "optsize");
        }
        if (comp.bin_file.options.tsan) {
            o.addFnAttr(llvm_fn, "sanitize_thread");
        }
        if (comp.getTarget().cpu.model.llvm_name) |s| {
            llvm_fn.addFunctionAttr("target-cpu", s);
        }
        if (comp.bin_file.options.llvm_cpu_features) |s| {
            llvm_fn.addFunctionAttr("target-features", s);
        }
        if (comp.getTarget().cpu.arch.isBpf()) {
            llvm_fn.addFunctionAttr("no-builtins", "");
        }
    }

    fn resolveGlobalDecl(o: *Object, decl_index: Module.Decl.Index) Error!Builder.Object.Index {
        const gop = try o.decl_map.getOrPut(o.gpa, decl_index);
        if (gop.found_existing) return gop.value_ptr.ptr(&o.builder).kind.object;
        errdefer assert(o.decl_map.remove(decl_index));

        const mod = o.module;
        const decl = mod.declPtr(decl_index);
        const fqn = try o.builder.string(mod.intern_pool.stringToSlice(
            try decl.getFullyQualifiedName(mod),
        ));

        const target = mod.getTarget();

        var global = Builder.Global{
            .addr_space = toLlvmGlobalAddressSpace(decl.@"addrspace", target),
            .type = try o.lowerType(decl.ty),
            .kind = .{ .object = @enumFromInt(o.builder.objects.items.len) },
        };
        var object = Builder.Object{
            .global = @enumFromInt(o.builder.globals.count()),
        };

        const is_extern = decl.isExtern(mod);
        const name = if (is_extern)
            try o.builder.string(mod.intern_pool.stringToSlice(decl.name))
        else
            fqn;
        const llvm_global = o.llvm_module.addGlobalInAddressSpace(
            global.type.toLlvm(&o.builder),
            fqn.toSlice(&o.builder).?,
            @intFromEnum(global.addr_space),
        );

        // This is needed for declarations created by `@extern`.
        if (is_extern) {
            global.unnamed_addr = .default;
            llvm_global.setUnnamedAddr(.False);
            global.linkage = .external;
            llvm_global.setLinkage(.External);
            if (decl.val.getVariable(mod)) |variable| {
                const single_threaded = mod.comp.bin_file.options.single_threaded;
                if (variable.is_threadlocal and !single_threaded) {
                    object.thread_local = .generaldynamic;
                    llvm_global.setThreadLocalMode(.GeneralDynamicTLSModel);
                } else {
                    object.thread_local = .default;
                    llvm_global.setThreadLocalMode(.NotThreadLocal);
                }
                if (variable.is_weak_linkage) {
                    global.linkage = .extern_weak;
                    llvm_global.setLinkage(.ExternalWeak);
                }
            }
        } else {
            global.linkage = .internal;
            llvm_global.setLinkage(.Internal);
            global.unnamed_addr = .unnamed_addr;
            llvm_global.setUnnamedAddr(.True);
        }

        try o.builder.llvm_globals.append(o.gpa, llvm_global);
        gop.value_ptr.* = try o.builder.addGlobal(name, global);
        try o.builder.objects.append(o.gpa, object);
        return global.kind.object;
    }

    fn isUnnamedType(o: *Object, ty: Type, val: *llvm.Value) bool {
        // Once `lowerType` succeeds, successive calls to it with the same Zig type
        // are guaranteed to succeed. So if a call to `lowerType` fails here it means
        // it is the first time lowering the type, which means the value can't possible
        // have that type.
        const llvm_ty = (o.lowerType(ty) catch return true).toLlvm(&o.builder);
        return val.typeOf() != llvm_ty;
    }

    fn lowerType(o: *Object, t: Type) Allocator.Error!Builder.Type {
        const ty = try o.lowerTypeInner(t);
        const mod = o.module;
        if (std.debug.runtime_safety and false) check: {
            const llvm_ty = ty.toLlvm(&o.builder);
            if (t.zigTypeTag(mod) == .Opaque) break :check;
            if (!t.hasRuntimeBits(mod)) break :check;
            if (!llvm_ty.isSized().toBool()) break :check;

            const zig_size = t.abiSize(mod);
            const llvm_size = o.target_data.abiSizeOfType(llvm_ty);
            if (llvm_size != zig_size) {
                log.err("when lowering {}, Zig ABI size = {d} but LLVM ABI size = {d}", .{
                    t.fmt(o.module), zig_size, llvm_size,
                });
            }
        }
        return ty;
    }

    fn lowerTypeInner(o: *Object, t: Type) Allocator.Error!Builder.Type {
        const mod = o.module;
        const target = mod.getTarget();
        return switch (t.toIntern()) {
            .u0_type, .i0_type => unreachable,
            inline .u1_type,
            .u8_type,
            .i8_type,
            .u16_type,
            .i16_type,
            .u29_type,
            .u32_type,
            .i32_type,
            .u64_type,
            .i64_type,
            .u80_type,
            .u128_type,
            .i128_type,
            => |tag| @field(Builder.Type, "i" ++ @tagName(tag)[1 .. @tagName(tag).len - "_type".len]),
            .usize_type, .isize_type => try o.builder.intType(target.ptrBitWidth()),
            inline .c_char_type,
            .c_short_type,
            .c_ushort_type,
            .c_int_type,
            .c_uint_type,
            .c_long_type,
            .c_ulong_type,
            .c_longlong_type,
            .c_ulonglong_type,
            => |tag| try o.builder.intType(target.c_type_bit_size(
                @field(std.Target.CType, @tagName(tag)["c_".len .. @tagName(tag).len - "_type".len]),
            )),
            .c_longdouble_type,
            .f16_type,
            .f32_type,
            .f64_type,
            .f80_type,
            .f128_type,
            => switch (t.floatBits(target)) {
                16 => if (backendSupportsF16(target)) .half else .i16,
                32 => .float,
                64 => .double,
                80 => if (backendSupportsF80(target)) .x86_fp80 else .i80,
                128 => .fp128,
                else => unreachable,
            },
            .anyopaque_type => unreachable,
            .bool_type => .i1,
            .void_type => .void,
            .type_type => unreachable,
            .anyerror_type => Builder.Type.err_int,
            .comptime_int_type, .comptime_float_type, .noreturn_type => unreachable,
            .anyframe_type => @panic("TODO implement lowerType for AnyFrame types"),
            .null_type,
            .undefined_type,
            .enum_literal_type,
            .atomic_order_type,
            .atomic_rmw_op_type,
            .calling_convention_type,
            .address_space_type,
            .float_mode_type,
            .reduce_op_type,
            .call_modifier_type,
            .prefetch_options_type,
            .export_options_type,
            .extern_options_type,
            .type_info_type,
            => unreachable,
            .manyptr_u8_type,
            .manyptr_const_u8_type,
            .manyptr_const_u8_sentinel_0_type,
            .single_const_pointer_to_comptime_int_type,
            => .ptr,
            .slice_const_u8_type,
            .slice_const_u8_sentinel_0_type,
            => try o.builder.structType(.normal, &.{ .ptr, try o.lowerType(Type.usize) }),
            .optional_noreturn_type => unreachable,
            .anyerror_void_error_union_type => Builder.Type.err_int,
            .generic_poison_type, .empty_struct_type => unreachable,
            // values, not types
            .undef,
            .zero,
            .zero_usize,
            .zero_u8,
            .one,
            .one_usize,
            .one_u8,
            .four_u8,
            .negative_one,
            .calling_convention_c,
            .calling_convention_inline,
            .void_value,
            .unreachable_value,
            .null_value,
            .bool_true,
            .bool_false,
            .empty_struct,
            .generic_poison,
            .var_args_param_type,
            .none,
            => unreachable,
            else => switch (mod.intern_pool.indexToKey(t.toIntern())) {
                .int_type => |int_type| try o.builder.intType(int_type.bits),
                .ptr_type => |ptr_type| switch (ptr_type.flags.size) {
                    .One, .Many, .C => try o.builder.ptrType(
                        toLlvmAddressSpace(ptr_type.flags.address_space, target),
                    ),
                    .Slice => try o.builder.structType(.normal, &.{
                        .ptr,
                        try o.lowerType(Type.usize),
                    }),
                },
                .array_type => |array_type| o.builder.arrayType(
                    array_type.len + @intFromBool(array_type.sentinel != .none),
                    try o.lowerType(array_type.child.toType()),
                ),
                .vector_type => |vector_type| o.builder.vectorType(
                    .normal,
                    vector_type.len,
                    try o.lowerType(vector_type.child.toType()),
                ),
                .opt_type => |child_ty| {
                    if (!child_ty.toType().hasRuntimeBitsIgnoreComptime(mod)) return .i8;

                    const payload_ty = try o.lowerType(child_ty.toType());
                    if (t.optionalReprIsPayload(mod)) return payload_ty;

                    comptime assert(optional_layout_version == 3);
                    var fields_buf: [3]Builder.Type = .{ payload_ty, .i8, .none };
                    const offset = child_ty.toType().abiSize(mod) + 1;
                    const abi_size = t.abiSize(mod);
                    const padding = abi_size - offset;
                    if (padding == 0) return o.builder.structType(.normal, fields_buf[0..2]);
                    fields_buf[2] = try o.builder.arrayType(padding, .i8);
                    return o.builder.structType(.normal, fields_buf[0..3]);
                },
                .anyframe_type => @panic("TODO implement lowerType for AnyFrame types"),
                .error_union_type => |error_union_type| {
                    const error_type = Builder.Type.err_int;
                    if (!error_union_type.payload_type.toType().hasRuntimeBitsIgnoreComptime(mod))
                        return error_type;
                    const payload_type = try o.lowerType(error_union_type.payload_type.toType());

                    const payload_align = error_union_type.payload_type.toType().abiAlignment(mod);
                    const error_align = Type.err_int.abiAlignment(mod);

                    const payload_size = error_union_type.payload_type.toType().abiSize(mod);
                    const error_size = Type.err_int.abiSize(mod);

                    var fields_buf: [3]Builder.Type = undefined;
                    if (error_align > payload_align) {
                        fields_buf[0] = error_type;
                        fields_buf[1] = payload_type;
                        const payload_end =
                            std.mem.alignForward(u64, error_size, payload_align) +
                            payload_size;
                        const abi_size = std.mem.alignForward(u64, payload_end, error_align);
                        const padding = abi_size - payload_end;
                        if (padding == 0) return o.builder.structType(.normal, fields_buf[0..2]);
                        fields_buf[2] = try o.builder.arrayType(padding, .i8);
                        return o.builder.structType(.normal, fields_buf[0..3]);
                    } else {
                        fields_buf[0] = payload_type;
                        fields_buf[1] = error_type;
                        const error_end =
                            std.mem.alignForward(u64, payload_size, error_align) +
                            error_size;
                        const abi_size = std.mem.alignForward(u64, error_end, payload_align);
                        const padding = abi_size - error_end;
                        if (padding == 0) return o.builder.structType(.normal, fields_buf[0..2]);
                        fields_buf[2] = try o.builder.arrayType(padding, .i8);
                        return o.builder.structType(.normal, fields_buf[0..3]);
                    }
                },
                .simple_type => unreachable,
                .struct_type => |struct_type| {
                    const gop = try o.type_map.getOrPut(o.gpa, t.toIntern());
                    if (gop.found_existing) return gop.value_ptr.*;

                    const struct_obj = mod.structPtrUnwrap(struct_type.index).?;
                    if (struct_obj.layout == .Packed) {
                        assert(struct_obj.haveLayout());
                        const int_ty = try o.lowerType(struct_obj.backing_int_ty);
                        gop.value_ptr.* = int_ty;
                        return int_ty;
                    }

                    const name = try o.builder.string(mod.intern_pool.stringToSlice(
                        try struct_obj.getFullyQualifiedName(mod),
                    ));
                    const ty = try o.builder.opaqueType(name);
                    gop.value_ptr.* = ty; // must be done before any recursive calls

                    assert(struct_obj.haveFieldTypes());

                    var llvm_field_types = std.ArrayListUnmanaged(Builder.Type){};
                    defer llvm_field_types.deinit(o.gpa);
                    try llvm_field_types.ensureUnusedCapacity(o.gpa, struct_obj.fields.count());

                    comptime assert(struct_layout_version == 2);
                    var offset: u64 = 0;
                    var big_align: u32 = 1;
                    var struct_kind: Builder.Type.Structure.Kind = .normal;

                    var it = struct_obj.runtimeFieldIterator(mod);
                    while (it.next()) |field_and_index| {
                        const field = field_and_index.field;
                        const field_align = field.alignment(mod, struct_obj.layout);
                        const field_ty_align = field.ty.abiAlignment(mod);
                        if (field_align < field_ty_align) struct_kind = .@"packed";
                        big_align = @max(big_align, field_align);
                        const prev_offset = offset;
                        offset = std.mem.alignForward(u64, offset, field_align);

                        const padding_len = offset - prev_offset;
                        if (padding_len > 0) try llvm_field_types.append(
                            o.gpa,
                            try o.builder.arrayType(padding_len, .i8),
                        );
                        try llvm_field_types.append(o.gpa, try o.lowerType(field.ty));

                        offset += field.ty.abiSize(mod);
                    }
                    {
                        const prev_offset = offset;
                        offset = std.mem.alignForward(u64, offset, big_align);
                        const padding_len = offset - prev_offset;
                        if (padding_len > 0) try llvm_field_types.append(
                            o.gpa,
                            try o.builder.arrayType(padding_len, .i8),
                        );
                    }

                    try o.builder.namedTypeSetBody(
                        ty,
                        try o.builder.structType(struct_kind, llvm_field_types.items),
                    );
                    return ty;
                },
                .anon_struct_type => |anon_struct_type| {
                    var llvm_field_types: std.ArrayListUnmanaged(Builder.Type) = .{};
                    defer llvm_field_types.deinit(o.gpa);
                    try llvm_field_types.ensureUnusedCapacity(o.gpa, anon_struct_type.types.len);

                    comptime assert(struct_layout_version == 2);
                    var offset: u64 = 0;
                    var big_align: u32 = 0;

                    for (anon_struct_type.types, anon_struct_type.values) |field_ty, field_val| {
                        if (field_val != .none or !field_ty.toType().hasRuntimeBits(mod)) continue;

                        const field_align = field_ty.toType().abiAlignment(mod);
                        big_align = @max(big_align, field_align);
                        const prev_offset = offset;
                        offset = std.mem.alignForward(u64, offset, field_align);

                        const padding_len = offset - prev_offset;
                        if (padding_len > 0) try llvm_field_types.append(
                            o.gpa,
                            try o.builder.arrayType(padding_len, .i8),
                        );
                        try llvm_field_types.append(o.gpa, try o.lowerType(field_ty.toType()));

                        offset += field_ty.toType().abiSize(mod);
                    }
                    {
                        const prev_offset = offset;
                        offset = std.mem.alignForward(u64, offset, big_align);
                        const padding_len = offset - prev_offset;
                        if (padding_len > 0) try llvm_field_types.append(
                            o.gpa,
                            try o.builder.arrayType(padding_len, .i8),
                        );
                    }
                    return o.builder.structType(.normal, llvm_field_types.items);
                },
                .union_type => |union_type| {
                    const gop = try o.type_map.getOrPut(o.gpa, t.toIntern());
                    if (gop.found_existing) return gop.value_ptr.*;

                    const union_obj = mod.unionPtr(union_type.index);
                    const layout = union_obj.getLayout(mod, union_type.hasTag());

                    if (union_obj.layout == .Packed) {
                        const int_ty = try o.builder.intType(@intCast(t.bitSize(mod)));
                        gop.value_ptr.* = int_ty;
                        return int_ty;
                    }

                    if (layout.payload_size == 0) {
                        const enum_tag_ty = try o.lowerType(union_obj.tag_ty);
                        gop.value_ptr.* = enum_tag_ty;
                        return enum_tag_ty;
                    }

                    const name = try o.builder.string(mod.intern_pool.stringToSlice(
                        try union_obj.getFullyQualifiedName(mod),
                    ));
                    const ty = try o.builder.opaqueType(name);
                    gop.value_ptr.* = ty; // must be done before any recursive calls

                    const aligned_field = union_obj.fields.values()[layout.most_aligned_field];
                    const aligned_field_ty = try o.lowerType(aligned_field.ty);

                    const payload_ty = ty: {
                        if (layout.most_aligned_field_size == layout.payload_size) {
                            break :ty aligned_field_ty;
                        }
                        const padding_len = if (layout.tag_size == 0)
                            layout.abi_size - layout.most_aligned_field_size
                        else
                            layout.payload_size - layout.most_aligned_field_size;
                        break :ty try o.builder.structType(.@"packed", &.{
                            aligned_field_ty,
                            try o.builder.arrayType(padding_len, .i8),
                        });
                    };

                    if (layout.tag_size == 0) {
                        try o.builder.namedTypeSetBody(
                            ty,
                            try o.builder.structType(.normal, &.{payload_ty}),
                        );
                        return ty;
                    }
                    const enum_tag_ty = try o.lowerType(union_obj.tag_ty);

                    // Put the tag before or after the payload depending on which one's
                    // alignment is greater.
                    var llvm_fields: [3]Builder.Type = undefined;
                    var llvm_fields_len: usize = 2;

                    if (layout.tag_align >= layout.payload_align) {
                        llvm_fields = .{ enum_tag_ty, payload_ty, .none };
                    } else {
                        llvm_fields = .{ payload_ty, enum_tag_ty, .none };
                    }

                    // Insert padding to make the LLVM struct ABI size match the Zig union ABI size.
                    if (layout.padding != 0) {
                        llvm_fields[llvm_fields_len] = try o.builder.arrayType(layout.padding, .i8);
                        llvm_fields_len += 1;
                    }

                    try o.builder.namedTypeSetBody(
                        ty,
                        try o.builder.structType(.normal, llvm_fields[0..llvm_fields_len]),
                    );
                    return ty;
                },
                .opaque_type => |opaque_type| {
                    const gop = try o.type_map.getOrPut(o.gpa, t.toIntern());
                    if (!gop.found_existing) {
                        const name = try o.builder.string(mod.intern_pool.stringToSlice(
                            try mod.opaqueFullyQualifiedName(opaque_type),
                        ));
                        gop.value_ptr.* = try o.builder.opaqueType(name);
                    }
                    return gop.value_ptr.*;
                },
                .enum_type => |enum_type| try o.lowerType(enum_type.tag_ty.toType()),
                .func_type => |func_type| try o.lowerTypeFn(func_type),
                .error_set_type, .inferred_error_set_type => Builder.Type.err_int,
                // values, not types
                .undef,
                .runtime_value,
                .simple_value,
                .variable,
                .extern_func,
                .func,
                .int,
                .err,
                .error_union,
                .enum_literal,
                .enum_tag,
                .empty_enum_value,
                .float,
                .ptr,
                .opt,
                .aggregate,
                .un,
                // memoization, not types
                .memoized_call,
                => unreachable,
            },
        };
    }

    /// Use this instead of lowerType when you want to handle correctly the case of elem_ty
    /// being a zero bit type, but it should still be lowered as an i8 in such case.
    /// There are other similar cases handled here as well.
    fn lowerPtrElemTy(o: *Object, elem_ty: Type) Allocator.Error!Builder.Type {
        const mod = o.module;
        const lower_elem_ty = switch (elem_ty.zigTypeTag(mod)) {
            .Opaque => true,
            .Fn => !mod.typeToFunc(elem_ty).?.is_generic,
            .Array => elem_ty.childType(mod).hasRuntimeBitsIgnoreComptime(mod),
            else => elem_ty.hasRuntimeBitsIgnoreComptime(mod),
        };
        return if (lower_elem_ty) try o.lowerType(elem_ty) else .i8;
    }

    fn lowerTypeFn(o: *Object, fn_info: InternPool.Key.FuncType) Allocator.Error!Builder.Type {
        const mod = o.module;
        const ret_ty = try lowerFnRetTy(o, fn_info);

        var llvm_params = std.ArrayListUnmanaged(Builder.Type){};
        defer llvm_params.deinit(o.gpa);

        if (firstParamSRet(fn_info, mod)) {
            try llvm_params.append(o.gpa, .ptr);
        }

        if (fn_info.return_type.toType().isError(mod) and
            mod.comp.bin_file.options.error_return_tracing)
        {
            const ptr_ty = try mod.singleMutPtrType(try o.getStackTraceType());
            try llvm_params.append(o.gpa, try o.lowerType(ptr_ty));
        }

        var it = iterateParamTypes(o, fn_info);
        while (try it.next()) |lowering| switch (lowering) {
            .no_bits => continue,
            .byval => {
                const param_ty = fn_info.param_types[it.zig_index - 1].toType();
                try llvm_params.append(o.gpa, try o.lowerType(param_ty));
            },
            .byref, .byref_mut => {
                try llvm_params.append(o.gpa, .ptr);
            },
            .abi_sized_int => {
                const param_ty = fn_info.param_types[it.zig_index - 1].toType();
                try llvm_params.append(o.gpa, try o.builder.intType(
                    @intCast(param_ty.abiSize(mod) * 8),
                ));
            },
            .slice => {
                try llvm_params.appendSlice(o.gpa, &.{ .ptr, try o.lowerType(Type.usize) });
            },
            .multiple_llvm_types => {
                try llvm_params.appendSlice(o.gpa, it.types_buffer[0..it.types_len]);
            },
            .as_u16 => {
                try llvm_params.append(o.gpa, .i16);
            },
            .float_array => |count| {
                const param_ty = fn_info.param_types[it.zig_index - 1].toType();
                const float_ty = try o.lowerType(aarch64_c_abi.getFloatArrayType(param_ty, mod).?);
                try llvm_params.append(o.gpa, try o.builder.arrayType(count, float_ty));
            },
            .i32_array, .i64_array => |arr_len| {
                try llvm_params.append(o.gpa, try o.builder.arrayType(arr_len, switch (lowering) {
                    .i32_array => .i32,
                    .i64_array => .i64,
                    else => unreachable,
                }));
            },
        };

        return o.builder.fnType(
            ret_ty,
            llvm_params.items,
            if (fn_info.is_var_args) .vararg else .normal,
        );
    }

    fn lowerValue(o: *Object, arg_tv: TypedValue) Error!*llvm.Value {
        const mod = o.module;
        const gpa = o.gpa;
        const target = mod.getTarget();
        var tv = arg_tv;
        switch (mod.intern_pool.indexToKey(tv.val.toIntern())) {
            .runtime_value => |rt| tv.val = rt.val.toValue(),
            else => {},
        }
        if (tv.val.isUndefDeep(mod)) {
            return (try o.lowerType(tv.ty)).toLlvm(&o.builder).getUndef();
        }

        const val_key = mod.intern_pool.indexToKey(tv.val.toIntern());
        switch (val_key) {
            .int_type,
            .ptr_type,
            .array_type,
            .vector_type,
            .opt_type,
            .anyframe_type,
            .error_union_type,
            .simple_type,
            .struct_type,
            .anon_struct_type,
            .union_type,
            .opaque_type,
            .enum_type,
            .func_type,
            .error_set_type,
            .inferred_error_set_type,
            => unreachable, // types, not values

            .undef, .runtime_value => unreachable, // handled above
            .simple_value => |simple_value| switch (simple_value) {
                .undefined,
                .void,
                .null,
                .empty_struct,
                .@"unreachable",
                .generic_poison,
                => unreachable, // non-runtime values
                .false => return Builder.Constant.false.toLlvm(&o.builder),
                .true => return Builder.Constant.true.toLlvm(&o.builder),
            },
            .variable,
            .enum_literal,
            .empty_enum_value,
            => unreachable, // non-runtime values
            .extern_func, .func => {
                const fn_decl_index = switch (val_key) {
                    .extern_func => |extern_func| extern_func.decl,
                    .func => |func| mod.funcPtr(func.index).owner_decl,
                    else => unreachable,
                };
                const fn_decl = mod.declPtr(fn_decl_index);
                try mod.markDeclAlive(fn_decl);
                const function_index = try o.resolveLlvmFunction(fn_decl_index);
                return function_index.toLlvm(&o.builder);
            },
            .int => {
                var bigint_space: Value.BigIntSpace = undefined;
                const bigint = tv.val.toBigInt(&bigint_space, mod);
                return lowerBigInt(o, tv.ty, bigint);
            },
            .err => |err| {
                const int = try mod.getErrorValue(err.name);
                const llvm_int = try o.builder.intConst(Builder.Type.err_int, int);
                return llvm_int.toLlvm(&o.builder);
            },
            .error_union => |error_union| {
                const err_tv: TypedValue = switch (error_union.val) {
                    .err_name => |err_name| .{
                        .ty = tv.ty.errorUnionSet(mod),
                        .val = (try mod.intern(.{ .err = .{
                            .ty = tv.ty.errorUnionSet(mod).toIntern(),
                            .name = err_name,
                        } })).toValue(),
                    },
                    .payload => .{
                        .ty = Type.err_int,
                        .val = try mod.intValue(Type.err_int, 0),
                    },
                };
                const payload_type = tv.ty.errorUnionPayload(mod);
                if (!payload_type.hasRuntimeBitsIgnoreComptime(mod)) {
                    // We use the error type directly as the type.
                    return o.lowerValue(err_tv);
                }

                const payload_align = payload_type.abiAlignment(mod);
                const error_align = err_tv.ty.abiAlignment(mod);
                const llvm_error_value = try o.lowerValue(err_tv);
                const llvm_payload_value = try o.lowerValue(.{
                    .ty = payload_type,
                    .val = switch (error_union.val) {
                        .err_name => try mod.intern(.{ .undef = payload_type.toIntern() }),
                        .payload => |payload| payload,
                    }.toValue(),
                });
                var fields_buf: [3]*llvm.Value = undefined;

                const llvm_ty = (try o.lowerType(tv.ty)).toLlvm(&o.builder);
                const llvm_field_count = llvm_ty.countStructElementTypes();
                if (llvm_field_count > 2) {
                    assert(llvm_field_count == 3);
                    fields_buf[2] = llvm_ty.structGetTypeAtIndex(2).getUndef();
                }

                if (error_align > payload_align) {
                    fields_buf[0] = llvm_error_value;
                    fields_buf[1] = llvm_payload_value;
                    return o.context.constStruct(&fields_buf, llvm_field_count, .False);
                } else {
                    fields_buf[0] = llvm_payload_value;
                    fields_buf[1] = llvm_error_value;
                    return o.context.constStruct(&fields_buf, llvm_field_count, .False);
                }
            },
            .enum_tag => |enum_tag| return o.lowerValue(.{
                .ty = mod.intern_pool.typeOf(enum_tag.int).toType(),
                .val = enum_tag.int.toValue(),
            }),
            .float => return switch (tv.ty.floatBits(target)) {
                16 => int: {
                    const repr: i16 = @bitCast(tv.val.toFloat(f16, mod));
                    break :int try o.builder.intConst(.i16, repr);
                },
                32 => int: {
                    const repr: i32 = @bitCast(tv.val.toFloat(f32, mod));
                    break :int try o.builder.intConst(.i32, repr);
                },
                64 => int: {
                    const repr: i64 = @bitCast(tv.val.toFloat(f64, mod));
                    break :int try o.builder.intConst(.i64, repr);
                },
                80 => int: {
                    const repr: i80 = @bitCast(tv.val.toFloat(f80, mod));
                    break :int try o.builder.intConst(.i80, repr);
                },
                128 => int: {
                    const repr: i128 = @bitCast(tv.val.toFloat(f128, mod));
                    break :int try o.builder.intConst(.i128, repr);
                },
                else => unreachable,
            }.toLlvm(&o.builder).constBitCast((try o.lowerType(tv.ty)).toLlvm(&o.builder)),
            .ptr => |ptr| {
                const ptr_tv: TypedValue = switch (ptr.len) {
                    .none => tv,
                    else => .{ .ty = tv.ty.slicePtrFieldType(mod), .val = tv.val.slicePtr(mod) },
                };
                const llvm_ptr_val = switch (ptr.addr) {
                    .decl => |decl| try o.lowerDeclRefValue(ptr_tv, decl),
                    .mut_decl => |mut_decl| try o.lowerDeclRefValue(ptr_tv, mut_decl.decl),
                    .int => |int| try o.lowerIntAsPtr(int.toValue()),
                    .eu_payload,
                    .opt_payload,
                    .elem,
                    .field,
                    => try o.lowerParentPtr(ptr_tv.val, ptr_tv.ty.ptrInfo(mod).packed_offset.bit_offset % 8 == 0),
                    .comptime_field => unreachable,
                };
                switch (ptr.len) {
                    .none => return llvm_ptr_val,
                    else => {
                        const fields: [2]*llvm.Value = .{
                            llvm_ptr_val,
                            try o.lowerValue(.{ .ty = Type.usize, .val = ptr.len.toValue() }),
                        };
                        return o.context.constStruct(&fields, fields.len, .False);
                    },
                }
            },
            .opt => |opt| {
                comptime assert(optional_layout_version == 3);
                const payload_ty = tv.ty.optionalChild(mod);

                const non_null_bit = (try o.builder.intConst(.i8, @intFromBool(opt.val != .none))).toLlvm(&o.builder);
                if (!payload_ty.hasRuntimeBitsIgnoreComptime(mod)) {
                    return non_null_bit;
                }
                const llvm_ty = (try o.lowerType(tv.ty)).toLlvm(&o.builder);
                if (tv.ty.optionalReprIsPayload(mod)) return switch (opt.val) {
                    .none => llvm_ty.constNull(),
                    else => |payload| o.lowerValue(.{ .ty = payload_ty, .val = payload.toValue() }),
                };
                assert(payload_ty.zigTypeTag(mod) != .Fn);

                const llvm_field_count = llvm_ty.countStructElementTypes();
                var fields_buf: [3]*llvm.Value = undefined;
                fields_buf[0] = try o.lowerValue(.{
                    .ty = payload_ty,
                    .val = switch (opt.val) {
                        .none => try mod.intern(.{ .undef = payload_ty.toIntern() }),
                        else => |payload| payload,
                    }.toValue(),
                });
                fields_buf[1] = non_null_bit;
                if (llvm_field_count > 2) {
                    assert(llvm_field_count == 3);
                    fields_buf[2] = llvm_ty.structGetTypeAtIndex(2).getUndef();
                }
                return o.context.constStruct(&fields_buf, llvm_field_count, .False);
            },
            .aggregate => |aggregate| switch (mod.intern_pool.indexToKey(tv.ty.toIntern())) {
                .array_type => switch (aggregate.storage) {
                    .bytes => |bytes| return o.context.constString(
                        bytes.ptr,
                        @as(c_uint, @intCast(tv.ty.arrayLenIncludingSentinel(mod))),
                        .True, // Don't null terminate. Bytes has the sentinel, if any.
                    ),
                    .elems => |elem_vals| {
                        const elem_ty = tv.ty.childType(mod);
                        const llvm_elems = try gpa.alloc(*llvm.Value, elem_vals.len);
                        defer gpa.free(llvm_elems);
                        var need_unnamed = false;
                        for (elem_vals, 0..) |elem_val, i| {
                            llvm_elems[i] = try o.lowerValue(.{ .ty = elem_ty, .val = elem_val.toValue() });
                            need_unnamed = need_unnamed or o.isUnnamedType(elem_ty, llvm_elems[i]);
                        }
                        if (need_unnamed) {
                            return o.context.constStruct(
                                llvm_elems.ptr,
                                @as(c_uint, @intCast(llvm_elems.len)),
                                .True,
                            );
                        } else {
                            const llvm_elem_ty = (try o.lowerType(elem_ty)).toLlvm(&o.builder);
                            return llvm_elem_ty.constArray(
                                llvm_elems.ptr,
                                @as(c_uint, @intCast(llvm_elems.len)),
                            );
                        }
                    },
                    .repeated_elem => |val| {
                        const elem_ty = tv.ty.childType(mod);
                        const sentinel = tv.ty.sentinel(mod);
                        const len = @as(usize, @intCast(tv.ty.arrayLen(mod)));
                        const len_including_sent = len + @intFromBool(sentinel != null);
                        const llvm_elems = try gpa.alloc(*llvm.Value, len_including_sent);
                        defer gpa.free(llvm_elems);

                        var need_unnamed = false;
                        if (len != 0) {
                            for (llvm_elems[0..len]) |*elem| {
                                elem.* = try o.lowerValue(.{ .ty = elem_ty, .val = val.toValue() });
                            }
                            need_unnamed = need_unnamed or o.isUnnamedType(elem_ty, llvm_elems[0]);
                        }

                        if (sentinel) |sent| {
                            llvm_elems[len] = try o.lowerValue(.{ .ty = elem_ty, .val = sent });
                            need_unnamed = need_unnamed or o.isUnnamedType(elem_ty, llvm_elems[len]);
                        }

                        if (need_unnamed) {
                            return o.context.constStruct(
                                llvm_elems.ptr,
                                @as(c_uint, @intCast(llvm_elems.len)),
                                .True,
                            );
                        } else {
                            const llvm_elem_ty = (try o.lowerType(elem_ty)).toLlvm(&o.builder);
                            return llvm_elem_ty.constArray(
                                llvm_elems.ptr,
                                @as(c_uint, @intCast(llvm_elems.len)),
                            );
                        }
                    },
                },
                .vector_type => |vector_type| {
                    const elem_ty = vector_type.child.toType();
                    const llvm_elems = try gpa.alloc(*llvm.Value, vector_type.len);
                    defer gpa.free(llvm_elems);
                    for (llvm_elems, 0..) |*llvm_elem, i| {
                        llvm_elem.* = switch (aggregate.storage) {
                            .bytes => |bytes| (try o.builder.intConst(.i8, bytes[i])).toLlvm(&o.builder),
                            .elems => |elems| try o.lowerValue(.{
                                .ty = elem_ty,
                                .val = elems[i].toValue(),
                            }),
                            .repeated_elem => |elem| try o.lowerValue(.{
                                .ty = elem_ty,
                                .val = elem.toValue(),
                            }),
                        };
                    }
                    return llvm.constVector(
                        llvm_elems.ptr,
                        @as(c_uint, @intCast(llvm_elems.len)),
                    );
                },
                .anon_struct_type => |tuple| {
                    var llvm_fields: std.ArrayListUnmanaged(*llvm.Value) = .{};
                    defer llvm_fields.deinit(gpa);

                    try llvm_fields.ensureUnusedCapacity(gpa, tuple.types.len);

                    comptime assert(struct_layout_version == 2);
                    var offset: u64 = 0;
                    var big_align: u32 = 0;
                    var need_unnamed = false;

                    for (tuple.types, tuple.values, 0..) |field_ty, field_val, i| {
                        if (field_val != .none) continue;
                        if (!field_ty.toType().hasRuntimeBitsIgnoreComptime(mod)) continue;

                        const field_align = field_ty.toType().abiAlignment(mod);
                        big_align = @max(big_align, field_align);
                        const prev_offset = offset;
                        offset = std.mem.alignForward(u64, offset, field_align);

                        const padding_len = offset - prev_offset;
                        if (padding_len > 0) {
                            const llvm_array_ty = try o.builder.arrayType(padding_len, .i8);
                            // TODO make this and all other padding elsewhere in debug
                            // builds be 0xaa not undef.
                            llvm_fields.appendAssumeCapacity(llvm_array_ty.toLlvm(&o.builder).getUndef());
                        }

                        const field_llvm_val = try o.lowerValue(.{
                            .ty = field_ty.toType(),
                            .val = try tv.val.fieldValue(mod, i),
                        });

                        need_unnamed = need_unnamed or o.isUnnamedType(field_ty.toType(), field_llvm_val);

                        llvm_fields.appendAssumeCapacity(field_llvm_val);

                        offset += field_ty.toType().abiSize(mod);
                    }
                    {
                        const prev_offset = offset;
                        offset = std.mem.alignForward(u64, offset, big_align);
                        const padding_len = offset - prev_offset;
                        if (padding_len > 0) {
                            const llvm_array_ty = try o.builder.arrayType(padding_len, .i8);
                            llvm_fields.appendAssumeCapacity(llvm_array_ty.toLlvm(&o.builder).getUndef());
                        }
                    }

                    if (need_unnamed) {
                        return o.context.constStruct(
                            llvm_fields.items.ptr,
                            @as(c_uint, @intCast(llvm_fields.items.len)),
                            .False,
                        );
                    } else {
                        const llvm_struct_ty = (try o.lowerType(tv.ty)).toLlvm(&o.builder);
                        return llvm_struct_ty.constNamedStruct(
                            llvm_fields.items.ptr,
                            @as(c_uint, @intCast(llvm_fields.items.len)),
                        );
                    }
                },
                .struct_type => |struct_type| {
                    const struct_obj = mod.structPtrUnwrap(struct_type.index).?;
                    const llvm_struct_ty = (try o.lowerType(tv.ty)).toLlvm(&o.builder);

                    if (struct_obj.layout == .Packed) {
                        assert(struct_obj.haveLayout());
                        const big_bits = struct_obj.backing_int_ty.bitSize(mod);
                        const int_llvm_ty = try o.builder.intType(@intCast(big_bits));
                        const fields = struct_obj.fields.values();
                        comptime assert(Type.packed_struct_layout_version == 2);
                        var running_int = (try o.builder.intConst(int_llvm_ty, 0)).toLlvm(&o.builder);
                        var running_bits: u16 = 0;
                        for (fields, 0..) |field, i| {
                            if (!field.ty.hasRuntimeBitsIgnoreComptime(mod)) continue;

                            const non_int_val = try o.lowerValue(.{
                                .ty = field.ty,
                                .val = try tv.val.fieldValue(mod, i),
                            });
                            const ty_bit_size = @as(u16, @intCast(field.ty.bitSize(mod)));
                            const small_int_ty = (try o.builder.intType(@intCast(ty_bit_size))).toLlvm(&o.builder);
                            const small_int_val = if (field.ty.isPtrAtRuntime(mod))
                                non_int_val.constPtrToInt(small_int_ty)
                            else
                                non_int_val.constBitCast(small_int_ty);
                            const shift_rhs = (try o.builder.intConst(int_llvm_ty, running_bits)).toLlvm(&o.builder);
                            // If the field is as large as the entire packed struct, this
                            // zext would go from, e.g. i16 to i16. This is legal with
                            // constZExtOrBitCast but not legal with constZExt.
                            const extended_int_val = small_int_val.constZExtOrBitCast(int_llvm_ty.toLlvm(&o.builder));
                            const shifted = extended_int_val.constShl(shift_rhs);
                            running_int = running_int.constOr(shifted);
                            running_bits += ty_bit_size;
                        }
                        return running_int;
                    }

                    const llvm_field_count = llvm_struct_ty.countStructElementTypes();
                    var llvm_fields = try std.ArrayListUnmanaged(*llvm.Value).initCapacity(gpa, llvm_field_count);
                    defer llvm_fields.deinit(gpa);

                    comptime assert(struct_layout_version == 2);
                    var offset: u64 = 0;
                    var big_align: u32 = 0;
                    var need_unnamed = false;

                    var it = struct_obj.runtimeFieldIterator(mod);
                    while (it.next()) |field_and_index| {
                        const field = field_and_index.field;
                        const field_align = field.alignment(mod, struct_obj.layout);
                        big_align = @max(big_align, field_align);
                        const prev_offset = offset;
                        offset = std.mem.alignForward(u64, offset, field_align);

                        const padding_len = offset - prev_offset;
                        if (padding_len > 0) {
                            const llvm_array_ty = try o.builder.arrayType(padding_len, .i8);
                            // TODO make this and all other padding elsewhere in debug
                            // builds be 0xaa not undef.
                            llvm_fields.appendAssumeCapacity(llvm_array_ty.toLlvm(&o.builder).getUndef());
                        }

                        const field_llvm_val = try o.lowerValue(.{
                            .ty = field.ty,
                            .val = try tv.val.fieldValue(mod, field_and_index.index),
                        });

                        need_unnamed = need_unnamed or o.isUnnamedType(field.ty, field_llvm_val);

                        llvm_fields.appendAssumeCapacity(field_llvm_val);

                        offset += field.ty.abiSize(mod);
                    }
                    {
                        const prev_offset = offset;
                        offset = std.mem.alignForward(u64, offset, big_align);
                        const padding_len = offset - prev_offset;
                        if (padding_len > 0) {
                            const llvm_array_ty = try o.builder.arrayType(padding_len, .i8);
                            llvm_fields.appendAssumeCapacity(llvm_array_ty.toLlvm(&o.builder).getUndef());
                        }
                    }

                    if (need_unnamed) {
                        return o.context.constStruct(
                            llvm_fields.items.ptr,
                            @as(c_uint, @intCast(llvm_fields.items.len)),
                            .False,
                        );
                    } else {
                        return llvm_struct_ty.constNamedStruct(
                            llvm_fields.items.ptr,
                            @as(c_uint, @intCast(llvm_fields.items.len)),
                        );
                    }
                },
                else => unreachable,
            },
            .un => {
                const llvm_union_ty = (try o.lowerType(tv.ty)).toLlvm(&o.builder);
                const tag_and_val: Value.Payload.Union.Data = switch (tv.val.toIntern()) {
                    .none => tv.val.castTag(.@"union").?.data,
                    else => switch (mod.intern_pool.indexToKey(tv.val.toIntern())) {
                        .un => |un| .{ .tag = un.tag.toValue(), .val = un.val.toValue() },
                        else => unreachable,
                    },
                };

                const layout = tv.ty.unionGetLayout(mod);

                if (layout.payload_size == 0) {
                    return lowerValue(o, .{
                        .ty = tv.ty.unionTagTypeSafety(mod).?,
                        .val = tag_and_val.tag,
                    });
                }
                const union_obj = mod.typeToUnion(tv.ty).?;
                const field_index = tv.ty.unionTagFieldIndex(tag_and_val.tag, o.module).?;
                assert(union_obj.haveFieldTypes());

                const field_ty = union_obj.fields.values()[field_index].ty;
                if (union_obj.layout == .Packed) {
                    if (!field_ty.hasRuntimeBits(mod))
                        return llvm_union_ty.constNull();
                    const non_int_val = try lowerValue(o, .{ .ty = field_ty, .val = tag_and_val.val });
                    const ty_bit_size = @as(u16, @intCast(field_ty.bitSize(mod)));
                    const small_int_ty = (try o.builder.intType(@intCast(ty_bit_size))).toLlvm(&o.builder);
                    const small_int_val = if (field_ty.isPtrAtRuntime(mod))
                        non_int_val.constPtrToInt(small_int_ty)
                    else
                        non_int_val.constBitCast(small_int_ty);
                    return small_int_val.constZExtOrBitCast(llvm_union_ty);
                }

                // Sometimes we must make an unnamed struct because LLVM does
                // not support bitcasting our payload struct to the true union payload type.
                // Instead we use an unnamed struct and every reference to the global
                // must pointer cast to the expected type before accessing the union.
                var need_unnamed: bool = layout.most_aligned_field != field_index;
                const payload = p: {
                    if (!field_ty.hasRuntimeBitsIgnoreComptime(mod)) {
                        const padding_len = @as(c_uint, @intCast(layout.payload_size));
                        break :p (try o.builder.arrayType(padding_len, .i8)).toLlvm(&o.builder).getUndef();
                    }
                    const field = try lowerValue(o, .{ .ty = field_ty, .val = tag_and_val.val });
                    need_unnamed = need_unnamed or o.isUnnamedType(field_ty, field);
                    const field_size = field_ty.abiSize(mod);
                    if (field_size == layout.payload_size) {
                        break :p field;
                    }
                    const padding_len = @as(c_uint, @intCast(layout.payload_size - field_size));
                    const fields: [2]*llvm.Value = .{
                        field, (try o.builder.arrayType(padding_len, .i8)).toLlvm(&o.builder).getUndef(),
                    };
                    break :p o.context.constStruct(&fields, fields.len, .True);
                };

                if (layout.tag_size == 0) {
                    const fields: [1]*llvm.Value = .{payload};
                    if (need_unnamed) {
                        return o.context.constStruct(&fields, fields.len, .False);
                    } else {
                        return llvm_union_ty.constNamedStruct(&fields, fields.len);
                    }
                }
                const llvm_tag_value = try lowerValue(o, .{
                    .ty = tv.ty.unionTagTypeSafety(mod).?,
                    .val = tag_and_val.tag,
                });
                var fields: [3]*llvm.Value = undefined;
                var fields_len: c_uint = 2;
                if (layout.tag_align >= layout.payload_align) {
                    fields = .{ llvm_tag_value, payload, undefined };
                } else {
                    fields = .{ payload, llvm_tag_value, undefined };
                }
                if (layout.padding != 0) {
                    fields[2] = (try o.builder.arrayType(layout.padding, .i8)).toLlvm(&o.builder).getUndef();
                    fields_len = 3;
                }
                if (need_unnamed) {
                    return o.context.constStruct(&fields, fields_len, .False);
                } else {
                    return llvm_union_ty.constNamedStruct(&fields, fields_len);
                }
            },
            .memoized_call => unreachable,
        }
    }

    fn lowerIntAsPtr(o: *Object, val: Value) Allocator.Error!*llvm.Value {
        const mod = o.module;
        switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .undef => return o.context.pointerType(0).getUndef(),
            .int => {
                var bigint_space: Value.BigIntSpace = undefined;
                const bigint = val.toBigInt(&bigint_space, mod);
                const llvm_int = try lowerBigInt(o, Type.usize, bigint);
                return llvm_int.constIntToPtr(o.context.pointerType(0));
            },
            else => unreachable,
        }
    }

    fn lowerBigInt(o: *Object, ty: Type, bigint: std.math.big.int.Const) Allocator.Error!*llvm.Value {
        return (try o.builder.bigIntConst(try o.builder.intType(ty.intInfo(o.module).bits), bigint))
            .toLlvm(&o.builder);
    }

    const ParentPtr = struct {
        ty: Type,
        llvm_ptr: *llvm.Value,
    };

    fn lowerParentPtrDecl(
        o: *Object,
        ptr_val: Value,
        decl_index: Module.Decl.Index,
    ) Error!*llvm.Value {
        const mod = o.module;
        const decl = mod.declPtr(decl_index);
        try mod.markDeclAlive(decl);
        const ptr_ty = try mod.singleMutPtrType(decl.ty);
        return try o.lowerDeclRefValue(.{ .ty = ptr_ty, .val = ptr_val }, decl_index);
    }

    fn lowerParentPtr(o: *Object, ptr_val: Value, byte_aligned: bool) Error!*llvm.Value {
        const mod = o.module;
        return switch (mod.intern_pool.indexToKey(ptr_val.toIntern()).ptr.addr) {
            .decl => |decl| o.lowerParentPtrDecl(ptr_val, decl),
            .mut_decl => |mut_decl| o.lowerParentPtrDecl(ptr_val, mut_decl.decl),
            .int => |int| o.lowerIntAsPtr(int.toValue()),
            .eu_payload => |eu_ptr| {
                const parent_llvm_ptr = try o.lowerParentPtr(eu_ptr.toValue(), true);

                const eu_ty = mod.intern_pool.typeOf(eu_ptr).toType().childType(mod);
                const payload_ty = eu_ty.errorUnionPayload(mod);
                if (!payload_ty.hasRuntimeBitsIgnoreComptime(mod)) {
                    // In this case, we represent pointer to error union the same as pointer
                    // to the payload.
                    return parent_llvm_ptr;
                }

                const payload_offset: u8 = if (payload_ty.abiAlignment(mod) > Type.anyerror.abiSize(mod)) 2 else 1;
                const indices: [2]*llvm.Value = .{
                    (try o.builder.intConst(.i32, 0)).toLlvm(&o.builder),
                    (try o.builder.intConst(.i32, payload_offset)).toLlvm(&o.builder),
                };
                const eu_llvm_ty = (try o.lowerType(eu_ty)).toLlvm(&o.builder);
                return eu_llvm_ty.constInBoundsGEP(parent_llvm_ptr, &indices, indices.len);
            },
            .opt_payload => |opt_ptr| {
                const parent_llvm_ptr = try o.lowerParentPtr(opt_ptr.toValue(), true);

                const opt_ty = mod.intern_pool.typeOf(opt_ptr).toType().childType(mod);
                const payload_ty = opt_ty.optionalChild(mod);
                if (!payload_ty.hasRuntimeBitsIgnoreComptime(mod) or
                    payload_ty.optionalReprIsPayload(mod))
                {
                    // In this case, we represent pointer to optional the same as pointer
                    // to the payload.
                    return parent_llvm_ptr;
                }

                const indices: [2]*llvm.Value = .{
                    (try o.builder.intConst(.i32, 0)).toLlvm(&o.builder),
                } ** 2;
                const opt_llvm_ty = (try o.lowerType(opt_ty)).toLlvm(&o.builder);
                return opt_llvm_ty.constInBoundsGEP(parent_llvm_ptr, &indices, indices.len);
            },
            .comptime_field => unreachable,
            .elem => |elem_ptr| {
                const parent_llvm_ptr = try o.lowerParentPtr(elem_ptr.base.toValue(), true);

                const indices: [1]*llvm.Value = .{
                    (try o.builder.intConst(try o.lowerType(Type.usize), elem_ptr.index)).toLlvm(&o.builder),
                };
                const elem_ty = mod.intern_pool.typeOf(elem_ptr.base).toType().elemType2(mod);
                const elem_llvm_ty = (try o.lowerType(elem_ty)).toLlvm(&o.builder);
                return elem_llvm_ty.constInBoundsGEP(parent_llvm_ptr, &indices, indices.len);
            },
            .field => |field_ptr| {
                const parent_llvm_ptr = try o.lowerParentPtr(field_ptr.base.toValue(), byte_aligned);
                const parent_ty = mod.intern_pool.typeOf(field_ptr.base).toType().childType(mod);

                const field_index = @as(u32, @intCast(field_ptr.index));
                switch (parent_ty.zigTypeTag(mod)) {
                    .Union => {
                        if (parent_ty.containerLayout(mod) == .Packed) {
                            return parent_llvm_ptr;
                        }

                        const layout = parent_ty.unionGetLayout(mod);
                        if (layout.payload_size == 0) {
                            // In this case a pointer to the union and a pointer to any
                            // (void) payload is the same.
                            return parent_llvm_ptr;
                        }
                        const llvm_pl_index = if (layout.tag_size == 0)
                            0
                        else
                            @intFromBool(layout.tag_align >= layout.payload_align);
                        const indices: [2]*llvm.Value = .{
                            (try o.builder.intConst(.i32, 0)).toLlvm(&o.builder),
                            (try o.builder.intConst(.i32, llvm_pl_index)).toLlvm(&o.builder),
                        };
                        const parent_llvm_ty = (try o.lowerType(parent_ty)).toLlvm(&o.builder);
                        return parent_llvm_ty.constInBoundsGEP(parent_llvm_ptr, &indices, indices.len);
                    },
                    .Struct => {
                        if (parent_ty.containerLayout(mod) == .Packed) {
                            if (!byte_aligned) return parent_llvm_ptr;
                            const llvm_usize = try o.lowerType(Type.usize);
                            const base_addr = parent_llvm_ptr.constPtrToInt(llvm_usize.toLlvm(&o.builder));
                            // count bits of fields before this one
                            const prev_bits = b: {
                                var b: usize = 0;
                                for (parent_ty.structFields(mod).values()[0..field_index]) |field| {
                                    if (field.is_comptime or !field.ty.hasRuntimeBitsIgnoreComptime(mod)) continue;
                                    b += @as(usize, @intCast(field.ty.bitSize(mod)));
                                }
                                break :b b;
                            };
                            const byte_offset = (try o.builder.intConst(llvm_usize, prev_bits / 8)).toLlvm(&o.builder);
                            const field_addr = base_addr.constAdd(byte_offset);
                            const final_llvm_ty = o.context.pointerType(0);
                            return field_addr.constIntToPtr(final_llvm_ty);
                        }

                        const parent_llvm_ty = (try o.lowerType(parent_ty)).toLlvm(&o.builder);
                        if (llvmField(parent_ty, field_index, mod)) |llvm_field| {
                            const indices: [2]*llvm.Value = .{
                                (try o.builder.intConst(.i32, 0)).toLlvm(&o.builder),
                                (try o.builder.intConst(.i32, llvm_field.index)).toLlvm(&o.builder),
                            };
                            return parent_llvm_ty.constInBoundsGEP(parent_llvm_ptr, &indices, indices.len);
                        } else {
                            const indices: [1]*llvm.Value = .{
                                (try o.builder.intConst(.i32, @intFromBool(parent_ty.hasRuntimeBitsIgnoreComptime(mod)))).toLlvm(&o.builder),
                            };
                            return parent_llvm_ty.constInBoundsGEP(parent_llvm_ptr, &indices, indices.len);
                        }
                    },
                    .Pointer => {
                        assert(parent_ty.isSlice(mod));
                        const indices: [2]*llvm.Value = .{
                            (try o.builder.intConst(.i32, 0)).toLlvm(&o.builder),
                            (try o.builder.intConst(.i32, field_index)).toLlvm(&o.builder),
                        };
                        const parent_llvm_ty = (try o.lowerType(parent_ty)).toLlvm(&o.builder);
                        return parent_llvm_ty.constInBoundsGEP(parent_llvm_ptr, &indices, indices.len);
                    },
                    else => unreachable,
                }
            },
        };
    }

    fn lowerDeclRefValue(
        o: *Object,
        tv: TypedValue,
        decl_index: Module.Decl.Index,
    ) Error!*llvm.Value {
        const mod = o.module;

        // In the case of something like:
        // fn foo() void {}
        // const bar = foo;
        // ... &bar;
        // `bar` is just an alias and we actually want to lower a reference to `foo`.
        const decl = mod.declPtr(decl_index);
        if (decl.val.getFunction(mod)) |func| {
            if (func.owner_decl != decl_index) {
                return o.lowerDeclRefValue(tv, func.owner_decl);
            }
        } else if (decl.val.getExternFunc(mod)) |func| {
            if (func.decl != decl_index) {
                return o.lowerDeclRefValue(tv, func.decl);
            }
        }

        const is_fn_body = decl.ty.zigTypeTag(mod) == .Fn;
        if ((!is_fn_body and !decl.ty.hasRuntimeBits(mod)) or
            (is_fn_body and mod.typeToFunc(decl.ty).?.is_generic))
        {
            return o.lowerPtrToVoid(tv.ty);
        }

        try mod.markDeclAlive(decl);

        const llvm_decl_val = if (is_fn_body)
            (try o.resolveLlvmFunction(decl_index)).toLlvm(&o.builder)
        else
            (try o.resolveGlobalDecl(decl_index)).toLlvm(&o.builder);

        const target = mod.getTarget();
        const llvm_wanted_addrspace = toLlvmAddressSpace(decl.@"addrspace", target);
        const llvm_actual_addrspace = toLlvmGlobalAddressSpace(decl.@"addrspace", target);
        const llvm_val = if (llvm_wanted_addrspace != llvm_actual_addrspace) blk: {
            const llvm_decl_wanted_ptr_ty = o.context.pointerType(@intFromEnum(llvm_wanted_addrspace));
            break :blk llvm_decl_val.constAddrSpaceCast(llvm_decl_wanted_ptr_ty);
        } else llvm_decl_val;

        const llvm_type = (try o.lowerType(tv.ty)).toLlvm(&o.builder);
        if (tv.ty.zigTypeTag(mod) == .Int) {
            return llvm_val.constPtrToInt(llvm_type);
        } else {
            return llvm_val.constBitCast(llvm_type);
        }
    }

    fn lowerPtrToVoid(o: *Object, ptr_ty: Type) !*llvm.Value {
        const mod = o.module;
        // Even though we are pointing at something which has zero bits (e.g. `void`),
        // Pointers are defined to have bits. So we must return something here.
        // The value cannot be undefined, because we use the `nonnull` annotation
        // for non-optional pointers. We also need to respect the alignment, even though
        // the address will never be dereferenced.
        const llvm_usize = try o.lowerType(Type.usize);
        const llvm_ptr_ty = (try o.lowerType(ptr_ty)).toLlvm(&o.builder);
        if (ptr_ty.ptrInfo(mod).flags.alignment.toByteUnitsOptional()) |alignment| {
            return (try o.builder.intConst(llvm_usize, alignment)).toLlvm(&o.builder).constIntToPtr(llvm_ptr_ty);
        }
        // Note that these 0xaa values are appropriate even in release-optimized builds
        // because we need a well-defined value that is not null, and LLVM does not
        // have an "undef_but_not_null" attribute. As an example, if this `alloc` AIR
        // instruction is followed by a `wrap_optional`, it will return this value
        // verbatim, and the result should test as non-null.
        const target = mod.getTarget();
        const int = try o.builder.intConst(llvm_usize, @as(u64, switch (target.ptrBitWidth()) {
            16 => 0xaaaa,
            32 => 0xaaaaaaaa,
            64 => 0xaaaaaaaa_aaaaaaaa,
            else => unreachable,
        }));
        return int.toLlvm(&o.builder).constIntToPtr(llvm_ptr_ty);
    }

    fn addAttr(o: *Object, val: *llvm.Value, index: llvm.AttributeIndex, name: []const u8) void {
        return o.addAttrInt(val, index, name, 0);
    }

    fn addArgAttr(o: *Object, fn_val: *llvm.Value, param_index: u32, attr_name: []const u8) void {
        return o.addAttr(fn_val, param_index + 1, attr_name);
    }

    fn addArgAttrInt(o: *Object, fn_val: *llvm.Value, param_index: u32, attr_name: []const u8, int: u64) void {
        return o.addAttrInt(fn_val, param_index + 1, attr_name, int);
    }

    fn removeAttr(val: *llvm.Value, index: llvm.AttributeIndex, name: []const u8) void {
        const kind_id = llvm.getEnumAttributeKindForName(name.ptr, name.len);
        assert(kind_id != 0);
        val.removeEnumAttributeAtIndex(index, kind_id);
    }

    fn addAttrInt(
        o: *Object,
        val: *llvm.Value,
        index: llvm.AttributeIndex,
        name: []const u8,
        int: u64,
    ) void {
        const kind_id = llvm.getEnumAttributeKindForName(name.ptr, name.len);
        assert(kind_id != 0);
        const llvm_attr = o.context.createEnumAttribute(kind_id, int);
        val.addAttributeAtIndex(index, llvm_attr);
    }

    fn addAttrString(
        o: *Object,
        val: *llvm.Value,
        index: llvm.AttributeIndex,
        name: []const u8,
        value: []const u8,
    ) void {
        const llvm_attr = o.context.createStringAttribute(
            name.ptr,
            @as(c_uint, @intCast(name.len)),
            value.ptr,
            @as(c_uint, @intCast(value.len)),
        );
        val.addAttributeAtIndex(index, llvm_attr);
    }

    fn addFnAttr(o: *Object, val: *llvm.Value, name: []const u8) void {
        o.addAttr(val, std.math.maxInt(llvm.AttributeIndex), name);
    }

    fn addFnAttrString(o: *Object, val: *llvm.Value, name: []const u8, value: []const u8) void {
        o.addAttrString(val, std.math.maxInt(llvm.AttributeIndex), name, value);
    }

    fn removeFnAttr(fn_val: *llvm.Value, name: []const u8) void {
        removeAttr(fn_val, std.math.maxInt(llvm.AttributeIndex), name);
    }

    fn addFnAttrInt(o: *Object, fn_val: *llvm.Value, name: []const u8, int: u64) void {
        return o.addAttrInt(fn_val, std.math.maxInt(llvm.AttributeIndex), name, int);
    }

    /// If the operand type of an atomic operation is not byte sized we need to
    /// widen it before using it and then truncate the result.
    /// RMW exchange of floating-point values is bitcasted to same-sized integer
    /// types to work around a LLVM deficiency when targeting ARM/AArch64.
    fn getAtomicAbiType(o: *Object, ty: Type, is_rmw_xchg: bool) Allocator.Error!Builder.Type {
        const mod = o.module;
        const int_ty = switch (ty.zigTypeTag(mod)) {
            .Int => ty,
            .Enum => ty.intTagType(mod),
            .Float => {
                if (!is_rmw_xchg) return .none;
                return o.builder.intType(@intCast(ty.abiSize(mod) * 8));
            },
            .Bool => return .i8,
            else => return .none,
        };
        const bit_count = int_ty.intInfo(mod).bits;
        if (!std.math.isPowerOfTwo(bit_count) or (bit_count % 8) != 0) {
            return o.builder.intType(@intCast(int_ty.abiSize(mod) * 8));
        } else {
            return .none;
        }
    }

    fn addByValParamAttrs(
        o: *Object,
        llvm_fn: *llvm.Value,
        param_ty: Type,
        param_index: u32,
        fn_info: InternPool.Key.FuncType,
        llvm_arg_i: u32,
    ) void {
        const mod = o.module;
        if (param_ty.isPtrAtRuntime(mod)) {
            const ptr_info = param_ty.ptrInfo(mod);
            if (math.cast(u5, param_index)) |i| {
                if (@as(u1, @truncate(fn_info.noalias_bits >> i)) != 0) {
                    o.addArgAttr(llvm_fn, llvm_arg_i, "noalias");
                }
            }
            if (!param_ty.isPtrLikeOptional(mod) and !ptr_info.flags.is_allowzero) {
                o.addArgAttr(llvm_fn, llvm_arg_i, "nonnull");
            }
            if (ptr_info.flags.is_const) {
                o.addArgAttr(llvm_fn, llvm_arg_i, "readonly");
            }
            const elem_align = ptr_info.flags.alignment.toByteUnitsOptional() orelse
                @max(ptr_info.child.toType().abiAlignment(mod), 1);
            o.addArgAttrInt(llvm_fn, llvm_arg_i, "align", elem_align);
        } else if (ccAbiPromoteInt(fn_info.cc, mod, param_ty)) |s| switch (s) {
            .signed => o.addArgAttr(llvm_fn, llvm_arg_i, "signext"),
            .unsigned => o.addArgAttr(llvm_fn, llvm_arg_i, "zeroext"),
        };
    }

    fn addByRefParamAttrs(
        o: *Object,
        llvm_fn: *llvm.Value,
        llvm_arg_i: u32,
        alignment: u32,
        byval_attr: bool,
        param_llvm_ty: Builder.Type,
    ) void {
        o.addArgAttr(llvm_fn, llvm_arg_i, "nonnull");
        o.addArgAttr(llvm_fn, llvm_arg_i, "readonly");
        o.addArgAttrInt(llvm_fn, llvm_arg_i, "align", alignment);
        if (byval_attr) {
            llvm_fn.addByValAttr(llvm_arg_i, param_llvm_ty.toLlvm(&o.builder));
        }
    }

    fn buildAllocaInner(
        o: *Object,
        builder: *llvm.Builder,
        llvm_func: *llvm.Value,
        di_scope_non_null: bool,
        llvm_ty: *llvm.Type,
        maybe_alignment: ?c_uint,
        target: std.Target,
    ) Allocator.Error!*llvm.Value {
        const address_space = llvmAllocaAddressSpace(target);

        const alloca = blk: {
            const prev_block = builder.getInsertBlock();
            const prev_debug_location = builder.getCurrentDebugLocation2();
            defer {
                builder.positionBuilderAtEnd(prev_block);
                if (di_scope_non_null) {
                    builder.setCurrentDebugLocation2(prev_debug_location);
                }
            }

            const entry_block = llvm_func.getFirstBasicBlock().?;
            if (entry_block.getFirstInstruction()) |first_inst| {
                builder.positionBuilder(entry_block, first_inst);
            } else {
                builder.positionBuilderAtEnd(entry_block);
            }
            builder.clearCurrentDebugLocation();

            break :blk builder.buildAllocaInAddressSpace(llvm_ty, @intFromEnum(address_space), "");
        };

        if (maybe_alignment) |alignment| {
            alloca.setAlignment(alignment);
        }

        // The pointer returned from this function should have the generic address space,
        // if this isn't the case then cast it to the generic address space.
        if (address_space != .default) {
            return builder.buildAddrSpaceCast(alloca, Builder.Type.ptr.toLlvm(&o.builder), "");
        }

        return alloca;
    }
};

pub const DeclGen = struct {
    object: *Object,
    decl: *Module.Decl,
    decl_index: Module.Decl.Index,
    err_msg: ?*Module.ErrorMsg,

    fn todo(dg: *DeclGen, comptime format: []const u8, args: anytype) Error {
        @setCold(true);
        assert(dg.err_msg == null);
        const o = dg.object;
        const gpa = o.gpa;
        const mod = o.module;
        const src_loc = LazySrcLoc.nodeOffset(0).toSrcLoc(dg.decl, mod);
        dg.err_msg = try Module.ErrorMsg.create(gpa, src_loc, "TODO (LLVM): " ++ format, args);
        return error.CodegenFail;
    }

    fn genDecl(dg: *DeclGen) !void {
        const o = dg.object;
        const mod = o.module;
        const decl = dg.decl;
        const decl_index = dg.decl_index;
        assert(decl.has_tv);

        if (decl.val.getExternFunc(mod)) |extern_func| {
            _ = try o.resolveLlvmFunction(extern_func.decl);
        } else {
            const target = mod.getTarget();
            const object_index = try o.resolveGlobalDecl(decl_index);
            const object = object_index.ptr(&o.builder);
            const global = object.global.ptr(&o.builder);
            var llvm_global = object.global.toLlvm(&o.builder);
            global.alignment = Builder.Alignment.fromByteUnits(decl.getAlignment(mod));
            llvm_global.setAlignment(decl.getAlignment(mod));
            if (mod.intern_pool.stringToSliceUnwrap(decl.@"linksection")) |s| llvm_global.setSection(s);
            assert(decl.has_tv);
            const init_val = if (decl.val.getVariable(mod)) |variable| init_val: {
                object.mutability = .global;
                break :init_val variable.init;
            } else init_val: {
                object.mutability = .constant;
                llvm_global.setGlobalConstant(.True);
                break :init_val decl.val.toIntern();
            };
            if (init_val != .none) {
                const llvm_init = try o.lowerValue(.{ .ty = decl.ty, .val = init_val.toValue() });
                if (llvm_global.globalGetValueType() == llvm_init.typeOf()) {
                    llvm_global.setInitializer(llvm_init);
                } else {
                    // LLVM does not allow us to change the type of globals. So we must
                    // create a new global with the correct type, copy all its attributes,
                    // and then update all references to point to the new global,
                    // delete the original, and rename the new one to the old one's name.
                    // This is necessary because LLVM does not support const bitcasting
                    // a struct with padding bytes, which is needed to lower a const union value
                    // to LLVM, when a field other than the most-aligned is active. Instead,
                    // we must lower to an unnamed struct, and pointer cast at usage sites
                    // of the global. Such an unnamed struct is the cause of the global type
                    // mismatch, because we don't have the LLVM type until the *value* is created,
                    // whereas the global needs to be created based on the type alone, because
                    // lowering the value may reference the global as a pointer.
                    // Related: https://github.com/ziglang/zig/issues/13265
                    const llvm_global_addrspace = toLlvmGlobalAddressSpace(decl.@"addrspace", target);
                    const new_global = o.llvm_module.addGlobalInAddressSpace(
                        llvm_init.typeOf(),
                        "",
                        @intFromEnum(llvm_global_addrspace),
                    );
                    new_global.setLinkage(llvm_global.getLinkage());
                    new_global.setUnnamedAddr(llvm_global.getUnnamedAddress());
                    new_global.setAlignment(llvm_global.getAlignment());
                    if (mod.intern_pool.stringToSliceUnwrap(decl.@"linksection")) |s|
                        new_global.setSection(s);
                    new_global.setInitializer(llvm_init);
                    // TODO: How should this work then the address space of a global changed?
                    llvm_global.replaceAllUsesWith(new_global);
                    new_global.takeName(llvm_global);
                    o.builder.llvm_globals.items[@intFromEnum(object.global)] = new_global;
                    llvm_global.deleteGlobal();
                    llvm_global = new_global;
                }
            }

            if (o.di_builder) |dib| {
                const di_file = try o.getDIFile(o.gpa, mod.namespacePtr(decl.src_namespace).file_scope);

                const line_number = decl.src_line + 1;
                const is_internal_linkage = !o.module.decl_exports.contains(decl_index);
                const di_global = dib.createGlobalVariableExpression(
                    di_file.toScope(),
                    mod.intern_pool.stringToSlice(decl.name),
                    llvm_global.getValueName(),
                    di_file,
                    line_number,
                    try o.lowerDebugType(decl.ty, .full),
                    is_internal_linkage,
                );

                try o.di_map.put(o.gpa, dg.decl, di_global.getVariable().toNode());
                if (!is_internal_linkage or decl.isExtern(mod)) llvm_global.attachMetaData(di_global);
            }
        }
    }
};

pub const FuncGen = struct {
    gpa: Allocator,
    dg: *DeclGen,
    air: Air,
    liveness: Liveness,
    context: *llvm.Context,
    builder: *llvm.Builder,
    di_scope: ?*llvm.DIScope,
    di_file: ?*llvm.DIFile,
    base_line: u32,
    prev_dbg_line: c_uint,
    prev_dbg_column: c_uint,

    /// Stack of locations where a call was inlined.
    dbg_inlined: std.ArrayListUnmanaged(DbgState) = .{},

    /// Stack of `DILexicalBlock`s. dbg_block instructions cannot happend accross
    /// dbg_inline instructions so no special handling there is required.
    dbg_block_stack: std.ArrayListUnmanaged(*llvm.DIScope) = .{},

    /// This stores the LLVM values used in a function, such that they can be referred to
    /// in other instructions. This table is cleared before every function is generated.
    func_inst_table: std.AutoHashMapUnmanaged(Air.Inst.Ref, *llvm.Value),

    /// If the return type is sret, this is the result pointer. Otherwise null.
    /// Note that this can disagree with isByRef for the return type in the case
    /// of C ABI functions.
    ret_ptr: ?*llvm.Value,
    /// Any function that needs to perform Valgrind client requests needs an array alloca
    /// instruction, however a maximum of one per function is needed.
    valgrind_client_request_array: ?*llvm.Value = null,
    /// These fields are used to refer to the LLVM value of the function parameters
    /// in an Arg instruction.
    /// This list may be shorter than the list according to the zig type system;
    /// it omits 0-bit types. If the function uses sret as the first parameter,
    /// this slice does not include it.
    args: []const *llvm.Value,
    arg_index: c_uint,

    llvm_func: *llvm.Value,

    err_ret_trace: ?*llvm.Value = null,

    /// This data structure is used to implement breaking to blocks.
    blocks: std.AutoHashMapUnmanaged(Air.Inst.Index, struct {
        parent_bb: *llvm.BasicBlock,
        breaks: *BreakList,
    }),

    single_threaded: bool,

    const DbgState = struct { loc: *llvm.DILocation, scope: *llvm.DIScope, base_line: u32 };
    const BreakList = std.MultiArrayList(struct {
        bb: *llvm.BasicBlock,
        val: *llvm.Value,
    });

    fn deinit(self: *FuncGen) void {
        self.builder.dispose();
        self.dbg_inlined.deinit(self.gpa);
        self.dbg_block_stack.deinit(self.gpa);
        self.func_inst_table.deinit(self.gpa);
        self.blocks.deinit(self.gpa);
    }

    fn todo(self: *FuncGen, comptime format: []const u8, args: anytype) Error {
        @setCold(true);
        return self.dg.todo(format, args);
    }

    fn resolveInst(self: *FuncGen, inst: Air.Inst.Ref) !*llvm.Value {
        const gpa = self.gpa;
        const gop = try self.func_inst_table.getOrPut(gpa, inst);
        if (gop.found_existing) return gop.value_ptr.*;

        const o = self.dg.object;
        const mod = o.module;
        const llvm_val = try self.resolveValue(.{
            .ty = self.typeOf(inst),
            .val = (try self.air.value(inst, mod)).?,
        });
        gop.value_ptr.* = llvm_val;
        return llvm_val;
    }

    fn resolveValue(self: *FuncGen, tv: TypedValue) !*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const llvm_val = try o.lowerValue(tv);
        if (!isByRef(tv.ty, mod)) return llvm_val;

        // We have an LLVM value but we need to create a global constant and
        // set the value as its initializer, and then return a pointer to the global.
        const target = mod.getTarget();
        const llvm_wanted_addrspace = toLlvmAddressSpace(.generic, target);
        const llvm_actual_addrspace = toLlvmGlobalAddressSpace(.generic, target);
        const global = o.llvm_module.addGlobalInAddressSpace(llvm_val.typeOf(), "", @intFromEnum(llvm_actual_addrspace));
        global.setInitializer(llvm_val);
        global.setLinkage(.Private);
        global.setGlobalConstant(.True);
        global.setUnnamedAddr(.True);
        global.setAlignment(tv.ty.abiAlignment(mod));
        const addrspace_casted_ptr = if (llvm_actual_addrspace != llvm_wanted_addrspace)
            global.constAddrSpaceCast(self.context.pointerType(@intFromEnum(llvm_wanted_addrspace)))
        else
            global;
        return addrspace_casted_ptr;
    }

    fn genBody(self: *FuncGen, body: []const Air.Inst.Index) Error!void {
        const o = self.dg.object;
        const mod = o.module;
        const ip = &mod.intern_pool;
        const air_tags = self.air.instructions.items(.tag);
        for (body, 0..) |inst, i| {
            if (self.liveness.isUnused(inst) and !self.air.mustLower(inst, ip))
                continue;

            const opt_value: ?*llvm.Value = switch (air_tags[inst]) {
                // zig fmt: off
                .add            => try self.airAdd(inst, false),
                .add_optimized  => try self.airAdd(inst, true),
                .add_wrap       => try self.airAddWrap(inst),
                .add_sat        => try self.airAddSat(inst),

                .sub            => try self.airSub(inst, false),
                .sub_optimized  => try self.airSub(inst, true),
                .sub_wrap       => try self.airSubWrap(inst),
                .sub_sat        => try self.airSubSat(inst),

                .mul           => try self.airMul(inst, false),
                .mul_optimized => try self.airMul(inst, true),
                .mul_wrap      => try self.airMulWrap(inst),
                .mul_sat       => try self.airMulSat(inst),

                .add_safe => try self.airSafeArithmetic(inst, "llvm.sadd.with.overflow", "llvm.uadd.with.overflow"),
                .sub_safe => try self.airSafeArithmetic(inst, "llvm.ssub.with.overflow", "llvm.usub.with.overflow"),
                .mul_safe => try self.airSafeArithmetic(inst, "llvm.smul.with.overflow", "llvm.umul.with.overflow"),

                .div_float => try self.airDivFloat(inst, false),
                .div_trunc => try self.airDivTrunc(inst, false),
                .div_floor => try self.airDivFloor(inst, false),
                .div_exact => try self.airDivExact(inst, false),
                .rem       => try self.airRem(inst, false),
                .mod       => try self.airMod(inst, false),
                .ptr_add   => try self.airPtrAdd(inst),
                .ptr_sub   => try self.airPtrSub(inst),
                .shl       => try self.airShl(inst),
                .shl_sat   => try self.airShlSat(inst),
                .shl_exact => try self.airShlExact(inst),
                .min       => try self.airMin(inst),
                .max       => try self.airMax(inst),
                .slice     => try self.airSlice(inst),
                .mul_add   => try self.airMulAdd(inst),

                .div_float_optimized => try self.airDivFloat(inst, true),
                .div_trunc_optimized => try self.airDivTrunc(inst, true),
                .div_floor_optimized => try self.airDivFloor(inst, true),
                .div_exact_optimized => try self.airDivExact(inst, true),
                .rem_optimized       => try self.airRem(inst, true),
                .mod_optimized       => try self.airMod(inst, true),

                .add_with_overflow => try self.airOverflow(inst, "llvm.sadd.with.overflow", "llvm.uadd.with.overflow"),
                .sub_with_overflow => try self.airOverflow(inst, "llvm.ssub.with.overflow", "llvm.usub.with.overflow"),
                .mul_with_overflow => try self.airOverflow(inst, "llvm.smul.with.overflow", "llvm.umul.with.overflow"),
                .shl_with_overflow => try self.airShlWithOverflow(inst),

                .bit_and, .bool_and => try self.airAnd(inst),
                .bit_or, .bool_or   => try self.airOr(inst),
                .xor                => try self.airXor(inst),
                .shr                => try self.airShr(inst, false),
                .shr_exact          => try self.airShr(inst, true),

                .sqrt         => try self.airUnaryOp(inst, .sqrt),
                .sin          => try self.airUnaryOp(inst, .sin),
                .cos          => try self.airUnaryOp(inst, .cos),
                .tan          => try self.airUnaryOp(inst, .tan),
                .exp          => try self.airUnaryOp(inst, .exp),
                .exp2         => try self.airUnaryOp(inst, .exp2),
                .log          => try self.airUnaryOp(inst, .log),
                .log2         => try self.airUnaryOp(inst, .log2),
                .log10        => try self.airUnaryOp(inst, .log10),
                .fabs         => try self.airUnaryOp(inst, .fabs),
                .floor        => try self.airUnaryOp(inst, .floor),
                .ceil         => try self.airUnaryOp(inst, .ceil),
                .round        => try self.airUnaryOp(inst, .round),
                .trunc_float  => try self.airUnaryOp(inst, .trunc),

                .neg           => try self.airNeg(inst, false),
                .neg_optimized => try self.airNeg(inst, true),

                .cmp_eq  => try self.airCmp(inst, .eq, false),
                .cmp_gt  => try self.airCmp(inst, .gt, false),
                .cmp_gte => try self.airCmp(inst, .gte, false),
                .cmp_lt  => try self.airCmp(inst, .lt, false),
                .cmp_lte => try self.airCmp(inst, .lte, false),
                .cmp_neq => try self.airCmp(inst, .neq, false),

                .cmp_eq_optimized  => try self.airCmp(inst, .eq, true),
                .cmp_gt_optimized  => try self.airCmp(inst, .gt, true),
                .cmp_gte_optimized => try self.airCmp(inst, .gte, true),
                .cmp_lt_optimized  => try self.airCmp(inst, .lt, true),
                .cmp_lte_optimized => try self.airCmp(inst, .lte, true),
                .cmp_neq_optimized => try self.airCmp(inst, .neq, true),

                .cmp_vector           => try self.airCmpVector(inst, false),
                .cmp_vector_optimized => try self.airCmpVector(inst, true),
                .cmp_lt_errors_len    => try self.airCmpLtErrorsLen(inst),

                .is_non_null     => try self.airIsNonNull(inst, false, .NE),
                .is_non_null_ptr => try self.airIsNonNull(inst, true , .NE),
                .is_null         => try self.airIsNonNull(inst, false, .EQ),
                .is_null_ptr     => try self.airIsNonNull(inst, true , .EQ),

                .is_non_err      => try self.airIsErr(inst, .EQ, false),
                .is_non_err_ptr  => try self.airIsErr(inst, .EQ, true),
                .is_err          => try self.airIsErr(inst, .NE, false),
                .is_err_ptr      => try self.airIsErr(inst, .NE, true),

                .alloc          => try self.airAlloc(inst),
                .ret_ptr        => try self.airRetPtr(inst),
                .arg            => try self.airArg(inst),
                .bitcast        => try self.airBitCast(inst),
                .int_from_bool    => try self.airIntFromBool(inst),
                .block          => try self.airBlock(inst),
                .br             => try self.airBr(inst),
                .switch_br      => try self.airSwitchBr(inst),
                .trap           => try self.airTrap(inst),
                .breakpoint     => try self.airBreakpoint(inst),
                .ret_addr       => try self.airRetAddr(inst),
                .frame_addr     => try self.airFrameAddress(inst),
                .cond_br        => try self.airCondBr(inst),
                .@"try"         => try self.airTry(body[i..]),
                .try_ptr        => try self.airTryPtr(inst),
                .intcast        => try self.airIntCast(inst),
                .trunc          => try self.airTrunc(inst),
                .fptrunc        => try self.airFptrunc(inst),
                .fpext          => try self.airFpext(inst),
                .int_from_ptr       => try self.airIntFromPtr(inst),
                .load           => try self.airLoad(body[i..]),
                .loop           => try self.airLoop(inst),
                .not            => try self.airNot(inst),
                .ret            => try self.airRet(inst),
                .ret_load       => try self.airRetLoad(inst),
                .store          => try self.airStore(inst, false),
                .store_safe     => try self.airStore(inst, true),
                .assembly       => try self.airAssembly(inst),
                .slice_ptr      => try self.airSliceField(inst, 0),
                .slice_len      => try self.airSliceField(inst, 1),

                .call              => try self.airCall(inst, .Auto),
                .call_always_tail  => try self.airCall(inst, .AlwaysTail),
                .call_never_tail   => try self.airCall(inst, .NeverTail),
                .call_never_inline => try self.airCall(inst, .NeverInline),

                .ptr_slice_ptr_ptr => try self.airPtrSliceFieldPtr(inst, 0),
                .ptr_slice_len_ptr => try self.airPtrSliceFieldPtr(inst, 1),

                .int_from_float           => try self.airIntFromFloat(inst, false),
                .int_from_float_optimized => try self.airIntFromFloat(inst, true),

                .array_to_slice => try self.airArrayToSlice(inst),
                .float_from_int   => try self.airFloatFromInt(inst),
                .cmpxchg_weak   => try self.airCmpxchg(inst, true),
                .cmpxchg_strong => try self.airCmpxchg(inst, false),
                .fence          => try self.airFence(inst),
                .atomic_rmw     => try self.airAtomicRmw(inst),
                .atomic_load    => try self.airAtomicLoad(inst),
                .memset         => try self.airMemset(inst, false),
                .memset_safe    => try self.airMemset(inst, true),
                .memcpy         => try self.airMemcpy(inst),
                .set_union_tag  => try self.airSetUnionTag(inst),
                .get_union_tag  => try self.airGetUnionTag(inst),
                .clz            => try self.airClzCtz(inst, "llvm.ctlz"),
                .ctz            => try self.airClzCtz(inst, "llvm.cttz"),
                .popcount       => try self.airBitOp(inst, "llvm.ctpop"),
                .byte_swap      => try self.airByteSwap(inst, "llvm.bswap"),
                .bit_reverse    => try self.airBitOp(inst, "llvm.bitreverse"),
                .tag_name       => try self.airTagName(inst),
                .error_name     => try self.airErrorName(inst),
                .splat          => try self.airSplat(inst),
                .select         => try self.airSelect(inst),
                .shuffle        => try self.airShuffle(inst),
                .aggregate_init => try self.airAggregateInit(inst),
                .union_init     => try self.airUnionInit(inst),
                .prefetch       => try self.airPrefetch(inst),
                .addrspace_cast => try self.airAddrSpaceCast(inst),

                .is_named_enum_value => try self.airIsNamedEnumValue(inst),
                .error_set_has_value => try self.airErrorSetHasValue(inst),

                .reduce           => try self.airReduce(inst, false),
                .reduce_optimized => try self.airReduce(inst, true),

                .atomic_store_unordered => try self.airAtomicStore(inst, .Unordered),
                .atomic_store_monotonic => try self.airAtomicStore(inst, .Monotonic),
                .atomic_store_release   => try self.airAtomicStore(inst, .Release),
                .atomic_store_seq_cst   => try self.airAtomicStore(inst, .SequentiallyConsistent),

                .struct_field_ptr => try self.airStructFieldPtr(inst),
                .struct_field_val => try self.airStructFieldVal(body[i..]),

                .struct_field_ptr_index_0 => try self.airStructFieldPtrIndex(inst, 0),
                .struct_field_ptr_index_1 => try self.airStructFieldPtrIndex(inst, 1),
                .struct_field_ptr_index_2 => try self.airStructFieldPtrIndex(inst, 2),
                .struct_field_ptr_index_3 => try self.airStructFieldPtrIndex(inst, 3),

                .field_parent_ptr => try self.airFieldParentPtr(inst),

                .array_elem_val     => try self.airArrayElemVal(body[i..]),
                .slice_elem_val     => try self.airSliceElemVal(body[i..]),
                .slice_elem_ptr     => try self.airSliceElemPtr(inst),
                .ptr_elem_val       => try self.airPtrElemVal(body[i..]),
                .ptr_elem_ptr       => try self.airPtrElemPtr(inst),

                .optional_payload         => try self.airOptionalPayload(body[i..]),
                .optional_payload_ptr     => try self.airOptionalPayloadPtr(inst),
                .optional_payload_ptr_set => try self.airOptionalPayloadPtrSet(inst),

                .unwrap_errunion_payload     => try self.airErrUnionPayload(body[i..], false),
                .unwrap_errunion_payload_ptr => try self.airErrUnionPayload(body[i..], true),
                .unwrap_errunion_err         => try self.airErrUnionErr(inst, false),
                .unwrap_errunion_err_ptr     => try self.airErrUnionErr(inst, true),
                .errunion_payload_ptr_set    => try self.airErrUnionPayloadPtrSet(inst),
                .err_return_trace            => try self.airErrReturnTrace(inst),
                .set_err_return_trace        => try self.airSetErrReturnTrace(inst),
                .save_err_return_trace_index => try self.airSaveErrReturnTraceIndex(inst),

                .wrap_optional         => try self.airWrapOptional(inst),
                .wrap_errunion_payload => try self.airWrapErrUnionPayload(inst),
                .wrap_errunion_err     => try self.airWrapErrUnionErr(inst),

                .wasm_memory_size => try self.airWasmMemorySize(inst),
                .wasm_memory_grow => try self.airWasmMemoryGrow(inst),

                .vector_store_elem => try self.airVectorStoreElem(inst),

                .inferred_alloc, .inferred_alloc_comptime => unreachable,

                .unreach  => self.airUnreach(inst),
                .dbg_stmt => self.airDbgStmt(inst),
                .dbg_inline_begin => try self.airDbgInlineBegin(inst),
                .dbg_inline_end => try self.airDbgInlineEnd(inst),
                .dbg_block_begin => try self.airDbgBlockBegin(),
                .dbg_block_end => try self.airDbgBlockEnd(),
                .dbg_var_ptr => try self.airDbgVarPtr(inst),
                .dbg_var_val => try self.airDbgVarVal(inst),

                .c_va_arg => try self.airCVaArg(inst),
                .c_va_copy => try self.airCVaCopy(inst),
                .c_va_end => try self.airCVaEnd(inst),
                .c_va_start => try self.airCVaStart(inst),

                .work_item_id => try self.airWorkItemId(inst),
                .work_group_size => try self.airWorkGroupSize(inst),
                .work_group_id => try self.airWorkGroupId(inst),
                // zig fmt: on
            };
            if (opt_value) |val| {
                const ref = Air.indexToRef(inst);
                try self.func_inst_table.putNoClobber(self.gpa, ref, val);
            }
        }
    }

    fn airCall(self: *FuncGen, inst: Air.Inst.Index, attr: llvm.CallAttr) !?*llvm.Value {
        const pl_op = self.air.instructions.items(.data)[inst].pl_op;
        const extra = self.air.extraData(Air.Call, pl_op.payload);
        const args = @as([]const Air.Inst.Ref, @ptrCast(self.air.extra[extra.end..][0..extra.data.args_len]));
        const o = self.dg.object;
        const mod = o.module;
        const callee_ty = self.typeOf(pl_op.operand);
        const zig_fn_ty = switch (callee_ty.zigTypeTag(mod)) {
            .Fn => callee_ty,
            .Pointer => callee_ty.childType(mod),
            else => unreachable,
        };
        const fn_info = mod.typeToFunc(zig_fn_ty).?;
        const return_type = fn_info.return_type.toType();
        const llvm_fn = try self.resolveInst(pl_op.operand);
        const target = mod.getTarget();
        const sret = firstParamSRet(fn_info, mod);

        var llvm_args = std.ArrayList(*llvm.Value).init(self.gpa);
        defer llvm_args.deinit();

        const ret_ptr = if (!sret) null else blk: {
            const llvm_ret_ty = (try o.lowerType(return_type)).toLlvm(&o.builder);
            const ret_ptr = try self.buildAlloca(llvm_ret_ty, return_type.abiAlignment(mod));
            try llvm_args.append(ret_ptr);
            break :blk ret_ptr;
        };

        const err_return_tracing = return_type.isError(mod) and
            o.module.comp.bin_file.options.error_return_tracing;
        if (err_return_tracing) {
            try llvm_args.append(self.err_ret_trace.?);
        }

        var it = iterateParamTypes(o, fn_info);
        while (try it.nextCall(self, args)) |lowering| switch (lowering) {
            .no_bits => continue,
            .byval => {
                const arg = args[it.zig_index - 1];
                const param_ty = self.typeOf(arg);
                const llvm_arg = try self.resolveInst(arg);
                const llvm_param_ty = (try o.lowerType(param_ty)).toLlvm(&o.builder);
                if (isByRef(param_ty, mod)) {
                    const alignment = param_ty.abiAlignment(mod);
                    const load_inst = self.builder.buildLoad(llvm_param_ty, llvm_arg, "");
                    load_inst.setAlignment(alignment);
                    try llvm_args.append(load_inst);
                } else {
                    try llvm_args.append(llvm_arg);
                }
            },
            .byref => {
                const arg = args[it.zig_index - 1];
                const param_ty = self.typeOf(arg);
                const llvm_arg = try self.resolveInst(arg);
                if (isByRef(param_ty, mod)) {
                    try llvm_args.append(llvm_arg);
                } else {
                    const alignment = param_ty.abiAlignment(mod);
                    const param_llvm_ty = llvm_arg.typeOf();
                    const arg_ptr = try self.buildAlloca(param_llvm_ty, alignment);
                    const store_inst = self.builder.buildStore(llvm_arg, arg_ptr);
                    store_inst.setAlignment(alignment);
                    try llvm_args.append(arg_ptr);
                }
            },
            .byref_mut => {
                const arg = args[it.zig_index - 1];
                const param_ty = self.typeOf(arg);
                const llvm_arg = try self.resolveInst(arg);

                const alignment = param_ty.abiAlignment(mod);
                const param_llvm_ty = (try o.lowerType(param_ty)).toLlvm(&o.builder);
                const arg_ptr = try self.buildAlloca(param_llvm_ty, alignment);
                if (isByRef(param_ty, mod)) {
                    const load_inst = self.builder.buildLoad(param_llvm_ty, llvm_arg, "");
                    load_inst.setAlignment(alignment);

                    const store_inst = self.builder.buildStore(load_inst, arg_ptr);
                    store_inst.setAlignment(alignment);
                    try llvm_args.append(arg_ptr);
                } else {
                    const store_inst = self.builder.buildStore(llvm_arg, arg_ptr);
                    store_inst.setAlignment(alignment);
                    try llvm_args.append(arg_ptr);
                }
            },
            .abi_sized_int => {
                const arg = args[it.zig_index - 1];
                const param_ty = self.typeOf(arg);
                const llvm_arg = try self.resolveInst(arg);
                const abi_size = @as(c_uint, @intCast(param_ty.abiSize(mod)));
                const int_llvm_ty = (try o.builder.intType(@intCast(abi_size * 8))).toLlvm(&o.builder);

                if (isByRef(param_ty, mod)) {
                    const alignment = param_ty.abiAlignment(mod);
                    const load_inst = self.builder.buildLoad(int_llvm_ty, llvm_arg, "");
                    load_inst.setAlignment(alignment);
                    try llvm_args.append(load_inst);
                } else {
                    // LLVM does not allow bitcasting structs so we must allocate
                    // a local, store as one type, and then load as another type.
                    const alignment = @max(
                        param_ty.abiAlignment(mod),
                        o.target_data.abiAlignmentOfType(int_llvm_ty),
                    );
                    const int_ptr = try self.buildAlloca(int_llvm_ty, alignment);
                    const store_inst = self.builder.buildStore(llvm_arg, int_ptr);
                    store_inst.setAlignment(alignment);
                    const load_inst = self.builder.buildLoad(int_llvm_ty, int_ptr, "");
                    load_inst.setAlignment(alignment);
                    try llvm_args.append(load_inst);
                }
            },
            .slice => {
                const arg = args[it.zig_index - 1];
                const llvm_arg = try self.resolveInst(arg);
                const ptr = self.builder.buildExtractValue(llvm_arg, 0, "");
                const len = self.builder.buildExtractValue(llvm_arg, 1, "");
                try llvm_args.ensureUnusedCapacity(2);
                llvm_args.appendAssumeCapacity(ptr);
                llvm_args.appendAssumeCapacity(len);
            },
            .multiple_llvm_types => {
                const arg = args[it.zig_index - 1];
                const param_ty = self.typeOf(arg);
                const llvm_types = it.types_buffer[0..it.types_len];
                const llvm_arg = try self.resolveInst(arg);
                const is_by_ref = isByRef(param_ty, mod);
                const arg_ptr = if (is_by_ref) llvm_arg else p: {
                    const p = try self.buildAlloca(llvm_arg.typeOf(), null);
                    const store_inst = self.builder.buildStore(llvm_arg, p);
                    store_inst.setAlignment(param_ty.abiAlignment(mod));
                    break :p p;
                };

                const llvm_ty = (try o.builder.structType(.normal, llvm_types)).toLlvm(&o.builder);
                try llvm_args.ensureUnusedCapacity(it.types_len);
                for (llvm_types, 0..) |field_ty, i_usize| {
                    const i = @as(c_uint, @intCast(i_usize));
                    const field_ptr = self.builder.buildStructGEP(llvm_ty, arg_ptr, i, "");
                    const load_inst = self.builder.buildLoad(field_ty.toLlvm(&o.builder), field_ptr, "");
                    load_inst.setAlignment(target.ptrBitWidth() / 8);
                    llvm_args.appendAssumeCapacity(load_inst);
                }
            },
            .as_u16 => {
                const arg = args[it.zig_index - 1];
                const llvm_arg = try self.resolveInst(arg);
                const casted = self.builder.buildBitCast(llvm_arg, Builder.Type.i16.toLlvm(&o.builder), "");
                try llvm_args.append(casted);
            },
            .float_array => |count| {
                const arg = args[it.zig_index - 1];
                const arg_ty = self.typeOf(arg);
                var llvm_arg = try self.resolveInst(arg);
                if (!isByRef(arg_ty, mod)) {
                    const p = try self.buildAlloca(llvm_arg.typeOf(), null);
                    const store_inst = self.builder.buildStore(llvm_arg, p);
                    store_inst.setAlignment(arg_ty.abiAlignment(mod));
                    llvm_arg = store_inst;
                }

                const float_ty = try o.lowerType(aarch64_c_abi.getFloatArrayType(arg_ty, mod).?);
                const array_ty = try o.builder.arrayType(count, float_ty);

                const alignment = arg_ty.abiAlignment(mod);
                const load_inst = self.builder.buildLoad(array_ty.toLlvm(&o.builder), llvm_arg, "");
                load_inst.setAlignment(alignment);
                try llvm_args.append(load_inst);
            },
            .i32_array, .i64_array => |arr_len| {
                const elem_size: u8 = if (lowering == .i32_array) 32 else 64;
                const arg = args[it.zig_index - 1];
                const arg_ty = self.typeOf(arg);
                var llvm_arg = try self.resolveInst(arg);
                if (!isByRef(arg_ty, mod)) {
                    const p = try self.buildAlloca(llvm_arg.typeOf(), null);
                    const store_inst = self.builder.buildStore(llvm_arg, p);
                    store_inst.setAlignment(arg_ty.abiAlignment(mod));
                    llvm_arg = store_inst;
                }

                const array_ty = try o.builder.arrayType(arr_len, try o.builder.intType(@intCast(elem_size)));
                const alignment = arg_ty.abiAlignment(mod);
                const load_inst = self.builder.buildLoad(array_ty.toLlvm(&o.builder), llvm_arg, "");
                load_inst.setAlignment(alignment);
                try llvm_args.append(load_inst);
            },
        };

        const call = self.builder.buildCall(
            (try o.lowerType(zig_fn_ty)).toLlvm(&o.builder),
            llvm_fn,
            llvm_args.items.ptr,
            @as(c_uint, @intCast(llvm_args.items.len)),
            toLlvmCallConv(fn_info.cc, target),
            attr,
            "",
        );

        if (callee_ty.zigTypeTag(mod) == .Pointer) {
            // Add argument attributes for function pointer calls.
            it = iterateParamTypes(o, fn_info);
            it.llvm_index += @intFromBool(sret);
            it.llvm_index += @intFromBool(err_return_tracing);
            while (try it.next()) |lowering| switch (lowering) {
                .byval => {
                    const param_index = it.zig_index - 1;
                    const param_ty = fn_info.param_types[param_index].toType();
                    if (!isByRef(param_ty, mod)) {
                        o.addByValParamAttrs(call, param_ty, param_index, fn_info, it.llvm_index - 1);
                    }
                },
                .byref => {
                    const param_index = it.zig_index - 1;
                    const param_ty = fn_info.param_types[param_index].toType();
                    const param_llvm_ty = try o.lowerType(param_ty);
                    const alignment = param_ty.abiAlignment(mod);
                    o.addByRefParamAttrs(call, it.llvm_index - 1, alignment, it.byval_attr, param_llvm_ty);
                },
                .byref_mut => {
                    o.addArgAttr(call, it.llvm_index - 1, "noundef");
                },
                // No attributes needed for these.
                .no_bits,
                .abi_sized_int,
                .multiple_llvm_types,
                .as_u16,
                .float_array,
                .i32_array,
                .i64_array,
                => continue,

                .slice => {
                    assert(!it.byval_attr);
                    const param_ty = fn_info.param_types[it.zig_index - 1].toType();
                    const ptr_info = param_ty.ptrInfo(mod);
                    const llvm_arg_i = it.llvm_index - 2;

                    if (math.cast(u5, it.zig_index - 1)) |i| {
                        if (@as(u1, @truncate(fn_info.noalias_bits >> i)) != 0) {
                            o.addArgAttr(call, llvm_arg_i, "noalias");
                        }
                    }
                    if (param_ty.zigTypeTag(mod) != .Optional) {
                        o.addArgAttr(call, llvm_arg_i, "nonnull");
                    }
                    if (ptr_info.flags.is_const) {
                        o.addArgAttr(call, llvm_arg_i, "readonly");
                    }
                    const elem_align = ptr_info.flags.alignment.toByteUnitsOptional() orelse
                        @max(ptr_info.child.toType().abiAlignment(mod), 1);
                    o.addArgAttrInt(call, llvm_arg_i, "align", elem_align);
                },
            };
        }

        if (fn_info.return_type == .noreturn_type and attr != .AlwaysTail) {
            return null;
        }

        if (self.liveness.isUnused(inst) or !return_type.hasRuntimeBitsIgnoreComptime(mod)) {
            return null;
        }

        const llvm_ret_ty = (try o.lowerType(return_type)).toLlvm(&o.builder);

        if (ret_ptr) |rp| {
            call.setCallSret(llvm_ret_ty);
            if (isByRef(return_type, mod)) {
                return rp;
            } else {
                // our by-ref status disagrees with sret so we must load.
                const loaded = self.builder.buildLoad(llvm_ret_ty, rp, "");
                loaded.setAlignment(return_type.abiAlignment(mod));
                return loaded;
            }
        }

        const abi_ret_ty = (try lowerFnRetTy(o, fn_info)).toLlvm(&o.builder);

        if (abi_ret_ty != llvm_ret_ty) {
            // In this case the function return type is honoring the calling convention by having
            // a different LLVM type than the usual one. We solve this here at the callsite
            // by using our canonical type, then loading it if necessary.
            const alignment = o.target_data.abiAlignmentOfType(abi_ret_ty);
            const rp = try self.buildAlloca(llvm_ret_ty, alignment);
            const store_inst = self.builder.buildStore(call, rp);
            store_inst.setAlignment(alignment);
            if (isByRef(return_type, mod)) {
                return rp;
            } else {
                const load_inst = self.builder.buildLoad(llvm_ret_ty, rp, "");
                load_inst.setAlignment(alignment);
                return load_inst;
            }
        }

        if (isByRef(return_type, mod)) {
            // our by-ref status disagrees with sret so we must allocate, store,
            // and return the allocation pointer.
            const alignment = return_type.abiAlignment(mod);
            const rp = try self.buildAlloca(llvm_ret_ty, alignment);
            const store_inst = self.builder.buildStore(call, rp);
            store_inst.setAlignment(alignment);
            return rp;
        } else {
            return call;
        }
    }

    fn buildSimplePanic(fg: *FuncGen, panic_id: Module.PanicId) !void {
        const o = fg.dg.object;
        const mod = o.module;
        const msg_decl_index = mod.panic_messages[@intFromEnum(panic_id)].unwrap().?;
        const msg_decl = mod.declPtr(msg_decl_index);
        const msg_len = msg_decl.ty.childType(mod).arrayLen(mod);
        const msg_ptr = try o.lowerValue(.{
            .ty = msg_decl.ty,
            .val = msg_decl.val,
        });
        const null_opt_addr_global = try o.getNullOptAddr();
        const target = mod.getTarget();
        const llvm_usize = try o.lowerType(Type.usize);
        // example:
        // call fastcc void @test2.panic(
        //   ptr @builtin.panic_messages.integer_overflow__anon_987, ; msg.ptr
        //   i64 16,                                                 ; msg.len
        //   ptr null,                                               ; stack trace
        //   ptr @2,                                                 ; addr (null ?usize)
        // )
        const args = [4]*llvm.Value{
            msg_ptr,
            (try o.builder.intConst(llvm_usize, msg_len)).toLlvm(&o.builder),
            fg.context.pointerType(0).constNull(),
            null_opt_addr_global,
        };
        const panic_func = mod.funcPtrUnwrap(mod.panic_func_index).?;
        const panic_decl = mod.declPtr(panic_func.owner_decl);
        const fn_info = mod.typeToFunc(panic_decl.ty).?;
        const panic_global = try o.resolveLlvmFunction(panic_func.owner_decl);
        _ = fg.builder.buildCall(
            (try o.lowerType(panic_decl.ty)).toLlvm(&o.builder),
            panic_global.toLlvm(&o.builder),
            &args,
            args.len,
            toLlvmCallConv(fn_info.cc, target),
            .Auto,
            "",
        );
        _ = fg.builder.buildUnreachable();
    }

    fn airRet(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const un_op = self.air.instructions.items(.data)[inst].un_op;
        const ret_ty = self.typeOf(un_op);
        if (self.ret_ptr) |ret_ptr| {
            const operand = try self.resolveInst(un_op);
            const ptr_ty = try mod.singleMutPtrType(ret_ty);
            try self.store(ret_ptr, ptr_ty, operand, .NotAtomic);
            _ = self.builder.buildRetVoid();
            return null;
        }
        const fn_info = mod.typeToFunc(self.dg.decl.ty).?;
        if (!ret_ty.hasRuntimeBitsIgnoreComptime(mod)) {
            if (fn_info.return_type.toType().isError(mod)) {
                // Functions with an empty error set are emitted with an error code
                // return type and return zero so they can be function pointers coerced
                // to functions that return anyerror.
                const int = try o.builder.intConst(Builder.Type.err_int, 0);
                _ = self.builder.buildRet(int.toLlvm(&o.builder));
            } else {
                _ = self.builder.buildRetVoid();
            }
            return null;
        }

        const abi_ret_ty = (try lowerFnRetTy(o, fn_info)).toLlvm(&o.builder);
        const operand = try self.resolveInst(un_op);
        const alignment = ret_ty.abiAlignment(mod);

        if (isByRef(ret_ty, mod)) {
            // operand is a pointer however self.ret_ptr is null so that means
            // we need to return a value.
            const load_inst = self.builder.buildLoad(abi_ret_ty, operand, "");
            load_inst.setAlignment(alignment);
            _ = self.builder.buildRet(load_inst);
            return null;
        }

        const llvm_ret_ty = operand.typeOf();
        if (abi_ret_ty == llvm_ret_ty) {
            _ = self.builder.buildRet(operand);
            return null;
        }

        const rp = try self.buildAlloca(llvm_ret_ty, alignment);
        const store_inst = self.builder.buildStore(operand, rp);
        store_inst.setAlignment(alignment);
        const load_inst = self.builder.buildLoad(abi_ret_ty, rp, "");
        load_inst.setAlignment(alignment);
        _ = self.builder.buildRet(load_inst);
        return null;
    }

    fn airRetLoad(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const un_op = self.air.instructions.items(.data)[inst].un_op;
        const ptr_ty = self.typeOf(un_op);
        const ret_ty = ptr_ty.childType(mod);
        const fn_info = mod.typeToFunc(self.dg.decl.ty).?;
        if (!ret_ty.hasRuntimeBitsIgnoreComptime(mod)) {
            if (fn_info.return_type.toType().isError(mod)) {
                // Functions with an empty error set are emitted with an error code
                // return type and return zero so they can be function pointers coerced
                // to functions that return anyerror.
                const int = try o.builder.intConst(Builder.Type.err_int, 0);
                _ = self.builder.buildRet(int.toLlvm(&o.builder));
            } else {
                _ = self.builder.buildRetVoid();
            }
            return null;
        }
        if (self.ret_ptr != null) {
            _ = self.builder.buildRetVoid();
            return null;
        }
        const ptr = try self.resolveInst(un_op);
        const abi_ret_ty = (try lowerFnRetTy(o, fn_info)).toLlvm(&o.builder);
        const loaded = self.builder.buildLoad(abi_ret_ty, ptr, "");
        loaded.setAlignment(ret_ty.abiAlignment(mod));
        _ = self.builder.buildRet(loaded);
        return null;
    }

    fn airCVaArg(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const list = try self.resolveInst(ty_op.operand);
        const arg_ty = self.air.getRefType(ty_op.ty);
        const llvm_arg_ty = (try o.lowerType(arg_ty)).toLlvm(&o.builder);

        return self.builder.buildVAArg(list, llvm_arg_ty, "");
    }

    fn airCVaCopy(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const src_list = try self.resolveInst(ty_op.operand);
        const va_list_ty = self.air.getRefType(ty_op.ty);
        const llvm_va_list_ty = (try o.lowerType(va_list_ty)).toLlvm(&o.builder);
        const mod = o.module;

        const result_alignment = va_list_ty.abiAlignment(mod);
        const dest_list = try self.buildAlloca(llvm_va_list_ty, result_alignment);

        const llvm_fn_name = "llvm.va_copy";
        const llvm_fn = o.llvm_module.getNamedFunction(llvm_fn_name) orelse blk: {
            const fn_type = try o.builder.fnType(.void, &.{ .ptr, .ptr }, .normal);
            break :blk o.llvm_module.addFunction(llvm_fn_name, fn_type.toLlvm(&o.builder));
        };

        const args: [2]*llvm.Value = .{ dest_list, src_list };
        _ = self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, &args, args.len, .Fast, .Auto, "");

        if (isByRef(va_list_ty, mod)) {
            return dest_list;
        } else {
            const loaded = self.builder.buildLoad(llvm_va_list_ty, dest_list, "");
            loaded.setAlignment(result_alignment);
            return loaded;
        }
    }

    fn airCVaEnd(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const un_op = self.air.instructions.items(.data)[inst].un_op;
        const list = try self.resolveInst(un_op);

        const llvm_fn_name = "llvm.va_end";
        const llvm_fn = o.llvm_module.getNamedFunction(llvm_fn_name) orelse blk: {
            const fn_type = try o.builder.fnType(.void, &.{.ptr}, .normal);
            break :blk o.llvm_module.addFunction(llvm_fn_name, fn_type.toLlvm(&o.builder));
        };
        const args: [1]*llvm.Value = .{list};
        _ = self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, &args, args.len, .Fast, .Auto, "");
        return null;
    }

    fn airCVaStart(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const va_list_ty = self.typeOfIndex(inst);
        const llvm_va_list_ty = (try o.lowerType(va_list_ty)).toLlvm(&o.builder);

        const result_alignment = va_list_ty.abiAlignment(mod);
        const list = try self.buildAlloca(llvm_va_list_ty, result_alignment);

        const llvm_fn_name = "llvm.va_start";
        const llvm_fn = o.llvm_module.getNamedFunction(llvm_fn_name) orelse blk: {
            const fn_type = try o.builder.fnType(.void, &.{.ptr}, .normal);
            break :blk o.llvm_module.addFunction(llvm_fn_name, fn_type.toLlvm(&o.builder));
        };
        const args: [1]*llvm.Value = .{list};
        _ = self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, &args, args.len, .Fast, .Auto, "");

        if (isByRef(va_list_ty, mod)) {
            return list;
        } else {
            const loaded = self.builder.buildLoad(llvm_va_list_ty, list, "");
            loaded.setAlignment(result_alignment);
            return loaded;
        }
    }

    fn airCmp(self: *FuncGen, inst: Air.Inst.Index, op: math.CompareOperator, want_fast_math: bool) !?*llvm.Value {
        self.builder.setFastMath(want_fast_math);

        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const operand_ty = self.typeOf(bin_op.lhs);

        return self.cmp(lhs, rhs, operand_ty, op);
    }

    fn airCmpVector(self: *FuncGen, inst: Air.Inst.Index, want_fast_math: bool) !?*llvm.Value {
        self.builder.setFastMath(want_fast_math);

        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const extra = self.air.extraData(Air.VectorCmp, ty_pl.payload).data;

        const lhs = try self.resolveInst(extra.lhs);
        const rhs = try self.resolveInst(extra.rhs);
        const vec_ty = self.typeOf(extra.lhs);
        const cmp_op = extra.compareOperator();

        return self.cmp(lhs, rhs, vec_ty, cmp_op);
    }

    fn airCmpLtErrorsLen(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const un_op = self.air.instructions.items(.data)[inst].un_op;
        const operand = try self.resolveInst(un_op);
        const llvm_fn = try self.getCmpLtErrorsLenFunction();
        const args: [1]*llvm.Value = .{operand};
        return self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, &args, args.len, .Fast, .Auto, "");
    }

    fn cmp(
        self: *FuncGen,
        lhs: *llvm.Value,
        rhs: *llvm.Value,
        operand_ty: Type,
        op: math.CompareOperator,
    ) Allocator.Error!*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const scalar_ty = operand_ty.scalarType(mod);
        const int_ty = switch (scalar_ty.zigTypeTag(mod)) {
            .Enum => scalar_ty.intTagType(mod),
            .Int, .Bool, .Pointer, .ErrorSet => scalar_ty,
            .Optional => blk: {
                const payload_ty = operand_ty.optionalChild(mod);
                if (!payload_ty.hasRuntimeBitsIgnoreComptime(mod) or
                    operand_ty.optionalReprIsPayload(mod))
                {
                    break :blk operand_ty;
                }
                // We need to emit instructions to check for equality/inequality
                // of optionals that are not pointers.
                const is_by_ref = isByRef(scalar_ty, mod);
                const opt_llvm_ty = (try o.lowerType(scalar_ty)).toLlvm(&o.builder);
                const lhs_non_null = try self.optIsNonNull(opt_llvm_ty, lhs, is_by_ref);
                const rhs_non_null = try self.optIsNonNull(opt_llvm_ty, rhs, is_by_ref);
                const llvm_i2 = try o.builder.intType(2);
                const lhs_non_null_i2 = self.builder.buildZExt(lhs_non_null, llvm_i2.toLlvm(&o.builder), "");
                const rhs_non_null_i2 = self.builder.buildZExt(rhs_non_null, llvm_i2.toLlvm(&o.builder), "");
                const lhs_shifted = self.builder.buildShl(lhs_non_null_i2, (try o.builder.intConst(llvm_i2, 1)).toLlvm(&o.builder), "");
                const lhs_rhs_ored = self.builder.buildOr(lhs_shifted, rhs_non_null_i2, "");
                const both_null_block = self.context.appendBasicBlock(self.llvm_func, "BothNull");
                const mixed_block = self.context.appendBasicBlock(self.llvm_func, "Mixed");
                const both_pl_block = self.context.appendBasicBlock(self.llvm_func, "BothNonNull");
                const end_block = self.context.appendBasicBlock(self.llvm_func, "End");
                const llvm_switch = self.builder.buildSwitch(lhs_rhs_ored, mixed_block, 2);
                const llvm_i2_00 = try o.builder.intConst(llvm_i2, 0b00);
                const llvm_i2_11 = try o.builder.intConst(llvm_i2, 0b11);
                llvm_switch.addCase(llvm_i2_00.toLlvm(&o.builder), both_null_block);
                llvm_switch.addCase(llvm_i2_11.toLlvm(&o.builder), both_pl_block);

                self.builder.positionBuilderAtEnd(both_null_block);
                _ = self.builder.buildBr(end_block);

                self.builder.positionBuilderAtEnd(mixed_block);
                _ = self.builder.buildBr(end_block);

                self.builder.positionBuilderAtEnd(both_pl_block);
                const lhs_payload = try self.optPayloadHandle(opt_llvm_ty, lhs, scalar_ty, true);
                const rhs_payload = try self.optPayloadHandle(opt_llvm_ty, rhs, scalar_ty, true);
                const payload_cmp = try self.cmp(lhs_payload, rhs_payload, payload_ty, op);
                _ = self.builder.buildBr(end_block);
                const both_pl_block_end = self.builder.getInsertBlock();

                self.builder.positionBuilderAtEnd(end_block);
                const incoming_blocks: [3]*llvm.BasicBlock = .{
                    both_null_block,
                    mixed_block,
                    both_pl_block_end,
                };
                const llvm_i1_0 = Builder.Constant.false.toLlvm(&o.builder);
                const llvm_i1_1 = Builder.Constant.true.toLlvm(&o.builder);
                const incoming_values: [3]*llvm.Value = .{
                    switch (op) {
                        .eq => llvm_i1_1,
                        .neq => llvm_i1_0,
                        else => unreachable,
                    },
                    switch (op) {
                        .eq => llvm_i1_0,
                        .neq => llvm_i1_1,
                        else => unreachable,
                    },
                    payload_cmp,
                };

                const phi_node = self.builder.buildPhi(Builder.Type.i1.toLlvm(&o.builder), "");
                comptime assert(incoming_values.len == incoming_blocks.len);
                phi_node.addIncoming(
                    &incoming_values,
                    &incoming_blocks,
                    incoming_values.len,
                );
                return phi_node;
            },
            .Float => return self.buildFloatCmp(op, operand_ty, .{ lhs, rhs }),
            else => unreachable,
        };
        const is_signed = int_ty.isSignedInt(mod);
        const operation: llvm.IntPredicate = switch (op) {
            .eq => .EQ,
            .neq => .NE,
            .lt => if (is_signed) llvm.IntPredicate.SLT else .ULT,
            .lte => if (is_signed) llvm.IntPredicate.SLE else .ULE,
            .gt => if (is_signed) llvm.IntPredicate.SGT else .UGT,
            .gte => if (is_signed) llvm.IntPredicate.SGE else .UGE,
        };
        return self.builder.buildICmp(operation, lhs, rhs, "");
    }

    fn airBlock(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const extra = self.air.extraData(Air.Block, ty_pl.payload);
        const body = self.air.extra[extra.end..][0..extra.data.body_len];
        const inst_ty = self.typeOfIndex(inst);
        const parent_bb = self.context.createBasicBlock("Block");

        if (inst_ty.isNoReturn(mod)) {
            try self.genBody(body);
            return null;
        }

        var breaks: BreakList = .{};
        defer breaks.deinit(self.gpa);

        try self.blocks.putNoClobber(self.gpa, inst, .{
            .parent_bb = parent_bb,
            .breaks = &breaks,
        });
        defer assert(self.blocks.remove(inst));

        try self.genBody(body);

        self.llvm_func.appendExistingBasicBlock(parent_bb);
        self.builder.positionBuilderAtEnd(parent_bb);

        // Create a phi node only if the block returns a value.
        const is_body = inst_ty.zigTypeTag(mod) == .Fn;
        if (!is_body and !inst_ty.hasRuntimeBitsIgnoreComptime(mod)) return null;

        const raw_llvm_ty = (try o.lowerType(inst_ty)).toLlvm(&o.builder);

        const llvm_ty = ty: {
            // If the zig tag type is a function, this represents an actual function body; not
            // a pointer to it. LLVM IR allows the call instruction to use function bodies instead
            // of function pointers, however the phi makes it a runtime value and therefore
            // the LLVM type has to be wrapped in a pointer.
            if (is_body or isByRef(inst_ty, mod)) {
                break :ty self.context.pointerType(0);
            }
            break :ty raw_llvm_ty;
        };

        const phi_node = self.builder.buildPhi(llvm_ty, "");
        phi_node.addIncoming(
            breaks.items(.val).ptr,
            breaks.items(.bb).ptr,
            @as(c_uint, @intCast(breaks.len)),
        );
        return phi_node;
    }

    fn airBr(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const branch = self.air.instructions.items(.data)[inst].br;
        const block = self.blocks.get(branch.block_inst).?;

        // Add the values to the lists only if the break provides a value.
        const operand_ty = self.typeOf(branch.operand);
        const mod = o.module;
        if (operand_ty.hasRuntimeBitsIgnoreComptime(mod) or operand_ty.zigTypeTag(mod) == .Fn) {
            const val = try self.resolveInst(branch.operand);

            // For the phi node, we need the basic blocks and the values of the
            // break instructions.
            try block.breaks.append(self.gpa, .{
                .bb = self.builder.getInsertBlock(),
                .val = val,
            });
        }
        _ = self.builder.buildBr(block.parent_bb);
        return null;
    }

    fn airCondBr(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const pl_op = self.air.instructions.items(.data)[inst].pl_op;
        const cond = try self.resolveInst(pl_op.operand);
        const extra = self.air.extraData(Air.CondBr, pl_op.payload);
        const then_body = self.air.extra[extra.end..][0..extra.data.then_body_len];
        const else_body = self.air.extra[extra.end + then_body.len ..][0..extra.data.else_body_len];

        const then_block = self.context.appendBasicBlock(self.llvm_func, "Then");
        const else_block = self.context.appendBasicBlock(self.llvm_func, "Else");
        _ = self.builder.buildCondBr(cond, then_block, else_block);

        self.builder.positionBuilderAtEnd(then_block);
        try self.genBody(then_body);

        self.builder.positionBuilderAtEnd(else_block);
        try self.genBody(else_body);

        // No need to reset the insert cursor since this instruction is noreturn.
        return null;
    }

    fn airTry(self: *FuncGen, body_tail: []const Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const inst = body_tail[0];
        const pl_op = self.air.instructions.items(.data)[inst].pl_op;
        const err_union = try self.resolveInst(pl_op.operand);
        const extra = self.air.extraData(Air.Try, pl_op.payload);
        const body = self.air.extra[extra.end..][0..extra.data.body_len];
        const err_union_ty = self.typeOf(pl_op.operand);
        const payload_ty = self.typeOfIndex(inst);
        const can_elide_load = if (isByRef(payload_ty, mod)) self.canElideLoad(body_tail) else false;
        const is_unused = self.liveness.isUnused(inst);
        return lowerTry(self, err_union, body, err_union_ty, false, can_elide_load, is_unused);
    }

    fn airTryPtr(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const extra = self.air.extraData(Air.TryPtr, ty_pl.payload);
        const err_union_ptr = try self.resolveInst(extra.data.ptr);
        const body = self.air.extra[extra.end..][0..extra.data.body_len];
        const err_union_ty = self.typeOf(extra.data.ptr).childType(mod);
        const is_unused = self.liveness.isUnused(inst);
        return lowerTry(self, err_union_ptr, body, err_union_ty, true, true, is_unused);
    }

    fn lowerTry(
        fg: *FuncGen,
        err_union: *llvm.Value,
        body: []const Air.Inst.Index,
        err_union_ty: Type,
        operand_is_ptr: bool,
        can_elide_load: bool,
        is_unused: bool,
    ) !?*llvm.Value {
        const o = fg.dg.object;
        const mod = o.module;
        const payload_ty = err_union_ty.errorUnionPayload(mod);
        const payload_has_bits = payload_ty.hasRuntimeBitsIgnoreComptime(mod);
        const err_union_llvm_ty = (try o.lowerType(err_union_ty)).toLlvm(&o.builder);

        if (!err_union_ty.errorUnionSet(mod).errorSetIsEmpty(mod)) {
            const is_err = err: {
                const err_set_ty = (try o.lowerType(Type.anyerror)).toLlvm(&o.builder);
                const zero = err_set_ty.constNull();
                if (!payload_has_bits) {
                    // TODO add alignment to this load
                    const loaded = if (operand_is_ptr)
                        fg.builder.buildLoad(err_set_ty, err_union, "")
                    else
                        err_union;
                    break :err fg.builder.buildICmp(.NE, loaded, zero, "");
                }
                const err_field_index = errUnionErrorOffset(payload_ty, mod);
                if (operand_is_ptr or isByRef(err_union_ty, mod)) {
                    const err_field_ptr = fg.builder.buildStructGEP(err_union_llvm_ty, err_union, err_field_index, "");
                    // TODO add alignment to this load
                    const loaded = fg.builder.buildLoad(err_set_ty, err_field_ptr, "");
                    break :err fg.builder.buildICmp(.NE, loaded, zero, "");
                }
                const loaded = fg.builder.buildExtractValue(err_union, err_field_index, "");
                break :err fg.builder.buildICmp(.NE, loaded, zero, "");
            };

            const return_block = fg.context.appendBasicBlock(fg.llvm_func, "TryRet");
            const continue_block = fg.context.appendBasicBlock(fg.llvm_func, "TryCont");
            _ = fg.builder.buildCondBr(is_err, return_block, continue_block);

            fg.builder.positionBuilderAtEnd(return_block);
            try fg.genBody(body);

            fg.builder.positionBuilderAtEnd(continue_block);
        }
        if (is_unused) {
            return null;
        }
        if (!payload_has_bits) {
            return if (operand_is_ptr) err_union else null;
        }
        const offset = errUnionPayloadOffset(payload_ty, mod);
        if (operand_is_ptr) {
            return fg.builder.buildStructGEP(err_union_llvm_ty, err_union, offset, "");
        } else if (isByRef(err_union_ty, mod)) {
            const payload_ptr = fg.builder.buildStructGEP(err_union_llvm_ty, err_union, offset, "");
            if (isByRef(payload_ty, mod)) {
                if (can_elide_load)
                    return payload_ptr;

                return fg.loadByRef(payload_ptr, payload_ty, payload_ty.abiAlignment(mod), false);
            }
            const load_inst = fg.builder.buildLoad(err_union_llvm_ty.structGetTypeAtIndex(offset), payload_ptr, "");
            load_inst.setAlignment(payload_ty.abiAlignment(mod));
            return load_inst;
        }
        return fg.builder.buildExtractValue(err_union, offset, "");
    }

    fn airSwitchBr(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const pl_op = self.air.instructions.items(.data)[inst].pl_op;
        const cond = try self.resolveInst(pl_op.operand);
        const switch_br = self.air.extraData(Air.SwitchBr, pl_op.payload);
        const else_block = self.context.appendBasicBlock(self.llvm_func, "Else");
        const llvm_usize = (try o.lowerType(Type.usize)).toLlvm(&o.builder);
        const cond_int = if (cond.typeOf().getTypeKind() == .Pointer)
            self.builder.buildPtrToInt(cond, llvm_usize, "")
        else
            cond;
        const llvm_switch = self.builder.buildSwitch(cond_int, else_block, switch_br.data.cases_len);

        var extra_index: usize = switch_br.end;
        var case_i: u32 = 0;

        while (case_i < switch_br.data.cases_len) : (case_i += 1) {
            const case = self.air.extraData(Air.SwitchBr.Case, extra_index);
            const items = @as([]const Air.Inst.Ref, @ptrCast(self.air.extra[case.end..][0..case.data.items_len]));
            const case_body = self.air.extra[case.end + items.len ..][0..case.data.body_len];
            extra_index = case.end + case.data.items_len + case_body.len;

            const case_block = self.context.appendBasicBlock(self.llvm_func, "Case");

            for (items) |item| {
                const llvm_item = try self.resolveInst(item);
                const llvm_int_item = if (llvm_item.typeOf().getTypeKind() == .Pointer)
                    llvm_item.constPtrToInt(llvm_usize)
                else
                    llvm_item;
                llvm_switch.addCase(llvm_int_item, case_block);
            }

            self.builder.positionBuilderAtEnd(case_block);
            try self.genBody(case_body);
        }

        self.builder.positionBuilderAtEnd(else_block);
        const else_body = self.air.extra[extra_index..][0..switch_br.data.else_body_len];
        if (else_body.len != 0) {
            try self.genBody(else_body);
        } else {
            _ = self.builder.buildUnreachable();
        }

        // No need to reset the insert cursor since this instruction is noreturn.
        return null;
    }

    fn airLoop(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const loop = self.air.extraData(Air.Block, ty_pl.payload);
        const body = self.air.extra[loop.end..][0..loop.data.body_len];
        const loop_block = self.context.appendBasicBlock(self.llvm_func, "Loop");
        _ = self.builder.buildBr(loop_block);

        self.builder.positionBuilderAtEnd(loop_block);
        try self.genBody(body);

        // TODO instead of this logic, change AIR to have the property that
        // every block is guaranteed to end with a noreturn instruction.
        // Then we can simply rely on the fact that a repeat or break instruction
        // would have been emitted already. Also the main loop in genBody can
        // be while(true) instead of for(body), which will eliminate 1 branch on
        // a hot path.
        if (body.len == 0 or !self.typeOfIndex(body[body.len - 1]).isNoReturn(mod)) {
            _ = self.builder.buildBr(loop_block);
        }
        return null;
    }

    fn airArrayToSlice(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand_ty = self.typeOf(ty_op.operand);
        const array_ty = operand_ty.childType(mod);
        const llvm_usize = try o.lowerType(Type.usize);
        const len = (try o.builder.intConst(llvm_usize, array_ty.arrayLen(mod))).toLlvm(&o.builder);
        const slice_llvm_ty = (try o.lowerType(self.typeOfIndex(inst))).toLlvm(&o.builder);
        const operand = try self.resolveInst(ty_op.operand);
        if (!array_ty.hasRuntimeBitsIgnoreComptime(mod)) {
            const partial = self.builder.buildInsertValue(slice_llvm_ty.getUndef(), operand, 0, "");
            return self.builder.buildInsertValue(partial, len, 1, "");
        }
        const indices: [2]*llvm.Value = .{
            (try o.builder.intConst(llvm_usize, 0)).toLlvm(&o.builder),
        } ** 2;
        const array_llvm_ty = (try o.lowerType(array_ty)).toLlvm(&o.builder);
        const ptr = self.builder.buildInBoundsGEP(array_llvm_ty, operand, &indices, indices.len, "");
        const partial = self.builder.buildInsertValue(slice_llvm_ty.getUndef(), ptr, 0, "");
        return self.builder.buildInsertValue(partial, len, 1, "");
    }

    fn airFloatFromInt(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;

        const operand = try self.resolveInst(ty_op.operand);
        const operand_ty = self.typeOf(ty_op.operand);
        const operand_scalar_ty = operand_ty.scalarType(mod);

        const dest_ty = self.typeOfIndex(inst);
        const dest_scalar_ty = dest_ty.scalarType(mod);
        const dest_llvm_ty = try o.lowerType(dest_ty);
        const target = mod.getTarget();

        if (intrinsicsAllowed(dest_scalar_ty, target)) {
            if (operand_scalar_ty.isSignedInt(mod)) {
                return self.builder.buildSIToFP(operand, dest_llvm_ty.toLlvm(&o.builder), "");
            } else {
                return self.builder.buildUIToFP(operand, dest_llvm_ty.toLlvm(&o.builder), "");
            }
        }

        const operand_bits = @as(u16, @intCast(operand_scalar_ty.bitSize(mod)));
        const rt_int_bits = compilerRtIntBits(operand_bits);
        const rt_int_ty = try o.builder.intType(rt_int_bits);
        var extended = e: {
            if (operand_scalar_ty.isSignedInt(mod)) {
                break :e self.builder.buildSExtOrBitCast(operand, rt_int_ty.toLlvm(&o.builder), "");
            } else {
                break :e self.builder.buildZExtOrBitCast(operand, rt_int_ty.toLlvm(&o.builder), "");
            }
        };
        const dest_bits = dest_scalar_ty.floatBits(target);
        const compiler_rt_operand_abbrev = compilerRtIntAbbrev(rt_int_bits);
        const compiler_rt_dest_abbrev = compilerRtFloatAbbrev(dest_bits);
        const sign_prefix = if (operand_scalar_ty.isSignedInt(mod)) "" else "un";
        const fn_name = try o.builder.fmt("__float{s}{s}i{s}f", .{
            sign_prefix,
            compiler_rt_operand_abbrev,
            compiler_rt_dest_abbrev,
        });

        var param_type = rt_int_ty;
        if (rt_int_bits == 128 and (target.os.tag == .windows and target.cpu.arch == .x86_64)) {
            // On Windows x86-64, "ti" functions must use Vector(2, u64) instead of the standard
            // i128 calling convention to adhere to the ABI that LLVM expects compiler-rt to have.
            param_type = try o.builder.vectorType(.normal, 2, .i64);
            extended = self.builder.buildBitCast(extended, param_type.toLlvm(&o.builder), "");
        }

        const libc_fn = try self.getLibcFunction(fn_name, &.{param_type}, dest_llvm_ty);
        const params = [1]*llvm.Value{extended};

        return self.builder.buildCall(libc_fn.globalGetValueType(), libc_fn, &params, params.len, .C, .Auto, "");
    }

    fn airIntFromFloat(self: *FuncGen, inst: Air.Inst.Index, want_fast_math: bool) !?*llvm.Value {
        self.builder.setFastMath(want_fast_math);

        const o = self.dg.object;
        const mod = o.module;
        const target = mod.getTarget();
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;

        const operand = try self.resolveInst(ty_op.operand);
        const operand_ty = self.typeOf(ty_op.operand);
        const operand_scalar_ty = operand_ty.scalarType(mod);

        const dest_ty = self.typeOfIndex(inst);
        const dest_scalar_ty = dest_ty.scalarType(mod);
        const dest_llvm_ty = try o.lowerType(dest_ty);

        if (intrinsicsAllowed(operand_scalar_ty, target)) {
            // TODO set fast math flag
            if (dest_scalar_ty.isSignedInt(mod)) {
                return self.builder.buildFPToSI(operand, dest_llvm_ty.toLlvm(&o.builder), "");
            } else {
                return self.builder.buildFPToUI(operand, dest_llvm_ty.toLlvm(&o.builder), "");
            }
        }

        const rt_int_bits = compilerRtIntBits(@intCast(dest_scalar_ty.bitSize(mod)));
        const ret_ty = try o.builder.intType(rt_int_bits);
        const libc_ret_ty = if (rt_int_bits == 128 and (target.os.tag == .windows and target.cpu.arch == .x86_64)) b: {
            // On Windows x86-64, "ti" functions must use Vector(2, u64) instead of the standard
            // i128 calling convention to adhere to the ABI that LLVM expects compiler-rt to have.
            break :b try o.builder.vectorType(.normal, 2, .i64);
        } else ret_ty;

        const operand_bits = operand_scalar_ty.floatBits(target);
        const compiler_rt_operand_abbrev = compilerRtFloatAbbrev(operand_bits);

        const compiler_rt_dest_abbrev = compilerRtIntAbbrev(rt_int_bits);
        const sign_prefix = if (dest_scalar_ty.isSignedInt(mod)) "" else "uns";

        const fn_name = try o.builder.fmt("__fix{s}{s}f{s}i", .{
            sign_prefix,
            compiler_rt_operand_abbrev,
            compiler_rt_dest_abbrev,
        });

        const operand_llvm_ty = try o.lowerType(operand_ty);
        const libc_fn = try self.getLibcFunction(fn_name, &.{operand_llvm_ty}, libc_ret_ty);
        const params = [1]*llvm.Value{operand};

        var result = self.builder.buildCall(libc_fn.globalGetValueType(), libc_fn, &params, params.len, .C, .Auto, "");

        if (libc_ret_ty != ret_ty) result = self.builder.buildBitCast(result, ret_ty.toLlvm(&o.builder), "");
        if (ret_ty != dest_llvm_ty) result = self.builder.buildTrunc(result, dest_llvm_ty.toLlvm(&o.builder), "");
        return result;
    }

    fn sliceOrArrayPtr(fg: *FuncGen, ptr: *llvm.Value, ty: Type) *llvm.Value {
        const o = fg.dg.object;
        const mod = o.module;
        if (ty.isSlice(mod)) {
            return fg.builder.buildExtractValue(ptr, 0, "");
        } else {
            return ptr;
        }
    }

    fn sliceOrArrayLenInBytes(fg: *FuncGen, ptr: *llvm.Value, ty: Type) Allocator.Error!*llvm.Value {
        const o = fg.dg.object;
        const mod = o.module;
        const llvm_usize = try o.lowerType(Type.usize);
        switch (ty.ptrSize(mod)) {
            .Slice => {
                const len = fg.builder.buildExtractValue(ptr, 1, "");
                const elem_ty = ty.childType(mod);
                const abi_size = elem_ty.abiSize(mod);
                if (abi_size == 1) return len;
                const abi_size_llvm_val = try o.builder.intConst(llvm_usize, abi_size);
                return fg.builder.buildMul(len, abi_size_llvm_val.toLlvm(&o.builder), "");
            },
            .One => {
                const array_ty = ty.childType(mod);
                const elem_ty = array_ty.childType(mod);
                const abi_size = elem_ty.abiSize(mod);
                return (try o.builder.intConst(llvm_usize, array_ty.arrayLen(mod) * abi_size)).toLlvm(&o.builder);
            },
            .Many, .C => unreachable,
        }
    }

    fn airSliceField(self: *FuncGen, inst: Air.Inst.Index, index: c_uint) !?*llvm.Value {
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);
        return self.builder.buildExtractValue(operand, index, "");
    }

    fn airPtrSliceFieldPtr(self: *FuncGen, inst: Air.Inst.Index, index: c_uint) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const slice_ptr = try self.resolveInst(ty_op.operand);
        const slice_ptr_ty = self.typeOf(ty_op.operand);
        const slice_llvm_ty = (try o.lowerPtrElemTy(slice_ptr_ty.childType(mod))).toLlvm(&o.builder);

        return self.builder.buildStructGEP(slice_llvm_ty, slice_ptr, index, "");
    }

    fn airSliceElemVal(self: *FuncGen, body_tail: []const Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const inst = body_tail[0];
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const slice_ty = self.typeOf(bin_op.lhs);
        const slice = try self.resolveInst(bin_op.lhs);
        const index = try self.resolveInst(bin_op.rhs);
        const elem_ty = slice_ty.childType(mod);
        const llvm_elem_ty = (try o.lowerPtrElemTy(elem_ty)).toLlvm(&o.builder);
        const base_ptr = self.builder.buildExtractValue(slice, 0, "");
        const indices: [1]*llvm.Value = .{index};
        const ptr = self.builder.buildInBoundsGEP(llvm_elem_ty, base_ptr, &indices, indices.len, "");
        if (isByRef(elem_ty, mod)) {
            if (self.canElideLoad(body_tail))
                return ptr;

            return self.loadByRef(ptr, elem_ty, elem_ty.abiAlignment(mod), false);
        }

        return self.load(ptr, slice_ty);
    }

    fn airSliceElemPtr(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const bin_op = self.air.extraData(Air.Bin, ty_pl.payload).data;
        const slice_ty = self.typeOf(bin_op.lhs);

        const slice = try self.resolveInst(bin_op.lhs);
        const index = try self.resolveInst(bin_op.rhs);
        const llvm_elem_ty = (try o.lowerPtrElemTy(slice_ty.childType(mod))).toLlvm(&o.builder);
        const base_ptr = self.builder.buildExtractValue(slice, 0, "");
        const indices: [1]*llvm.Value = .{index};
        return self.builder.buildInBoundsGEP(llvm_elem_ty, base_ptr, &indices, indices.len, "");
    }

    fn airArrayElemVal(self: *FuncGen, body_tail: []const Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const inst = body_tail[0];

        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const array_ty = self.typeOf(bin_op.lhs);
        const array_llvm_val = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const array_llvm_ty = (try o.lowerType(array_ty)).toLlvm(&o.builder);
        const elem_ty = array_ty.childType(mod);
        if (isByRef(array_ty, mod)) {
            const indices: [2]*llvm.Value = .{ Builder.Type.i32.toLlvm(&o.builder).constNull(), rhs };
            if (isByRef(elem_ty, mod)) {
                const elem_ptr = self.builder.buildInBoundsGEP(array_llvm_ty, array_llvm_val, &indices, indices.len, "");
                if (canElideLoad(self, body_tail))
                    return elem_ptr;

                return self.loadByRef(elem_ptr, elem_ty, elem_ty.abiAlignment(mod), false);
            } else {
                const elem_llvm_ty = (try o.lowerType(elem_ty)).toLlvm(&o.builder);
                if (Air.refToIndex(bin_op.lhs)) |lhs_index| {
                    if (self.air.instructions.items(.tag)[lhs_index] == .load) {
                        const load_data = self.air.instructions.items(.data)[lhs_index];
                        const load_ptr = load_data.ty_op.operand;
                        if (Air.refToIndex(load_ptr)) |load_ptr_index| {
                            const load_ptr_tag = self.air.instructions.items(.tag)[load_ptr_index];
                            switch (load_ptr_tag) {
                                .struct_field_ptr, .struct_field_ptr_index_0, .struct_field_ptr_index_1, .struct_field_ptr_index_2, .struct_field_ptr_index_3 => {
                                    const load_ptr_inst = try self.resolveInst(load_ptr);
                                    const gep = self.builder.buildInBoundsGEP(array_llvm_ty, load_ptr_inst, &indices, indices.len, "");
                                    return self.builder.buildLoad(elem_llvm_ty, gep, "");
                                },
                                else => {},
                            }
                        }
                    }
                }
                const elem_ptr = self.builder.buildInBoundsGEP(array_llvm_ty, array_llvm_val, &indices, indices.len, "");
                return self.builder.buildLoad(elem_llvm_ty, elem_ptr, "");
            }
        }

        // This branch can be reached for vectors, which are always by-value.
        return self.builder.buildExtractElement(array_llvm_val, rhs, "");
    }

    fn airPtrElemVal(self: *FuncGen, body_tail: []const Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const inst = body_tail[0];
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const ptr_ty = self.typeOf(bin_op.lhs);
        const elem_ty = ptr_ty.childType(mod);
        const llvm_elem_ty = (try o.lowerPtrElemTy(elem_ty)).toLlvm(&o.builder);
        const base_ptr = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        // TODO: when we go fully opaque pointers in LLVM 16 we can remove this branch
        const ptr = if (ptr_ty.isSinglePointer(mod)) ptr: {
            // If this is a single-item pointer to an array, we need another index in the GEP.
            const indices: [2]*llvm.Value = .{ Builder.Type.i32.toLlvm(&o.builder).constNull(), rhs };
            break :ptr self.builder.buildInBoundsGEP(llvm_elem_ty, base_ptr, &indices, indices.len, "");
        } else ptr: {
            const indices: [1]*llvm.Value = .{rhs};
            break :ptr self.builder.buildInBoundsGEP(llvm_elem_ty, base_ptr, &indices, indices.len, "");
        };
        if (isByRef(elem_ty, mod)) {
            if (self.canElideLoad(body_tail))
                return ptr;

            return self.loadByRef(ptr, elem_ty, elem_ty.abiAlignment(mod), false);
        }

        return self.load(ptr, ptr_ty);
    }

    fn airPtrElemPtr(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const bin_op = self.air.extraData(Air.Bin, ty_pl.payload).data;
        const ptr_ty = self.typeOf(bin_op.lhs);
        const elem_ty = ptr_ty.childType(mod);
        if (!elem_ty.hasRuntimeBitsIgnoreComptime(mod)) return o.lowerPtrToVoid(ptr_ty);

        const base_ptr = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);

        const elem_ptr = self.air.getRefType(ty_pl.ty);
        if (elem_ptr.ptrInfo(mod).flags.vector_index != .none) return base_ptr;

        const llvm_elem_ty = (try o.lowerPtrElemTy(elem_ty)).toLlvm(&o.builder);
        if (ptr_ty.isSinglePointer(mod)) {
            // If this is a single-item pointer to an array, we need another index in the GEP.
            const indices: [2]*llvm.Value = .{ Builder.Type.i32.toLlvm(&o.builder).constNull(), rhs };
            return self.builder.buildInBoundsGEP(llvm_elem_ty, base_ptr, &indices, indices.len, "");
        } else {
            const indices: [1]*llvm.Value = .{rhs};
            return self.builder.buildInBoundsGEP(llvm_elem_ty, base_ptr, &indices, indices.len, "");
        }
    }

    fn airStructFieldPtr(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const struct_field = self.air.extraData(Air.StructField, ty_pl.payload).data;
        const struct_ptr = try self.resolveInst(struct_field.struct_operand);
        const struct_ptr_ty = self.typeOf(struct_field.struct_operand);
        return self.fieldPtr(inst, struct_ptr, struct_ptr_ty, struct_field.field_index);
    }

    fn airStructFieldPtrIndex(
        self: *FuncGen,
        inst: Air.Inst.Index,
        field_index: u32,
    ) !?*llvm.Value {
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const struct_ptr = try self.resolveInst(ty_op.operand);
        const struct_ptr_ty = self.typeOf(ty_op.operand);
        return self.fieldPtr(inst, struct_ptr, struct_ptr_ty, field_index);
    }

    fn airStructFieldVal(self: *FuncGen, body_tail: []const Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const inst = body_tail[0];
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const struct_field = self.air.extraData(Air.StructField, ty_pl.payload).data;
        const struct_ty = self.typeOf(struct_field.struct_operand);
        const struct_llvm_val = try self.resolveInst(struct_field.struct_operand);
        const field_index = struct_field.field_index;
        const field_ty = struct_ty.structFieldType(field_index, mod);
        if (!field_ty.hasRuntimeBitsIgnoreComptime(mod)) {
            return null;
        }

        if (!isByRef(struct_ty, mod)) {
            assert(!isByRef(field_ty, mod));
            switch (struct_ty.zigTypeTag(mod)) {
                .Struct => switch (struct_ty.containerLayout(mod)) {
                    .Packed => {
                        const struct_obj = mod.typeToStruct(struct_ty).?;
                        const bit_offset = struct_obj.packedFieldBitOffset(mod, field_index);
                        const containing_int = struct_llvm_val;
                        const shift_amt = containing_int.typeOf().constInt(bit_offset, .False);
                        const shifted_value = self.builder.buildLShr(containing_int, shift_amt, "");
                        const elem_llvm_ty = (try o.lowerType(field_ty)).toLlvm(&o.builder);
                        if (field_ty.zigTypeTag(mod) == .Float or field_ty.zigTypeTag(mod) == .Vector) {
                            const elem_bits = @as(c_uint, @intCast(field_ty.bitSize(mod)));
                            const same_size_int = (try o.builder.intType(@intCast(elem_bits))).toLlvm(&o.builder);
                            const truncated_int = self.builder.buildTrunc(shifted_value, same_size_int, "");
                            return self.builder.buildBitCast(truncated_int, elem_llvm_ty, "");
                        } else if (field_ty.isPtrAtRuntime(mod)) {
                            const elem_bits = @as(c_uint, @intCast(field_ty.bitSize(mod)));
                            const same_size_int = (try o.builder.intType(@intCast(elem_bits))).toLlvm(&o.builder);
                            const truncated_int = self.builder.buildTrunc(shifted_value, same_size_int, "");
                            return self.builder.buildIntToPtr(truncated_int, elem_llvm_ty, "");
                        }
                        return self.builder.buildTrunc(shifted_value, elem_llvm_ty, "");
                    },
                    else => {
                        const llvm_field_index = llvmField(struct_ty, field_index, mod).?.index;
                        return self.builder.buildExtractValue(struct_llvm_val, llvm_field_index, "");
                    },
                },
                .Union => {
                    assert(struct_ty.containerLayout(mod) == .Packed);
                    const containing_int = struct_llvm_val;
                    const elem_llvm_ty = (try o.lowerType(field_ty)).toLlvm(&o.builder);
                    if (field_ty.zigTypeTag(mod) == .Float or field_ty.zigTypeTag(mod) == .Vector) {
                        const elem_bits = @as(c_uint, @intCast(field_ty.bitSize(mod)));
                        const same_size_int = (try o.builder.intType(@intCast(elem_bits))).toLlvm(&o.builder);
                        const truncated_int = self.builder.buildTrunc(containing_int, same_size_int, "");
                        return self.builder.buildBitCast(truncated_int, elem_llvm_ty, "");
                    } else if (field_ty.isPtrAtRuntime(mod)) {
                        const elem_bits = @as(c_uint, @intCast(field_ty.bitSize(mod)));
                        const same_size_int = (try o.builder.intType(@intCast(elem_bits))).toLlvm(&o.builder);
                        const truncated_int = self.builder.buildTrunc(containing_int, same_size_int, "");
                        return self.builder.buildIntToPtr(truncated_int, elem_llvm_ty, "");
                    }
                    return self.builder.buildTrunc(containing_int, elem_llvm_ty, "");
                },
                else => unreachable,
            }
        }

        switch (struct_ty.zigTypeTag(mod)) {
            .Struct => {
                assert(struct_ty.containerLayout(mod) != .Packed);
                const llvm_field = llvmField(struct_ty, field_index, mod).?;
                const struct_llvm_ty = (try o.lowerType(struct_ty)).toLlvm(&o.builder);
                const field_ptr = self.builder.buildStructGEP(struct_llvm_ty, struct_llvm_val, llvm_field.index, "");
                const field_ptr_ty = try mod.ptrType(.{
                    .child = llvm_field.ty.toIntern(),
                    .flags = .{
                        .alignment = InternPool.Alignment.fromNonzeroByteUnits(llvm_field.alignment),
                    },
                });
                if (isByRef(field_ty, mod)) {
                    if (canElideLoad(self, body_tail))
                        return field_ptr;

                    assert(llvm_field.alignment != 0);
                    return self.loadByRef(field_ptr, field_ty, llvm_field.alignment, false);
                } else {
                    return self.load(field_ptr, field_ptr_ty);
                }
            },
            .Union => {
                const union_llvm_ty = (try o.lowerType(struct_ty)).toLlvm(&o.builder);
                const layout = struct_ty.unionGetLayout(mod);
                const payload_index = @intFromBool(layout.tag_align >= layout.payload_align);
                const field_ptr = self.builder.buildStructGEP(union_llvm_ty, struct_llvm_val, payload_index, "");
                const llvm_field_ty = (try o.lowerType(field_ty)).toLlvm(&o.builder);
                if (isByRef(field_ty, mod)) {
                    if (canElideLoad(self, body_tail))
                        return field_ptr;

                    return self.loadByRef(field_ptr, field_ty, layout.payload_align, false);
                } else {
                    return self.builder.buildLoad(llvm_field_ty, field_ptr, "");
                }
            },
            else => unreachable,
        }
    }

    fn airFieldParentPtr(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const extra = self.air.extraData(Air.FieldParentPtr, ty_pl.payload).data;

        const field_ptr = try self.resolveInst(extra.field_ptr);

        const parent_ty = self.air.getRefType(ty_pl.ty).childType(mod);
        const field_offset = parent_ty.structFieldOffset(extra.field_index, mod);

        const res_ty = (try o.lowerType(self.air.getRefType(ty_pl.ty))).toLlvm(&o.builder);
        if (field_offset == 0) {
            return field_ptr;
        }
        const llvm_usize = try o.lowerType(Type.usize);

        const field_ptr_int = self.builder.buildPtrToInt(field_ptr, llvm_usize.toLlvm(&o.builder), "");
        const base_ptr_int = self.builder.buildNUWSub(field_ptr_int, (try o.builder.intConst(llvm_usize, field_offset)).toLlvm(&o.builder), "");
        return self.builder.buildIntToPtr(base_ptr_int, res_ty, "");
    }

    fn airNot(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);

        return self.builder.buildNot(operand, "");
    }

    fn airUnreach(self: *FuncGen, inst: Air.Inst.Index) ?*llvm.Value {
        _ = inst;
        _ = self.builder.buildUnreachable();
        return null;
    }

    fn airDbgStmt(self: *FuncGen, inst: Air.Inst.Index) ?*llvm.Value {
        const di_scope = self.di_scope orelse return null;
        const dbg_stmt = self.air.instructions.items(.data)[inst].dbg_stmt;
        self.prev_dbg_line = @as(c_uint, @intCast(self.base_line + dbg_stmt.line + 1));
        self.prev_dbg_column = @as(c_uint, @intCast(dbg_stmt.column + 1));
        const inlined_at = if (self.dbg_inlined.items.len > 0)
            self.dbg_inlined.items[self.dbg_inlined.items.len - 1].loc
        else
            null;
        self.builder.setCurrentDebugLocation(self.prev_dbg_line, self.prev_dbg_column, di_scope, inlined_at);
        return null;
    }

    fn airDbgInlineBegin(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const dib = o.di_builder orelse return null;
        const ty_fn = self.air.instructions.items(.data)[inst].ty_fn;

        const mod = o.module;
        const func = mod.funcPtr(ty_fn.func);
        const decl_index = func.owner_decl;
        const decl = mod.declPtr(decl_index);
        const di_file = try o.getDIFile(self.gpa, mod.namespacePtr(decl.src_namespace).file_scope);
        self.di_file = di_file;
        const line_number = decl.src_line + 1;
        const cur_debug_location = self.builder.getCurrentDebugLocation2();

        try self.dbg_inlined.append(self.gpa, .{
            .loc = @as(*llvm.DILocation, @ptrCast(cur_debug_location)),
            .scope = self.di_scope.?,
            .base_line = self.base_line,
        });

        const fqn = try decl.getFullyQualifiedName(mod);

        const is_internal_linkage = !mod.decl_exports.contains(decl_index);
        const fn_ty = try mod.funcType(.{
            .param_types = &.{},
            .return_type = .void_type,
            .alignment = .none,
            .noalias_bits = 0,
            .comptime_bits = 0,
            .cc = .Unspecified,
            .is_var_args = false,
            .is_generic = false,
            .is_noinline = false,
            .align_is_generic = false,
            .cc_is_generic = false,
            .section_is_generic = false,
            .addrspace_is_generic = false,
        });
        const fn_di_ty = try o.lowerDebugType(fn_ty, .full);
        const subprogram = dib.createFunction(
            di_file.toScope(),
            mod.intern_pool.stringToSlice(decl.name),
            mod.intern_pool.stringToSlice(fqn),
            di_file,
            line_number,
            fn_di_ty,
            is_internal_linkage,
            true, // is definition
            line_number + func.lbrace_line, // scope line
            llvm.DIFlags.StaticMember,
            mod.comp.bin_file.options.optimize_mode != .Debug,
            null, // decl_subprogram
        );

        const lexical_block = dib.createLexicalBlock(subprogram.toScope(), di_file, line_number, 1);
        self.di_scope = lexical_block.toScope();
        self.base_line = decl.src_line;
        return null;
    }

    fn airDbgInlineEnd(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        if (o.di_builder == null) return null;
        const ty_fn = self.air.instructions.items(.data)[inst].ty_fn;

        const mod = o.module;
        const func = mod.funcPtr(ty_fn.func);
        const decl = mod.declPtr(func.owner_decl);
        const di_file = try o.getDIFile(self.gpa, mod.namespacePtr(decl.src_namespace).file_scope);
        self.di_file = di_file;
        const old = self.dbg_inlined.pop();
        self.di_scope = old.scope;
        self.base_line = old.base_line;
        return null;
    }

    fn airDbgBlockBegin(self: *FuncGen) !?*llvm.Value {
        const o = self.dg.object;
        const dib = o.di_builder orelse return null;
        const old_scope = self.di_scope.?;
        try self.dbg_block_stack.append(self.gpa, old_scope);
        const lexical_block = dib.createLexicalBlock(old_scope, self.di_file.?, self.prev_dbg_line, self.prev_dbg_column);
        self.di_scope = lexical_block.toScope();
        return null;
    }

    fn airDbgBlockEnd(self: *FuncGen) !?*llvm.Value {
        const o = self.dg.object;
        if (o.di_builder == null) return null;
        self.di_scope = self.dbg_block_stack.pop();
        return null;
    }

    fn airDbgVarPtr(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const dib = o.di_builder orelse return null;
        const pl_op = self.air.instructions.items(.data)[inst].pl_op;
        const operand = try self.resolveInst(pl_op.operand);
        const name = self.air.nullTerminatedString(pl_op.payload);
        const ptr_ty = self.typeOf(pl_op.operand);

        const di_local_var = dib.createAutoVariable(
            self.di_scope.?,
            name.ptr,
            self.di_file.?,
            self.prev_dbg_line,
            try o.lowerDebugType(ptr_ty.childType(mod), .full),
            true, // always preserve
            0, // flags
        );
        const inlined_at = if (self.dbg_inlined.items.len > 0)
            self.dbg_inlined.items[self.dbg_inlined.items.len - 1].loc
        else
            null;
        const debug_loc = llvm.getDebugLoc(self.prev_dbg_line, self.prev_dbg_column, self.di_scope.?, inlined_at);
        const insert_block = self.builder.getInsertBlock();
        _ = dib.insertDeclareAtEnd(operand, di_local_var, debug_loc, insert_block);
        return null;
    }

    fn airDbgVarVal(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const dib = o.di_builder orelse return null;
        const pl_op = self.air.instructions.items(.data)[inst].pl_op;
        const operand = try self.resolveInst(pl_op.operand);
        const operand_ty = self.typeOf(pl_op.operand);
        const name = self.air.nullTerminatedString(pl_op.payload);

        if (needDbgVarWorkaround(o)) {
            return null;
        }

        const di_local_var = dib.createAutoVariable(
            self.di_scope.?,
            name.ptr,
            self.di_file.?,
            self.prev_dbg_line,
            try o.lowerDebugType(operand_ty, .full),
            true, // always preserve
            0, // flags
        );
        const inlined_at = if (self.dbg_inlined.items.len > 0)
            self.dbg_inlined.items[self.dbg_inlined.items.len - 1].loc
        else
            null;
        const debug_loc = llvm.getDebugLoc(self.prev_dbg_line, self.prev_dbg_column, self.di_scope.?, inlined_at);
        const insert_block = self.builder.getInsertBlock();
        const mod = o.module;
        if (isByRef(operand_ty, mod)) {
            _ = dib.insertDeclareAtEnd(operand, di_local_var, debug_loc, insert_block);
        } else if (o.module.comp.bin_file.options.optimize_mode == .Debug) {
            const alignment = operand_ty.abiAlignment(mod);
            const alloca = try self.buildAlloca(operand.typeOf(), alignment);
            const store_inst = self.builder.buildStore(operand, alloca);
            store_inst.setAlignment(alignment);
            _ = dib.insertDeclareAtEnd(alloca, di_local_var, debug_loc, insert_block);
        } else {
            _ = dib.insertDbgValueIntrinsicAtEnd(operand, di_local_var, debug_loc, insert_block);
        }
        return null;
    }

    fn airAssembly(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        // Eventually, the Zig compiler needs to be reworked to have inline
        // assembly go through the same parsing code regardless of backend, and
        // have LLVM-flavored inline assembly be *output* from that assembler.
        // We don't have such an assembler implemented yet though. For now,
        // this implementation feeds the inline assembly code directly to LLVM.

        const o = self.dg.object;
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const extra = self.air.extraData(Air.Asm, ty_pl.payload);
        const is_volatile = @as(u1, @truncate(extra.data.flags >> 31)) != 0;
        const clobbers_len = @as(u31, @truncate(extra.data.flags));
        var extra_i: usize = extra.end;

        const outputs = @as([]const Air.Inst.Ref, @ptrCast(self.air.extra[extra_i..][0..extra.data.outputs_len]));
        extra_i += outputs.len;
        const inputs = @as([]const Air.Inst.Ref, @ptrCast(self.air.extra[extra_i..][0..extra.data.inputs_len]));
        extra_i += inputs.len;

        var llvm_constraints: std.ArrayListUnmanaged(u8) = .{};
        defer llvm_constraints.deinit(self.gpa);

        var arena_allocator = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        // The exact number of return / parameter values depends on which output values
        // are passed by reference as indirect outputs (determined below).
        const max_return_count = outputs.len;
        const llvm_ret_types = try arena.alloc(Builder.Type, max_return_count);
        const llvm_ret_indirect = try arena.alloc(bool, max_return_count);

        const max_param_count = inputs.len + outputs.len;
        const llvm_param_types = try arena.alloc(*llvm.Type, max_param_count);
        const llvm_param_values = try arena.alloc(*llvm.Value, max_param_count);
        // This stores whether we need to add an elementtype attribute and
        // if so, the element type itself.
        const llvm_param_attrs = try arena.alloc(?*llvm.Type, max_param_count);
        const mod = o.module;
        const target = mod.getTarget();

        var llvm_ret_i: usize = 0;
        var llvm_param_i: usize = 0;
        var total_i: u16 = 0;

        var name_map: std.StringArrayHashMapUnmanaged(u16) = .{};
        try name_map.ensureUnusedCapacity(arena, max_param_count);

        for (outputs, 0..) |output, i| {
            const extra_bytes = std.mem.sliceAsBytes(self.air.extra[extra_i..]);
            const constraint = std.mem.sliceTo(std.mem.sliceAsBytes(self.air.extra[extra_i..]), 0);
            const name = std.mem.sliceTo(extra_bytes[constraint.len + 1 ..], 0);
            // This equation accounts for the fact that even if we have exactly 4 bytes
            // for the string, we still use the next u32 for the null terminator.
            extra_i += (constraint.len + name.len + (2 + 3)) / 4;

            try llvm_constraints.ensureUnusedCapacity(self.gpa, constraint.len + 3);
            if (total_i != 0) {
                llvm_constraints.appendAssumeCapacity(',');
            }
            llvm_constraints.appendAssumeCapacity('=');

            // Pass any non-return outputs indirectly, if the constraint accepts a memory location
            llvm_ret_indirect[i] = (output != .none) and constraintAllowsMemory(constraint);
            if (output != .none) {
                const output_inst = try self.resolveInst(output);
                const output_ty = self.typeOf(output);
                assert(output_ty.zigTypeTag(mod) == .Pointer);
                const elem_llvm_ty = try o.lowerPtrElemTy(output_ty.childType(mod));

                if (llvm_ret_indirect[i]) {
                    // Pass the result by reference as an indirect output (e.g. "=*m")
                    llvm_constraints.appendAssumeCapacity('*');

                    llvm_param_values[llvm_param_i] = output_inst;
                    llvm_param_types[llvm_param_i] = output_inst.typeOf();
                    llvm_param_attrs[llvm_param_i] = elem_llvm_ty.toLlvm(&o.builder);
                    llvm_param_i += 1;
                } else {
                    // Pass the result directly (e.g. "=r")
                    llvm_ret_types[llvm_ret_i] = elem_llvm_ty;
                    llvm_ret_i += 1;
                }
            } else {
                const ret_ty = self.typeOfIndex(inst);
                llvm_ret_types[llvm_ret_i] = try o.lowerType(ret_ty);
                llvm_ret_i += 1;
            }

            // LLVM uses commas internally to separate different constraints,
            // alternative constraints are achieved with pipes.
            // We still allow the user to use commas in a way that is similar
            // to GCC's inline assembly.
            // http://llvm.org/docs/LangRef.html#constraint-codes
            for (constraint[1..]) |byte| {
                switch (byte) {
                    ',' => llvm_constraints.appendAssumeCapacity('|'),
                    '*' => {}, // Indirect outputs are handled above
                    else => llvm_constraints.appendAssumeCapacity(byte),
                }
            }

            if (!std.mem.eql(u8, name, "_")) {
                const gop = name_map.getOrPutAssumeCapacity(name);
                if (gop.found_existing) return self.todo("duplicate asm output name '{s}'", .{name});
                gop.value_ptr.* = total_i;
            }
            total_i += 1;
        }

        for (inputs) |input| {
            const extra_bytes = std.mem.sliceAsBytes(self.air.extra[extra_i..]);
            const constraint = std.mem.sliceTo(extra_bytes, 0);
            const name = std.mem.sliceTo(extra_bytes[constraint.len + 1 ..], 0);
            // This equation accounts for the fact that even if we have exactly 4 bytes
            // for the string, we still use the next u32 for the null terminator.
            extra_i += (constraint.len + name.len + (2 + 3)) / 4;

            const arg_llvm_value = try self.resolveInst(input);
            const arg_ty = self.typeOf(input);
            var llvm_elem_ty: Builder.Type = .none;
            if (isByRef(arg_ty, mod)) {
                llvm_elem_ty = try o.lowerPtrElemTy(arg_ty);
                if (constraintAllowsMemory(constraint)) {
                    llvm_param_values[llvm_param_i] = arg_llvm_value;
                    llvm_param_types[llvm_param_i] = arg_llvm_value.typeOf();
                } else {
                    const alignment = arg_ty.abiAlignment(mod);
                    const arg_llvm_ty = (try o.lowerType(arg_ty)).toLlvm(&o.builder);
                    const load_inst = self.builder.buildLoad(arg_llvm_ty, arg_llvm_value, "");
                    load_inst.setAlignment(alignment);
                    llvm_param_values[llvm_param_i] = load_inst;
                    llvm_param_types[llvm_param_i] = arg_llvm_ty;
                }
            } else {
                if (constraintAllowsRegister(constraint)) {
                    llvm_param_values[llvm_param_i] = arg_llvm_value;
                    llvm_param_types[llvm_param_i] = arg_llvm_value.typeOf();
                } else {
                    const alignment = arg_ty.abiAlignment(mod);
                    const arg_ptr = try self.buildAlloca(arg_llvm_value.typeOf(), alignment);
                    const store_inst = self.builder.buildStore(arg_llvm_value, arg_ptr);
                    store_inst.setAlignment(alignment);
                    llvm_param_values[llvm_param_i] = arg_ptr;
                    llvm_param_types[llvm_param_i] = arg_ptr.typeOf();
                }
            }

            try llvm_constraints.ensureUnusedCapacity(self.gpa, constraint.len + 1);
            if (total_i != 0) {
                llvm_constraints.appendAssumeCapacity(',');
            }
            for (constraint) |byte| {
                llvm_constraints.appendAssumeCapacity(switch (byte) {
                    ',' => '|',
                    else => byte,
                });
            }

            if (!std.mem.eql(u8, name, "_")) {
                const gop = name_map.getOrPutAssumeCapacity(name);
                if (gop.found_existing) return self.todo("duplicate asm input name '{s}'", .{name});
                gop.value_ptr.* = total_i;
            }

            // In the case of indirect inputs, LLVM requires the callsite to have
            // an elementtype(<ty>) attribute.
            if (constraint[0] == '*') {
                llvm_param_attrs[llvm_param_i] = (if (llvm_elem_ty != .none)
                    llvm_elem_ty
                else
                    try o.lowerPtrElemTy(arg_ty.childType(mod))).toLlvm(&o.builder);
            } else {
                llvm_param_attrs[llvm_param_i] = null;
            }

            llvm_param_i += 1;
            total_i += 1;
        }

        {
            var clobber_i: u32 = 0;
            while (clobber_i < clobbers_len) : (clobber_i += 1) {
                const clobber = std.mem.sliceTo(std.mem.sliceAsBytes(self.air.extra[extra_i..]), 0);
                // This equation accounts for the fact that even if we have exactly 4 bytes
                // for the string, we still use the next u32 for the null terminator.
                extra_i += clobber.len / 4 + 1;

                try llvm_constraints.ensureUnusedCapacity(self.gpa, clobber.len + 4);
                if (total_i != 0) {
                    llvm_constraints.appendAssumeCapacity(',');
                }
                llvm_constraints.appendSliceAssumeCapacity("~{");
                llvm_constraints.appendSliceAssumeCapacity(clobber);
                llvm_constraints.appendSliceAssumeCapacity("}");

                total_i += 1;
            }
        }

        // We have finished scanning through all inputs/outputs, so the number of
        // parameters and return values is known.
        const param_count = llvm_param_i;
        const return_count = llvm_ret_i;

        // For some targets, Clang unconditionally adds some clobbers to all inline assembly.
        // While this is probably not strictly necessary, if we don't follow Clang's lead
        // here then we may risk tripping LLVM bugs since anything not used by Clang tends
        // to be buggy and regress often.
        switch (target.cpu.arch) {
            .x86_64, .x86 => {
                if (total_i != 0) try llvm_constraints.append(self.gpa, ',');
                try llvm_constraints.appendSlice(self.gpa, "~{dirflag},~{fpsr},~{flags}");
                total_i += 3;
            },
            .mips, .mipsel, .mips64, .mips64el => {
                if (total_i != 0) try llvm_constraints.append(self.gpa, ',');
                try llvm_constraints.appendSlice(self.gpa, "~{$1}");
                total_i += 1;
            },
            else => {},
        }

        const asm_source = std.mem.sliceAsBytes(self.air.extra[extra_i..])[0..extra.data.source_len];

        // hackety hacks until stage2 has proper inline asm in the frontend.
        var rendered_template = std.ArrayList(u8).init(self.gpa);
        defer rendered_template.deinit();

        const State = enum { start, percent, input, modifier };

        var state: State = .start;

        var name_start: usize = undefined;
        var modifier_start: usize = undefined;
        for (asm_source, 0..) |byte, i| {
            switch (state) {
                .start => switch (byte) {
                    '%' => state = .percent,
                    '$' => try rendered_template.appendSlice("$$"),
                    else => try rendered_template.append(byte),
                },
                .percent => switch (byte) {
                    '%' => {
                        try rendered_template.append('%');
                        state = .start;
                    },
                    '[' => {
                        try rendered_template.append('$');
                        try rendered_template.append('{');
                        name_start = i + 1;
                        state = .input;
                    },
                    else => {
                        try rendered_template.append('%');
                        try rendered_template.append(byte);
                        state = .start;
                    },
                },
                .input => switch (byte) {
                    ']', ':' => {
                        const name = asm_source[name_start..i];

                        const index = name_map.get(name) orelse {
                            // we should validate the assembly in Sema; by now it is too late
                            return self.todo("unknown input or output name: '{s}'", .{name});
                        };
                        try rendered_template.writer().print("{d}", .{index});
                        if (byte == ':') {
                            try rendered_template.append(':');
                            modifier_start = i + 1;
                            state = .modifier;
                        } else {
                            try rendered_template.append('}');
                            state = .start;
                        }
                    },
                    else => {},
                },
                .modifier => switch (byte) {
                    ']' => {
                        try rendered_template.appendSlice(asm_source[modifier_start..i]);
                        try rendered_template.append('}');
                        state = .start;
                    },
                    else => {},
                },
            }
        }

        const ret_llvm_ty = switch (return_count) {
            0 => .void,
            1 => llvm_ret_types[0],
            else => try o.builder.structType(.normal, llvm_ret_types),
        };

        const llvm_fn_ty = llvm.functionType(
            ret_llvm_ty.toLlvm(&o.builder),
            llvm_param_types.ptr,
            @as(c_uint, @intCast(param_count)),
            .False,
        );
        const asm_fn = llvm.getInlineAsm(
            llvm_fn_ty,
            rendered_template.items.ptr,
            rendered_template.items.len,
            llvm_constraints.items.ptr,
            llvm_constraints.items.len,
            llvm.Bool.fromBool(is_volatile),
            .False,
            .ATT,
            .False,
        );
        const call = self.builder.buildCall(
            llvm_fn_ty,
            asm_fn,
            llvm_param_values.ptr,
            @as(c_uint, @intCast(param_count)),
            .C,
            .Auto,
            "",
        );
        for (llvm_param_attrs[0..param_count], 0..) |llvm_elem_ty, i| {
            if (llvm_elem_ty) |llvm_ty| {
                llvm.setCallElemTypeAttr(call, i, llvm_ty);
            }
        }

        var ret_val = call;
        llvm_ret_i = 0;
        for (outputs, 0..) |output, i| {
            if (llvm_ret_indirect[i]) continue;

            const output_value = if (return_count > 1) b: {
                break :b self.builder.buildExtractValue(call, @as(c_uint, @intCast(llvm_ret_i)), "");
            } else call;

            if (output != .none) {
                const output_ptr = try self.resolveInst(output);
                const output_ptr_ty = self.typeOf(output);

                const store_inst = self.builder.buildStore(output_value, output_ptr);
                store_inst.setAlignment(output_ptr_ty.ptrAlignment(mod));
            } else {
                ret_val = output_value;
            }
            llvm_ret_i += 1;
        }

        return ret_val;
    }

    fn airIsNonNull(
        self: *FuncGen,
        inst: Air.Inst.Index,
        operand_is_ptr: bool,
        pred: llvm.IntPredicate,
    ) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const un_op = self.air.instructions.items(.data)[inst].un_op;
        const operand = try self.resolveInst(un_op);
        const operand_ty = self.typeOf(un_op);
        const optional_ty = if (operand_is_ptr) operand_ty.childType(mod) else operand_ty;
        const optional_llvm_ty = (try o.lowerType(optional_ty)).toLlvm(&o.builder);
        const payload_ty = optional_ty.optionalChild(mod);
        if (optional_ty.optionalReprIsPayload(mod)) {
            const loaded = if (operand_is_ptr)
                self.builder.buildLoad(optional_llvm_ty, operand, "")
            else
                operand;
            if (payload_ty.isSlice(mod)) {
                const slice_ptr = self.builder.buildExtractValue(loaded, 0, "");
                const ptr_ty = (try o.lowerType(payload_ty.slicePtrFieldType(mod))).toLlvm(&o.builder);
                return self.builder.buildICmp(pred, slice_ptr, ptr_ty.constNull(), "");
            }
            return self.builder.buildICmp(pred, loaded, optional_llvm_ty.constNull(), "");
        }

        comptime assert(optional_layout_version == 3);

        if (!payload_ty.hasRuntimeBitsIgnoreComptime(mod)) {
            const loaded = if (operand_is_ptr)
                self.builder.buildLoad(optional_llvm_ty, operand, "")
            else
                operand;
            return self.builder.buildICmp(pred, loaded, (try o.builder.intConst(.i8, 0)).toLlvm(&o.builder), "");
        }

        const is_by_ref = operand_is_ptr or isByRef(optional_ty, mod);
        const non_null_bit = try self.optIsNonNull(optional_llvm_ty, operand, is_by_ref);
        if (pred == .EQ) {
            return self.builder.buildNot(non_null_bit, "");
        } else {
            return non_null_bit;
        }
    }

    fn airIsErr(
        self: *FuncGen,
        inst: Air.Inst.Index,
        op: llvm.IntPredicate,
        operand_is_ptr: bool,
    ) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const un_op = self.air.instructions.items(.data)[inst].un_op;
        const operand = try self.resolveInst(un_op);
        const operand_ty = self.typeOf(un_op);
        const err_union_ty = if (operand_is_ptr) operand_ty.childType(mod) else operand_ty;
        const payload_ty = err_union_ty.errorUnionPayload(mod);
        const err_set_ty = (try o.lowerType(Type.anyerror)).toLlvm(&o.builder);
        const zero = err_set_ty.constNull();

        if (err_union_ty.errorUnionSet(mod).errorSetIsEmpty(mod)) {
            const val: Builder.Constant = switch (op) {
                .EQ => .true, // 0 == 0
                .NE => .false, // 0 != 0
                else => unreachable,
            };
            return val.toLlvm(&o.builder);
        }

        if (!payload_ty.hasRuntimeBitsIgnoreComptime(mod)) {
            const loaded = if (operand_is_ptr)
                self.builder.buildLoad((try o.lowerType(err_union_ty)).toLlvm(&o.builder), operand, "")
            else
                operand;
            return self.builder.buildICmp(op, loaded, zero, "");
        }

        const err_field_index = errUnionErrorOffset(payload_ty, mod);

        if (operand_is_ptr or isByRef(err_union_ty, mod)) {
            const err_union_llvm_ty = (try o.lowerType(err_union_ty)).toLlvm(&o.builder);
            const err_field_ptr = self.builder.buildStructGEP(err_union_llvm_ty, operand, err_field_index, "");
            const loaded = self.builder.buildLoad(err_set_ty, err_field_ptr, "");
            return self.builder.buildICmp(op, loaded, zero, "");
        }

        const loaded = self.builder.buildExtractValue(operand, err_field_index, "");
        return self.builder.buildICmp(op, loaded, zero, "");
    }

    fn airOptionalPayloadPtr(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);
        const optional_ty = self.typeOf(ty_op.operand).childType(mod);
        const payload_ty = optional_ty.optionalChild(mod);
        if (!payload_ty.hasRuntimeBitsIgnoreComptime(mod)) {
            // We have a pointer to a zero-bit value and we need to return
            // a pointer to a zero-bit value.
            return operand;
        }
        if (optional_ty.optionalReprIsPayload(mod)) {
            // The payload and the optional are the same value.
            return operand;
        }
        const optional_llvm_ty = (try o.lowerType(optional_ty)).toLlvm(&o.builder);
        return self.builder.buildStructGEP(optional_llvm_ty, operand, 0, "");
    }

    fn airOptionalPayloadPtrSet(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        comptime assert(optional_layout_version == 3);

        const o = self.dg.object;
        const mod = o.module;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);
        const optional_ty = self.typeOf(ty_op.operand).childType(mod);
        const payload_ty = optional_ty.optionalChild(mod);
        const non_null_bit = (try o.builder.intConst(.i8, 1)).toLlvm(&o.builder);
        if (!payload_ty.hasRuntimeBitsIgnoreComptime(mod)) {
            // We have a pointer to a i8. We need to set it to 1 and then return the same pointer.
            _ = self.builder.buildStore(non_null_bit, operand);
            return operand;
        }
        if (optional_ty.optionalReprIsPayload(mod)) {
            // The payload and the optional are the same value.
            // Setting to non-null will be done when the payload is set.
            return operand;
        }

        // First set the non-null bit.
        const optional_llvm_ty = (try o.lowerType(optional_ty)).toLlvm(&o.builder);
        const non_null_ptr = self.builder.buildStructGEP(optional_llvm_ty, operand, 1, "");
        // TODO set alignment on this store
        _ = self.builder.buildStore(non_null_bit, non_null_ptr);

        // Then return the payload pointer (only if it's used).
        if (self.liveness.isUnused(inst))
            return null;

        return self.builder.buildStructGEP(optional_llvm_ty, operand, 0, "");
    }

    fn airOptionalPayload(self: *FuncGen, body_tail: []const Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const inst = body_tail[0];
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);
        const optional_ty = self.typeOf(ty_op.operand);
        const payload_ty = self.typeOfIndex(inst);
        if (!payload_ty.hasRuntimeBitsIgnoreComptime(mod)) return null;

        if (optional_ty.optionalReprIsPayload(mod)) {
            // Payload value is the same as the optional value.
            return operand;
        }

        const opt_llvm_ty = (try o.lowerType(optional_ty)).toLlvm(&o.builder);
        const can_elide_load = if (isByRef(payload_ty, mod)) self.canElideLoad(body_tail) else false;
        return self.optPayloadHandle(opt_llvm_ty, operand, optional_ty, can_elide_load);
    }

    fn airErrUnionPayload(
        self: *FuncGen,
        body_tail: []const Air.Inst.Index,
        operand_is_ptr: bool,
    ) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const inst = body_tail[0];
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);
        const operand_ty = self.typeOf(ty_op.operand);
        const err_union_ty = if (operand_is_ptr) operand_ty.childType(mod) else operand_ty;
        const result_ty = self.typeOfIndex(inst);
        const payload_ty = if (operand_is_ptr) result_ty.childType(mod) else result_ty;

        if (!payload_ty.hasRuntimeBitsIgnoreComptime(mod)) {
            return if (operand_is_ptr) operand else null;
        }
        const offset = errUnionPayloadOffset(payload_ty, mod);
        const err_union_llvm_ty = (try o.lowerType(err_union_ty)).toLlvm(&o.builder);
        if (operand_is_ptr) {
            return self.builder.buildStructGEP(err_union_llvm_ty, operand, offset, "");
        } else if (isByRef(err_union_ty, mod)) {
            const payload_ptr = self.builder.buildStructGEP(err_union_llvm_ty, operand, offset, "");
            if (isByRef(payload_ty, mod)) {
                if (self.canElideLoad(body_tail))
                    return payload_ptr;

                return self.loadByRef(payload_ptr, payload_ty, payload_ty.abiAlignment(mod), false);
            }
            const load_inst = self.builder.buildLoad(err_union_llvm_ty.structGetTypeAtIndex(offset), payload_ptr, "");
            load_inst.setAlignment(payload_ty.abiAlignment(mod));
            return load_inst;
        }
        return self.builder.buildExtractValue(operand, offset, "");
    }

    fn airErrUnionErr(
        self: *FuncGen,
        inst: Air.Inst.Index,
        operand_is_ptr: bool,
    ) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);
        const operand_ty = self.typeOf(ty_op.operand);
        const err_union_ty = if (operand_is_ptr) operand_ty.childType(mod) else operand_ty;
        if (err_union_ty.errorUnionSet(mod).errorSetIsEmpty(mod)) {
            if (operand_is_ptr) {
                return operand;
            } else {
                return (try o.builder.intConst(Builder.Type.err_int, 0)).toLlvm(&o.builder);
            }
        }

        const err_set_llvm_ty = (try o.lowerType(Type.anyerror)).toLlvm(&o.builder);

        const payload_ty = err_union_ty.errorUnionPayload(mod);
        if (!payload_ty.hasRuntimeBitsIgnoreComptime(mod)) {
            if (!operand_is_ptr) return operand;
            return self.builder.buildLoad(err_set_llvm_ty, operand, "");
        }

        const offset = errUnionErrorOffset(payload_ty, mod);

        if (operand_is_ptr or isByRef(err_union_ty, mod)) {
            const err_union_llvm_ty = (try o.lowerType(err_union_ty)).toLlvm(&o.builder);
            const err_field_ptr = self.builder.buildStructGEP(err_union_llvm_ty, operand, offset, "");
            return self.builder.buildLoad(err_set_llvm_ty, err_field_ptr, "");
        }

        return self.builder.buildExtractValue(operand, offset, "");
    }

    fn airErrUnionPayloadPtrSet(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);
        const err_union_ty = self.typeOf(ty_op.operand).childType(mod);

        const payload_ty = err_union_ty.errorUnionPayload(mod);
        const non_error_val = try o.lowerValue(.{ .ty = Type.anyerror, .val = try mod.intValue(Type.err_int, 0) });
        if (!payload_ty.hasRuntimeBitsIgnoreComptime(mod)) {
            _ = self.builder.buildStore(non_error_val, operand);
            return operand;
        }
        const err_union_llvm_ty = (try o.lowerType(err_union_ty)).toLlvm(&o.builder);
        {
            const error_offset = errUnionErrorOffset(payload_ty, mod);
            // First set the non-error value.
            const non_null_ptr = self.builder.buildStructGEP(err_union_llvm_ty, operand, error_offset, "");
            const store_inst = self.builder.buildStore(non_error_val, non_null_ptr);
            store_inst.setAlignment(Type.anyerror.abiAlignment(mod));
        }
        // Then return the payload pointer (only if it is used).
        if (self.liveness.isUnused(inst))
            return null;

        const payload_offset = errUnionPayloadOffset(payload_ty, mod);
        return self.builder.buildStructGEP(err_union_llvm_ty, operand, payload_offset, "");
    }

    fn airErrReturnTrace(self: *FuncGen, _: Air.Inst.Index) !?*llvm.Value {
        return self.err_ret_trace.?;
    }

    fn airSetErrReturnTrace(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const un_op = self.air.instructions.items(.data)[inst].un_op;
        const operand = try self.resolveInst(un_op);
        self.err_ret_trace = operand;
        return null;
    }

    fn airSaveErrReturnTraceIndex(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        //const struct_ty = try self.resolveInst(ty_pl.ty);
        const struct_ty = self.air.getRefType(ty_pl.ty);
        const field_index = ty_pl.payload;

        const mod = o.module;
        const llvm_field = llvmField(struct_ty, field_index, mod).?;
        const struct_llvm_ty = (try o.lowerType(struct_ty)).toLlvm(&o.builder);
        const field_ptr = self.builder.buildStructGEP(struct_llvm_ty, self.err_ret_trace.?, llvm_field.index, "");
        const field_ptr_ty = try mod.ptrType(.{
            .child = llvm_field.ty.toIntern(),
            .flags = .{
                .alignment = InternPool.Alignment.fromNonzeroByteUnits(llvm_field.alignment),
            },
        });
        return self.load(field_ptr, field_ptr_ty);
    }

    fn airWrapOptional(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const payload_ty = self.typeOf(ty_op.operand);
        const non_null_bit = (try o.builder.intConst(.i8, 1)).toLlvm(&o.builder);
        comptime assert(optional_layout_version == 3);
        if (!payload_ty.hasRuntimeBitsIgnoreComptime(mod)) return non_null_bit;
        const operand = try self.resolveInst(ty_op.operand);
        const optional_ty = self.typeOfIndex(inst);
        if (optional_ty.optionalReprIsPayload(mod)) {
            return operand;
        }
        const llvm_optional_ty = (try o.lowerType(optional_ty)).toLlvm(&o.builder);
        if (isByRef(optional_ty, mod)) {
            const optional_ptr = try self.buildAlloca(llvm_optional_ty, optional_ty.abiAlignment(mod));
            const payload_ptr = self.builder.buildStructGEP(llvm_optional_ty, optional_ptr, 0, "");
            const payload_ptr_ty = try mod.singleMutPtrType(payload_ty);
            try self.store(payload_ptr, payload_ptr_ty, operand, .NotAtomic);
            const non_null_ptr = self.builder.buildStructGEP(llvm_optional_ty, optional_ptr, 1, "");
            _ = self.builder.buildStore(non_null_bit, non_null_ptr);
            return optional_ptr;
        }
        const partial = self.builder.buildInsertValue(llvm_optional_ty.getUndef(), operand, 0, "");
        return self.builder.buildInsertValue(partial, non_null_bit, 1, "");
    }

    fn airWrapErrUnionPayload(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const err_un_ty = self.typeOfIndex(inst);
        const operand = try self.resolveInst(ty_op.operand);
        const payload_ty = self.typeOf(ty_op.operand);
        if (!payload_ty.hasRuntimeBitsIgnoreComptime(mod)) {
            return operand;
        }
        const ok_err_code = (try o.lowerType(Type.anyerror)).toLlvm(&o.builder).constNull();
        const err_un_llvm_ty = (try o.lowerType(err_un_ty)).toLlvm(&o.builder);

        const payload_offset = errUnionPayloadOffset(payload_ty, mod);
        const error_offset = errUnionErrorOffset(payload_ty, mod);
        if (isByRef(err_un_ty, mod)) {
            const result_ptr = try self.buildAlloca(err_un_llvm_ty, err_un_ty.abiAlignment(mod));
            const err_ptr = self.builder.buildStructGEP(err_un_llvm_ty, result_ptr, error_offset, "");
            const store_inst = self.builder.buildStore(ok_err_code, err_ptr);
            store_inst.setAlignment(Type.anyerror.abiAlignment(mod));
            const payload_ptr = self.builder.buildStructGEP(err_un_llvm_ty, result_ptr, payload_offset, "");
            const payload_ptr_ty = try mod.singleMutPtrType(payload_ty);
            try self.store(payload_ptr, payload_ptr_ty, operand, .NotAtomic);
            return result_ptr;
        }

        const partial = self.builder.buildInsertValue(err_un_llvm_ty.getUndef(), ok_err_code, error_offset, "");
        return self.builder.buildInsertValue(partial, operand, payload_offset, "");
    }

    fn airWrapErrUnionErr(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const err_un_ty = self.typeOfIndex(inst);
        const payload_ty = err_un_ty.errorUnionPayload(mod);
        const operand = try self.resolveInst(ty_op.operand);
        if (!payload_ty.hasRuntimeBitsIgnoreComptime(mod)) {
            return operand;
        }
        const err_un_llvm_ty = (try o.lowerType(err_un_ty)).toLlvm(&o.builder);

        const payload_offset = errUnionPayloadOffset(payload_ty, mod);
        const error_offset = errUnionErrorOffset(payload_ty, mod);
        if (isByRef(err_un_ty, mod)) {
            const result_ptr = try self.buildAlloca(err_un_llvm_ty, err_un_ty.abiAlignment(mod));
            const err_ptr = self.builder.buildStructGEP(err_un_llvm_ty, result_ptr, error_offset, "");
            const store_inst = self.builder.buildStore(operand, err_ptr);
            store_inst.setAlignment(Type.anyerror.abiAlignment(mod));
            const payload_ptr = self.builder.buildStructGEP(err_un_llvm_ty, result_ptr, payload_offset, "");
            const payload_ptr_ty = try mod.singleMutPtrType(payload_ty);
            // TODO store undef to payload_ptr
            _ = payload_ptr;
            _ = payload_ptr_ty;
            return result_ptr;
        }

        const partial = self.builder.buildInsertValue(err_un_llvm_ty.getUndef(), operand, error_offset, "");
        // TODO set payload bytes to undef
        return partial;
    }

    fn airWasmMemorySize(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const pl_op = self.air.instructions.items(.data)[inst].pl_op;
        const index = pl_op.payload;
        const llvm_fn = try self.getIntrinsic("llvm.wasm.memory.size", &.{.i32});
        const args: [1]*llvm.Value = .{
            (try o.builder.intConst(.i32, index)).toLlvm(&o.builder),
        };
        return self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, &args, args.len, .Fast, .Auto, "");
    }

    fn airWasmMemoryGrow(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const pl_op = self.air.instructions.items(.data)[inst].pl_op;
        const index = pl_op.payload;
        const operand = try self.resolveInst(pl_op.operand);
        const llvm_fn = try self.getIntrinsic("llvm.wasm.memory.grow", &.{.i32});
        const args: [2]*llvm.Value = .{
            (try o.builder.intConst(.i32, index)).toLlvm(&o.builder),
            operand,
        };
        return self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, &args, args.len, .Fast, .Auto, "");
    }

    fn airVectorStoreElem(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const data = self.air.instructions.items(.data)[inst].vector_store_elem;
        const extra = self.air.extraData(Air.Bin, data.payload).data;

        const vector_ptr = try self.resolveInst(data.vector_ptr);
        const vector_ptr_ty = self.typeOf(data.vector_ptr);
        const index = try self.resolveInst(extra.lhs);
        const operand = try self.resolveInst(extra.rhs);

        const loaded_vector = blk: {
            const elem_llvm_ty = (try o.lowerType(vector_ptr_ty.childType(mod))).toLlvm(&o.builder);
            const load_inst = self.builder.buildLoad(elem_llvm_ty, vector_ptr, "");
            load_inst.setAlignment(vector_ptr_ty.ptrAlignment(mod));
            load_inst.setVolatile(llvm.Bool.fromBool(vector_ptr_ty.isVolatilePtr(mod)));
            break :blk load_inst;
        };
        const modified_vector = self.builder.buildInsertElement(loaded_vector, operand, index, "");
        try self.store(vector_ptr, vector_ptr_ty, modified_vector, .NotAtomic);
        return null;
    }

    fn airMin(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const scalar_ty = self.typeOfIndex(inst).scalarType(mod);

        if (scalar_ty.isAnyFloat()) return self.buildFloatOp(.fmin, scalar_ty, 2, .{ lhs, rhs });
        if (scalar_ty.isSignedInt(mod)) return self.builder.buildSMin(lhs, rhs, "");
        return self.builder.buildUMin(lhs, rhs, "");
    }

    fn airMax(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const scalar_ty = self.typeOfIndex(inst).scalarType(mod);

        if (scalar_ty.isAnyFloat()) return self.buildFloatOp(.fmax, scalar_ty, 2, .{ lhs, rhs });
        if (scalar_ty.isSignedInt(mod)) return self.builder.buildSMax(lhs, rhs, "");
        return self.builder.buildUMax(lhs, rhs, "");
    }

    fn airSlice(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const bin_op = self.air.extraData(Air.Bin, ty_pl.payload).data;
        const ptr = try self.resolveInst(bin_op.lhs);
        const len = try self.resolveInst(bin_op.rhs);
        const inst_ty = self.typeOfIndex(inst);
        const llvm_slice_ty = (try o.lowerType(inst_ty)).toLlvm(&o.builder);

        // In case of slicing a global, the result type looks something like `{ i8*, i64 }`
        // but `ptr` is pointing to the global directly.
        const partial = self.builder.buildInsertValue(llvm_slice_ty.getUndef(), ptr, 0, "");
        return self.builder.buildInsertValue(partial, len, 1, "");
    }

    fn airAdd(self: *FuncGen, inst: Air.Inst.Index, want_fast_math: bool) !?*llvm.Value {
        self.builder.setFastMath(want_fast_math);

        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const inst_ty = self.typeOfIndex(inst);
        const scalar_ty = inst_ty.scalarType(mod);

        if (scalar_ty.isAnyFloat()) return self.buildFloatOp(.add, inst_ty, 2, .{ lhs, rhs });
        if (scalar_ty.isSignedInt(mod)) return self.builder.buildNSWAdd(lhs, rhs, "");
        return self.builder.buildNUWAdd(lhs, rhs, "");
    }

    fn airSafeArithmetic(
        fg: *FuncGen,
        inst: Air.Inst.Index,
        signed_intrinsic: []const u8,
        unsigned_intrinsic: []const u8,
    ) !?*llvm.Value {
        const o = fg.dg.object;
        const mod = o.module;

        const bin_op = fg.air.instructions.items(.data)[inst].bin_op;
        const lhs = try fg.resolveInst(bin_op.lhs);
        const rhs = try fg.resolveInst(bin_op.rhs);
        const inst_ty = fg.typeOfIndex(inst);
        const scalar_ty = inst_ty.scalarType(mod);
        const is_scalar = scalar_ty.ip_index == inst_ty.ip_index;

        const intrinsic_name = switch (scalar_ty.isSignedInt(mod)) {
            true => signed_intrinsic,
            false => unsigned_intrinsic,
        };
        const llvm_fn = try fg.getIntrinsic(intrinsic_name, &.{try o.lowerType(inst_ty)});
        const result_struct = fg.builder.buildCall(
            llvm_fn.globalGetValueType(),
            llvm_fn,
            &[_]*llvm.Value{ lhs, rhs },
            2,
            .Fast,
            .Auto,
            "",
        );
        const overflow_bit = fg.builder.buildExtractValue(result_struct, 1, "");
        const scalar_overflow_bit = switch (is_scalar) {
            true => overflow_bit,
            false => fg.builder.buildOrReduce(overflow_bit),
        };

        const fail_block = fg.context.appendBasicBlock(fg.llvm_func, "OverflowFail");
        const ok_block = fg.context.appendBasicBlock(fg.llvm_func, "OverflowOk");
        _ = fg.builder.buildCondBr(scalar_overflow_bit, fail_block, ok_block);

        fg.builder.positionBuilderAtEnd(fail_block);
        try fg.buildSimplePanic(.integer_overflow);

        fg.builder.positionBuilderAtEnd(ok_block);
        return fg.builder.buildExtractValue(result_struct, 0, "");
    }

    fn airAddWrap(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);

        return self.builder.buildAdd(lhs, rhs, "");
    }

    fn airAddSat(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const inst_ty = self.typeOfIndex(inst);
        const scalar_ty = inst_ty.scalarType(mod);

        if (scalar_ty.isAnyFloat()) return self.todo("saturating float add", .{});
        if (scalar_ty.isSignedInt(mod)) return self.builder.buildSAddSat(lhs, rhs, "");

        return self.builder.buildUAddSat(lhs, rhs, "");
    }

    fn airSub(self: *FuncGen, inst: Air.Inst.Index, want_fast_math: bool) !?*llvm.Value {
        self.builder.setFastMath(want_fast_math);

        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const inst_ty = self.typeOfIndex(inst);
        const scalar_ty = inst_ty.scalarType(mod);

        if (scalar_ty.isAnyFloat()) return self.buildFloatOp(.sub, inst_ty, 2, .{ lhs, rhs });
        if (scalar_ty.isSignedInt(mod)) return self.builder.buildNSWSub(lhs, rhs, "");
        return self.builder.buildNUWSub(lhs, rhs, "");
    }

    fn airSubWrap(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);

        return self.builder.buildSub(lhs, rhs, "");
    }

    fn airSubSat(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const inst_ty = self.typeOfIndex(inst);
        const scalar_ty = inst_ty.scalarType(mod);

        if (scalar_ty.isAnyFloat()) return self.todo("saturating float sub", .{});
        if (scalar_ty.isSignedInt(mod)) return self.builder.buildSSubSat(lhs, rhs, "");
        return self.builder.buildUSubSat(lhs, rhs, "");
    }

    fn airMul(self: *FuncGen, inst: Air.Inst.Index, want_fast_math: bool) !?*llvm.Value {
        self.builder.setFastMath(want_fast_math);

        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const inst_ty = self.typeOfIndex(inst);
        const scalar_ty = inst_ty.scalarType(mod);

        if (scalar_ty.isAnyFloat()) return self.buildFloatOp(.mul, inst_ty, 2, .{ lhs, rhs });
        if (scalar_ty.isSignedInt(mod)) return self.builder.buildNSWMul(lhs, rhs, "");
        return self.builder.buildNUWMul(lhs, rhs, "");
    }

    fn airMulWrap(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);

        return self.builder.buildMul(lhs, rhs, "");
    }

    fn airMulSat(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const inst_ty = self.typeOfIndex(inst);
        const scalar_ty = inst_ty.scalarType(mod);

        if (scalar_ty.isAnyFloat()) return self.todo("saturating float mul", .{});
        if (scalar_ty.isSignedInt(mod)) return self.builder.buildSMulFixSat(lhs, rhs, "");
        return self.builder.buildUMulFixSat(lhs, rhs, "");
    }

    fn airDivFloat(self: *FuncGen, inst: Air.Inst.Index, want_fast_math: bool) !?*llvm.Value {
        self.builder.setFastMath(want_fast_math);

        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const inst_ty = self.typeOfIndex(inst);

        return self.buildFloatOp(.div, inst_ty, 2, .{ lhs, rhs });
    }

    fn airDivTrunc(self: *FuncGen, inst: Air.Inst.Index, want_fast_math: bool) !?*llvm.Value {
        self.builder.setFastMath(want_fast_math);

        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const inst_ty = self.typeOfIndex(inst);
        const scalar_ty = inst_ty.scalarType(mod);

        if (scalar_ty.isRuntimeFloat()) {
            const result = try self.buildFloatOp(.div, inst_ty, 2, .{ lhs, rhs });
            return self.buildFloatOp(.trunc, inst_ty, 1, .{result});
        }
        if (scalar_ty.isSignedInt(mod)) return self.builder.buildSDiv(lhs, rhs, "");
        return self.builder.buildUDiv(lhs, rhs, "");
    }

    fn airDivFloor(self: *FuncGen, inst: Air.Inst.Index, want_fast_math: bool) !?*llvm.Value {
        self.builder.setFastMath(want_fast_math);

        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const inst_ty = self.typeOfIndex(inst);
        const scalar_ty = inst_ty.scalarType(mod);

        if (scalar_ty.isRuntimeFloat()) {
            const result = try self.buildFloatOp(.div, inst_ty, 2, .{ lhs, rhs });
            return self.buildFloatOp(.floor, inst_ty, 1, .{result});
        }
        if (scalar_ty.isSignedInt(mod)) {
            const inst_llvm_ty = try o.lowerType(inst_ty);
            const scalar_bit_size_minus_one = scalar_ty.bitSize(mod) - 1;
            const bit_size_minus_one = if (inst_ty.zigTypeTag(mod) == .Vector) const_vector: {
                const vec_len = inst_ty.vectorLen(mod);

                const shifts = try self.gpa.alloc(*llvm.Value, vec_len);
                defer self.gpa.free(shifts);

                @memset(shifts, (try o.builder.intConst(try o.lowerType(scalar_ty), scalar_bit_size_minus_one)).toLlvm(&o.builder));
                break :const_vector llvm.constVector(shifts.ptr, vec_len);
            } else (try o.builder.intConst(inst_llvm_ty, scalar_bit_size_minus_one)).toLlvm(&o.builder);

            const div = self.builder.buildSDiv(lhs, rhs, "");
            const rem = self.builder.buildSRem(lhs, rhs, "");
            const div_sign = self.builder.buildXor(lhs, rhs, "");
            const div_sign_mask = self.builder.buildAShr(div_sign, bit_size_minus_one, "");
            const zero = inst_llvm_ty.toLlvm(&o.builder).constNull();
            const rem_nonzero = self.builder.buildICmp(.NE, rem, zero, "");
            const correction = self.builder.buildSelect(rem_nonzero, div_sign_mask, zero, "");
            return self.builder.buildNSWAdd(div, correction, "");
        }
        return self.builder.buildUDiv(lhs, rhs, "");
    }

    fn airDivExact(self: *FuncGen, inst: Air.Inst.Index, want_fast_math: bool) !?*llvm.Value {
        self.builder.setFastMath(want_fast_math);

        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const inst_ty = self.typeOfIndex(inst);
        const scalar_ty = inst_ty.scalarType(mod);

        if (scalar_ty.isRuntimeFloat()) return self.buildFloatOp(.div, inst_ty, 2, .{ lhs, rhs });
        if (scalar_ty.isSignedInt(mod)) return self.builder.buildExactSDiv(lhs, rhs, "");
        return self.builder.buildExactUDiv(lhs, rhs, "");
    }

    fn airRem(self: *FuncGen, inst: Air.Inst.Index, want_fast_math: bool) !?*llvm.Value {
        self.builder.setFastMath(want_fast_math);

        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const inst_ty = self.typeOfIndex(inst);
        const scalar_ty = inst_ty.scalarType(mod);

        if (scalar_ty.isRuntimeFloat()) return self.buildFloatOp(.fmod, inst_ty, 2, .{ lhs, rhs });
        if (scalar_ty.isSignedInt(mod)) return self.builder.buildSRem(lhs, rhs, "");
        return self.builder.buildURem(lhs, rhs, "");
    }

    fn airMod(self: *FuncGen, inst: Air.Inst.Index, want_fast_math: bool) !?*llvm.Value {
        self.builder.setFastMath(want_fast_math);

        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const inst_ty = self.typeOfIndex(inst);
        const inst_llvm_ty = try o.lowerType(inst_ty);
        const scalar_ty = inst_ty.scalarType(mod);

        if (scalar_ty.isRuntimeFloat()) {
            const a = try self.buildFloatOp(.fmod, inst_ty, 2, .{ lhs, rhs });
            const b = try self.buildFloatOp(.add, inst_ty, 2, .{ a, rhs });
            const c = try self.buildFloatOp(.fmod, inst_ty, 2, .{ b, rhs });
            const zero = inst_llvm_ty.toLlvm(&o.builder).constNull();
            const ltz = try self.buildFloatCmp(.lt, inst_ty, .{ lhs, zero });
            return self.builder.buildSelect(ltz, c, a, "");
        }
        if (scalar_ty.isSignedInt(mod)) {
            const scalar_bit_size_minus_one = scalar_ty.bitSize(mod) - 1;
            const bit_size_minus_one = if (inst_ty.zigTypeTag(mod) == .Vector) const_vector: {
                const vec_len = inst_ty.vectorLen(mod);

                const shifts = try self.gpa.alloc(*llvm.Value, vec_len);
                defer self.gpa.free(shifts);

                @memset(shifts, (try o.builder.intConst(try o.lowerType(scalar_ty), scalar_bit_size_minus_one)).toLlvm(&o.builder));
                break :const_vector llvm.constVector(shifts.ptr, vec_len);
            } else (try o.builder.intConst(inst_llvm_ty, scalar_bit_size_minus_one)).toLlvm(&o.builder);

            const rem = self.builder.buildSRem(lhs, rhs, "");
            const div_sign = self.builder.buildXor(lhs, rhs, "");
            const div_sign_mask = self.builder.buildAShr(div_sign, bit_size_minus_one, "");
            const rhs_masked = self.builder.buildAnd(rhs, div_sign_mask, "");
            const zero = inst_llvm_ty.toLlvm(&o.builder).constNull();
            const rem_nonzero = self.builder.buildICmp(.NE, rem, zero, "");
            const correction = self.builder.buildSelect(rem_nonzero, rhs_masked, zero, "");
            return self.builder.buildNSWAdd(rem, correction, "");
        }
        return self.builder.buildURem(lhs, rhs, "");
    }

    fn airPtrAdd(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const bin_op = self.air.extraData(Air.Bin, ty_pl.payload).data;
        const ptr = try self.resolveInst(bin_op.lhs);
        const offset = try self.resolveInst(bin_op.rhs);
        const ptr_ty = self.typeOf(bin_op.lhs);
        const llvm_elem_ty = (try o.lowerPtrElemTy(ptr_ty.childType(mod))).toLlvm(&o.builder);
        switch (ptr_ty.ptrSize(mod)) {
            .One => {
                // It's a pointer to an array, so according to LLVM we need an extra GEP index.
                const indices: [2]*llvm.Value = .{ Builder.Type.i32.toLlvm(&o.builder).constNull(), offset };
                return self.builder.buildInBoundsGEP(llvm_elem_ty, ptr, &indices, indices.len, "");
            },
            .C, .Many => {
                const indices: [1]*llvm.Value = .{offset};
                return self.builder.buildInBoundsGEP(llvm_elem_ty, ptr, &indices, indices.len, "");
            },
            .Slice => {
                const base = self.builder.buildExtractValue(ptr, 0, "");
                const indices: [1]*llvm.Value = .{offset};
                return self.builder.buildInBoundsGEP(llvm_elem_ty, base, &indices, indices.len, "");
            },
        }
    }

    fn airPtrSub(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const bin_op = self.air.extraData(Air.Bin, ty_pl.payload).data;
        const ptr = try self.resolveInst(bin_op.lhs);
        const offset = try self.resolveInst(bin_op.rhs);
        const negative_offset = self.builder.buildNeg(offset, "");
        const ptr_ty = self.typeOf(bin_op.lhs);
        const llvm_elem_ty = (try o.lowerPtrElemTy(ptr_ty.childType(mod))).toLlvm(&o.builder);
        switch (ptr_ty.ptrSize(mod)) {
            .One => {
                // It's a pointer to an array, so according to LLVM we need an extra GEP index.
                const indices: [2]*llvm.Value = .{
                    Builder.Type.i32.toLlvm(&o.builder).constNull(), negative_offset,
                };
                return self.builder.buildInBoundsGEP(llvm_elem_ty, ptr, &indices, indices.len, "");
            },
            .C, .Many => {
                const indices: [1]*llvm.Value = .{negative_offset};
                return self.builder.buildInBoundsGEP(llvm_elem_ty, ptr, &indices, indices.len, "");
            },
            .Slice => {
                const base = self.builder.buildExtractValue(ptr, 0, "");
                const indices: [1]*llvm.Value = .{negative_offset};
                return self.builder.buildInBoundsGEP(llvm_elem_ty, base, &indices, indices.len, "");
            },
        }
    }

    fn airOverflow(
        self: *FuncGen,
        inst: Air.Inst.Index,
        signed_intrinsic: []const u8,
        unsigned_intrinsic: []const u8,
    ) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const extra = self.air.extraData(Air.Bin, ty_pl.payload).data;

        const lhs = try self.resolveInst(extra.lhs);
        const rhs = try self.resolveInst(extra.rhs);

        const lhs_ty = self.typeOf(extra.lhs);
        const scalar_ty = lhs_ty.scalarType(mod);
        const dest_ty = self.typeOfIndex(inst);

        const intrinsic_name = if (scalar_ty.isSignedInt(mod)) signed_intrinsic else unsigned_intrinsic;

        const llvm_dest_ty = (try o.lowerType(dest_ty)).toLlvm(&o.builder);

        const llvm_fn = try self.getIntrinsic(intrinsic_name, &.{try o.lowerType(lhs_ty)});
        const result_struct = self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, &[_]*llvm.Value{ lhs, rhs }, 2, .Fast, .Auto, "");

        const result = self.builder.buildExtractValue(result_struct, 0, "");
        const overflow_bit = self.builder.buildExtractValue(result_struct, 1, "");

        const result_index = llvmField(dest_ty, 0, mod).?.index;
        const overflow_index = llvmField(dest_ty, 1, mod).?.index;

        if (isByRef(dest_ty, mod)) {
            const result_alignment = dest_ty.abiAlignment(mod);
            const alloca_inst = try self.buildAlloca(llvm_dest_ty, result_alignment);
            {
                const field_ptr = self.builder.buildStructGEP(llvm_dest_ty, alloca_inst, result_index, "");
                const store_inst = self.builder.buildStore(result, field_ptr);
                store_inst.setAlignment(result_alignment);
            }
            {
                const field_ptr = self.builder.buildStructGEP(llvm_dest_ty, alloca_inst, overflow_index, "");
                const store_inst = self.builder.buildStore(overflow_bit, field_ptr);
                store_inst.setAlignment(1);
            }

            return alloca_inst;
        }

        const partial = self.builder.buildInsertValue(llvm_dest_ty.getUndef(), result, result_index, "");
        return self.builder.buildInsertValue(partial, overflow_bit, overflow_index, "");
    }

    fn buildElementwiseCall(
        self: *FuncGen,
        llvm_fn: *llvm.Value,
        args_vectors: []const *llvm.Value,
        result_vector: *llvm.Value,
        vector_len: usize,
    ) !*llvm.Value {
        const o = self.dg.object;
        const args_len = @as(c_uint, @intCast(args_vectors.len));
        assert(args_len <= 3);

        var i: usize = 0;
        var result = result_vector;
        while (i < vector_len) : (i += 1) {
            const index_i32 = (try o.builder.intConst(.i32, i)).toLlvm(&o.builder);

            var args: [3]*llvm.Value = undefined;
            for (args_vectors, 0..) |arg_vector, k| {
                args[k] = self.builder.buildExtractElement(arg_vector, index_i32, "");
            }
            const result_elem = self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, &args, args_len, .C, .Auto, "");
            result = self.builder.buildInsertElement(result, result_elem, index_i32, "");
        }
        return result;
    }

    fn getLibcFunction(
        self: *FuncGen,
        fn_name: Builder.String,
        param_types: []const Builder.Type,
        return_type: Builder.Type,
    ) Allocator.Error!*llvm.Value {
        const o = self.dg.object;
        const slice = fn_name.toSlice(&o.builder).?;
        return o.llvm_module.getNamedFunction(slice) orelse b: {
            const alias = o.llvm_module.getNamedGlobalAlias(slice.ptr, slice.len);
            break :b if (alias) |a| a.getAliasee() else null;
        } orelse b: {
            const fn_type = try o.builder.fnType(return_type, param_types, .normal);
            const f = o.llvm_module.addFunction(slice, fn_type.toLlvm(&o.builder));

            var global = Builder.Global{
                .type = fn_type,
                .kind = .{ .function = @enumFromInt(o.builder.functions.items.len) },
            };
            var function = Builder.Function{
                .global = @enumFromInt(o.builder.globals.count()),
            };

            try o.builder.llvm_globals.append(self.gpa, f);
            _ = try o.builder.addGlobal(fn_name, global);
            try o.builder.functions.append(self.gpa, function);
            break :b f;
        };
    }

    /// Creates a floating point comparison by lowering to the appropriate
    /// hardware instruction or softfloat routine for the target
    fn buildFloatCmp(
        self: *FuncGen,
        pred: math.CompareOperator,
        ty: Type,
        params: [2]*llvm.Value,
    ) !*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const target = o.module.getTarget();
        const scalar_ty = ty.scalarType(mod);
        const scalar_llvm_ty = try o.lowerType(scalar_ty);

        if (intrinsicsAllowed(scalar_ty, target)) {
            const llvm_predicate: llvm.RealPredicate = switch (pred) {
                .eq => .OEQ,
                .neq => .UNE,
                .lt => .OLT,
                .lte => .OLE,
                .gt => .OGT,
                .gte => .OGE,
            };
            return self.builder.buildFCmp(llvm_predicate, params[0], params[1], "");
        }

        const float_bits = scalar_ty.floatBits(target);
        const compiler_rt_float_abbrev = compilerRtFloatAbbrev(float_bits);
        const fn_base_name = switch (pred) {
            .neq => "ne",
            .eq => "eq",
            .lt => "lt",
            .lte => "le",
            .gt => "gt",
            .gte => "ge",
        };
        const fn_name = try o.builder.fmt("__{s}{s}f2", .{ fn_base_name, compiler_rt_float_abbrev });

        const libc_fn = try self.getLibcFunction(
            fn_name,
            ([1]Builder.Type{scalar_llvm_ty} ** 2)[0..],
            .i32,
        );

        const zero = (try o.builder.intConst(.i32, 0)).toLlvm(&o.builder);
        const int_pred: llvm.IntPredicate = switch (pred) {
            .eq => .EQ,
            .neq => .NE,
            .lt => .SLT,
            .lte => .SLE,
            .gt => .SGT,
            .gte => .SGE,
        };

        if (ty.zigTypeTag(mod) == .Vector) {
            const vec_len = ty.vectorLen(mod);
            const vector_result_ty = (try o.builder.vectorType(.normal, vec_len, .i32)).toLlvm(&o.builder);

            var result = vector_result_ty.getUndef();
            result = try self.buildElementwiseCall(libc_fn, &params, result, vec_len);

            const zero_vector = self.builder.buildVectorSplat(vec_len, zero, "");
            return self.builder.buildICmp(int_pred, result, zero_vector, "");
        }

        const result = self.builder.buildCall(libc_fn.globalGetValueType(), libc_fn, &params, params.len, .C, .Auto, "");
        return self.builder.buildICmp(int_pred, result, zero, "");
    }

    const FloatOp = enum {
        add,
        ceil,
        cos,
        div,
        exp,
        exp2,
        fabs,
        floor,
        fma,
        fmax,
        fmin,
        fmod,
        log,
        log10,
        log2,
        mul,
        neg,
        round,
        sin,
        sqrt,
        sub,
        tan,
        trunc,
    };

    const FloatOpStrat = union(enum) {
        intrinsic: []const u8,
        libc: Builder.String,
    };

    /// Creates a floating point operation (add, sub, fma, sqrt, exp, etc.)
    /// by lowering to the appropriate hardware instruction or softfloat
    /// routine for the target
    fn buildFloatOp(
        self: *FuncGen,
        comptime op: FloatOp,
        ty: Type,
        comptime params_len: usize,
        params: [params_len]*llvm.Value,
    ) !*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const target = mod.getTarget();
        const scalar_ty = ty.scalarType(mod);
        const llvm_ty = try o.lowerType(ty);
        const scalar_llvm_ty = try o.lowerType(scalar_ty);

        const intrinsics_allowed = op != .tan and intrinsicsAllowed(scalar_ty, target);
        const strat: FloatOpStrat = if (intrinsics_allowed) switch (op) {
            // Some operations are dedicated LLVM instructions, not available as intrinsics
            .neg => return self.builder.buildFNeg(params[0], ""),
            .add => return self.builder.buildFAdd(params[0], params[1], ""),
            .sub => return self.builder.buildFSub(params[0], params[1], ""),
            .mul => return self.builder.buildFMul(params[0], params[1], ""),
            .div => return self.builder.buildFDiv(params[0], params[1], ""),
            .fmod => return self.builder.buildFRem(params[0], params[1], ""),
            .fmax => return self.builder.buildMaxNum(params[0], params[1], ""),
            .fmin => return self.builder.buildMinNum(params[0], params[1], ""),
            else => .{ .intrinsic = "llvm." ++ @tagName(op) },
        } else b: {
            const float_bits = scalar_ty.floatBits(target);
            break :b switch (op) {
                .neg => {
                    // In this case we can generate a softfloat negation by XORing the
                    // bits with a constant.
                    const int_ty = try o.builder.intType(@intCast(float_bits));
                    const one = (try o.builder.intConst(int_ty, 1)).toLlvm(&o.builder);
                    const shift_amt = try o.builder.intConst(int_ty, float_bits - 1);
                    const sign_mask = one.constShl(shift_amt.toLlvm(&o.builder));
                    const result = if (ty.zigTypeTag(mod) == .Vector) blk: {
                        const splat_sign_mask = self.builder.buildVectorSplat(ty.vectorLen(mod), sign_mask, "");
                        const cast_ty = try o.builder.vectorType(.normal, ty.vectorLen(mod), int_ty);
                        const bitcasted_operand = self.builder.buildBitCast(params[0], cast_ty.toLlvm(&o.builder), "");
                        break :blk self.builder.buildXor(bitcasted_operand, splat_sign_mask, "");
                    } else blk: {
                        const bitcasted_operand = self.builder.buildBitCast(params[0], int_ty.toLlvm(&o.builder), "");
                        break :blk self.builder.buildXor(bitcasted_operand, sign_mask, "");
                    };
                    return self.builder.buildBitCast(result, llvm_ty.toLlvm(&o.builder), "");
                },
                .add, .sub, .div, .mul => .{ .libc = try o.builder.fmt("__{s}{s}f3", .{
                    @tagName(op), compilerRtFloatAbbrev(float_bits),
                }) },
                .ceil,
                .cos,
                .exp,
                .exp2,
                .fabs,
                .floor,
                .fma,
                .fmax,
                .fmin,
                .fmod,
                .log,
                .log10,
                .log2,
                .round,
                .sin,
                .sqrt,
                .tan,
                .trunc,
                => .{ .libc = try o.builder.fmt("{s}{s}{s}", .{
                    libcFloatPrefix(float_bits), @tagName(op), libcFloatSuffix(float_bits),
                }) },
            };
        };

        const llvm_fn: *llvm.Value = switch (strat) {
            .intrinsic => |fn_name| try self.getIntrinsic(fn_name, &.{llvm_ty}),
            .libc => |fn_name| b: {
                const libc_fn = try self.getLibcFunction(
                    fn_name,
                    ([1]Builder.Type{scalar_llvm_ty} ** 3)[0..params.len],
                    scalar_llvm_ty,
                );
                if (ty.zigTypeTag(mod) == .Vector) {
                    const result = llvm_ty.toLlvm(&o.builder).getUndef();
                    return self.buildElementwiseCall(libc_fn, &params, result, ty.vectorLen(mod));
                }

                break :b libc_fn;
            },
        };
        return self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, &params, params_len, .C, .Auto, "");
    }

    fn airMulAdd(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const pl_op = self.air.instructions.items(.data)[inst].pl_op;
        const extra = self.air.extraData(Air.Bin, pl_op.payload).data;

        const mulend1 = try self.resolveInst(extra.lhs);
        const mulend2 = try self.resolveInst(extra.rhs);
        const addend = try self.resolveInst(pl_op.operand);

        const ty = self.typeOfIndex(inst);
        return self.buildFloatOp(.fma, ty, 3, .{ mulend1, mulend2, addend });
    }

    fn airShlWithOverflow(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const extra = self.air.extraData(Air.Bin, ty_pl.payload).data;

        const lhs = try self.resolveInst(extra.lhs);
        const rhs = try self.resolveInst(extra.rhs);

        const lhs_ty = self.typeOf(extra.lhs);
        const rhs_ty = self.typeOf(extra.rhs);
        const lhs_scalar_ty = lhs_ty.scalarType(mod);
        const rhs_scalar_ty = rhs_ty.scalarType(mod);

        const dest_ty = self.typeOfIndex(inst);
        const llvm_dest_ty = (try o.lowerType(dest_ty)).toLlvm(&o.builder);

        const casted_rhs = if (rhs_scalar_ty.bitSize(mod) < lhs_scalar_ty.bitSize(mod))
            self.builder.buildZExt(rhs, (try o.lowerType(lhs_ty)).toLlvm(&o.builder), "")
        else
            rhs;

        const result = self.builder.buildShl(lhs, casted_rhs, "");
        const reconstructed = if (lhs_scalar_ty.isSignedInt(mod))
            self.builder.buildAShr(result, casted_rhs, "")
        else
            self.builder.buildLShr(result, casted_rhs, "");

        const overflow_bit = self.builder.buildICmp(.NE, lhs, reconstructed, "");

        const result_index = llvmField(dest_ty, 0, mod).?.index;
        const overflow_index = llvmField(dest_ty, 1, mod).?.index;

        if (isByRef(dest_ty, mod)) {
            const result_alignment = dest_ty.abiAlignment(mod);
            const alloca_inst = try self.buildAlloca(llvm_dest_ty, result_alignment);
            {
                const field_ptr = self.builder.buildStructGEP(llvm_dest_ty, alloca_inst, result_index, "");
                const store_inst = self.builder.buildStore(result, field_ptr);
                store_inst.setAlignment(result_alignment);
            }
            {
                const field_ptr = self.builder.buildStructGEP(llvm_dest_ty, alloca_inst, overflow_index, "");
                const store_inst = self.builder.buildStore(overflow_bit, field_ptr);
                store_inst.setAlignment(1);
            }

            return alloca_inst;
        }

        const partial = self.builder.buildInsertValue(llvm_dest_ty.getUndef(), result, result_index, "");
        return self.builder.buildInsertValue(partial, overflow_bit, overflow_index, "");
    }

    fn airAnd(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        return self.builder.buildAnd(lhs, rhs, "");
    }

    fn airOr(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        return self.builder.buildOr(lhs, rhs, "");
    }

    fn airXor(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        return self.builder.buildXor(lhs, rhs, "");
    }

    fn airShlExact(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;

        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);

        const lhs_ty = self.typeOf(bin_op.lhs);
        const rhs_ty = self.typeOf(bin_op.rhs);
        const lhs_scalar_ty = lhs_ty.scalarType(mod);
        const rhs_scalar_ty = rhs_ty.scalarType(mod);

        const casted_rhs = if (rhs_scalar_ty.bitSize(mod) < lhs_scalar_ty.bitSize(mod))
            self.builder.buildZExt(rhs, (try o.lowerType(lhs_ty)).toLlvm(&o.builder), "")
        else
            rhs;
        if (lhs_scalar_ty.isSignedInt(mod)) return self.builder.buildNSWShl(lhs, casted_rhs, "");
        return self.builder.buildNUWShl(lhs, casted_rhs, "");
    }

    fn airShl(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;

        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);

        const lhs_type = self.typeOf(bin_op.lhs);
        const rhs_type = self.typeOf(bin_op.rhs);
        const lhs_scalar_ty = lhs_type.scalarType(mod);
        const rhs_scalar_ty = rhs_type.scalarType(mod);

        const casted_rhs = if (rhs_scalar_ty.bitSize(mod) < lhs_scalar_ty.bitSize(mod))
            self.builder.buildZExt(rhs, (try o.lowerType(lhs_type)).toLlvm(&o.builder), "")
        else
            rhs;
        return self.builder.buildShl(lhs, casted_rhs, "");
    }

    fn airShlSat(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;

        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);

        const lhs_ty = self.typeOf(bin_op.lhs);
        const rhs_ty = self.typeOf(bin_op.rhs);
        const lhs_scalar_ty = lhs_ty.scalarType(mod);
        const rhs_scalar_ty = rhs_ty.scalarType(mod);
        const lhs_bits = lhs_scalar_ty.bitSize(mod);

        const casted_rhs = if (rhs_scalar_ty.bitSize(mod) < lhs_bits)
            self.builder.buildZExt(rhs, lhs.typeOf(), "")
        else
            rhs;

        const result = if (lhs_scalar_ty.isSignedInt(mod))
            self.builder.buildSShlSat(lhs, casted_rhs, "")
        else
            self.builder.buildUShlSat(lhs, casted_rhs, "");

        // LLVM langref says "If b is (statically or dynamically) equal to or
        // larger than the integer bit width of the arguments, the result is a
        // poison value."
        // However Zig semantics says that saturating shift left can never produce
        // undefined; instead it saturates.
        const lhs_scalar_llvm_ty = try o.lowerType(lhs_scalar_ty);
        const bits = (try o.builder.intConst(lhs_scalar_llvm_ty, lhs_bits)).toLlvm(&o.builder);
        const lhs_max = (try o.builder.intConst(lhs_scalar_llvm_ty, -1)).toLlvm(&o.builder);
        if (rhs_ty.zigTypeTag(mod) == .Vector) {
            const vec_len = rhs_ty.vectorLen(mod);
            const bits_vec = self.builder.buildVectorSplat(vec_len, bits, "");
            const lhs_max_vec = self.builder.buildVectorSplat(vec_len, lhs_max, "");
            const in_range = self.builder.buildICmp(.ULT, rhs, bits_vec, "");
            return self.builder.buildSelect(in_range, result, lhs_max_vec, "");
        } else {
            const in_range = self.builder.buildICmp(.ULT, rhs, bits, "");
            return self.builder.buildSelect(in_range, result, lhs_max, "");
        }
    }

    fn airShr(self: *FuncGen, inst: Air.Inst.Index, is_exact: bool) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;

        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);

        const lhs_ty = self.typeOf(bin_op.lhs);
        const rhs_ty = self.typeOf(bin_op.rhs);
        const lhs_scalar_ty = lhs_ty.scalarType(mod);
        const rhs_scalar_ty = rhs_ty.scalarType(mod);

        const casted_rhs = if (rhs_scalar_ty.bitSize(mod) < lhs_scalar_ty.bitSize(mod))
            self.builder.buildZExt(rhs, (try o.lowerType(lhs_ty)).toLlvm(&o.builder), "")
        else
            rhs;
        const is_signed_int = lhs_scalar_ty.isSignedInt(mod);

        if (is_exact) {
            if (is_signed_int) {
                return self.builder.buildAShrExact(lhs, casted_rhs, "");
            } else {
                return self.builder.buildLShrExact(lhs, casted_rhs, "");
            }
        } else {
            if (is_signed_int) {
                return self.builder.buildAShr(lhs, casted_rhs, "");
            } else {
                return self.builder.buildLShr(lhs, casted_rhs, "");
            }
        }
    }

    fn airIntCast(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const dest_ty = self.typeOfIndex(inst);
        const dest_info = dest_ty.intInfo(mod);
        const dest_llvm_ty = (try o.lowerType(dest_ty)).toLlvm(&o.builder);
        const operand = try self.resolveInst(ty_op.operand);
        const operand_ty = self.typeOf(ty_op.operand);
        const operand_info = operand_ty.intInfo(mod);

        if (operand_info.bits < dest_info.bits) {
            switch (operand_info.signedness) {
                .signed => return self.builder.buildSExt(operand, dest_llvm_ty, ""),
                .unsigned => return self.builder.buildZExt(operand, dest_llvm_ty, ""),
            }
        } else if (operand_info.bits > dest_info.bits) {
            return self.builder.buildTrunc(operand, dest_llvm_ty, "");
        } else {
            return operand;
        }
    }

    fn airTrunc(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);
        const dest_llvm_ty = (try o.lowerType(self.typeOfIndex(inst))).toLlvm(&o.builder);
        return self.builder.buildTrunc(operand, dest_llvm_ty, "");
    }

    fn airFptrunc(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);
        const operand_ty = self.typeOf(ty_op.operand);
        const dest_ty = self.typeOfIndex(inst);
        const target = mod.getTarget();
        const dest_bits = dest_ty.floatBits(target);
        const src_bits = operand_ty.floatBits(target);

        if (intrinsicsAllowed(dest_ty, target) and intrinsicsAllowed(operand_ty, target)) {
            const dest_llvm_ty = (try o.lowerType(dest_ty)).toLlvm(&o.builder);
            return self.builder.buildFPTrunc(operand, dest_llvm_ty, "");
        } else {
            const operand_llvm_ty = try o.lowerType(operand_ty);
            const dest_llvm_ty = try o.lowerType(dest_ty);

            const fn_name = try o.builder.fmt("__trunc{s}f{s}f2", .{
                compilerRtFloatAbbrev(src_bits), compilerRtFloatAbbrev(dest_bits),
            });

            const params = [1]*llvm.Value{operand};
            const llvm_fn = try self.getLibcFunction(fn_name, &.{operand_llvm_ty}, dest_llvm_ty);

            return self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, &params, params.len, .C, .Auto, "");
        }
    }

    fn airFpext(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);
        const operand_ty = self.typeOf(ty_op.operand);
        const dest_ty = self.typeOfIndex(inst);
        const target = mod.getTarget();
        const dest_bits = dest_ty.floatBits(target);
        const src_bits = operand_ty.floatBits(target);

        if (intrinsicsAllowed(dest_ty, target) and intrinsicsAllowed(operand_ty, target)) {
            const dest_llvm_ty = (try o.lowerType(dest_ty)).toLlvm(&o.builder);
            return self.builder.buildFPExt(operand, dest_llvm_ty, "");
        } else {
            const operand_llvm_ty = try o.lowerType(operand_ty);
            const dest_llvm_ty = try o.lowerType(dest_ty);

            const fn_name = try o.builder.fmt("__extend{s}f{s}f2", .{
                compilerRtFloatAbbrev(src_bits), compilerRtFloatAbbrev(dest_bits),
            });

            const params = [1]*llvm.Value{operand};
            const llvm_fn = try self.getLibcFunction(fn_name, &.{operand_llvm_ty}, dest_llvm_ty);

            return self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, &params, params.len, .C, .Auto, "");
        }
    }

    fn airIntFromPtr(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const un_op = self.air.instructions.items(.data)[inst].un_op;
        const operand = try self.resolveInst(un_op);
        const ptr_ty = self.typeOf(un_op);
        const operand_ptr = self.sliceOrArrayPtr(operand, ptr_ty);
        const dest_llvm_ty = (try o.lowerType(self.typeOfIndex(inst))).toLlvm(&o.builder);
        return self.builder.buildPtrToInt(operand_ptr, dest_llvm_ty, "");
    }

    fn airBitCast(self: *FuncGen, inst: Air.Inst.Index) !*llvm.Value {
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand_ty = self.typeOf(ty_op.operand);
        const inst_ty = self.typeOfIndex(inst);
        const operand = try self.resolveInst(ty_op.operand);
        return self.bitCast(operand, operand_ty, inst_ty);
    }

    fn bitCast(self: *FuncGen, operand: *llvm.Value, operand_ty: Type, inst_ty: Type) !*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const operand_is_ref = isByRef(operand_ty, mod);
        const result_is_ref = isByRef(inst_ty, mod);
        const llvm_dest_ty = (try o.lowerType(inst_ty)).toLlvm(&o.builder);

        if (operand_is_ref and result_is_ref) {
            // They are both pointers, so just return the same opaque pointer :)
            return operand;
        }

        if (llvm_dest_ty.getTypeKind() == .Integer and
            operand.typeOf().getTypeKind() == .Integer)
        {
            return self.builder.buildZExtOrBitCast(operand, llvm_dest_ty, "");
        }

        if (operand_ty.zigTypeTag(mod) == .Int and inst_ty.isPtrAtRuntime(mod)) {
            return self.builder.buildIntToPtr(operand, llvm_dest_ty, "");
        }

        if (operand_ty.zigTypeTag(mod) == .Vector and inst_ty.zigTypeTag(mod) == .Array) {
            const elem_ty = operand_ty.childType(mod);
            if (!result_is_ref) {
                return self.dg.todo("implement bitcast vector to non-ref array", .{});
            }
            const array_ptr = try self.buildAlloca(llvm_dest_ty, null);
            const bitcast_ok = elem_ty.bitSize(mod) == elem_ty.abiSize(mod) * 8;
            if (bitcast_ok) {
                const llvm_store = self.builder.buildStore(operand, array_ptr);
                llvm_store.setAlignment(inst_ty.abiAlignment(mod));
            } else {
                // If the ABI size of the element type is not evenly divisible by size in bits;
                // a simple bitcast will not work, and we fall back to extractelement.
                const llvm_usize = try o.lowerType(Type.usize);
                const zero = try o.builder.intConst(llvm_usize, 0);
                const vector_len = operand_ty.arrayLen(mod);
                var i: u64 = 0;
                while (i < vector_len) : (i += 1) {
                    const index_usize = try o.builder.intConst(llvm_usize, i);
                    const index_u32 = try o.builder.intConst(.i32, i);
                    const indexes: [2]*llvm.Value = .{
                        zero.toLlvm(&o.builder),
                        index_usize.toLlvm(&o.builder),
                    };
                    const elem_ptr = self.builder.buildInBoundsGEP(llvm_dest_ty, array_ptr, &indexes, indexes.len, "");
                    const elem = self.builder.buildExtractElement(operand, index_u32.toLlvm(&o.builder), "");
                    _ = self.builder.buildStore(elem, elem_ptr);
                }
            }
            return array_ptr;
        } else if (operand_ty.zigTypeTag(mod) == .Array and inst_ty.zigTypeTag(mod) == .Vector) {
            const elem_ty = operand_ty.childType(mod);
            const llvm_vector_ty = (try o.lowerType(inst_ty)).toLlvm(&o.builder);
            if (!operand_is_ref) {
                return self.dg.todo("implement bitcast non-ref array to vector", .{});
            }

            const bitcast_ok = elem_ty.bitSize(mod) == elem_ty.abiSize(mod) * 8;
            if (bitcast_ok) {
                const vector = self.builder.buildLoad(llvm_vector_ty, operand, "");
                // The array is aligned to the element's alignment, while the vector might have a completely
                // different alignment. This means we need to enforce the alignment of this load.
                vector.setAlignment(elem_ty.abiAlignment(mod));
                return vector;
            } else {
                // If the ABI size of the element type is not evenly divisible by size in bits;
                // a simple bitcast will not work, and we fall back to extractelement.
                const array_llvm_ty = (try o.lowerType(operand_ty)).toLlvm(&o.builder);
                const elem_llvm_ty = (try o.lowerType(elem_ty)).toLlvm(&o.builder);
                const llvm_usize = try o.lowerType(Type.usize);
                const zero = try o.builder.intConst(llvm_usize, 0);
                const vector_len = operand_ty.arrayLen(mod);
                var vector = llvm_vector_ty.getUndef();
                var i: u64 = 0;
                while (i < vector_len) : (i += 1) {
                    const index_usize = try o.builder.intConst(llvm_usize, i);
                    const index_u32 = try o.builder.intConst(.i32, i);
                    const indexes: [2]*llvm.Value = .{
                        zero.toLlvm(&o.builder),
                        index_usize.toLlvm(&o.builder),
                    };
                    const elem_ptr = self.builder.buildInBoundsGEP(array_llvm_ty, operand, &indexes, indexes.len, "");
                    const elem = self.builder.buildLoad(elem_llvm_ty, elem_ptr, "");
                    vector = self.builder.buildInsertElement(vector, elem, index_u32.toLlvm(&o.builder), "");
                }

                return vector;
            }
        }

        if (operand_is_ref) {
            const load_inst = self.builder.buildLoad(llvm_dest_ty, operand, "");
            load_inst.setAlignment(operand_ty.abiAlignment(mod));
            return load_inst;
        }

        if (result_is_ref) {
            const alignment = @max(operand_ty.abiAlignment(mod), inst_ty.abiAlignment(mod));
            const result_ptr = try self.buildAlloca(llvm_dest_ty, alignment);
            const store_inst = self.builder.buildStore(operand, result_ptr);
            store_inst.setAlignment(alignment);
            return result_ptr;
        }

        if (llvm_dest_ty.getTypeKind() == .Struct) {
            // Both our operand and our result are values, not pointers,
            // but LLVM won't let us bitcast struct values.
            // Therefore, we store operand to alloca, then load for result.
            const alignment = @max(operand_ty.abiAlignment(mod), inst_ty.abiAlignment(mod));
            const result_ptr = try self.buildAlloca(llvm_dest_ty, alignment);
            const store_inst = self.builder.buildStore(operand, result_ptr);
            store_inst.setAlignment(alignment);
            const load_inst = self.builder.buildLoad(llvm_dest_ty, result_ptr, "");
            load_inst.setAlignment(alignment);
            return load_inst;
        }

        return self.builder.buildBitCast(operand, llvm_dest_ty, "");
    }

    fn airIntFromBool(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const un_op = self.air.instructions.items(.data)[inst].un_op;
        const operand = try self.resolveInst(un_op);
        return operand;
    }

    fn airArg(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const arg_val = self.args[self.arg_index];
        self.arg_index += 1;

        const inst_ty = self.typeOfIndex(inst);
        if (o.di_builder) |dib| {
            if (needDbgVarWorkaround(o)) {
                return arg_val;
            }

            const src_index = self.air.instructions.items(.data)[inst].arg.src_index;
            const func = self.dg.decl.getOwnedFunction(mod).?;
            const lbrace_line = mod.declPtr(func.owner_decl).src_line + func.lbrace_line + 1;
            const lbrace_col = func.lbrace_column + 1;
            const di_local_var = dib.createParameterVariable(
                self.di_scope.?,
                func.getParamName(mod, src_index).ptr, // TODO test 0 bit args
                self.di_file.?,
                lbrace_line,
                try o.lowerDebugType(inst_ty, .full),
                true, // always preserve
                0, // flags
                self.arg_index, // includes +1 because 0 is return type
            );

            const debug_loc = llvm.getDebugLoc(lbrace_line, lbrace_col, self.di_scope.?, null);
            const insert_block = self.builder.getInsertBlock();
            if (isByRef(inst_ty, mod)) {
                _ = dib.insertDeclareAtEnd(arg_val, di_local_var, debug_loc, insert_block);
            } else if (o.module.comp.bin_file.options.optimize_mode == .Debug) {
                const alignment = inst_ty.abiAlignment(mod);
                const alloca = try self.buildAlloca(arg_val.typeOf(), alignment);
                const store_inst = self.builder.buildStore(arg_val, alloca);
                store_inst.setAlignment(alignment);
                _ = dib.insertDeclareAtEnd(alloca, di_local_var, debug_loc, insert_block);
            } else {
                _ = dib.insertDbgValueIntrinsicAtEnd(arg_val, di_local_var, debug_loc, insert_block);
            }
        }

        return arg_val;
    }

    fn airAlloc(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ptr_ty = self.typeOfIndex(inst);
        const pointee_type = ptr_ty.childType(mod);
        if (!pointee_type.isFnOrHasRuntimeBitsIgnoreComptime(mod))
            return o.lowerPtrToVoid(ptr_ty);

        const pointee_llvm_ty = (try o.lowerType(pointee_type)).toLlvm(&o.builder);
        const alignment = ptr_ty.ptrAlignment(mod);
        return self.buildAlloca(pointee_llvm_ty, alignment);
    }

    fn airRetPtr(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ptr_ty = self.typeOfIndex(inst);
        const ret_ty = ptr_ty.childType(mod);
        if (!ret_ty.isFnOrHasRuntimeBitsIgnoreComptime(mod)) return o.lowerPtrToVoid(ptr_ty);
        if (self.ret_ptr) |ret_ptr| return ret_ptr;
        const ret_llvm_ty = (try o.lowerType(ret_ty)).toLlvm(&o.builder);
        return self.buildAlloca(ret_llvm_ty, ptr_ty.ptrAlignment(mod));
    }

    /// Use this instead of builder.buildAlloca, because this function makes sure to
    /// put the alloca instruction at the top of the function!
    fn buildAlloca(self: *FuncGen, llvm_ty: *llvm.Type, alignment: ?c_uint) Allocator.Error!*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const target = mod.getTarget();
        return o.buildAllocaInner(self.builder, self.llvm_func, self.di_scope != null, llvm_ty, alignment, target);
    }

    fn airStore(self: *FuncGen, inst: Air.Inst.Index, safety: bool) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const dest_ptr = try self.resolveInst(bin_op.lhs);
        const ptr_ty = self.typeOf(bin_op.lhs);
        const operand_ty = ptr_ty.childType(mod);

        const val_is_undef = if (try self.air.value(bin_op.rhs, mod)) |val| val.isUndefDeep(mod) else false;
        if (val_is_undef) {
            // Even if safety is disabled, we still emit a memset to undefined since it conveys
            // extra information to LLVM. However, safety makes the difference between using
            // 0xaa or actual undefined for the fill byte.
            const fill_byte = if (safety)
                (try o.builder.intConst(.i8, 0xaa)).toLlvm(&o.builder)
            else
                Builder.Type.i8.toLlvm(&o.builder).getUndef();
            const operand_size = operand_ty.abiSize(mod);
            const usize_ty = try o.lowerType(Type.usize);
            const len = (try o.builder.intConst(usize_ty, operand_size)).toLlvm(&o.builder);
            const dest_ptr_align = ptr_ty.ptrAlignment(mod);
            _ = self.builder.buildMemSet(dest_ptr, fill_byte, len, dest_ptr_align, ptr_ty.isVolatilePtr(mod));
            if (safety and mod.comp.bin_file.options.valgrind) {
                try self.valgrindMarkUndef(dest_ptr, len);
            }
            return null;
        }

        const src_operand = try self.resolveInst(bin_op.rhs);
        try self.store(dest_ptr, ptr_ty, src_operand, .NotAtomic);
        return null;
    }

    /// As an optimization, we want to avoid unnecessary copies of isByRef=true
    /// types. Here, we scan forward in the current block, looking to see if
    /// this load dies before any side effects occur. In such case, we can
    /// safely return the operand without making a copy.
    ///
    /// The first instruction of `body_tail` is the one whose copy we want to elide.
    fn canElideLoad(fg: *FuncGen, body_tail: []const Air.Inst.Index) bool {
        const o = fg.dg.object;
        const mod = o.module;
        const ip = &mod.intern_pool;
        for (body_tail[1..]) |body_inst| {
            switch (fg.liveness.categorizeOperand(fg.air, body_inst, body_tail[0], ip)) {
                .none => continue,
                .write, .noret, .complex => return false,
                .tomb => return true,
            }
        }
        // The only way to get here is to hit the end of a loop instruction
        // (implicit repeat).
        return false;
    }

    fn airLoad(fg: *FuncGen, body_tail: []const Air.Inst.Index) !?*llvm.Value {
        const o = fg.dg.object;
        const mod = o.module;
        const inst = body_tail[0];
        const ty_op = fg.air.instructions.items(.data)[inst].ty_op;
        const ptr_ty = fg.typeOf(ty_op.operand);
        const ptr_info = ptr_ty.ptrInfo(mod);
        const ptr = try fg.resolveInst(ty_op.operand);

        elide: {
            if (!isByRef(ptr_info.child.toType(), mod)) break :elide;
            if (!canElideLoad(fg, body_tail)) break :elide;
            return ptr;
        }
        return fg.load(ptr, ptr_ty);
    }

    fn airTrap(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        _ = inst;
        const llvm_fn = try self.getIntrinsic("llvm.trap", &.{});
        _ = self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, undefined, 0, .Cold, .Auto, "");
        _ = self.builder.buildUnreachable();
        return null;
    }

    fn airBreakpoint(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        _ = inst;
        const llvm_fn = try self.getIntrinsic("llvm.debugtrap", &.{});
        _ = self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, undefined, 0, .C, .Auto, "");
        return null;
    }

    fn airRetAddr(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        _ = inst;
        const o = self.dg.object;
        const mod = o.module;
        const llvm_usize = (try o.lowerType(Type.usize)).toLlvm(&o.builder);
        const target = mod.getTarget();
        if (!target_util.supportsReturnAddress(target)) {
            // https://github.com/ziglang/zig/issues/11946
            return llvm_usize.constNull();
        }

        const llvm_i32 = Builder.Type.i32.toLlvm(&o.builder);
        const llvm_fn = try self.getIntrinsic("llvm.returnaddress", &.{});
        const params = [_]*llvm.Value{llvm_i32.constNull()};
        const ptr_val = self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, &params, params.len, .Fast, .Auto, "");
        return self.builder.buildPtrToInt(ptr_val, llvm_usize, "");
    }

    fn airFrameAddress(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        _ = inst;
        const o = self.dg.object;
        const llvm_fn_name = "llvm.frameaddress.p0";
        const llvm_fn = o.llvm_module.getNamedFunction(llvm_fn_name) orelse blk: {
            const fn_type = try o.builder.fnType(.ptr, &.{.i32}, .normal);
            break :blk o.llvm_module.addFunction(llvm_fn_name, fn_type.toLlvm(&o.builder));
        };

        const params = [_]*llvm.Value{Builder.Type.i32.toLlvm(&o.builder).constNull()};
        const ptr_val = self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, &params, params.len, .Fast, .Auto, "");
        const llvm_usize = (try o.lowerType(Type.usize)).toLlvm(&o.builder);
        return self.builder.buildPtrToInt(ptr_val, llvm_usize, "");
    }

    fn airFence(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const atomic_order = self.air.instructions.items(.data)[inst].fence;
        const llvm_memory_order = toLlvmAtomicOrdering(atomic_order);
        const single_threaded = llvm.Bool.fromBool(self.single_threaded);
        _ = self.builder.buildFence(llvm_memory_order, single_threaded, "");
        return null;
    }

    fn airCmpxchg(self: *FuncGen, inst: Air.Inst.Index, is_weak: bool) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const extra = self.air.extraData(Air.Cmpxchg, ty_pl.payload).data;
        const ptr = try self.resolveInst(extra.ptr);
        var expected_value = try self.resolveInst(extra.expected_value);
        var new_value = try self.resolveInst(extra.new_value);
        const operand_ty = self.typeOf(extra.ptr).childType(mod);
        const abi_ty = try o.getAtomicAbiType(operand_ty, false);
        if (abi_ty != .none) {
            const llvm_abi_ty = abi_ty.toLlvm(&o.builder);
            // operand needs widening and truncating
            if (operand_ty.isSignedInt(mod)) {
                expected_value = self.builder.buildSExt(expected_value, llvm_abi_ty, "");
                new_value = self.builder.buildSExt(new_value, llvm_abi_ty, "");
            } else {
                expected_value = self.builder.buildZExt(expected_value, llvm_abi_ty, "");
                new_value = self.builder.buildZExt(new_value, llvm_abi_ty, "");
            }
        }
        const result = self.builder.buildAtomicCmpXchg(
            ptr,
            expected_value,
            new_value,
            toLlvmAtomicOrdering(extra.successOrder()),
            toLlvmAtomicOrdering(extra.failureOrder()),
            llvm.Bool.fromBool(self.single_threaded),
        );
        result.setWeak(llvm.Bool.fromBool(is_weak));

        const optional_ty = self.typeOfIndex(inst);

        var payload = self.builder.buildExtractValue(result, 0, "");
        if (abi_ty != .none) {
            payload = self.builder.buildTrunc(payload, (try o.lowerType(operand_ty)).toLlvm(&o.builder), "");
        }
        const success_bit = self.builder.buildExtractValue(result, 1, "");

        if (optional_ty.optionalReprIsPayload(mod)) {
            return self.builder.buildSelect(success_bit, payload.typeOf().constNull(), payload, "");
        }

        comptime assert(optional_layout_version == 3);

        const non_null_bit = self.builder.buildNot(success_bit, "");
        return buildOptional(self, optional_ty, payload, non_null_bit);
    }

    fn airAtomicRmw(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const pl_op = self.air.instructions.items(.data)[inst].pl_op;
        const extra = self.air.extraData(Air.AtomicRmw, pl_op.payload).data;
        const ptr = try self.resolveInst(pl_op.operand);
        const ptr_ty = self.typeOf(pl_op.operand);
        const operand_ty = ptr_ty.childType(mod);
        const operand = try self.resolveInst(extra.operand);
        const is_signed_int = operand_ty.isSignedInt(mod);
        const is_float = operand_ty.isRuntimeFloat();
        const op = toLlvmAtomicRmwBinOp(extra.op(), is_signed_int, is_float);
        const ordering = toLlvmAtomicOrdering(extra.ordering());
        const single_threaded = llvm.Bool.fromBool(self.single_threaded);
        const abi_ty = try o.getAtomicAbiType(operand_ty, op == .Xchg);
        if (abi_ty != .none) {
            const llvm_abi_ty = abi_ty.toLlvm(&o.builder);
            // operand needs widening and truncating or bitcasting.
            const casted_operand = if (is_float)
                self.builder.buildBitCast(operand, llvm_abi_ty, "")
            else if (is_signed_int)
                self.builder.buildSExt(operand, llvm_abi_ty, "")
            else
                self.builder.buildZExt(operand, llvm_abi_ty, "");

            const uncasted_result = self.builder.buildAtomicRmw(
                op,
                ptr,
                casted_operand,
                ordering,
                single_threaded,
            );
            const operand_llvm_ty = (try o.lowerType(operand_ty)).toLlvm(&o.builder);
            if (is_float) {
                return self.builder.buildBitCast(uncasted_result, operand_llvm_ty, "");
            } else {
                return self.builder.buildTrunc(uncasted_result, operand_llvm_ty, "");
            }
        }

        if (operand.typeOf().getTypeKind() != .Pointer) {
            return self.builder.buildAtomicRmw(op, ptr, operand, ordering, single_threaded);
        }

        // It's a pointer but we need to treat it as an int.
        const usize_llvm_ty = (try o.lowerType(Type.usize)).toLlvm(&o.builder);
        const casted_operand = self.builder.buildPtrToInt(operand, usize_llvm_ty, "");
        const uncasted_result = self.builder.buildAtomicRmw(
            op,
            ptr,
            casted_operand,
            ordering,
            single_threaded,
        );
        const operand_llvm_ty = (try o.lowerType(operand_ty)).toLlvm(&o.builder);
        return self.builder.buildIntToPtr(uncasted_result, operand_llvm_ty, "");
    }

    fn airAtomicLoad(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const atomic_load = self.air.instructions.items(.data)[inst].atomic_load;
        const ptr = try self.resolveInst(atomic_load.ptr);
        const ptr_ty = self.typeOf(atomic_load.ptr);
        const ptr_info = ptr_ty.ptrInfo(mod);
        const elem_ty = ptr_info.child.toType();
        if (!elem_ty.hasRuntimeBitsIgnoreComptime(mod))
            return null;
        const ordering = toLlvmAtomicOrdering(atomic_load.order);
        const abi_ty = try o.getAtomicAbiType(elem_ty, false);
        const ptr_alignment = @as(u32, @intCast(ptr_info.flags.alignment.toByteUnitsOptional() orelse
            ptr_info.child.toType().abiAlignment(mod)));
        const ptr_volatile = llvm.Bool.fromBool(ptr_info.flags.is_volatile);
        const elem_llvm_ty = (try o.lowerType(elem_ty)).toLlvm(&o.builder);

        if (abi_ty != .none) {
            const llvm_abi_ty = abi_ty.toLlvm(&o.builder);
            // operand needs widening and truncating
            const load_inst = self.builder.buildLoad(llvm_abi_ty, ptr, "");
            load_inst.setAlignment(ptr_alignment);
            load_inst.setVolatile(ptr_volatile);
            load_inst.setOrdering(ordering);
            return self.builder.buildTrunc(load_inst, elem_llvm_ty, "");
        }
        const load_inst = self.builder.buildLoad(elem_llvm_ty, ptr, "");
        load_inst.setAlignment(ptr_alignment);
        load_inst.setVolatile(ptr_volatile);
        load_inst.setOrdering(ordering);
        return load_inst;
    }

    fn airAtomicStore(
        self: *FuncGen,
        inst: Air.Inst.Index,
        ordering: llvm.AtomicOrdering,
    ) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const ptr_ty = self.typeOf(bin_op.lhs);
        const operand_ty = ptr_ty.childType(mod);
        if (!operand_ty.isFnOrHasRuntimeBitsIgnoreComptime(mod)) return null;
        const ptr = try self.resolveInst(bin_op.lhs);
        var element = try self.resolveInst(bin_op.rhs);
        const abi_ty = try o.getAtomicAbiType(operand_ty, false);

        if (abi_ty != .none) {
            const llvm_abi_ty = abi_ty.toLlvm(&o.builder);
            // operand needs widening
            if (operand_ty.isSignedInt(mod)) {
                element = self.builder.buildSExt(element, llvm_abi_ty, "");
            } else {
                element = self.builder.buildZExt(element, llvm_abi_ty, "");
            }
        }
        try self.store(ptr, ptr_ty, element, ordering);
        return null;
    }

    fn airMemset(self: *FuncGen, inst: Air.Inst.Index, safety: bool) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const dest_slice = try self.resolveInst(bin_op.lhs);
        const ptr_ty = self.typeOf(bin_op.lhs);
        const elem_ty = self.typeOf(bin_op.rhs);
        const dest_ptr_align = ptr_ty.ptrAlignment(mod);
        const dest_ptr = self.sliceOrArrayPtr(dest_slice, ptr_ty);
        const is_volatile = ptr_ty.isVolatilePtr(mod);

        // Any WebAssembly runtime will trap when the destination pointer is out-of-bounds, regardless
        // of the length. This means we need to emit a check where we skip the memset when the length
        // is 0 as we allow for undefined pointers in 0-sized slices.
        // This logic can be removed once https://github.com/ziglang/zig/issues/16360 is done.
        const intrinsic_len0_traps = o.target.isWasm() and
            ptr_ty.isSlice(mod) and
            std.Target.wasm.featureSetHas(o.target.cpu.features, .bulk_memory);

        if (try self.air.value(bin_op.rhs, mod)) |elem_val| {
            if (elem_val.isUndefDeep(mod)) {
                // Even if safety is disabled, we still emit a memset to undefined since it conveys
                // extra information to LLVM. However, safety makes the difference between using
                // 0xaa or actual undefined for the fill byte.
                const fill_byte = if (safety)
                    (try o.builder.intConst(.i8, 0xaa)).toLlvm(&o.builder)
                else
                    Builder.Type.i8.toLlvm(&o.builder).getUndef();
                const len = try self.sliceOrArrayLenInBytes(dest_slice, ptr_ty);
                if (intrinsic_len0_traps) {
                    try self.safeWasmMemset(dest_ptr, fill_byte, len, dest_ptr_align, is_volatile);
                } else {
                    _ = self.builder.buildMemSet(dest_ptr, fill_byte, len, dest_ptr_align, is_volatile);
                }

                if (safety and mod.comp.bin_file.options.valgrind) {
                    try self.valgrindMarkUndef(dest_ptr, len);
                }
                return null;
            }

            // Test if the element value is compile-time known to be a
            // repeating byte pattern, for example, `@as(u64, 0)` has a
            // repeating byte pattern of 0 bytes. In such case, the memset
            // intrinsic can be used.
            if (try elem_val.hasRepeatedByteRepr(elem_ty, mod)) |byte_val| {
                const fill_byte = try self.resolveValue(.{
                    .ty = Type.u8,
                    .val = byte_val,
                });
                const len = try self.sliceOrArrayLenInBytes(dest_slice, ptr_ty);

                if (intrinsic_len0_traps) {
                    try self.safeWasmMemset(dest_ptr, fill_byte, len, dest_ptr_align, is_volatile);
                } else {
                    _ = self.builder.buildMemSet(dest_ptr, fill_byte, len, dest_ptr_align, is_volatile);
                }
                return null;
            }
        }

        const value = try self.resolveInst(bin_op.rhs);
        const elem_abi_size = elem_ty.abiSize(mod);

        if (elem_abi_size == 1) {
            // In this case we can take advantage of LLVM's intrinsic.
            const fill_byte = try self.bitCast(value, elem_ty, Type.u8);
            const len = try self.sliceOrArrayLenInBytes(dest_slice, ptr_ty);

            if (intrinsic_len0_traps) {
                try self.safeWasmMemset(dest_ptr, fill_byte, len, dest_ptr_align, is_volatile);
            } else {
                _ = self.builder.buildMemSet(dest_ptr, fill_byte, len, dest_ptr_align, is_volatile);
            }
            return null;
        }

        // non-byte-sized element. lower with a loop. something like this:

        // entry:
        //   ...
        //   %end_ptr = getelementptr %ptr, %len
        //   br loop
        // loop:
        //   %it_ptr = phi body %next_ptr, entry %ptr
        //   %end = cmp eq %it_ptr, %end_ptr
        //   cond_br %end body, end
        // body:
        //   store %it_ptr, %value
        //   %next_ptr = getelementptr %it_ptr, 1
        //   br loop
        // end:
        //   ...
        const entry_block = self.builder.getInsertBlock();
        const loop_block = self.context.appendBasicBlock(self.llvm_func, "InlineMemsetLoop");
        const body_block = self.context.appendBasicBlock(self.llvm_func, "InlineMemsetBody");
        const end_block = self.context.appendBasicBlock(self.llvm_func, "InlineMemsetEnd");

        const usize_ty = try o.lowerType(Type.usize);
        const len = switch (ptr_ty.ptrSize(mod)) {
            .Slice => self.builder.buildExtractValue(dest_slice, 1, ""),
            .One => (try o.builder.intConst(usize_ty, ptr_ty.childType(mod).arrayLen(mod))).toLlvm(&o.builder),
            .Many, .C => unreachable,
        };
        const elem_llvm_ty = (try o.lowerType(elem_ty)).toLlvm(&o.builder);
        const len_gep = [_]*llvm.Value{len};
        const end_ptr = self.builder.buildInBoundsGEP(elem_llvm_ty, dest_ptr, &len_gep, len_gep.len, "");
        _ = self.builder.buildBr(loop_block);

        self.builder.positionBuilderAtEnd(loop_block);
        const it_ptr = self.builder.buildPhi(self.context.pointerType(0), "");
        const end = self.builder.buildICmp(.NE, it_ptr, end_ptr, "");
        _ = self.builder.buildCondBr(end, body_block, end_block);

        self.builder.positionBuilderAtEnd(body_block);
        const elem_abi_alignment = elem_ty.abiAlignment(mod);
        const it_ptr_alignment = @min(elem_abi_alignment, dest_ptr_align);
        if (isByRef(elem_ty, mod)) {
            _ = self.builder.buildMemCpy(
                it_ptr,
                it_ptr_alignment,
                value,
                elem_abi_alignment,
                (try o.builder.intConst(usize_ty, elem_abi_size)).toLlvm(&o.builder),
                is_volatile,
            );
        } else {
            const store_inst = self.builder.buildStore(value, it_ptr);
            store_inst.setAlignment(it_ptr_alignment);
            store_inst.setVolatile(llvm.Bool.fromBool(is_volatile));
        }
        const one_gep = [_]*llvm.Value{
            (try o.builder.intConst(usize_ty, 1)).toLlvm(&o.builder),
        };
        const next_ptr = self.builder.buildInBoundsGEP(elem_llvm_ty, it_ptr, &one_gep, one_gep.len, "");
        _ = self.builder.buildBr(loop_block);

        self.builder.positionBuilderAtEnd(end_block);

        const incoming_values: [2]*llvm.Value = .{ next_ptr, dest_ptr };
        const incoming_blocks: [2]*llvm.BasicBlock = .{ body_block, entry_block };
        it_ptr.addIncoming(&incoming_values, &incoming_blocks, 2);

        return null;
    }

    fn safeWasmMemset(
        self: *FuncGen,
        dest_ptr: *llvm.Value,
        fill_byte: *llvm.Value,
        len: *llvm.Value,
        dest_ptr_align: u32,
        is_volatile: bool,
    ) !void {
        const llvm_usize_ty = self.context.intType(self.dg.object.target.ptrBitWidth());
        const cond = try self.cmp(len, llvm_usize_ty.constInt(0, .False), Type.usize, .neq);
        const memset_block = self.context.appendBasicBlock(self.llvm_func, "MemsetTrapSkip");
        const end_block = self.context.appendBasicBlock(self.llvm_func, "MemsetTrapEnd");
        _ = self.builder.buildCondBr(cond, memset_block, end_block);
        self.builder.positionBuilderAtEnd(memset_block);
        _ = self.builder.buildMemSet(dest_ptr, fill_byte, len, dest_ptr_align, is_volatile);
        _ = self.builder.buildBr(end_block);
        self.builder.positionBuilderAtEnd(end_block);
    }

    fn airMemcpy(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const dest_slice = try self.resolveInst(bin_op.lhs);
        const dest_ptr_ty = self.typeOf(bin_op.lhs);
        const src_slice = try self.resolveInst(bin_op.rhs);
        const src_ptr_ty = self.typeOf(bin_op.rhs);
        const src_ptr = self.sliceOrArrayPtr(src_slice, src_ptr_ty);
        const len = try self.sliceOrArrayLenInBytes(dest_slice, dest_ptr_ty);
        const dest_ptr = self.sliceOrArrayPtr(dest_slice, dest_ptr_ty);
        const is_volatile = src_ptr_ty.isVolatilePtr(mod) or dest_ptr_ty.isVolatilePtr(mod);

        // When bulk-memory is enabled, this will be lowered to WebAssembly's memory.copy instruction.
        // This instruction will trap on an invalid address, regardless of the length.
        // For this reason we must add a check for 0-sized slices as its pointer field can be undefined.
        // We only have to do this for slices as arrays will have a valid pointer.
        // This logic can be removed once https://github.com/ziglang/zig/issues/16360 is done.
        if (o.target.isWasm() and
            std.Target.wasm.featureSetHas(o.target.cpu.features, .bulk_memory) and
            dest_ptr_ty.isSlice(mod))
        {
            const llvm_usize_ty = self.context.intType(self.dg.object.target.ptrBitWidth());
            const cond = try self.cmp(len, llvm_usize_ty.constInt(0, .False), Type.usize, .neq);
            const memcpy_block = self.context.appendBasicBlock(self.llvm_func, "MemcpyTrapSkip");
            const end_block = self.context.appendBasicBlock(self.llvm_func, "MemcpyTrapEnd");
            _ = self.builder.buildCondBr(cond, memcpy_block, end_block);
            self.builder.positionBuilderAtEnd(memcpy_block);
            _ = self.builder.buildMemCpy(
                dest_ptr,
                dest_ptr_ty.ptrAlignment(mod),
                src_ptr,
                src_ptr_ty.ptrAlignment(mod),
                len,
                is_volatile,
            );
            _ = self.builder.buildBr(end_block);
            self.builder.positionBuilderAtEnd(end_block);
            return null;
        }

        _ = self.builder.buildMemCpy(
            dest_ptr,
            dest_ptr_ty.ptrAlignment(mod),
            src_ptr,
            src_ptr_ty.ptrAlignment(mod),
            len,
            is_volatile,
        );
        return null;
    }

    fn airSetUnionTag(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const un_ty = self.typeOf(bin_op.lhs).childType(mod);
        const layout = un_ty.unionGetLayout(mod);
        if (layout.tag_size == 0) return null;
        const union_ptr = try self.resolveInst(bin_op.lhs);
        const new_tag = try self.resolveInst(bin_op.rhs);
        if (layout.payload_size == 0) {
            // TODO alignment on this store
            _ = self.builder.buildStore(new_tag, union_ptr);
            return null;
        }
        const un_llvm_ty = (try o.lowerType(un_ty)).toLlvm(&o.builder);
        const tag_index = @intFromBool(layout.tag_align < layout.payload_align);
        const tag_field_ptr = self.builder.buildStructGEP(un_llvm_ty, union_ptr, tag_index, "");
        // TODO alignment on this store
        _ = self.builder.buildStore(new_tag, tag_field_ptr);
        return null;
    }

    fn airGetUnionTag(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const un_ty = self.typeOf(ty_op.operand);
        const layout = un_ty.unionGetLayout(mod);
        if (layout.tag_size == 0) return null;
        const union_handle = try self.resolveInst(ty_op.operand);
        if (isByRef(un_ty, mod)) {
            const llvm_un_ty = (try o.lowerType(un_ty)).toLlvm(&o.builder);
            if (layout.payload_size == 0) {
                return self.builder.buildLoad(llvm_un_ty, union_handle, "");
            }
            const tag_index = @intFromBool(layout.tag_align < layout.payload_align);
            const tag_field_ptr = self.builder.buildStructGEP(llvm_un_ty, union_handle, tag_index, "");
            return self.builder.buildLoad(llvm_un_ty.structGetTypeAtIndex(tag_index), tag_field_ptr, "");
        } else {
            if (layout.payload_size == 0) {
                return union_handle;
            }
            const tag_index = @intFromBool(layout.tag_align < layout.payload_align);
            return self.builder.buildExtractValue(union_handle, tag_index, "");
        }
    }

    fn airUnaryOp(self: *FuncGen, inst: Air.Inst.Index, comptime op: FloatOp) !?*llvm.Value {
        const un_op = self.air.instructions.items(.data)[inst].un_op;
        const operand = try self.resolveInst(un_op);
        const operand_ty = self.typeOf(un_op);

        return self.buildFloatOp(op, operand_ty, 1, .{operand});
    }

    fn airNeg(self: *FuncGen, inst: Air.Inst.Index, want_fast_math: bool) !?*llvm.Value {
        self.builder.setFastMath(want_fast_math);

        const un_op = self.air.instructions.items(.data)[inst].un_op;
        const operand = try self.resolveInst(un_op);
        const operand_ty = self.typeOf(un_op);

        return self.buildFloatOp(.neg, operand_ty, 1, .{operand});
    }

    fn airClzCtz(self: *FuncGen, inst: Air.Inst.Index, llvm_fn_name: []const u8) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand_ty = self.typeOf(ty_op.operand);
        const operand = try self.resolveInst(ty_op.operand);

        const llvm_i1 = Builder.Type.i1.toLlvm(&o.builder);
        const fn_val = try self.getIntrinsic(llvm_fn_name, &.{try o.lowerType(operand_ty)});

        const params = [_]*llvm.Value{ operand, llvm_i1.constNull() };
        const wrong_size_result = self.builder.buildCall(fn_val.globalGetValueType(), fn_val, &params, params.len, .C, .Auto, "");
        const result_ty = self.typeOfIndex(inst);
        const result_llvm_ty = (try o.lowerType(result_ty)).toLlvm(&o.builder);

        const bits = operand_ty.intInfo(mod).bits;
        const result_bits = result_ty.intInfo(mod).bits;
        if (bits > result_bits) {
            return self.builder.buildTrunc(wrong_size_result, result_llvm_ty, "");
        } else if (bits < result_bits) {
            return self.builder.buildZExt(wrong_size_result, result_llvm_ty, "");
        } else {
            return wrong_size_result;
        }
    }

    fn airBitOp(self: *FuncGen, inst: Air.Inst.Index, llvm_fn_name: []const u8) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand_ty = self.typeOf(ty_op.operand);
        const operand = try self.resolveInst(ty_op.operand);

        const params = [_]*llvm.Value{operand};
        const fn_val = try self.getIntrinsic(llvm_fn_name, &.{try o.lowerType(operand_ty)});

        const wrong_size_result = self.builder.buildCall(fn_val.globalGetValueType(), fn_val, &params, params.len, .C, .Auto, "");
        const result_ty = self.typeOfIndex(inst);
        const result_llvm_ty = (try o.lowerType(result_ty)).toLlvm(&o.builder);

        const bits = operand_ty.intInfo(mod).bits;
        const result_bits = result_ty.intInfo(mod).bits;
        if (bits > result_bits) {
            return self.builder.buildTrunc(wrong_size_result, result_llvm_ty, "");
        } else if (bits < result_bits) {
            return self.builder.buildZExt(wrong_size_result, result_llvm_ty, "");
        } else {
            return wrong_size_result;
        }
    }

    fn airByteSwap(self: *FuncGen, inst: Air.Inst.Index, llvm_fn_name: []const u8) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand_ty = self.typeOf(ty_op.operand);
        var bits = operand_ty.intInfo(mod).bits;
        assert(bits % 8 == 0);

        var operand = try self.resolveInst(ty_op.operand);
        var operand_llvm_ty = try o.lowerType(operand_ty);

        if (bits % 16 == 8) {
            // If not an even byte-multiple, we need zero-extend + shift-left 1 byte
            // The truncated result at the end will be the correct bswap
            const scalar_ty = try o.builder.intType(@intCast(bits + 8));
            if (operand_ty.zigTypeTag(mod) == .Vector) {
                const vec_len = operand_ty.vectorLen(mod);
                operand_llvm_ty = try o.builder.vectorType(.normal, vec_len, scalar_ty);

                const shifts = try self.gpa.alloc(*llvm.Value, vec_len);
                defer self.gpa.free(shifts);
                @memset(shifts, (try o.builder.intConst(scalar_ty, 8)).toLlvm(&o.builder));
                const shift_vec = llvm.constVector(shifts.ptr, vec_len);

                const extended = self.builder.buildZExt(operand, operand_llvm_ty.toLlvm(&o.builder), "");
                operand = self.builder.buildShl(extended, shift_vec, "");
            } else {
                const extended = self.builder.buildZExt(operand, scalar_ty.toLlvm(&o.builder), "");
                operand = self.builder.buildShl(extended, (try o.builder.intConst(scalar_ty, 8)).toLlvm(&o.builder), "");
                operand_llvm_ty = scalar_ty;
            }
            bits = bits + 8;
        }

        const params = [_]*llvm.Value{operand};
        const fn_val = try self.getIntrinsic(llvm_fn_name, &.{operand_llvm_ty});

        const wrong_size_result = self.builder.buildCall(fn_val.globalGetValueType(), fn_val, &params, params.len, .C, .Auto, "");

        const result_ty = self.typeOfIndex(inst);
        const result_llvm_ty = (try o.lowerType(result_ty)).toLlvm(&o.builder);
        const result_bits = result_ty.intInfo(mod).bits;
        if (bits > result_bits) {
            return self.builder.buildTrunc(wrong_size_result, result_llvm_ty, "");
        } else if (bits < result_bits) {
            return self.builder.buildZExt(wrong_size_result, result_llvm_ty, "");
        } else {
            return wrong_size_result;
        }
    }

    fn airErrorSetHasValue(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);
        const error_set_ty = self.air.getRefType(ty_op.ty);

        const names = error_set_ty.errorSetNames(mod);
        const valid_block = self.context.appendBasicBlock(self.llvm_func, "Valid");
        const invalid_block = self.context.appendBasicBlock(self.llvm_func, "Invalid");
        const end_block = self.context.appendBasicBlock(self.llvm_func, "End");
        const switch_instr = self.builder.buildSwitch(operand, invalid_block, @as(c_uint, @intCast(names.len)));

        for (names) |name| {
            const err_int = @as(Module.ErrorInt, @intCast(mod.global_error_set.getIndex(name).?));
            const this_tag_int_value = try o.lowerValue(.{
                .ty = Type.err_int,
                .val = try mod.intValue(Type.err_int, err_int),
            });
            switch_instr.addCase(this_tag_int_value, valid_block);
        }
        self.builder.positionBuilderAtEnd(valid_block);
        _ = self.builder.buildBr(end_block);

        self.builder.positionBuilderAtEnd(invalid_block);
        _ = self.builder.buildBr(end_block);

        self.builder.positionBuilderAtEnd(end_block);

        const incoming_values: [2]*llvm.Value = .{
            Builder.Constant.true.toLlvm(&o.builder),
            Builder.Constant.false.toLlvm(&o.builder),
        };
        const incoming_blocks: [2]*llvm.BasicBlock = .{
            valid_block, invalid_block,
        };
        const phi_node = self.builder.buildPhi(Builder.Type.i1.toLlvm(&o.builder), "");
        phi_node.addIncoming(&incoming_values, &incoming_blocks, 2);
        return phi_node;
    }

    fn airIsNamedEnumValue(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const un_op = self.air.instructions.items(.data)[inst].un_op;
        const operand = try self.resolveInst(un_op);
        const enum_ty = self.typeOf(un_op);

        const llvm_fn = try self.getIsNamedEnumValueFunction(enum_ty);
        const params = [_]*llvm.Value{operand};
        return self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, &params, params.len, .Fast, .Auto, "");
    }

    fn getIsNamedEnumValueFunction(self: *FuncGen, enum_ty: Type) !*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const enum_type = mod.intern_pool.indexToKey(enum_ty.toIntern()).enum_type;

        // TODO: detect when the type changes and re-emit this function.
        const gop = try o.named_enum_map.getOrPut(o.gpa, enum_type.decl);
        if (gop.found_existing) return gop.value_ptr.toLlvm(&o.builder);
        errdefer assert(o.named_enum_map.remove(enum_type.decl));

        const fqn = try mod.declPtr(enum_type.decl).getFullyQualifiedName(mod);
        const llvm_fn_name = try o.builder.fmt("__zig_is_named_enum_value_{}", .{
            fqn.fmt(&mod.intern_pool),
        });

        const fn_type = try o.builder.fnType(.i1, &.{try o.lowerType(
            enum_type.tag_ty.toType(),
        )}, .normal);
        const fn_val = o.llvm_module.addFunction(llvm_fn_name.toSlice(&o.builder).?, fn_type.toLlvm(&o.builder));
        fn_val.setLinkage(.Internal);
        fn_val.setFunctionCallConv(.Fast);
        o.addCommonFnAttributes(fn_val);

        var global = Builder.Global{
            .linkage = .internal,
            .type = fn_type,
            .kind = .{ .function = @enumFromInt(o.builder.functions.items.len) },
        };
        var function = Builder.Function{
            .global = @enumFromInt(o.builder.globals.count()),
        };

        const prev_block = self.builder.getInsertBlock();
        const prev_debug_location = self.builder.getCurrentDebugLocation2();
        defer {
            self.builder.positionBuilderAtEnd(prev_block);
            if (self.di_scope != null) {
                self.builder.setCurrentDebugLocation2(prev_debug_location);
            }
        }

        const entry_block = self.context.appendBasicBlock(fn_val, "Entry");
        self.builder.positionBuilderAtEnd(entry_block);
        self.builder.clearCurrentDebugLocation();

        const named_block = self.context.appendBasicBlock(fn_val, "Named");
        const unnamed_block = self.context.appendBasicBlock(fn_val, "Unnamed");
        const tag_int_value = fn_val.getParam(0);
        const switch_instr = self.builder.buildSwitch(tag_int_value, unnamed_block, @as(c_uint, @intCast(enum_type.names.len)));

        for (enum_type.names, 0..) |_, field_index_usize| {
            const field_index = @as(u32, @intCast(field_index_usize));
            const this_tag_int_value = int: {
                break :int try o.lowerValue(.{
                    .ty = enum_ty,
                    .val = try mod.enumValueFieldIndex(enum_ty, field_index),
                });
            };
            switch_instr.addCase(this_tag_int_value, named_block);
        }
        self.builder.positionBuilderAtEnd(named_block);
        _ = self.builder.buildRet(Builder.Constant.true.toLlvm(&o.builder));

        self.builder.positionBuilderAtEnd(unnamed_block);
        _ = self.builder.buildRet(Builder.Constant.false.toLlvm(&o.builder));

        try o.builder.llvm_globals.append(self.gpa, fn_val);
        _ = try o.builder.addGlobal(llvm_fn_name, global);
        try o.builder.functions.append(self.gpa, function);
        gop.value_ptr.* = global.kind.function;
        return fn_val;
    }

    fn airTagName(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const un_op = self.air.instructions.items(.data)[inst].un_op;
        const operand = try self.resolveInst(un_op);
        const enum_ty = self.typeOf(un_op);

        const llvm_fn = try self.getEnumTagNameFunction(enum_ty);
        const params = [_]*llvm.Value{operand};
        return self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, &params, params.len, .Fast, .Auto, "");
    }

    fn getEnumTagNameFunction(self: *FuncGen, enum_ty: Type) !*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const enum_type = mod.intern_pool.indexToKey(enum_ty.toIntern()).enum_type;

        // TODO: detect when the type changes and re-emit this function.
        const gop = try o.decl_map.getOrPut(o.gpa, enum_type.decl);
        if (gop.found_existing) return gop.value_ptr.toLlvm(&o.builder);
        errdefer assert(o.decl_map.remove(enum_type.decl));

        const fqn = try mod.declPtr(enum_type.decl).getFullyQualifiedName(mod);
        const llvm_fn_name = try o.builder.fmt("__zig_tag_name_{}", .{fqn.fmt(&mod.intern_pool)});

        const slice_ty = Type.slice_const_u8_sentinel_0;
        const ret_ty = try o.lowerType(slice_ty);
        const llvm_ret_ty = ret_ty.toLlvm(&o.builder);
        const usize_ty = try o.lowerType(Type.usize);
        const slice_alignment = slice_ty.abiAlignment(mod);

        const fn_type = try o.builder.fnType(ret_ty, &.{
            try o.lowerType(enum_type.tag_ty.toType()),
        }, .normal);
        const fn_val = o.llvm_module.addFunction(llvm_fn_name.toSlice(&o.builder).?, fn_type.toLlvm(&o.builder));
        fn_val.setLinkage(.Internal);
        fn_val.setFunctionCallConv(.Fast);
        o.addCommonFnAttributes(fn_val);

        var global = Builder.Global{
            .linkage = .internal,
            .type = fn_type,
            .kind = .{ .function = @enumFromInt(o.builder.functions.items.len) },
        };
        var function = Builder.Function{
            .global = @enumFromInt(o.builder.globals.count()),
        };

        const prev_block = self.builder.getInsertBlock();
        const prev_debug_location = self.builder.getCurrentDebugLocation2();
        defer {
            self.builder.positionBuilderAtEnd(prev_block);
            if (self.di_scope != null) {
                self.builder.setCurrentDebugLocation2(prev_debug_location);
            }
        }

        const entry_block = self.context.appendBasicBlock(fn_val, "Entry");
        self.builder.positionBuilderAtEnd(entry_block);
        self.builder.clearCurrentDebugLocation();

        const bad_value_block = self.context.appendBasicBlock(fn_val, "BadValue");
        const tag_int_value = fn_val.getParam(0);
        const switch_instr = self.builder.buildSwitch(tag_int_value, bad_value_block, @as(c_uint, @intCast(enum_type.names.len)));

        const array_ptr_indices: [2]*llvm.Value = .{
            (try o.builder.intConst(usize_ty, 0)).toLlvm(&o.builder),
        } ** 2;

        for (enum_type.names, 0..) |name_ip, field_index_usize| {
            const field_index = @as(u32, @intCast(field_index_usize));
            const name = mod.intern_pool.stringToSlice(name_ip);
            const str_init = self.context.constString(name.ptr, @as(c_uint, @intCast(name.len)), .False);
            const str_init_llvm_ty = str_init.typeOf();
            const str_global = o.llvm_module.addGlobal(str_init_llvm_ty, "");
            str_global.setInitializer(str_init);
            str_global.setLinkage(.Private);
            str_global.setGlobalConstant(.True);
            str_global.setUnnamedAddr(.True);
            str_global.setAlignment(1);

            const slice_fields = [_]*llvm.Value{
                str_init_llvm_ty.constInBoundsGEP(str_global, &array_ptr_indices, array_ptr_indices.len),
                (try o.builder.intConst(usize_ty, name.len)).toLlvm(&o.builder),
            };
            const slice_init = llvm_ret_ty.constNamedStruct(&slice_fields, slice_fields.len);
            const slice_global = o.llvm_module.addGlobal(slice_init.typeOf(), "");
            slice_global.setInitializer(slice_init);
            slice_global.setLinkage(.Private);
            slice_global.setGlobalConstant(.True);
            slice_global.setUnnamedAddr(.True);
            slice_global.setAlignment(slice_alignment);

            const return_block = self.context.appendBasicBlock(fn_val, "Name");
            const this_tag_int_value = try o.lowerValue(.{
                .ty = enum_ty,
                .val = try mod.enumValueFieldIndex(enum_ty, field_index),
            });
            switch_instr.addCase(this_tag_int_value, return_block);

            self.builder.positionBuilderAtEnd(return_block);
            const loaded = self.builder.buildLoad(llvm_ret_ty, slice_global, "");
            loaded.setAlignment(slice_alignment);
            _ = self.builder.buildRet(loaded);
        }

        self.builder.positionBuilderAtEnd(bad_value_block);
        _ = self.builder.buildUnreachable();

        try o.builder.llvm_globals.append(self.gpa, fn_val);
        gop.value_ptr.* = try o.builder.addGlobal(llvm_fn_name, global);
        try o.builder.functions.append(self.gpa, function);
        return fn_val;
    }

    fn getCmpLtErrorsLenFunction(self: *FuncGen) !*llvm.Value {
        const o = self.dg.object;

        if (o.llvm_module.getNamedFunction(lt_errors_fn_name)) |llvm_fn| {
            return llvm_fn;
        }

        // Function signature: fn (anyerror) bool

        const fn_type = try o.builder.fnType(.i1, &.{Builder.Type.err_int}, .normal);
        const llvm_fn = o.llvm_module.addFunction(lt_errors_fn_name, fn_type.toLlvm(&o.builder));

        var global = Builder.Global{
            .type = fn_type,
            .kind = .{ .function = @enumFromInt(o.builder.functions.items.len) },
        };
        var function = Builder.Function{
            .global = @enumFromInt(o.builder.globals.count()),
        };

        llvm_fn.setLinkage(.Internal);
        llvm_fn.setFunctionCallConv(.Fast);
        o.addCommonFnAttributes(llvm_fn);

        try o.builder.llvm_globals.append(self.gpa, llvm_fn);
        _ = try o.builder.addGlobal(try o.builder.string(lt_errors_fn_name), global);
        try o.builder.functions.append(self.gpa, function);
        return llvm_fn;
    }

    fn airErrorName(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const un_op = self.air.instructions.items(.data)[inst].un_op;
        const operand = try self.resolveInst(un_op);
        const slice_ty = self.typeOfIndex(inst);
        const slice_llvm_ty = (try o.lowerType(slice_ty)).toLlvm(&o.builder);

        const error_name_table_ptr = try self.getErrorNameTable();
        const ptr_slice_llvm_ty = self.context.pointerType(0);
        const error_name_table = self.builder.buildLoad(ptr_slice_llvm_ty, error_name_table_ptr, "");
        const indices = [_]*llvm.Value{operand};
        const error_name_ptr = self.builder.buildInBoundsGEP(slice_llvm_ty, error_name_table, &indices, indices.len, "");
        return self.builder.buildLoad(slice_llvm_ty, error_name_ptr, "");
    }

    fn airSplat(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const scalar = try self.resolveInst(ty_op.operand);
        const vector_ty = self.typeOfIndex(inst);
        const len = vector_ty.vectorLen(mod);
        return self.builder.buildVectorSplat(len, scalar, "");
    }

    fn airSelect(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const pl_op = self.air.instructions.items(.data)[inst].pl_op;
        const extra = self.air.extraData(Air.Bin, pl_op.payload).data;
        const pred = try self.resolveInst(pl_op.operand);
        const a = try self.resolveInst(extra.lhs);
        const b = try self.resolveInst(extra.rhs);

        return self.builder.buildSelect(pred, a, b, "");
    }

    fn airShuffle(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const extra = self.air.extraData(Air.Shuffle, ty_pl.payload).data;
        const a = try self.resolveInst(extra.a);
        const b = try self.resolveInst(extra.b);
        const mask = extra.mask.toValue();
        const mask_len = extra.mask_len;
        const a_len = self.typeOf(extra.a).vectorLen(mod);

        // LLVM uses integers larger than the length of the first array to
        // index into the second array. This was deemed unnecessarily fragile
        // when changing code, so Zig uses negative numbers to index the
        // second vector. These start at -1 and go down, and are easiest to use
        // with the ~ operator. Here we convert between the two formats.
        const values = try self.gpa.alloc(*llvm.Value, mask_len);
        defer self.gpa.free(values);

        for (values, 0..) |*val, i| {
            const elem = try mask.elemValue(mod, i);
            if (elem.isUndef(mod)) {
                val.* = Builder.Type.i32.toLlvm(&o.builder).getUndef();
            } else {
                const int = elem.toSignedInt(mod);
                const unsigned = if (int >= 0) @as(u32, @intCast(int)) else @as(u32, @intCast(~int + a_len));
                val.* = (try o.builder.intConst(.i32, unsigned)).toLlvm(&o.builder);
            }
        }

        const llvm_mask_value = llvm.constVector(values.ptr, mask_len);
        return self.builder.buildShuffleVector(a, b, llvm_mask_value, "");
    }

    /// Reduce a vector by repeatedly applying `llvm_fn` to produce an accumulated result.
    ///
    /// Equivalent to:
    ///   reduce: {
    ///     var i: usize = 0;
    ///     var accum: T = init;
    ///     while (i < vec.len) : (i += 1) {
    ///       accum = llvm_fn(accum, vec[i]);
    ///     }
    ///     break :reduce accum;
    ///   }
    ///
    fn buildReducedCall(
        self: *FuncGen,
        llvm_fn: *llvm.Value,
        operand_vector: *llvm.Value,
        vector_len: usize,
        accum_init: *llvm.Value,
    ) !*llvm.Value {
        const o = self.dg.object;
        const usize_ty = try o.lowerType(Type.usize);
        const llvm_vector_len = try o.builder.intConst(usize_ty, vector_len);
        const llvm_result_ty = accum_init.typeOf();

        // Allocate and initialize our mutable variables
        const i_ptr = try self.buildAlloca(usize_ty.toLlvm(&o.builder), null);
        _ = self.builder.buildStore((try o.builder.intConst(usize_ty, 0)).toLlvm(&o.builder), i_ptr);
        const accum_ptr = try self.buildAlloca(llvm_result_ty, null);
        _ = self.builder.buildStore(accum_init, accum_ptr);

        // Setup the loop
        const loop = self.context.appendBasicBlock(self.llvm_func, "ReduceLoop");
        const loop_exit = self.context.appendBasicBlock(self.llvm_func, "AfterReduce");
        _ = self.builder.buildBr(loop);
        {
            self.builder.positionBuilderAtEnd(loop);

            // while (i < vec.len)
            const i = self.builder.buildLoad(usize_ty.toLlvm(&o.builder), i_ptr, "");
            const cond = self.builder.buildICmp(.ULT, i, llvm_vector_len.toLlvm(&o.builder), "");
            const loop_then = self.context.appendBasicBlock(self.llvm_func, "ReduceLoopThen");

            _ = self.builder.buildCondBr(cond, loop_then, loop_exit);

            {
                self.builder.positionBuilderAtEnd(loop_then);

                // accum = f(accum, vec[i]);
                const accum = self.builder.buildLoad(llvm_result_ty, accum_ptr, "");
                const element = self.builder.buildExtractElement(operand_vector, i, "");
                const params = [2]*llvm.Value{ accum, element };
                const new_accum = self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, &params, params.len, .C, .Auto, "");
                _ = self.builder.buildStore(new_accum, accum_ptr);

                // i += 1
                const new_i = self.builder.buildAdd(i, (try o.builder.intConst(usize_ty, 1)).toLlvm(&o.builder), "");
                _ = self.builder.buildStore(new_i, i_ptr);
                _ = self.builder.buildBr(loop);
            }
        }

        self.builder.positionBuilderAtEnd(loop_exit);
        return self.builder.buildLoad(llvm_result_ty, accum_ptr, "");
    }

    fn airReduce(self: *FuncGen, inst: Air.Inst.Index, want_fast_math: bool) !?*llvm.Value {
        self.builder.setFastMath(want_fast_math);
        const o = self.dg.object;
        const mod = o.module;
        const target = mod.getTarget();

        const reduce = self.air.instructions.items(.data)[inst].reduce;
        const operand = try self.resolveInst(reduce.operand);
        const operand_ty = self.typeOf(reduce.operand);
        const scalar_ty = self.typeOfIndex(inst);

        switch (reduce.operation) {
            .And => return self.builder.buildAndReduce(operand),
            .Or => return self.builder.buildOrReduce(operand),
            .Xor => return self.builder.buildXorReduce(operand),
            .Min => switch (scalar_ty.zigTypeTag(mod)) {
                .Int => return self.builder.buildIntMinReduce(operand, scalar_ty.isSignedInt(mod)),
                .Float => if (intrinsicsAllowed(scalar_ty, target)) {
                    return self.builder.buildFPMinReduce(operand);
                },
                else => unreachable,
            },
            .Max => switch (scalar_ty.zigTypeTag(mod)) {
                .Int => return self.builder.buildIntMaxReduce(operand, scalar_ty.isSignedInt(mod)),
                .Float => if (intrinsicsAllowed(scalar_ty, target)) {
                    return self.builder.buildFPMaxReduce(operand);
                },
                else => unreachable,
            },
            .Add => switch (scalar_ty.zigTypeTag(mod)) {
                .Int => return self.builder.buildAddReduce(operand),
                .Float => if (intrinsicsAllowed(scalar_ty, target)) {
                    const scalar_llvm_ty = (try o.lowerType(scalar_ty)).toLlvm(&o.builder);
                    const neutral_value = scalar_llvm_ty.constReal(-0.0);
                    return self.builder.buildFPAddReduce(neutral_value, operand);
                },
                else => unreachable,
            },
            .Mul => switch (scalar_ty.zigTypeTag(mod)) {
                .Int => return self.builder.buildMulReduce(operand),
                .Float => if (intrinsicsAllowed(scalar_ty, target)) {
                    const scalar_llvm_ty = (try o.lowerType(scalar_ty)).toLlvm(&o.builder);
                    const neutral_value = scalar_llvm_ty.constReal(1.0);
                    return self.builder.buildFPMulReduce(neutral_value, operand);
                },
                else => unreachable,
            },
        }

        // Reduction could not be performed with intrinsics.
        // Use a manual loop over a softfloat call instead.
        const float_bits = scalar_ty.floatBits(target);
        const fn_name = switch (reduce.operation) {
            .Min => try o.builder.fmt("{s}fmin{s}", .{
                libcFloatPrefix(float_bits), libcFloatSuffix(float_bits),
            }),
            .Max => try o.builder.fmt("{s}fmax{s}", .{
                libcFloatPrefix(float_bits), libcFloatSuffix(float_bits),
            }),
            .Add => try o.builder.fmt("__add{s}f3", .{
                compilerRtFloatAbbrev(float_bits),
            }),
            .Mul => try o.builder.fmt("__mul{s}f3", .{
                compilerRtFloatAbbrev(float_bits),
            }),
            else => unreachable,
        };

        const param_llvm_ty = try o.lowerType(scalar_ty);
        const libc_fn = try self.getLibcFunction(fn_name, &(.{param_llvm_ty} ** 2), param_llvm_ty);
        const init_value = try o.lowerValue(.{
            .ty = scalar_ty,
            .val = try mod.floatValue(scalar_ty, switch (reduce.operation) {
                .Min => std.math.nan(f32),
                .Max => std.math.nan(f32),
                .Add => -0.0,
                .Mul => 1.0,
                else => unreachable,
            }),
        });
        return self.buildReducedCall(libc_fn, operand, operand_ty.vectorLen(mod), init_value);
    }

    fn airAggregateInit(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const result_ty = self.typeOfIndex(inst);
        const len = @as(usize, @intCast(result_ty.arrayLen(mod)));
        const elements = @as([]const Air.Inst.Ref, @ptrCast(self.air.extra[ty_pl.payload..][0..len]));
        const llvm_result_ty = (try o.lowerType(result_ty)).toLlvm(&o.builder);

        switch (result_ty.zigTypeTag(mod)) {
            .Vector => {
                var vector = llvm_result_ty.getUndef();
                for (elements, 0..) |elem, i| {
                    const index_u32 = try o.builder.intConst(.i32, i);
                    const llvm_elem = try self.resolveInst(elem);
                    vector = self.builder.buildInsertElement(vector, llvm_elem, index_u32.toLlvm(&o.builder), "");
                }
                return vector;
            },
            .Struct => {
                if (result_ty.containerLayout(mod) == .Packed) {
                    const struct_obj = mod.typeToStruct(result_ty).?;
                    assert(struct_obj.haveLayout());
                    const big_bits = struct_obj.backing_int_ty.bitSize(mod);
                    const int_ty = try o.builder.intType(@intCast(big_bits));
                    const fields = struct_obj.fields.values();
                    comptime assert(Type.packed_struct_layout_version == 2);
                    var running_int = (try o.builder.intConst(int_ty, 0)).toLlvm(&o.builder);
                    var running_bits: u16 = 0;
                    for (elements, 0..) |elem, i| {
                        const field = fields[i];
                        if (!field.ty.hasRuntimeBitsIgnoreComptime(mod)) continue;

                        const non_int_val = try self.resolveInst(elem);
                        const ty_bit_size = @as(u16, @intCast(field.ty.bitSize(mod)));
                        const small_int_ty = (try o.builder.intType(@intCast(ty_bit_size))).toLlvm(&o.builder);
                        const small_int_val = if (field.ty.isPtrAtRuntime(mod))
                            self.builder.buildPtrToInt(non_int_val, small_int_ty, "")
                        else
                            self.builder.buildBitCast(non_int_val, small_int_ty, "");
                        const shift_rhs = try o.builder.intConst(int_ty, running_bits);
                        // If the field is as large as the entire packed struct, this
                        // zext would go from, e.g. i16 to i16. This is legal with
                        // constZExtOrBitCast but not legal with constZExt.
                        const extended_int_val = self.builder.buildZExtOrBitCast(small_int_val, int_ty.toLlvm(&o.builder), "");
                        const shifted = self.builder.buildShl(extended_int_val, shift_rhs.toLlvm(&o.builder), "");
                        running_int = self.builder.buildOr(running_int, shifted, "");
                        running_bits += ty_bit_size;
                    }
                    return running_int;
                }

                if (isByRef(result_ty, mod)) {
                    // TODO in debug builds init to undef so that the padding will be 0xaa
                    // even if we fully populate the fields.
                    const alloca_inst = try self.buildAlloca(llvm_result_ty, result_ty.abiAlignment(mod));

                    var indices: [2]*llvm.Value = .{
                        (try o.builder.intConst(.i32, 0)).toLlvm(&o.builder),
                        undefined,
                    };
                    for (elements, 0..) |elem, i| {
                        if ((try result_ty.structFieldValueComptime(mod, i)) != null) continue;

                        const llvm_elem = try self.resolveInst(elem);
                        const llvm_i = llvmField(result_ty, i, mod).?.index;
                        indices[1] = (try o.builder.intConst(.i32, llvm_i)).toLlvm(&o.builder);
                        const field_ptr = self.builder.buildInBoundsGEP(llvm_result_ty, alloca_inst, &indices, indices.len, "");
                        const field_ptr_ty = try mod.ptrType(.{
                            .child = self.typeOf(elem).toIntern(),
                            .flags = .{
                                .alignment = InternPool.Alignment.fromNonzeroByteUnits(
                                    result_ty.structFieldAlign(i, mod),
                                ),
                            },
                        });
                        try self.store(field_ptr, field_ptr_ty, llvm_elem, .NotAtomic);
                    }

                    return alloca_inst;
                } else {
                    var result = llvm_result_ty.getUndef();
                    for (elements, 0..) |elem, i| {
                        if ((try result_ty.structFieldValueComptime(mod, i)) != null) continue;

                        const llvm_elem = try self.resolveInst(elem);
                        const llvm_i = llvmField(result_ty, i, mod).?.index;
                        result = self.builder.buildInsertValue(result, llvm_elem, llvm_i, "");
                    }
                    return result;
                }
            },
            .Array => {
                assert(isByRef(result_ty, mod));

                const usize_ty = try o.lowerType(Type.usize);
                const alloca_inst = try self.buildAlloca(llvm_result_ty, result_ty.abiAlignment(mod));

                const array_info = result_ty.arrayInfo(mod);
                const elem_ptr_ty = try mod.ptrType(.{
                    .child = array_info.elem_type.toIntern(),
                });

                for (elements, 0..) |elem, i| {
                    const indices: [2]*llvm.Value = .{
                        (try o.builder.intConst(usize_ty, 0)).toLlvm(&o.builder),
                        (try o.builder.intConst(usize_ty, i)).toLlvm(&o.builder),
                    };
                    const elem_ptr = self.builder.buildInBoundsGEP(llvm_result_ty, alloca_inst, &indices, indices.len, "");
                    const llvm_elem = try self.resolveInst(elem);
                    try self.store(elem_ptr, elem_ptr_ty, llvm_elem, .NotAtomic);
                }
                if (array_info.sentinel) |sent_val| {
                    const indices: [2]*llvm.Value = .{
                        (try o.builder.intConst(usize_ty, 0)).toLlvm(&o.builder),
                        (try o.builder.intConst(usize_ty, array_info.len)).toLlvm(&o.builder),
                    };
                    const elem_ptr = self.builder.buildInBoundsGEP(llvm_result_ty, alloca_inst, &indices, indices.len, "");
                    const llvm_elem = try self.resolveValue(.{
                        .ty = array_info.elem_type,
                        .val = sent_val,
                    });

                    try self.store(elem_ptr, elem_ptr_ty, llvm_elem, .NotAtomic);
                }

                return alloca_inst;
            },
            else => unreachable,
        }
    }

    fn airUnionInit(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const extra = self.air.extraData(Air.UnionInit, ty_pl.payload).data;
        const union_ty = self.typeOfIndex(inst);
        const union_llvm_ty = try o.lowerType(union_ty);
        const layout = union_ty.unionGetLayout(mod);
        const union_obj = mod.typeToUnion(union_ty).?;

        if (union_obj.layout == .Packed) {
            const big_bits = union_ty.bitSize(mod);
            const int_llvm_ty = (try o.builder.intType(@intCast(big_bits))).toLlvm(&o.builder);
            const field = union_obj.fields.values()[extra.field_index];
            const non_int_val = try self.resolveInst(extra.init);
            const ty_bit_size = @as(u16, @intCast(field.ty.bitSize(mod)));
            const small_int_ty = (try o.builder.intType(@intCast(ty_bit_size))).toLlvm(&o.builder);
            const small_int_val = if (field.ty.isPtrAtRuntime(mod))
                self.builder.buildPtrToInt(non_int_val, small_int_ty, "")
            else
                self.builder.buildBitCast(non_int_val, small_int_ty, "");
            return self.builder.buildZExtOrBitCast(small_int_val, int_llvm_ty, "");
        }

        const tag_int = blk: {
            const tag_ty = union_ty.unionTagTypeHypothetical(mod);
            const union_field_name = union_obj.fields.keys()[extra.field_index];
            const enum_field_index = tag_ty.enumFieldIndex(union_field_name, mod).?;
            const tag_val = try mod.enumValueFieldIndex(tag_ty, enum_field_index);
            const tag_int_val = try tag_val.intFromEnum(tag_ty, mod);
            break :blk tag_int_val.toUnsignedInt(mod);
        };
        if (layout.payload_size == 0) {
            if (layout.tag_size == 0) {
                return null;
            }
            assert(!isByRef(union_ty, mod));
            return (try o.builder.intConst(union_llvm_ty, tag_int)).toLlvm(&o.builder);
        }
        assert(isByRef(union_ty, mod));
        // The llvm type of the alloca will be the named LLVM union type, and will not
        // necessarily match the format that we need, depending on which tag is active.
        // We must construct the correct unnamed struct type here, in order to then set
        // the fields appropriately.
        const result_ptr = try self.buildAlloca(union_llvm_ty.toLlvm(&o.builder), layout.abi_align);
        const llvm_payload = try self.resolveInst(extra.init);
        assert(union_obj.haveFieldTypes());
        const field = union_obj.fields.values()[extra.field_index];
        const field_llvm_ty = try o.lowerType(field.ty);
        const field_size = field.ty.abiSize(mod);
        const field_align = field.normalAlignment(mod);

        const llvm_union_ty = (t: {
            const payload_ty = p: {
                if (!field.ty.hasRuntimeBitsIgnoreComptime(mod)) {
                    const padding_len = layout.payload_size;
                    break :p try o.builder.arrayType(padding_len, .i8);
                }
                if (field_size == layout.payload_size) {
                    break :p field_llvm_ty;
                }
                const padding_len = layout.payload_size - field_size;
                break :p try o.builder.structType(.@"packed", &.{
                    field_llvm_ty, try o.builder.arrayType(padding_len, .i8),
                });
            };
            if (layout.tag_size == 0) break :t try o.builder.structType(.normal, &.{payload_ty});
            const tag_ty = try o.lowerType(union_obj.tag_ty);
            var fields: [3]Builder.Type = undefined;
            var fields_len: usize = 2;
            if (layout.tag_align >= layout.payload_align) {
                fields = .{ tag_ty, payload_ty, undefined };
            } else {
                fields = .{ payload_ty, tag_ty, undefined };
            }
            if (layout.padding != 0) {
                fields[fields_len] = try o.builder.arrayType(layout.padding, .i8);
                fields_len += 1;
            }
            break :t try o.builder.structType(.normal, fields[0..fields_len]);
        }).toLlvm(&o.builder);

        // Now we follow the layout as expressed above with GEP instructions to set the
        // tag and the payload.
        const field_ptr_ty = try mod.ptrType(.{
            .child = field.ty.toIntern(),
            .flags = .{
                .alignment = InternPool.Alignment.fromNonzeroByteUnits(field_align),
            },
        });
        if (layout.tag_size == 0) {
            const indices: [3]*llvm.Value = .{
                (try o.builder.intConst(.i32, 0)).toLlvm(&o.builder),
            } ** 3;
            const len: c_uint = if (field_size == layout.payload_size) 2 else 3;
            const field_ptr = self.builder.buildInBoundsGEP(llvm_union_ty, result_ptr, &indices, len, "");
            try self.store(field_ptr, field_ptr_ty, llvm_payload, .NotAtomic);
            return result_ptr;
        }

        {
            const indices: [3]*llvm.Value = .{
                (try o.builder.intConst(.i32, 0)).toLlvm(&o.builder),
                (try o.builder.intConst(.i32, @intFromBool(layout.tag_align >= layout.payload_align))).toLlvm(&o.builder),
                (try o.builder.intConst(.i32, 0)).toLlvm(&o.builder),
            };
            const len: c_uint = if (field_size == layout.payload_size) 2 else 3;
            const field_ptr = self.builder.buildInBoundsGEP(llvm_union_ty, result_ptr, &indices, len, "");
            try self.store(field_ptr, field_ptr_ty, llvm_payload, .NotAtomic);
        }
        {
            const indices: [2]*llvm.Value = .{
                (try o.builder.intConst(.i32, 0)).toLlvm(&o.builder),
                (try o.builder.intConst(.i32, @intFromBool(layout.tag_align < layout.payload_align))).toLlvm(&o.builder),
            };
            const field_ptr = self.builder.buildInBoundsGEP(llvm_union_ty, result_ptr, &indices, indices.len, "");
            const tag_ty = try o.lowerType(union_obj.tag_ty);
            const llvm_tag = try o.builder.intConst(tag_ty, tag_int);
            const store_inst = self.builder.buildStore(llvm_tag.toLlvm(&o.builder), field_ptr);
            store_inst.setAlignment(union_obj.tag_ty.abiAlignment(mod));
        }

        return result_ptr;
    }

    fn airPrefetch(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const prefetch = self.air.instructions.items(.data)[inst].prefetch;

        comptime assert(@intFromEnum(std.builtin.PrefetchOptions.Rw.read) == 0);
        comptime assert(@intFromEnum(std.builtin.PrefetchOptions.Rw.write) == 1);

        // TODO these two asserts should be able to be comptime because the type is a u2
        assert(prefetch.locality >= 0);
        assert(prefetch.locality <= 3);

        comptime assert(@intFromEnum(std.builtin.PrefetchOptions.Cache.instruction) == 0);
        comptime assert(@intFromEnum(std.builtin.PrefetchOptions.Cache.data) == 1);

        // LLVM fails during codegen of instruction cache prefetchs for these architectures.
        // This is an LLVM bug as the prefetch intrinsic should be a noop if not supported
        // by the target.
        // To work around this, don't emit llvm.prefetch in this case.
        // See https://bugs.llvm.org/show_bug.cgi?id=21037
        const mod = o.module;
        const target = mod.getTarget();
        switch (prefetch.cache) {
            .instruction => switch (target.cpu.arch) {
                .x86_64,
                .x86,
                .powerpc,
                .powerpcle,
                .powerpc64,
                .powerpc64le,
                => return null,
                .arm, .armeb, .thumb, .thumbeb => {
                    switch (prefetch.rw) {
                        .write => return null,
                        else => {},
                    }
                },
                else => {},
            },
            .data => {},
        }

        const llvm_fn_name = "llvm.prefetch.p0";
        const fn_val = o.llvm_module.getNamedFunction(llvm_fn_name) orelse blk: {
            // declare void @llvm.prefetch(i8*, i32, i32, i32)
            const fn_type = try o.builder.fnType(.void, &.{ .ptr, .i32, .i32, .i32 }, .normal);
            break :blk o.llvm_module.addFunction(llvm_fn_name, fn_type.toLlvm(&o.builder));
        };

        const ptr = try self.resolveInst(prefetch.ptr);

        const params = [_]*llvm.Value{
            ptr,
            (try o.builder.intConst(.i32, @intFromEnum(prefetch.rw))).toLlvm(&o.builder),
            (try o.builder.intConst(.i32, prefetch.locality)).toLlvm(&o.builder),
            (try o.builder.intConst(.i32, @intFromEnum(prefetch.cache))).toLlvm(&o.builder),
        };
        _ = self.builder.buildCall(fn_val.globalGetValueType(), fn_val, &params, params.len, .C, .Auto, "");
        return null;
    }

    fn airAddrSpaceCast(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const inst_ty = self.typeOfIndex(inst);
        const operand = try self.resolveInst(ty_op.operand);

        const llvm_dest_ty = (try o.lowerType(inst_ty)).toLlvm(&o.builder);
        return self.builder.buildAddrSpaceCast(operand, llvm_dest_ty, "");
    }

    fn amdgcnWorkIntrinsic(self: *FuncGen, dimension: u32, default: u32, comptime basename: []const u8) !?*llvm.Value {
        const llvm_fn_name = switch (dimension) {
            0 => basename ++ ".x",
            1 => basename ++ ".y",
            2 => basename ++ ".z",
            else => return (try self.dg.object.builder.intConst(.i32, default)).toLlvm(&self.dg.object.builder),
        };

        const args: [0]*llvm.Value = .{};
        const llvm_fn = try self.getIntrinsic(llvm_fn_name, &.{});
        return self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, &args, args.len, .Fast, .Auto, "");
    }

    fn airWorkItemId(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const target = o.module.getTarget();
        assert(target.cpu.arch == .amdgcn); // TODO is to port this function to other GPU architectures

        const pl_op = self.air.instructions.items(.data)[inst].pl_op;
        const dimension = pl_op.payload;
        return self.amdgcnWorkIntrinsic(dimension, 0, "llvm.amdgcn.workitem.id");
    }

    fn airWorkGroupSize(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const target = o.module.getTarget();
        assert(target.cpu.arch == .amdgcn); // TODO is to port this function to other GPU architectures

        const pl_op = self.air.instructions.items(.data)[inst].pl_op;
        const dimension = pl_op.payload;
        if (dimension >= 3) {
            return (try o.builder.intConst(.i32, 1)).toLlvm(&o.builder);
        }

        // Fetch the dispatch pointer, which points to this structure:
        // https://github.com/RadeonOpenCompute/ROCR-Runtime/blob/adae6c61e10d371f7cbc3d0e94ae2c070cab18a4/src/inc/hsa.h#L2913
        const llvm_fn = try self.getIntrinsic("llvm.amdgcn.dispatch.ptr", &.{});
        const args: [0]*llvm.Value = .{};
        const dispatch_ptr = self.builder.buildCall(llvm_fn.globalGetValueType(), llvm_fn, &args, args.len, .Fast, .Auto, "");
        dispatch_ptr.setAlignment(4);

        // Load the work_group_* member from the struct as u16.
        // Just treat the dispatch pointer as an array of u16 to keep things simple.
        const offset = 2 + dimension;
        const index = [_]*llvm.Value{
            (try o.builder.intConst(.i32, offset)).toLlvm(&o.builder),
        };
        const llvm_u16 = Builder.Type.i16.toLlvm(&o.builder);
        const workgroup_size_ptr = self.builder.buildInBoundsGEP(llvm_u16, dispatch_ptr, &index, index.len, "");
        const workgroup_size = self.builder.buildLoad(llvm_u16, workgroup_size_ptr, "");
        workgroup_size.setAlignment(2);
        return workgroup_size;
    }

    fn airWorkGroupId(self: *FuncGen, inst: Air.Inst.Index) !?*llvm.Value {
        const o = self.dg.object;
        const target = o.module.getTarget();
        assert(target.cpu.arch == .amdgcn); // TODO is to port this function to other GPU architectures

        const pl_op = self.air.instructions.items(.data)[inst].pl_op;
        const dimension = pl_op.payload;
        return self.amdgcnWorkIntrinsic(dimension, 0, "llvm.amdgcn.workgroup.id");
    }

    fn getErrorNameTable(self: *FuncGen) !*llvm.Value {
        const o = self.dg.object;
        if (o.error_name_table) |table| {
            return table;
        }

        const mod = o.module;
        const slice_ty = Type.slice_const_u8_sentinel_0;
        const slice_alignment = slice_ty.abiAlignment(mod);
        const llvm_slice_ptr_ty = self.context.pointerType(0); // TODO: Address space

        const error_name_table_global = o.llvm_module.addGlobal(llvm_slice_ptr_ty, "__zig_err_name_table");
        error_name_table_global.setInitializer(llvm_slice_ptr_ty.getUndef());
        error_name_table_global.setLinkage(.Private);
        error_name_table_global.setGlobalConstant(.True);
        error_name_table_global.setUnnamedAddr(.True);
        error_name_table_global.setAlignment(slice_alignment);

        o.error_name_table = error_name_table_global;
        return error_name_table_global;
    }

    /// Assumes the optional is not pointer-like and payload has bits.
    fn optIsNonNull(
        self: *FuncGen,
        opt_llvm_ty: *llvm.Type,
        opt_handle: *llvm.Value,
        is_by_ref: bool,
    ) Allocator.Error!*llvm.Value {
        const field = b: {
            if (is_by_ref) {
                const field_ptr = self.builder.buildStructGEP(opt_llvm_ty, opt_handle, 1, "");
                break :b self.builder.buildLoad(Builder.Type.i8.toLlvm(&self.dg.object.builder), field_ptr, "");
            }
            break :b self.builder.buildExtractValue(opt_handle, 1, "");
        };
        comptime assert(optional_layout_version == 3);

        return self.builder.buildICmp(.NE, field, (try self.dg.object.builder.intConst(.i8, 0)).toLlvm(&self.dg.object.builder), "");
    }

    /// Assumes the optional is not pointer-like and payload has bits.
    fn optPayloadHandle(
        fg: *FuncGen,
        opt_llvm_ty: *llvm.Type,
        opt_handle: *llvm.Value,
        opt_ty: Type,
        can_elide_load: bool,
    ) !*llvm.Value {
        const o = fg.dg.object;
        const mod = o.module;
        const payload_ty = opt_ty.optionalChild(mod);

        if (isByRef(opt_ty, mod)) {
            // We have a pointer and we need to return a pointer to the first field.
            const payload_ptr = fg.builder.buildStructGEP(opt_llvm_ty, opt_handle, 0, "");

            const payload_alignment = payload_ty.abiAlignment(mod);
            if (isByRef(payload_ty, mod)) {
                if (can_elide_load)
                    return payload_ptr;

                return fg.loadByRef(payload_ptr, payload_ty, payload_alignment, false);
            }
            const payload_llvm_ty = (try o.lowerType(payload_ty)).toLlvm(&o.builder);
            const load_inst = fg.builder.buildLoad(payload_llvm_ty, payload_ptr, "");
            load_inst.setAlignment(payload_alignment);
            return load_inst;
        }

        assert(!isByRef(payload_ty, mod));
        return fg.builder.buildExtractValue(opt_handle, 0, "");
    }

    fn buildOptional(
        self: *FuncGen,
        optional_ty: Type,
        payload: *llvm.Value,
        non_null_bit: *llvm.Value,
    ) !?*llvm.Value {
        const o = self.dg.object;
        const optional_llvm_ty = (try o.lowerType(optional_ty)).toLlvm(&o.builder);
        const non_null_field = self.builder.buildZExt(non_null_bit, Builder.Type.i8.toLlvm(&o.builder), "");
        const mod = o.module;

        if (isByRef(optional_ty, mod)) {
            const payload_alignment = optional_ty.abiAlignment(mod);
            const alloca_inst = try self.buildAlloca(optional_llvm_ty, payload_alignment);

            {
                const field_ptr = self.builder.buildStructGEP(optional_llvm_ty, alloca_inst, 0, "");
                const store_inst = self.builder.buildStore(payload, field_ptr);
                store_inst.setAlignment(payload_alignment);
            }
            {
                const field_ptr = self.builder.buildStructGEP(optional_llvm_ty, alloca_inst, 1, "");
                const store_inst = self.builder.buildStore(non_null_field, field_ptr);
                store_inst.setAlignment(1);
            }

            return alloca_inst;
        }

        const partial = self.builder.buildInsertValue(optional_llvm_ty.getUndef(), payload, 0, "");
        return self.builder.buildInsertValue(partial, non_null_field, 1, "");
    }

    fn fieldPtr(
        self: *FuncGen,
        inst: Air.Inst.Index,
        struct_ptr: *llvm.Value,
        struct_ptr_ty: Type,
        field_index: u32,
    ) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const struct_ty = struct_ptr_ty.childType(mod);
        switch (struct_ty.zigTypeTag(mod)) {
            .Struct => switch (struct_ty.containerLayout(mod)) {
                .Packed => {
                    const result_ty = self.typeOfIndex(inst);
                    const result_ty_info = result_ty.ptrInfo(mod);

                    if (result_ty_info.packed_offset.host_size != 0) {
                        // From LLVM's perspective, a pointer to a packed struct and a pointer
                        // to a field of a packed struct are the same. The difference is in the
                        // Zig pointer type which provides information for how to mask and shift
                        // out the relevant bits when accessing the pointee.
                        return struct_ptr;
                    }

                    // We have a pointer to a packed struct field that happens to be byte-aligned.
                    // Offset our operand pointer by the correct number of bytes.
                    const byte_offset = struct_ty.packedStructFieldByteOffset(field_index, mod);
                    if (byte_offset == 0) return struct_ptr;
                    const byte_llvm_ty = Builder.Type.i8.toLlvm(&o.builder);
                    const usize_ty = try o.lowerType(Type.usize);
                    const llvm_index = try o.builder.intConst(usize_ty, byte_offset);
                    const indices: [1]*llvm.Value = .{llvm_index.toLlvm(&o.builder)};
                    return self.builder.buildInBoundsGEP(byte_llvm_ty, struct_ptr, &indices, indices.len, "");
                },
                else => {
                    const struct_llvm_ty = (try o.lowerPtrElemTy(struct_ty)).toLlvm(&o.builder);

                    if (llvmField(struct_ty, field_index, mod)) |llvm_field| {
                        return self.builder.buildStructGEP(struct_llvm_ty, struct_ptr, llvm_field.index, "");
                    } else {
                        // If we found no index then this means this is a zero sized field at the
                        // end of the struct. Treat our struct pointer as an array of two and get
                        // the index to the element at index `1` to get a pointer to the end of
                        // the struct.
                        const llvm_index = try o.builder.intConst(.i32, @intFromBool(struct_ty.hasRuntimeBitsIgnoreComptime(mod)));
                        const indices: [1]*llvm.Value = .{llvm_index.toLlvm(&o.builder)};
                        return self.builder.buildInBoundsGEP(struct_llvm_ty, struct_ptr, &indices, indices.len, "");
                    }
                },
            },
            .Union => {
                const layout = struct_ty.unionGetLayout(mod);
                if (layout.payload_size == 0 or struct_ty.containerLayout(mod) == .Packed) return struct_ptr;
                const payload_index = @intFromBool(layout.tag_align >= layout.payload_align);
                const union_llvm_ty = (try o.lowerType(struct_ty)).toLlvm(&o.builder);
                const union_field_ptr = self.builder.buildStructGEP(union_llvm_ty, struct_ptr, payload_index, "");
                return union_field_ptr;
            },
            else => unreachable,
        }
    }

    fn getIntrinsic(fg: *FuncGen, name: []const u8, types: []const Builder.Type) Allocator.Error!*llvm.Value {
        const o = fg.dg.object;
        const id = llvm.lookupIntrinsicID(name.ptr, name.len);
        assert(id != 0);
        const llvm_types = try o.gpa.alloc(*llvm.Type, types.len);
        defer o.gpa.free(llvm_types);
        for (llvm_types, types) |*llvm_type, ty| llvm_type.* = ty.toLlvm(&o.builder);
        return o.llvm_module.getIntrinsicDeclaration(id, llvm_types.ptr, llvm_types.len);
    }

    /// Load a by-ref type by constructing a new alloca and performing a memcpy.
    fn loadByRef(
        fg: *FuncGen,
        ptr: *llvm.Value,
        pointee_type: Type,
        ptr_alignment: u32,
        is_volatile: bool,
    ) !*llvm.Value {
        const o = fg.dg.object;
        const mod = o.module;
        const pointee_llvm_ty = (try o.lowerType(pointee_type)).toLlvm(&o.builder);
        const result_align = @max(ptr_alignment, pointee_type.abiAlignment(mod));
        const result_ptr = try fg.buildAlloca(pointee_llvm_ty, result_align);
        const usize_ty = try o.lowerType(Type.usize);
        const size_bytes = pointee_type.abiSize(mod);
        _ = fg.builder.buildMemCpy(
            result_ptr,
            result_align,
            ptr,
            ptr_alignment,
            (try o.builder.intConst(usize_ty, size_bytes)).toLlvm(&o.builder),
            is_volatile,
        );
        return result_ptr;
    }

    /// This function always performs a copy. For isByRef=true types, it creates a new
    /// alloca and copies the value into it, then returns the alloca instruction.
    /// For isByRef=false types, it creates a load instruction and returns it.
    fn load(self: *FuncGen, ptr: *llvm.Value, ptr_ty: Type) !?*llvm.Value {
        const o = self.dg.object;
        const mod = o.module;
        const info = ptr_ty.ptrInfo(mod);
        const elem_ty = info.child.toType();
        if (!elem_ty.hasRuntimeBitsIgnoreComptime(mod)) return null;

        const ptr_alignment = @as(u32, @intCast(info.flags.alignment.toByteUnitsOptional() orelse
            elem_ty.abiAlignment(mod)));
        const ptr_volatile = llvm.Bool.fromBool(info.flags.is_volatile);

        assert(info.flags.vector_index != .runtime);
        if (info.flags.vector_index != .none) {
            const index_u32 = try o.builder.intConst(.i32, @intFromEnum(info.flags.vector_index));
            const vec_elem_ty = try o.lowerType(elem_ty);
            const vec_ty = try o.builder.vectorType(.normal, info.packed_offset.host_size, vec_elem_ty);

            const loaded_vector = self.builder.buildLoad(vec_ty.toLlvm(&o.builder), ptr, "");
            loaded_vector.setAlignment(ptr_alignment);
            loaded_vector.setVolatile(ptr_volatile);

            return self.builder.buildExtractElement(loaded_vector, index_u32.toLlvm(&o.builder), "");
        }

        if (info.packed_offset.host_size == 0) {
            if (isByRef(elem_ty, mod)) {
                return self.loadByRef(ptr, elem_ty, ptr_alignment, info.flags.is_volatile);
            }
            const elem_llvm_ty = (try o.lowerType(elem_ty)).toLlvm(&o.builder);
            const llvm_inst = self.builder.buildLoad(elem_llvm_ty, ptr, "");
            llvm_inst.setAlignment(ptr_alignment);
            llvm_inst.setVolatile(ptr_volatile);
            return llvm_inst;
        }

        const int_elem_ty = (try o.builder.intType(@intCast(info.packed_offset.host_size * 8))).toLlvm(&o.builder);
        const containing_int = self.builder.buildLoad(int_elem_ty, ptr, "");
        containing_int.setAlignment(ptr_alignment);
        containing_int.setVolatile(ptr_volatile);

        const elem_bits = @as(c_uint, @intCast(ptr_ty.childType(mod).bitSize(mod)));
        const shift_amt = containing_int.typeOf().constInt(info.packed_offset.bit_offset, .False);
        const shifted_value = self.builder.buildLShr(containing_int, shift_amt, "");
        const elem_llvm_ty = (try o.lowerType(elem_ty)).toLlvm(&o.builder);

        if (isByRef(elem_ty, mod)) {
            const result_align = elem_ty.abiAlignment(mod);
            const result_ptr = try self.buildAlloca(elem_llvm_ty, result_align);

            const same_size_int = (try o.builder.intType(@intCast(elem_bits))).toLlvm(&o.builder);
            const truncated_int = self.builder.buildTrunc(shifted_value, same_size_int, "");
            const store_inst = self.builder.buildStore(truncated_int, result_ptr);
            store_inst.setAlignment(result_align);
            return result_ptr;
        }

        if (elem_ty.zigTypeTag(mod) == .Float or elem_ty.zigTypeTag(mod) == .Vector) {
            const same_size_int = (try o.builder.intType(@intCast(elem_bits))).toLlvm(&o.builder);
            const truncated_int = self.builder.buildTrunc(shifted_value, same_size_int, "");
            return self.builder.buildBitCast(truncated_int, elem_llvm_ty, "");
        }

        if (elem_ty.isPtrAtRuntime(mod)) {
            const same_size_int = (try o.builder.intType(@intCast(elem_bits))).toLlvm(&o.builder);
            const truncated_int = self.builder.buildTrunc(shifted_value, same_size_int, "");
            return self.builder.buildIntToPtr(truncated_int, elem_llvm_ty, "");
        }

        return self.builder.buildTrunc(shifted_value, elem_llvm_ty, "");
    }

    fn store(
        self: *FuncGen,
        ptr: *llvm.Value,
        ptr_ty: Type,
        elem: *llvm.Value,
        ordering: llvm.AtomicOrdering,
    ) !void {
        const o = self.dg.object;
        const mod = o.module;
        const info = ptr_ty.ptrInfo(mod);
        const elem_ty = info.child.toType();
        if (!elem_ty.isFnOrHasRuntimeBitsIgnoreComptime(mod)) {
            return;
        }
        const ptr_alignment = ptr_ty.ptrAlignment(mod);
        const ptr_volatile = llvm.Bool.fromBool(info.flags.is_volatile);

        assert(info.flags.vector_index != .runtime);
        if (info.flags.vector_index != .none) {
            const index_u32 = try o.builder.intConst(.i32, @intFromEnum(info.flags.vector_index));
            const vec_elem_ty = try o.lowerType(elem_ty);
            const vec_ty = try o.builder.vectorType(.normal, info.packed_offset.host_size, vec_elem_ty);

            const loaded_vector = self.builder.buildLoad(vec_ty.toLlvm(&o.builder), ptr, "");
            loaded_vector.setAlignment(ptr_alignment);
            loaded_vector.setVolatile(ptr_volatile);

            const modified_vector = self.builder.buildInsertElement(loaded_vector, elem, index_u32.toLlvm(&o.builder), "");

            const store_inst = self.builder.buildStore(modified_vector, ptr);
            assert(ordering == .NotAtomic);
            store_inst.setAlignment(ptr_alignment);
            store_inst.setVolatile(ptr_volatile);
            return;
        }

        if (info.packed_offset.host_size != 0) {
            const int_elem_ty = (try o.builder.intType(@intCast(info.packed_offset.host_size * 8))).toLlvm(&o.builder);
            const containing_int = self.builder.buildLoad(int_elem_ty, ptr, "");
            assert(ordering == .NotAtomic);
            containing_int.setAlignment(ptr_alignment);
            containing_int.setVolatile(ptr_volatile);
            const elem_bits = @as(c_uint, @intCast(ptr_ty.childType(mod).bitSize(mod)));
            const containing_int_ty = containing_int.typeOf();
            const shift_amt = containing_int_ty.constInt(info.packed_offset.bit_offset, .False);
            // Convert to equally-sized integer type in order to perform the bit
            // operations on the value to store
            const value_bits_type = (try o.builder.intType(@intCast(elem_bits))).toLlvm(&o.builder);
            const value_bits = if (elem_ty.isPtrAtRuntime(mod))
                self.builder.buildPtrToInt(elem, value_bits_type, "")
            else
                self.builder.buildBitCast(elem, value_bits_type, "");

            var mask_val = value_bits_type.constAllOnes();
            mask_val = mask_val.constZExt(containing_int_ty);
            mask_val = mask_val.constShl(shift_amt);
            mask_val = mask_val.constNot();

            const anded_containing_int = self.builder.buildAnd(containing_int, mask_val, "");
            const extended_value = self.builder.buildZExt(value_bits, containing_int_ty, "");
            const shifted_value = self.builder.buildShl(extended_value, shift_amt, "");
            const ored_value = self.builder.buildOr(shifted_value, anded_containing_int, "");

            const store_inst = self.builder.buildStore(ored_value, ptr);
            assert(ordering == .NotAtomic);
            store_inst.setAlignment(ptr_alignment);
            store_inst.setVolatile(ptr_volatile);
            return;
        }
        if (!isByRef(elem_ty, mod)) {
            const store_inst = self.builder.buildStore(elem, ptr);
            store_inst.setOrdering(ordering);
            store_inst.setAlignment(ptr_alignment);
            store_inst.setVolatile(ptr_volatile);
            return;
        }
        assert(ordering == .NotAtomic);
        const size_bytes = elem_ty.abiSize(mod);
        _ = self.builder.buildMemCpy(
            ptr,
            ptr_alignment,
            elem,
            elem_ty.abiAlignment(mod),
            (try o.builder.intConst(try o.lowerType(Type.usize), size_bytes)).toLlvm(&o.builder),
            info.flags.is_volatile,
        );
    }

    fn valgrindMarkUndef(fg: *FuncGen, ptr: *llvm.Value, len: *llvm.Value) Allocator.Error!void {
        const VG_USERREQ__MAKE_MEM_UNDEFINED = 1296236545;
        const o = fg.dg.object;
        const usize_ty = try o.lowerType(Type.usize);
        const zero = (try o.builder.intConst(usize_ty, 0)).toLlvm(&o.builder);
        const req = (try o.builder.intConst(usize_ty, VG_USERREQ__MAKE_MEM_UNDEFINED)).toLlvm(&o.builder);
        const ptr_as_usize = fg.builder.buildPtrToInt(ptr, usize_ty.toLlvm(&o.builder), "");
        _ = try valgrindClientRequest(fg, zero, req, ptr_as_usize, len, zero, zero, zero);
    }

    fn valgrindClientRequest(
        fg: *FuncGen,
        default_value: *llvm.Value,
        request: *llvm.Value,
        a1: *llvm.Value,
        a2: *llvm.Value,
        a3: *llvm.Value,
        a4: *llvm.Value,
        a5: *llvm.Value,
    ) Allocator.Error!*llvm.Value {
        const o = fg.dg.object;
        const mod = o.module;
        const target = mod.getTarget();
        if (!target_util.hasValgrindSupport(target)) return default_value;

        const llvm_usize = try o.lowerType(Type.usize);
        const usize_alignment = @as(c_uint, @intCast(Type.usize.abiSize(mod)));

        const array_llvm_ty = (try o.builder.arrayType(6, llvm_usize)).toLlvm(&o.builder);
        const array_ptr = fg.valgrind_client_request_array orelse a: {
            const array_ptr = try fg.buildAlloca(array_llvm_ty, usize_alignment);
            fg.valgrind_client_request_array = array_ptr;
            break :a array_ptr;
        };
        const array_elements = [_]*llvm.Value{ request, a1, a2, a3, a4, a5 };
        const zero = (try o.builder.intConst(llvm_usize, 0)).toLlvm(&o.builder);
        for (array_elements, 0..) |elem, i| {
            const indexes = [_]*llvm.Value{
                zero, (try o.builder.intConst(llvm_usize, i)).toLlvm(&o.builder),
            };
            const elem_ptr = fg.builder.buildInBoundsGEP(array_llvm_ty, array_ptr, &indexes, indexes.len, "");
            const store_inst = fg.builder.buildStore(elem, elem_ptr);
            store_inst.setAlignment(usize_alignment);
        }

        const arch_specific: struct {
            template: [:0]const u8,
            constraints: [:0]const u8,
        } = switch (target.cpu.arch) {
            .x86 => .{
                .template =
                \\roll $$3,  %edi ; roll $$13, %edi
                \\roll $$61, %edi ; roll $$51, %edi
                \\xchgl %ebx,%ebx
                ,
                .constraints = "={edx},{eax},0,~{cc},~{memory}",
            },
            .x86_64 => .{
                .template =
                \\rolq $$3,  %rdi ; rolq $$13, %rdi
                \\rolq $$61, %rdi ; rolq $$51, %rdi
                \\xchgq %rbx,%rbx
                ,
                .constraints = "={rdx},{rax},0,~{cc},~{memory}",
            },
            .aarch64, .aarch64_32, .aarch64_be => .{
                .template =
                \\ror x12, x12, #3  ;  ror x12, x12, #13
                \\ror x12, x12, #51 ;  ror x12, x12, #61
                \\orr x10, x10, x10
                ,
                .constraints = "={x3},{x4},0,~{cc},~{memory}",
            },
            else => unreachable,
        };

        const fn_llvm_ty = (try o.builder.fnType(llvm_usize, &(.{llvm_usize} ** 2), .normal)).toLlvm(&o.builder);
        const array_ptr_as_usize = fg.builder.buildPtrToInt(array_ptr, llvm_usize.toLlvm(&o.builder), "");
        const args = [_]*llvm.Value{ array_ptr_as_usize, default_value };
        const asm_fn = llvm.getInlineAsm(
            fn_llvm_ty,
            arch_specific.template.ptr,
            arch_specific.template.len,
            arch_specific.constraints.ptr,
            arch_specific.constraints.len,
            .True, // has side effects
            .False, // alignstack
            .ATT,
            .False, // can throw
        );

        const call = fg.builder.buildCall(
            fn_llvm_ty,
            asm_fn,
            &args,
            args.len,
            .C,
            .Auto,
            "",
        );
        return call;
    }

    fn typeOf(fg: *FuncGen, inst: Air.Inst.Ref) Type {
        const o = fg.dg.object;
        const mod = o.module;
        return fg.air.typeOf(inst, &mod.intern_pool);
    }

    fn typeOfIndex(fg: *FuncGen, inst: Air.Inst.Index) Type {
        const o = fg.dg.object;
        const mod = o.module;
        return fg.air.typeOfIndex(inst, &mod.intern_pool);
    }
};

fn initializeLLVMTarget(arch: std.Target.Cpu.Arch) void {
    switch (arch) {
        .aarch64, .aarch64_be, .aarch64_32 => {
            llvm.LLVMInitializeAArch64Target();
            llvm.LLVMInitializeAArch64TargetInfo();
            llvm.LLVMInitializeAArch64TargetMC();
            llvm.LLVMInitializeAArch64AsmPrinter();
            llvm.LLVMInitializeAArch64AsmParser();
        },
        .amdgcn => {
            llvm.LLVMInitializeAMDGPUTarget();
            llvm.LLVMInitializeAMDGPUTargetInfo();
            llvm.LLVMInitializeAMDGPUTargetMC();
            llvm.LLVMInitializeAMDGPUAsmPrinter();
            llvm.LLVMInitializeAMDGPUAsmParser();
        },
        .thumb, .thumbeb, .arm, .armeb => {
            llvm.LLVMInitializeARMTarget();
            llvm.LLVMInitializeARMTargetInfo();
            llvm.LLVMInitializeARMTargetMC();
            llvm.LLVMInitializeARMAsmPrinter();
            llvm.LLVMInitializeARMAsmParser();
        },
        .avr => {
            llvm.LLVMInitializeAVRTarget();
            llvm.LLVMInitializeAVRTargetInfo();
            llvm.LLVMInitializeAVRTargetMC();
            llvm.LLVMInitializeAVRAsmPrinter();
            llvm.LLVMInitializeAVRAsmParser();
        },
        .bpfel, .bpfeb => {
            llvm.LLVMInitializeBPFTarget();
            llvm.LLVMInitializeBPFTargetInfo();
            llvm.LLVMInitializeBPFTargetMC();
            llvm.LLVMInitializeBPFAsmPrinter();
            llvm.LLVMInitializeBPFAsmParser();
        },
        .hexagon => {
            llvm.LLVMInitializeHexagonTarget();
            llvm.LLVMInitializeHexagonTargetInfo();
            llvm.LLVMInitializeHexagonTargetMC();
            llvm.LLVMInitializeHexagonAsmPrinter();
            llvm.LLVMInitializeHexagonAsmParser();
        },
        .lanai => {
            llvm.LLVMInitializeLanaiTarget();
            llvm.LLVMInitializeLanaiTargetInfo();
            llvm.LLVMInitializeLanaiTargetMC();
            llvm.LLVMInitializeLanaiAsmPrinter();
            llvm.LLVMInitializeLanaiAsmParser();
        },
        .mips, .mipsel, .mips64, .mips64el => {
            llvm.LLVMInitializeMipsTarget();
            llvm.LLVMInitializeMipsTargetInfo();
            llvm.LLVMInitializeMipsTargetMC();
            llvm.LLVMInitializeMipsAsmPrinter();
            llvm.LLVMInitializeMipsAsmParser();
        },
        .msp430 => {
            llvm.LLVMInitializeMSP430Target();
            llvm.LLVMInitializeMSP430TargetInfo();
            llvm.LLVMInitializeMSP430TargetMC();
            llvm.LLVMInitializeMSP430AsmPrinter();
            llvm.LLVMInitializeMSP430AsmParser();
        },
        .nvptx, .nvptx64 => {
            llvm.LLVMInitializeNVPTXTarget();
            llvm.LLVMInitializeNVPTXTargetInfo();
            llvm.LLVMInitializeNVPTXTargetMC();
            llvm.LLVMInitializeNVPTXAsmPrinter();
            // There is no LLVMInitializeNVPTXAsmParser function available.
        },
        .powerpc, .powerpcle, .powerpc64, .powerpc64le => {
            llvm.LLVMInitializePowerPCTarget();
            llvm.LLVMInitializePowerPCTargetInfo();
            llvm.LLVMInitializePowerPCTargetMC();
            llvm.LLVMInitializePowerPCAsmPrinter();
            llvm.LLVMInitializePowerPCAsmParser();
        },
        .riscv32, .riscv64 => {
            llvm.LLVMInitializeRISCVTarget();
            llvm.LLVMInitializeRISCVTargetInfo();
            llvm.LLVMInitializeRISCVTargetMC();
            llvm.LLVMInitializeRISCVAsmPrinter();
            llvm.LLVMInitializeRISCVAsmParser();
        },
        .sparc, .sparc64, .sparcel => {
            llvm.LLVMInitializeSparcTarget();
            llvm.LLVMInitializeSparcTargetInfo();
            llvm.LLVMInitializeSparcTargetMC();
            llvm.LLVMInitializeSparcAsmPrinter();
            llvm.LLVMInitializeSparcAsmParser();
        },
        .s390x => {
            llvm.LLVMInitializeSystemZTarget();
            llvm.LLVMInitializeSystemZTargetInfo();
            llvm.LLVMInitializeSystemZTargetMC();
            llvm.LLVMInitializeSystemZAsmPrinter();
            llvm.LLVMInitializeSystemZAsmParser();
        },
        .wasm32, .wasm64 => {
            llvm.LLVMInitializeWebAssemblyTarget();
            llvm.LLVMInitializeWebAssemblyTargetInfo();
            llvm.LLVMInitializeWebAssemblyTargetMC();
            llvm.LLVMInitializeWebAssemblyAsmPrinter();
            llvm.LLVMInitializeWebAssemblyAsmParser();
        },
        .x86, .x86_64 => {
            llvm.LLVMInitializeX86Target();
            llvm.LLVMInitializeX86TargetInfo();
            llvm.LLVMInitializeX86TargetMC();
            llvm.LLVMInitializeX86AsmPrinter();
            llvm.LLVMInitializeX86AsmParser();
        },
        .xtensa => {
            if (build_options.llvm_has_xtensa) {
                llvm.LLVMInitializeXtensaTarget();
                llvm.LLVMInitializeXtensaTargetInfo();
                llvm.LLVMInitializeXtensaTargetMC();
                llvm.LLVMInitializeXtensaAsmPrinter();
                llvm.LLVMInitializeXtensaAsmParser();
            }
        },
        .xcore => {
            llvm.LLVMInitializeXCoreTarget();
            llvm.LLVMInitializeXCoreTargetInfo();
            llvm.LLVMInitializeXCoreTargetMC();
            llvm.LLVMInitializeXCoreAsmPrinter();
            // There is no LLVMInitializeXCoreAsmParser function.
        },
        .m68k => {
            if (build_options.llvm_has_m68k) {
                llvm.LLVMInitializeM68kTarget();
                llvm.LLVMInitializeM68kTargetInfo();
                llvm.LLVMInitializeM68kTargetMC();
                llvm.LLVMInitializeM68kAsmPrinter();
                llvm.LLVMInitializeM68kAsmParser();
            }
        },
        .csky => {
            if (build_options.llvm_has_csky) {
                llvm.LLVMInitializeCSKYTarget();
                llvm.LLVMInitializeCSKYTargetInfo();
                llvm.LLVMInitializeCSKYTargetMC();
                // There is no LLVMInitializeCSKYAsmPrinter function.
                llvm.LLVMInitializeCSKYAsmParser();
            }
        },
        .ve => {
            llvm.LLVMInitializeVETarget();
            llvm.LLVMInitializeVETargetInfo();
            llvm.LLVMInitializeVETargetMC();
            llvm.LLVMInitializeVEAsmPrinter();
            llvm.LLVMInitializeVEAsmParser();
        },
        .arc => {
            if (build_options.llvm_has_arc) {
                llvm.LLVMInitializeARCTarget();
                llvm.LLVMInitializeARCTargetInfo();
                llvm.LLVMInitializeARCTargetMC();
                llvm.LLVMInitializeARCAsmPrinter();
                // There is no LLVMInitializeARCAsmParser function.
            }
        },

        // LLVM backends that have no initialization functions.
        .tce,
        .tcele,
        .r600,
        .le32,
        .le64,
        .amdil,
        .amdil64,
        .hsail,
        .hsail64,
        .shave,
        .spir,
        .spir64,
        .kalimba,
        .renderscript32,
        .renderscript64,
        .dxil,
        .loongarch32,
        .loongarch64,
        => {},

        .spu_2 => unreachable, // LLVM does not support this backend
        .spirv32 => unreachable, // LLVM does not support this backend
        .spirv64 => unreachable, // LLVM does not support this backend
    }
}

fn toLlvmAtomicOrdering(atomic_order: std.builtin.AtomicOrder) llvm.AtomicOrdering {
    return switch (atomic_order) {
        .Unordered => .Unordered,
        .Monotonic => .Monotonic,
        .Acquire => .Acquire,
        .Release => .Release,
        .AcqRel => .AcquireRelease,
        .SeqCst => .SequentiallyConsistent,
    };
}

fn toLlvmAtomicRmwBinOp(
    op: std.builtin.AtomicRmwOp,
    is_signed: bool,
    is_float: bool,
) llvm.AtomicRMWBinOp {
    return switch (op) {
        .Xchg => .Xchg,
        .Add => if (is_float) .FAdd else return .Add,
        .Sub => if (is_float) .FSub else return .Sub,
        .And => .And,
        .Nand => .Nand,
        .Or => .Or,
        .Xor => .Xor,
        .Max => if (is_float) .FMax else if (is_signed) .Max else return .UMax,
        .Min => if (is_float) .FMin else if (is_signed) .Min else return .UMin,
    };
}

fn toLlvmCallConv(cc: std.builtin.CallingConvention, target: std.Target) llvm.CallConv {
    return switch (cc) {
        .Unspecified, .Inline, .Async => .Fast,
        .C, .Naked => .C,
        .Stdcall => .X86_StdCall,
        .Fastcall => .X86_FastCall,
        .Vectorcall => return switch (target.cpu.arch) {
            .x86, .x86_64 => .X86_VectorCall,
            .aarch64, .aarch64_be, .aarch64_32 => .AArch64_VectorCall,
            else => unreachable,
        },
        .Thiscall => .X86_ThisCall,
        .APCS => .ARM_APCS,
        .AAPCS => .ARM_AAPCS,
        .AAPCSVFP => .ARM_AAPCS_VFP,
        .Interrupt => return switch (target.cpu.arch) {
            .x86, .x86_64 => .X86_INTR,
            .avr => .AVR_INTR,
            .msp430 => .MSP430_INTR,
            else => unreachable,
        },
        .Signal => .AVR_SIGNAL,
        .SysV => .X86_64_SysV,
        .Win64 => .Win64,
        .Kernel => return switch (target.cpu.arch) {
            .nvptx, .nvptx64 => .PTX_Kernel,
            .amdgcn => .AMDGPU_KERNEL,
            else => unreachable,
        },
    };
}

/// Convert a zig-address space to an llvm address space.
fn toLlvmAddressSpace(address_space: std.builtin.AddressSpace, target: std.Target) Builder.AddrSpace {
    for (llvmAddrSpaceInfo(target)) |info| if (info.zig == address_space) return info.llvm;
    unreachable;
}

const AddrSpaceInfo = struct {
    zig: ?std.builtin.AddressSpace,
    llvm: Builder.AddrSpace,
    non_integral: bool = false,
    size: ?u16 = null,
    abi: ?u16 = null,
    pref: ?u16 = null,
    idx: ?u16 = null,
    force_in_data_layout: bool = false,
};
fn llvmAddrSpaceInfo(target: std.Target) []const AddrSpaceInfo {
    return switch (target.cpu.arch) {
        .x86, .x86_64 => &.{
            .{ .zig = .generic, .llvm = .default },
            .{ .zig = .gs, .llvm = Builder.AddrSpace.x86.gs },
            .{ .zig = .fs, .llvm = Builder.AddrSpace.x86.fs },
            .{ .zig = .ss, .llvm = Builder.AddrSpace.x86.ss },
            .{ .zig = null, .llvm = Builder.AddrSpace.x86.ptr32_sptr, .size = 32, .abi = 32, .force_in_data_layout = true },
            .{ .zig = null, .llvm = Builder.AddrSpace.x86.ptr32_uptr, .size = 32, .abi = 32, .force_in_data_layout = true },
            .{ .zig = null, .llvm = Builder.AddrSpace.x86.ptr64, .size = 64, .abi = 64, .force_in_data_layout = true },
        },
        .nvptx, .nvptx64 => &.{
            .{ .zig = .generic, .llvm = .default },
            .{ .zig = .global, .llvm = Builder.AddrSpace.nvptx.global },
            .{ .zig = .constant, .llvm = Builder.AddrSpace.nvptx.constant },
            .{ .zig = .param, .llvm = Builder.AddrSpace.nvptx.param },
            .{ .zig = .shared, .llvm = Builder.AddrSpace.nvptx.shared },
            .{ .zig = .local, .llvm = Builder.AddrSpace.nvptx.local },
        },
        .amdgcn => &.{
            .{ .zig = .generic, .llvm = Builder.AddrSpace.amdgpu.flat },
            .{ .zig = .global, .llvm = Builder.AddrSpace.amdgpu.global },
            .{ .zig = .constant, .llvm = Builder.AddrSpace.amdgpu.constant },
            .{ .zig = .shared, .llvm = Builder.AddrSpace.amdgpu.local },
            .{ .zig = .local, .llvm = Builder.AddrSpace.amdgpu.private },
        },
        .avr => &.{
            .{ .zig = .generic, .llvm = .default },
            .{ .zig = .flash, .llvm = Builder.AddrSpace.avr.flash },
            .{ .zig = .flash1, .llvm = Builder.AddrSpace.avr.flash1 },
            .{ .zig = .flash2, .llvm = Builder.AddrSpace.avr.flash2 },
            .{ .zig = .flash3, .llvm = Builder.AddrSpace.avr.flash3 },
            .{ .zig = .flash4, .llvm = Builder.AddrSpace.avr.flash4 },
            .{ .zig = .flash5, .llvm = Builder.AddrSpace.avr.flash5 },
        },
        .wasm32, .wasm64 => &.{
            .{ .zig = .generic, .llvm = .default },
            .{ .zig = null, .llvm = Builder.AddrSpace.wasm.variable, .non_integral = true },
            .{ .zig = null, .llvm = Builder.AddrSpace.wasm.externref, .non_integral = true, .size = 8, .abi = 8 },
            .{ .zig = null, .llvm = Builder.AddrSpace.wasm.funcref, .non_integral = true, .size = 8, .abi = 8 },
        },
        else => &.{
            .{ .zig = .generic, .llvm = .default },
        },
    };
}

/// On some targets, local values that are in the generic address space must be generated into a
/// different address, space and then cast back to the generic address space.
/// For example, on GPUs local variable declarations must be generated into the local address space.
/// This function returns the address space local values should be generated into.
fn llvmAllocaAddressSpace(target: std.Target) Builder.AddrSpace {
    return switch (target.cpu.arch) {
        // On amdgcn, locals should be generated into the private address space.
        // To make Zig not impossible to use, these are then converted to addresses in the
        // generic address space and treates as regular pointers. This is the way that HIP also does it.
        .amdgcn => Builder.AddrSpace.amdgpu.private,
        else => .default,
    };
}

/// On some targets, global values that are in the generic address space must be generated into a
/// different address space, and then cast back to the generic address space.
fn llvmDefaultGlobalAddressSpace(target: std.Target) Builder.AddrSpace {
    return switch (target.cpu.arch) {
        // On amdgcn, globals must be explicitly allocated and uploaded so that the program can access
        // them.
        .amdgcn => Builder.AddrSpace.amdgpu.global,
        else => .default,
    };
}

/// Return the actual address space that a value should be stored in if its a global address space.
/// When a value is placed in the resulting address space, it needs to be cast back into wanted_address_space.
fn toLlvmGlobalAddressSpace(wanted_address_space: std.builtin.AddressSpace, target: std.Target) Builder.AddrSpace {
    return switch (wanted_address_space) {
        .generic => llvmDefaultGlobalAddressSpace(target),
        else => |as| toLlvmAddressSpace(as, target),
    };
}

const LlvmField = struct {
    index: c_uint,
    ty: Type,
    alignment: u32,
};

/// Take into account 0 bit fields and padding. Returns null if an llvm
/// field could not be found.
/// This only happens if you want the field index of a zero sized field at
/// the end of the struct.
fn llvmField(ty: Type, field_index: usize, mod: *Module) ?LlvmField {
    // Detects where we inserted extra padding fields so that we can skip
    // over them in this function.
    comptime assert(struct_layout_version == 2);
    var offset: u64 = 0;
    var big_align: u32 = 0;

    const struct_type = switch (mod.intern_pool.indexToKey(ty.toIntern())) {
        .anon_struct_type => |tuple| {
            var llvm_field_index: c_uint = 0;
            for (tuple.types, tuple.values, 0..) |field_ty, field_val, i| {
                if (field_val != .none or !field_ty.toType().hasRuntimeBits(mod)) continue;

                const field_align = field_ty.toType().abiAlignment(mod);
                big_align = @max(big_align, field_align);
                const prev_offset = offset;
                offset = std.mem.alignForward(u64, offset, field_align);

                const padding_len = offset - prev_offset;
                if (padding_len > 0) {
                    llvm_field_index += 1;
                }

                if (field_index <= i) {
                    return .{
                        .index = llvm_field_index,
                        .ty = field_ty.toType(),
                        .alignment = field_align,
                    };
                }

                llvm_field_index += 1;
                offset += field_ty.toType().abiSize(mod);
            }
            return null;
        },
        .struct_type => |s| s,
        else => unreachable,
    };
    const struct_obj = mod.structPtrUnwrap(struct_type.index).?;
    const layout = struct_obj.layout;
    assert(layout != .Packed);

    var llvm_field_index: c_uint = 0;
    var it = struct_obj.runtimeFieldIterator(mod);
    while (it.next()) |field_and_index| {
        const field = field_and_index.field;
        const field_align = field.alignment(mod, layout);
        big_align = @max(big_align, field_align);
        const prev_offset = offset;
        offset = std.mem.alignForward(u64, offset, field_align);

        const padding_len = offset - prev_offset;
        if (padding_len > 0) {
            llvm_field_index += 1;
        }

        if (field_index == field_and_index.index) {
            return .{
                .index = llvm_field_index,
                .ty = field.ty,
                .alignment = field_align,
            };
        }

        llvm_field_index += 1;
        offset += field.ty.abiSize(mod);
    } else {
        // We did not find an llvm field that corresponds to this zig field.
        return null;
    }
}

fn firstParamSRet(fn_info: InternPool.Key.FuncType, mod: *Module) bool {
    if (!fn_info.return_type.toType().hasRuntimeBitsIgnoreComptime(mod)) return false;

    const target = mod.getTarget();
    switch (fn_info.cc) {
        .Unspecified, .Inline => return isByRef(fn_info.return_type.toType(), mod),
        .C => switch (target.cpu.arch) {
            .mips, .mipsel => return false,
            .x86_64 => switch (target.os.tag) {
                .windows => return x86_64_abi.classifyWindows(fn_info.return_type.toType(), mod) == .memory,
                else => return firstParamSRetSystemV(fn_info.return_type.toType(), mod),
            },
            .wasm32 => return wasm_c_abi.classifyType(fn_info.return_type.toType(), mod)[0] == .indirect,
            .aarch64, .aarch64_be => return aarch64_c_abi.classifyType(fn_info.return_type.toType(), mod) == .memory,
            .arm, .armeb => switch (arm_c_abi.classifyType(fn_info.return_type.toType(), mod, .ret)) {
                .memory, .i64_array => return true,
                .i32_array => |size| return size != 1,
                .byval => return false,
            },
            .riscv32, .riscv64 => return riscv_c_abi.classifyType(fn_info.return_type.toType(), mod) == .memory,
            else => return false, // TODO investigate C ABI for other architectures
        },
        .SysV => return firstParamSRetSystemV(fn_info.return_type.toType(), mod),
        .Win64 => return x86_64_abi.classifyWindows(fn_info.return_type.toType(), mod) == .memory,
        .Stdcall => return !isScalar(mod, fn_info.return_type.toType()),
        else => return false,
    }
}

fn firstParamSRetSystemV(ty: Type, mod: *Module) bool {
    const class = x86_64_abi.classifySystemV(ty, mod, .ret);
    if (class[0] == .memory) return true;
    if (class[0] == .x87 and class[2] != .none) return true;
    return false;
}

/// In order to support the C calling convention, some return types need to be lowered
/// completely differently in the function prototype to honor the C ABI, and then
/// be effectively bitcasted to the actual return type.
fn lowerFnRetTy(o: *Object, fn_info: InternPool.Key.FuncType) Allocator.Error!Builder.Type {
    const mod = o.module;
    const return_type = fn_info.return_type.toType();
    if (!return_type.hasRuntimeBitsIgnoreComptime(mod)) {
        // If the return type is an error set or an error union, then we make this
        // anyerror return type instead, so that it can be coerced into a function
        // pointer type which has anyerror as the return type.
        return if (return_type.isError(mod)) Builder.Type.err_int else .void;
    }
    const target = mod.getTarget();
    switch (fn_info.cc) {
        .Unspecified,
        .Inline,
        => return if (isByRef(return_type, mod)) .void else o.lowerType(return_type),
        .C => {
            switch (target.cpu.arch) {
                .mips, .mipsel => return o.lowerType(return_type),
                .x86_64 => switch (target.os.tag) {
                    .windows => return lowerWin64FnRetTy(o, fn_info),
                    else => return lowerSystemVFnRetTy(o, fn_info),
                },
                .wasm32 => {
                    if (isScalar(mod, return_type)) {
                        return o.lowerType(return_type);
                    }
                    const classes = wasm_c_abi.classifyType(return_type, mod);
                    if (classes[0] == .indirect or classes[0] == .none) {
                        return .void;
                    }

                    assert(classes[0] == .direct and classes[1] == .none);
                    const scalar_type = wasm_c_abi.scalarType(return_type, mod);
                    return o.builder.intType(@intCast(scalar_type.abiSize(mod) * 8));
                },
                .aarch64, .aarch64_be => {
                    switch (aarch64_c_abi.classifyType(return_type, mod)) {
                        .memory => return .void,
                        .float_array => return o.lowerType(return_type),
                        .byval => return o.lowerType(return_type),
                        .integer => return o.builder.intType(@intCast(return_type.bitSize(mod))),
                        .double_integer => return o.builder.arrayType(2, .i64),
                    }
                },
                .arm, .armeb => {
                    switch (arm_c_abi.classifyType(return_type, mod, .ret)) {
                        .memory, .i64_array => return .void,
                        .i32_array => |len| return if (len == 1) .i32 else .void,
                        .byval => return o.lowerType(return_type),
                    }
                },
                .riscv32, .riscv64 => {
                    switch (riscv_c_abi.classifyType(return_type, mod)) {
                        .memory => return .void,
                        .integer => {
                            return o.builder.intType(@intCast(return_type.bitSize(mod)));
                        },
                        .double_integer => {
                            return o.builder.structType(.normal, &.{ .i64, .i64 });
                        },
                        .byval => return o.lowerType(return_type),
                    }
                },
                // TODO investigate C ABI for other architectures
                else => return o.lowerType(return_type),
            }
        },
        .Win64 => return lowerWin64FnRetTy(o, fn_info),
        .SysV => return lowerSystemVFnRetTy(o, fn_info),
        .Stdcall => return if (isScalar(mod, return_type)) o.lowerType(return_type) else .void,
        else => return o.lowerType(return_type),
    }
}

fn lowerWin64FnRetTy(o: *Object, fn_info: InternPool.Key.FuncType) Allocator.Error!Builder.Type {
    const mod = o.module;
    const return_type = fn_info.return_type.toType();
    switch (x86_64_abi.classifyWindows(return_type, mod)) {
        .integer => {
            if (isScalar(mod, return_type)) {
                return o.lowerType(return_type);
            } else {
                return o.builder.intType(@intCast(return_type.abiSize(mod) * 8));
            }
        },
        .win_i128 => return o.builder.vectorType(.normal, 2, .i64),
        .memory => return .void,
        .sse => return o.lowerType(return_type),
        else => unreachable,
    }
}

fn lowerSystemVFnRetTy(o: *Object, fn_info: InternPool.Key.FuncType) Allocator.Error!Builder.Type {
    const mod = o.module;
    const return_type = fn_info.return_type.toType();
    if (isScalar(mod, return_type)) {
        return o.lowerType(return_type);
    }
    const classes = x86_64_abi.classifySystemV(return_type, mod, .ret);
    if (classes[0] == .memory) return .void;
    var types_index: u32 = 0;
    var types_buffer: [8]Builder.Type = undefined;
    for (classes) |class| {
        switch (class) {
            .integer => {
                types_buffer[types_index] = .i64;
                types_index += 1;
            },
            .sse, .sseup => {
                types_buffer[types_index] = .double;
                types_index += 1;
            },
            .float => {
                types_buffer[types_index] = .float;
                types_index += 1;
            },
            .float_combine => {
                types_buffer[types_index] = try o.builder.vectorType(.normal, 2, .float);
                types_index += 1;
            },
            .x87 => {
                if (types_index != 0 or classes[2] != .none) return .void;
                types_buffer[types_index] = .x86_fp80;
                types_index += 1;
            },
            .x87up => continue,
            .complex_x87 => {
                @panic("TODO");
            },
            .memory => unreachable, // handled above
            .win_i128 => unreachable, // windows only
            .none => break,
        }
    }
    if (classes[0] == .integer and classes[1] == .none) {
        return o.builder.intType(@intCast(return_type.abiSize(mod) * 8));
    }
    return o.builder.structType(.normal, types_buffer[0..types_index]);
}

const ParamTypeIterator = struct {
    object: *Object,
    fn_info: InternPool.Key.FuncType,
    zig_index: u32,
    llvm_index: u32,
    types_len: u32,
    types_buffer: [8]Builder.Type,
    byval_attr: bool,

    const Lowering = union(enum) {
        no_bits,
        byval,
        byref,
        byref_mut,
        abi_sized_int,
        multiple_llvm_types,
        slice,
        as_u16,
        float_array: u8,
        i32_array: u8,
        i64_array: u8,
    };

    pub fn next(it: *ParamTypeIterator) Allocator.Error!?Lowering {
        if (it.zig_index >= it.fn_info.param_types.len) return null;
        const ty = it.fn_info.param_types[it.zig_index];
        it.byval_attr = false;
        return nextInner(it, ty.toType());
    }

    /// `airCall` uses this instead of `next` so that it can take into account variadic functions.
    pub fn nextCall(it: *ParamTypeIterator, fg: *FuncGen, args: []const Air.Inst.Ref) Allocator.Error!?Lowering {
        if (it.zig_index >= it.fn_info.param_types.len) {
            if (it.zig_index >= args.len) {
                return null;
            } else {
                return nextInner(it, fg.typeOf(args[it.zig_index]));
            }
        } else {
            return nextInner(it, it.fn_info.param_types[it.zig_index].toType());
        }
    }

    fn nextInner(it: *ParamTypeIterator, ty: Type) Allocator.Error!?Lowering {
        const mod = it.object.module;
        const target = mod.getTarget();

        if (!ty.hasRuntimeBitsIgnoreComptime(mod)) {
            it.zig_index += 1;
            return .no_bits;
        }
        switch (it.fn_info.cc) {
            .Unspecified, .Inline => {
                it.zig_index += 1;
                it.llvm_index += 1;
                if (ty.isSlice(mod) or (ty.zigTypeTag(mod) == .Optional and ty.optionalChild(mod).isSlice(mod))) {
                    it.llvm_index += 1;
                    return .slice;
                } else if (isByRef(ty, mod)) {
                    return .byref;
                } else {
                    return .byval;
                }
            },
            .Async => {
                @panic("TODO implement async function lowering in the LLVM backend");
            },
            .C => {
                switch (target.cpu.arch) {
                    .mips, .mipsel => {
                        it.zig_index += 1;
                        it.llvm_index += 1;
                        return .byval;
                    },
                    .x86_64 => switch (target.os.tag) {
                        .windows => return it.nextWin64(ty),
                        else => return it.nextSystemV(ty),
                    },
                    .wasm32 => {
                        it.zig_index += 1;
                        it.llvm_index += 1;
                        if (isScalar(mod, ty)) {
                            return .byval;
                        }
                        const classes = wasm_c_abi.classifyType(ty, mod);
                        if (classes[0] == .indirect) {
                            return .byref;
                        }
                        return .abi_sized_int;
                    },
                    .aarch64, .aarch64_be => {
                        it.zig_index += 1;
                        it.llvm_index += 1;
                        switch (aarch64_c_abi.classifyType(ty, mod)) {
                            .memory => return .byref_mut,
                            .float_array => |len| return Lowering{ .float_array = len },
                            .byval => return .byval,
                            .integer => {
                                it.types_len = 1;
                                it.types_buffer[0] = .i64;
                                return .multiple_llvm_types;
                            },
                            .double_integer => return Lowering{ .i64_array = 2 },
                        }
                    },
                    .arm, .armeb => {
                        it.zig_index += 1;
                        it.llvm_index += 1;
                        switch (arm_c_abi.classifyType(ty, mod, .arg)) {
                            .memory => {
                                it.byval_attr = true;
                                return .byref;
                            },
                            .byval => return .byval,
                            .i32_array => |size| return Lowering{ .i32_array = size },
                            .i64_array => |size| return Lowering{ .i64_array = size },
                        }
                    },
                    .riscv32, .riscv64 => {
                        it.zig_index += 1;
                        it.llvm_index += 1;
                        if (ty.toIntern() == .f16_type) {
                            return .as_u16;
                        }
                        switch (riscv_c_abi.classifyType(ty, mod)) {
                            .memory => return .byref_mut,
                            .byval => return .byval,
                            .integer => return .abi_sized_int,
                            .double_integer => return Lowering{ .i64_array = 2 },
                        }
                    },
                    // TODO investigate C ABI for other architectures
                    else => {
                        it.zig_index += 1;
                        it.llvm_index += 1;
                        return .byval;
                    },
                }
            },
            .Win64 => return it.nextWin64(ty),
            .SysV => return it.nextSystemV(ty),
            .Stdcall => {
                it.zig_index += 1;
                it.llvm_index += 1;

                if (isScalar(mod, ty)) {
                    return .byval;
                } else {
                    it.byval_attr = true;
                    return .byref;
                }
            },
            else => {
                it.zig_index += 1;
                it.llvm_index += 1;
                return .byval;
            },
        }
    }

    fn nextWin64(it: *ParamTypeIterator, ty: Type) ?Lowering {
        const mod = it.object.module;
        switch (x86_64_abi.classifyWindows(ty, mod)) {
            .integer => {
                if (isScalar(mod, ty)) {
                    it.zig_index += 1;
                    it.llvm_index += 1;
                    return .byval;
                } else {
                    it.zig_index += 1;
                    it.llvm_index += 1;
                    return .abi_sized_int;
                }
            },
            .win_i128 => {
                it.zig_index += 1;
                it.llvm_index += 1;
                return .byref;
            },
            .memory => {
                it.zig_index += 1;
                it.llvm_index += 1;
                return .byref_mut;
            },
            .sse => {
                it.zig_index += 1;
                it.llvm_index += 1;
                return .byval;
            },
            else => unreachable,
        }
    }

    fn nextSystemV(it: *ParamTypeIterator, ty: Type) Allocator.Error!?Lowering {
        const mod = it.object.module;
        const classes = x86_64_abi.classifySystemV(ty, mod, .arg);
        if (classes[0] == .memory) {
            it.zig_index += 1;
            it.llvm_index += 1;
            it.byval_attr = true;
            return .byref;
        }
        if (isScalar(mod, ty)) {
            it.zig_index += 1;
            it.llvm_index += 1;
            return .byval;
        }
        var types_index: u32 = 0;
        var types_buffer: [8]Builder.Type = undefined;
        for (classes) |class| {
            switch (class) {
                .integer => {
                    types_buffer[types_index] = .i64;
                    types_index += 1;
                },
                .sse, .sseup => {
                    types_buffer[types_index] = .double;
                    types_index += 1;
                },
                .float => {
                    types_buffer[types_index] = .float;
                    types_index += 1;
                },
                .float_combine => {
                    types_buffer[types_index] = try it.object.builder.vectorType(.normal, 2, .float);
                    types_index += 1;
                },
                .x87 => {
                    it.zig_index += 1;
                    it.llvm_index += 1;
                    it.byval_attr = true;
                    return .byref;
                },
                .x87up => unreachable,
                .complex_x87 => {
                    @panic("TODO");
                },
                .memory => unreachable, // handled above
                .win_i128 => unreachable, // windows only
                .none => break,
            }
        }
        if (classes[0] == .integer and classes[1] == .none) {
            it.zig_index += 1;
            it.llvm_index += 1;
            return .abi_sized_int;
        }
        it.types_len = types_index;
        it.types_buffer = types_buffer;
        it.llvm_index += types_index;
        it.zig_index += 1;
        return .multiple_llvm_types;
    }
};

fn iterateParamTypes(object: *Object, fn_info: InternPool.Key.FuncType) ParamTypeIterator {
    return .{
        .object = object,
        .fn_info = fn_info,
        .zig_index = 0,
        .llvm_index = 0,
        .types_len = 0,
        .types_buffer = undefined,
        .byval_attr = false,
    };
}

fn ccAbiPromoteInt(
    cc: std.builtin.CallingConvention,
    mod: *Module,
    ty: Type,
) ?std.builtin.Signedness {
    const target = mod.getTarget();
    switch (cc) {
        .Unspecified, .Inline, .Async => return null,
        else => {},
    }
    const int_info = switch (ty.zigTypeTag(mod)) {
        .Bool => Type.u1.intInfo(mod),
        .Int, .Enum, .ErrorSet => ty.intInfo(mod),
        else => return null,
    };
    if (int_info.bits <= 16) return int_info.signedness;
    switch (target.cpu.arch) {
        .riscv64 => {
            if (int_info.bits == 32) {
                // LLVM always signextends 32 bit ints, unsure if bug.
                return .signed;
            }
            if (int_info.bits < 64) {
                return int_info.signedness;
            }
        },
        .sparc64,
        .powerpc64,
        .powerpc64le,
        => {
            if (int_info.bits < 64) {
                return int_info.signedness;
            }
        },
        else => {},
    }
    return null;
}

/// This is the one source of truth for whether a type is passed around as an LLVM pointer,
/// or as an LLVM value.
fn isByRef(ty: Type, mod: *Module) bool {
    // For tuples and structs, if there are more than this many non-void
    // fields, then we make it byref, otherwise byval.
    const max_fields_byval = 0;

    switch (ty.zigTypeTag(mod)) {
        .Type,
        .ComptimeInt,
        .ComptimeFloat,
        .EnumLiteral,
        .Undefined,
        .Null,
        .Opaque,
        => unreachable,

        .NoReturn,
        .Void,
        .Bool,
        .Int,
        .Float,
        .Pointer,
        .ErrorSet,
        .Fn,
        .Enum,
        .Vector,
        .AnyFrame,
        => return false,

        .Array, .Frame => return ty.hasRuntimeBits(mod),
        .Struct => {
            // Packed structs are represented to LLVM as integers.
            if (ty.containerLayout(mod) == .Packed) return false;
            const struct_type = switch (mod.intern_pool.indexToKey(ty.toIntern())) {
                .anon_struct_type => |tuple| {
                    var count: usize = 0;
                    for (tuple.types, tuple.values) |field_ty, field_val| {
                        if (field_val != .none or !field_ty.toType().hasRuntimeBits(mod)) continue;

                        count += 1;
                        if (count > max_fields_byval) return true;
                        if (isByRef(field_ty.toType(), mod)) return true;
                    }
                    return false;
                },
                .struct_type => |s| s,
                else => unreachable,
            };
            const struct_obj = mod.structPtrUnwrap(struct_type.index).?;
            var count: usize = 0;
            for (struct_obj.fields.values()) |field| {
                if (field.is_comptime or !field.ty.hasRuntimeBits(mod)) continue;

                count += 1;
                if (count > max_fields_byval) return true;
                if (isByRef(field.ty, mod)) return true;
            }
            return false;
        },
        .Union => switch (ty.containerLayout(mod)) {
            .Packed => return false,
            else => return ty.hasRuntimeBits(mod),
        },
        .ErrorUnion => {
            const payload_ty = ty.errorUnionPayload(mod);
            if (!payload_ty.hasRuntimeBitsIgnoreComptime(mod)) {
                return false;
            }
            return true;
        },
        .Optional => {
            const payload_ty = ty.optionalChild(mod);
            if (!payload_ty.hasRuntimeBitsIgnoreComptime(mod)) {
                return false;
            }
            if (ty.optionalReprIsPayload(mod)) {
                return false;
            }
            return true;
        },
    }
}

fn isScalar(mod: *Module, ty: Type) bool {
    return switch (ty.zigTypeTag(mod)) {
        .Void,
        .Bool,
        .NoReturn,
        .Int,
        .Float,
        .Pointer,
        .Optional,
        .ErrorSet,
        .Enum,
        .AnyFrame,
        .Vector,
        => true,

        .Struct => ty.containerLayout(mod) == .Packed,
        .Union => ty.containerLayout(mod) == .Packed,
        else => false,
    };
}

/// This function returns true if we expect LLVM to lower x86_fp80 correctly
/// and false if we expect LLVM to crash if it counters an x86_fp80 type.
fn backendSupportsF80(target: std.Target) bool {
    return switch (target.cpu.arch) {
        .x86_64, .x86 => !std.Target.x86.featureSetHas(target.cpu.features, .soft_float),
        else => false,
    };
}

/// This function returns true if we expect LLVM to lower f16 correctly
/// and false if we expect LLVM to crash if it counters an f16 type or
/// if it produces miscompilations.
fn backendSupportsF16(target: std.Target) bool {
    return switch (target.cpu.arch) {
        .powerpc,
        .powerpcle,
        .powerpc64,
        .powerpc64le,
        .wasm32,
        .wasm64,
        .mips,
        .mipsel,
        .mips64,
        .mips64el,
        => false,
        .aarch64 => std.Target.aarch64.featureSetHas(target.cpu.features, .fp_armv8),
        else => true,
    };
}

/// This function returns true if we expect LLVM to lower f128 correctly,
/// and false if we expect LLVm to crash if it encounters and f128 type
/// or if it produces miscompilations.
fn backendSupportsF128(target: std.Target) bool {
    return switch (target.cpu.arch) {
        .amdgcn => false,
        .aarch64 => std.Target.aarch64.featureSetHas(target.cpu.features, .fp_armv8),
        else => true,
    };
}

/// LLVM does not support all relevant intrinsics for all targets, so we
/// may need to manually generate a libc call
fn intrinsicsAllowed(scalar_ty: Type, target: std.Target) bool {
    return switch (scalar_ty.toIntern()) {
        .f16_type => backendSupportsF16(target),
        .f80_type => (target.c_type_bit_size(.longdouble) == 80) and backendSupportsF80(target),
        .f128_type => (target.c_type_bit_size(.longdouble) == 128) and backendSupportsF128(target),
        else => true,
    };
}

/// We need to insert extra padding if LLVM's isn't enough.
/// However we don't want to ever call LLVMABIAlignmentOfType or
/// LLVMABISizeOfType because these functions will trip assertions
/// when using them for self-referential types. So our strategy is
/// to use non-packed llvm structs but to emit all padding explicitly.
/// We can do this because for all types, Zig ABI alignment >= LLVM ABI
/// alignment.
const struct_layout_version = 2;

// TODO: Restore the non_null field to i1 once
//       https://github.com/llvm/llvm-project/issues/56585/ is fixed
const optional_layout_version = 3;

/// We use the least significant bit of the pointer address to tell us
/// whether the type is fully resolved. Types that are only fwd declared
/// have the LSB flipped to a 1.
const AnnotatedDITypePtr = enum(usize) {
    _,

    fn initFwd(di_type: *llvm.DIType) AnnotatedDITypePtr {
        const addr = @intFromPtr(di_type);
        assert(@as(u1, @truncate(addr)) == 0);
        return @as(AnnotatedDITypePtr, @enumFromInt(addr | 1));
    }

    fn initFull(di_type: *llvm.DIType) AnnotatedDITypePtr {
        const addr = @intFromPtr(di_type);
        return @as(AnnotatedDITypePtr, @enumFromInt(addr));
    }

    fn init(di_type: *llvm.DIType, resolve: Object.DebugResolveStatus) AnnotatedDITypePtr {
        const addr = @intFromPtr(di_type);
        const bit = @intFromBool(resolve == .fwd);
        return @as(AnnotatedDITypePtr, @enumFromInt(addr | bit));
    }

    fn toDIType(self: AnnotatedDITypePtr) *llvm.DIType {
        const fixed_addr = @intFromEnum(self) & ~@as(usize, 1);
        return @as(*llvm.DIType, @ptrFromInt(fixed_addr));
    }

    fn isFwdOnly(self: AnnotatedDITypePtr) bool {
        return @as(u1, @truncate(@intFromEnum(self))) != 0;
    }
};

const lt_errors_fn_name = "__zig_lt_errors_len";

/// Without this workaround, LLVM crashes with "unknown codeview register H1"
/// https://github.com/llvm/llvm-project/issues/56484
fn needDbgVarWorkaround(o: *Object) bool {
    const target = o.module.getTarget();
    if (target.os.tag == .windows and target.cpu.arch == .aarch64) {
        return true;
    }
    return false;
}

fn compilerRtIntBits(bits: u16) u16 {
    inline for (.{ 32, 64, 128 }) |b| {
        if (bits <= b) {
            return b;
        }
    }
    return bits;
}

fn errUnionPayloadOffset(payload_ty: Type, mod: *Module) u1 {
    return @intFromBool(Type.anyerror.abiAlignment(mod) > payload_ty.abiAlignment(mod));
}

fn errUnionErrorOffset(payload_ty: Type, mod: *Module) u1 {
    return @intFromBool(Type.anyerror.abiAlignment(mod) <= payload_ty.abiAlignment(mod));
}

/// Returns true for asm constraint (e.g. "=*m", "=r") if it accepts a memory location
///
/// See also TargetInfo::validateOutputConstraint, AArch64TargetInfo::validateAsmConstraint, etc. in Clang
fn constraintAllowsMemory(constraint: []const u8) bool {
    // TODO: This implementation is woefully incomplete.
    for (constraint) |byte| {
        switch (byte) {
            '=', '*', ',', '&' => {},
            'm', 'o', 'X', 'g' => return true,
            else => {},
        }
    } else return false;
}

/// Returns true for asm constraint (e.g. "=*m", "=r") if it accepts a register
///
/// See also TargetInfo::validateOutputConstraint, AArch64TargetInfo::validateAsmConstraint, etc. in Clang
fn constraintAllowsRegister(constraint: []const u8) bool {
    // TODO: This implementation is woefully incomplete.
    for (constraint) |byte| {
        switch (byte) {
            '=', '*', ',', '&' => {},
            'm', 'o' => {},
            else => return true,
        }
    } else return false;
}
