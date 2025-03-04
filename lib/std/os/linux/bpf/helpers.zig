const std = @import("../../../std.zig");
const kern = @import("kern.zig");

const PtRegs = @compileError("TODO missing os bits: PtRegs");
const TcpHdr = @compileError("TODO missing os bits: TcpHdr");
const SkFullSock = @compileError("TODO missing os bits: SkFullSock");

// in BPF, all the helper calls
// TODO: when https://github.com/ziglang/zig/issues/1717 is here, make a nice
// function that uses the Helper enum
//
// Note, these function signatures were created from documentation found in
// '/usr/include/linux/bpf.h'
pub const map_lookup_elem: *align(1) const fn (map: *const kern.MapDef, key: ?*const anyopaque) ?*anyopaque = @ptrFromInt(1);
pub const map_update_elem: *align(1) const fn (map: *const kern.MapDef, key: ?*const anyopaque, value: ?*const anyopaque, flags: u64) c_long = @ptrFromInt(2);
pub const map_delete_elem: *align(1) const fn (map: *const kern.MapDef, key: ?*const anyopaque) c_long = @ptrFromInt(3);
pub const probe_read: *align(1) const fn (dst: ?*anyopaque, size: u32, unsafe_ptr: ?*const anyopaque) c_long = @ptrFromInt(4);
pub const ktime_get_ns: *align(1) const fn () u64 = @ptrFromInt(5);
pub const trace_printk: *align(1) const fn (fmt: [*:0]const u8, fmt_size: u32, arg1: u64, arg2: u64, arg3: u64) c_long = @ptrFromInt(6);
pub const get_prandom_u32: *align(1) const fn () u32 = @ptrFromInt(7);
pub const get_smp_processor_id: *align(1) const fn () u32 = @ptrFromInt(8);
pub const skb_store_bytes: *align(1) const fn (skb: *kern.SkBuff, offset: u32, from: ?*const anyopaque, len: u32, flags: u64) c_long = @ptrFromInt(9);
pub const l3_csum_replace: *align(1) const fn (skb: *kern.SkBuff, offset: u32, from: u64, to: u64, size: u64) c_long = @ptrFromInt(10);
pub const l4_csum_replace: *align(1) const fn (skb: *kern.SkBuff, offset: u32, from: u64, to: u64, flags: u64) c_long = @ptrFromInt(11);
pub const tail_call: *align(1) const fn (ctx: ?*anyopaque, prog_array_map: *const kern.MapDef, index: u32) c_long = @ptrFromInt(12);
pub const clone_redirect: *align(1) const fn (skb: *kern.SkBuff, ifindex: u32, flags: u64) c_long = @ptrFromInt(13);
pub const get_current_pid_tgid: *align(1) const fn () u64 = @ptrFromInt(14);
pub const get_current_uid_gid: *align(1) const fn () u64 = @ptrFromInt(15);
pub const get_current_comm: *align(1) const fn (buf: ?*anyopaque, size_of_buf: u32) c_long = @ptrFromInt(16);
pub const get_cgroup_classid: *align(1) const fn (skb: *kern.SkBuff) u32 = @ptrFromInt(17);
// Note vlan_proto is big endian
pub const skb_vlan_push: *align(1) const fn (skb: *kern.SkBuff, vlan_proto: u16, vlan_tci: u16) c_long = @ptrFromInt(18);
pub const skb_vlan_pop: *align(1) const fn (skb: *kern.SkBuff) c_long = @ptrFromInt(19);
pub const skb_get_tunnel_key: *align(1) const fn (skb: *kern.SkBuff, key: *kern.TunnelKey, size: u32, flags: u64) c_long = @ptrFromInt(20);
pub const skb_set_tunnel_key: *align(1) const fn (skb: *kern.SkBuff, key: *kern.TunnelKey, size: u32, flags: u64) c_long = @ptrFromInt(21);
pub const perf_event_read: *align(1) const fn (map: *const kern.MapDef, flags: u64) u64 = @ptrFromInt(22);
pub const redirect: *align(1) const fn (ifindex: u32, flags: u64) c_long = @ptrFromInt(23);
pub const get_route_realm: *align(1) const fn (skb: *kern.SkBuff) u32 = @ptrFromInt(24);
pub const perf_event_output: *align(1) const fn (ctx: ?*anyopaque, map: *const kern.MapDef, flags: u64, data: ?*anyopaque, size: u64) c_long = @ptrFromInt(25);
pub const skb_load_bytes: *align(1) const fn (skb: ?*anyopaque, offset: u32, to: ?*anyopaque, len: u32) c_long = @ptrFromInt(26);
pub const get_stackid: *align(1) const fn (ctx: ?*anyopaque, map: *const kern.MapDef, flags: u64) c_long = @ptrFromInt(27);
// from and to point to __be32
pub const csum_diff: *align(1) const fn (from: *u32, from_size: u32, to: *u32, to_size: u32, seed: u32) i64 = @ptrFromInt(28);
pub const skb_get_tunnel_opt: *align(1) const fn (skb: *kern.SkBuff, opt: ?*anyopaque, size: u32) c_long = @ptrFromInt(29);
pub const skb_set_tunnel_opt: *align(1) const fn (skb: *kern.SkBuff, opt: ?*anyopaque, size: u32) c_long = @ptrFromInt(30);
// proto is __be16
pub const skb_change_proto: *align(1) const fn (skb: *kern.SkBuff, proto: u16, flags: u64) c_long = @ptrFromInt(31);
pub const skb_change_type: *align(1) const fn (skb: *kern.SkBuff, skb_type: u32) c_long = @ptrFromInt(32);
pub const skb_under_cgroup: *align(1) const fn (skb: *kern.SkBuff, map: ?*const anyopaque, index: u32) c_long = @ptrFromInt(33);
pub const get_hash_recalc: *align(1) const fn (skb: *kern.SkBuff) u32 = @ptrFromInt(34);
pub const get_current_task: *align(1) const fn () u64 = @ptrFromInt(35);
pub const probe_write_user: *align(1) const fn (dst: ?*anyopaque, src: ?*const anyopaque, len: u32) c_long = @ptrFromInt(36);
pub const current_task_under_cgroup: *align(1) const fn (map: *const kern.MapDef, index: u32) c_long = @ptrFromInt(37);
pub const skb_change_tail: *align(1) const fn (skb: *kern.SkBuff, len: u32, flags: u64) c_long = @ptrFromInt(38);
pub const skb_pull_data: *align(1) const fn (skb: *kern.SkBuff, len: u32) c_long = @ptrFromInt(39);
pub const csum_update: *align(1) const fn (skb: *kern.SkBuff, csum: u32) i64 = @ptrFromInt(40);
pub const set_hash_invalid: *align(1) const fn (skb: *kern.SkBuff) void = @ptrFromInt(41);
pub const get_numa_node_id: *align(1) const fn () c_long = @ptrFromInt(42);
pub const skb_change_head: *align(1) const fn (skb: *kern.SkBuff, len: u32, flags: u64) c_long = @ptrFromInt(43);
pub const xdp_adjust_head: *align(1) const fn (xdp_md: *kern.XdpMd, delta: c_int) c_long = @ptrFromInt(44);
pub const probe_read_str: *align(1) const fn (dst: ?*anyopaque, size: u32, unsafe_ptr: ?*const anyopaque) c_long = @ptrFromInt(45);
pub const get_socket_cookie: *align(1) const fn (ctx: ?*anyopaque) u64 = @ptrFromInt(46);
pub const get_socket_uid: *align(1) const fn (skb: *kern.SkBuff) u32 = @ptrFromInt(47);
pub const set_hash: *align(1) const fn (skb: *kern.SkBuff, hash: u32) c_long = @ptrFromInt(48);
pub const setsockopt: *align(1) const fn (bpf_socket: *kern.SockOps, level: c_int, optname: c_int, optval: ?*anyopaque, optlen: c_int) c_long = @ptrFromInt(49);
pub const skb_adjust_room: *align(1) const fn (skb: *kern.SkBuff, len_diff: i32, mode: u32, flags: u64) c_long = @ptrFromInt(50);
pub const redirect_map: *align(1) const fn (map: *const kern.MapDef, key: u32, flags: u64) c_long = @ptrFromInt(51);
pub const sk_redirect_map: *align(1) const fn (skb: *kern.SkBuff, map: *const kern.MapDef, key: u32, flags: u64) c_long = @ptrFromInt(52);
pub const sock_map_update: *align(1) const fn (skops: *kern.SockOps, map: *const kern.MapDef, key: ?*anyopaque, flags: u64) c_long = @ptrFromInt(53);
pub const xdp_adjust_meta: *align(1) const fn (xdp_md: *kern.XdpMd, delta: c_int) c_long = @ptrFromInt(54);
pub const perf_event_read_value: *align(1) const fn (map: *const kern.MapDef, flags: u64, buf: *kern.PerfEventValue, buf_size: u32) c_long = @ptrFromInt(55);
pub const perf_prog_read_value: *align(1) const fn (ctx: *kern.PerfEventData, buf: *kern.PerfEventValue, buf_size: u32) c_long = @ptrFromInt(56);
pub const getsockopt: *align(1) const fn (bpf_socket: ?*anyopaque, level: c_int, optname: c_int, optval: ?*anyopaque, optlen: c_int) c_long = @ptrFromInt(57);
pub const override_return: *align(1) const fn (regs: *PtRegs, rc: u64) c_long = @ptrFromInt(58);
pub const sock_ops_cb_flags_set: *align(1) const fn (bpf_sock: *kern.SockOps, argval: c_int) c_long = @ptrFromInt(59);
pub const msg_redirect_map: *align(1) const fn (msg: *kern.SkMsgMd, map: *const kern.MapDef, key: u32, flags: u64) c_long = @ptrFromInt(60);
pub const msg_apply_bytes: *align(1) const fn (msg: *kern.SkMsgMd, bytes: u32) c_long = @ptrFromInt(61);
pub const msg_cork_bytes: *align(1) const fn (msg: *kern.SkMsgMd, bytes: u32) c_long = @ptrFromInt(62);
pub const msg_pull_data: *align(1) const fn (msg: *kern.SkMsgMd, start: u32, end: u32, flags: u64) c_long = @ptrFromInt(63);
pub const bind: *align(1) const fn (ctx: *kern.BpfSockAddr, addr: *kern.SockAddr, addr_len: c_int) c_long = @ptrFromInt(64);
pub const xdp_adjust_tail: *align(1) const fn (xdp_md: *kern.XdpMd, delta: c_int) c_long = @ptrFromInt(65);
pub const skb_get_xfrm_state: *align(1) const fn (skb: *kern.SkBuff, index: u32, xfrm_state: *kern.XfrmState, size: u32, flags: u64) c_long = @ptrFromInt(66);
pub const get_stack: *align(1) const fn (ctx: ?*anyopaque, buf: ?*anyopaque, size: u32, flags: u64) c_long = @ptrFromInt(67);
pub const skb_load_bytes_relative: *align(1) const fn (skb: ?*const anyopaque, offset: u32, to: ?*anyopaque, len: u32, start_header: u32) c_long = @ptrFromInt(68);
pub const fib_lookup: *align(1) const fn (ctx: ?*anyopaque, params: *kern.FibLookup, plen: c_int, flags: u32) c_long = @ptrFromInt(69);
pub const sock_hash_update: *align(1) const fn (skops: *kern.SockOps, map: *const kern.MapDef, key: ?*anyopaque, flags: u64) c_long = @ptrFromInt(70);
pub const msg_redirect_hash: *align(1) const fn (msg: *kern.SkMsgMd, map: *const kern.MapDef, key: ?*anyopaque, flags: u64) c_long = @ptrFromInt(71);
pub const sk_redirect_hash: *align(1) const fn (skb: *kern.SkBuff, map: *const kern.MapDef, key: ?*anyopaque, flags: u64) c_long = @ptrFromInt(72);
pub const lwt_push_encap: *align(1) const fn (skb: *kern.SkBuff, typ: u32, hdr: ?*anyopaque, len: u32) c_long = @ptrFromInt(73);
pub const lwt_seg6_store_bytes: *align(1) const fn (skb: *kern.SkBuff, offset: u32, from: ?*const anyopaque, len: u32) c_long = @ptrFromInt(74);
pub const lwt_seg6_adjust_srh: *align(1) const fn (skb: *kern.SkBuff, offset: u32, delta: i32) c_long = @ptrFromInt(75);
pub const lwt_seg6_action: *align(1) const fn (skb: *kern.SkBuff, action: u32, param: ?*anyopaque, param_len: u32) c_long = @ptrFromInt(76);
pub const rc_repeat: *align(1) const fn (ctx: ?*anyopaque) c_long = @ptrFromInt(77);
pub const rc_keydown: *align(1) const fn (ctx: ?*anyopaque, protocol: u32, scancode: u64, toggle: u32) c_long = @ptrFromInt(78);
pub const skb_cgroup_id: *align(1) const fn (skb: *kern.SkBuff) u64 = @ptrFromInt(79);
pub const get_current_cgroup_id: *align(1) const fn () u64 = @ptrFromInt(80);
pub const get_local_storage: *align(1) const fn (map: ?*anyopaque, flags: u64) ?*anyopaque = @ptrFromInt(81);
pub const sk_select_reuseport: *align(1) const fn (reuse: *kern.SkReusePortMd, map: *const kern.MapDef, key: ?*anyopaque, flags: u64) c_long = @ptrFromInt(82);
pub const skb_ancestor_cgroup_id: *align(1) const fn (skb: *kern.SkBuff, ancestor_level: c_int) u64 = @ptrFromInt(83);
pub const sk_lookup_tcp: *align(1) const fn (ctx: ?*anyopaque, tuple: *kern.SockTuple, tuple_size: u32, netns: u64, flags: u64) ?*kern.Sock = @ptrFromInt(84);
pub const sk_lookup_udp: *align(1) const fn (ctx: ?*anyopaque, tuple: *kern.SockTuple, tuple_size: u32, netns: u64, flags: u64) ?*kern.Sock = @ptrFromInt(85);
pub const sk_release: *align(1) const fn (sock: *kern.Sock) c_long = @ptrFromInt(86);
pub const map_push_elem: *align(1) const fn (map: *const kern.MapDef, value: ?*const anyopaque, flags: u64) c_long = @ptrFromInt(87);
pub const map_pop_elem: *align(1) const fn (map: *const kern.MapDef, value: ?*anyopaque) c_long = @ptrFromInt(88);
pub const map_peek_elem: *align(1) const fn (map: *const kern.MapDef, value: ?*anyopaque) c_long = @ptrFromInt(89);
pub const msg_push_data: *align(1) const fn (msg: *kern.SkMsgMd, start: u32, len: u32, flags: u64) c_long = @ptrFromInt(90);
pub const msg_pop_data: *align(1) const fn (msg: *kern.SkMsgMd, start: u32, len: u32, flags: u64) c_long = @ptrFromInt(91);
pub const rc_pointer_rel: *align(1) const fn (ctx: ?*anyopaque, rel_x: i32, rel_y: i32) c_long = @ptrFromInt(92);
pub const spin_lock: *align(1) const fn (lock: *kern.SpinLock) c_long = @ptrFromInt(93);
pub const spin_unlock: *align(1) const fn (lock: *kern.SpinLock) c_long = @ptrFromInt(94);
pub const sk_fullsock: *align(1) const fn (sk: *kern.Sock) ?*SkFullSock = @ptrFromInt(95);
pub const tcp_sock: *align(1) const fn (sk: *kern.Sock) ?*kern.TcpSock = @ptrFromInt(96);
pub const skb_ecn_set_ce: *align(1) const fn (skb: *kern.SkBuff) c_long = @ptrFromInt(97);
pub const get_listener_sock: *align(1) const fn (sk: *kern.Sock) ?*kern.Sock = @ptrFromInt(98);
pub const skc_lookup_tcp: *align(1) const fn (ctx: ?*anyopaque, tuple: *kern.SockTuple, tuple_size: u32, netns: u64, flags: u64) ?*kern.Sock = @ptrFromInt(99);
pub const tcp_check_syncookie: *align(1) const fn (sk: *kern.Sock, iph: ?*anyopaque, iph_len: u32, th: *TcpHdr, th_len: u32) c_long = @ptrFromInt(100);
pub const sysctl_get_name: *align(1) const fn (ctx: *kern.SysCtl, buf: ?*u8, buf_len: c_ulong, flags: u64) c_long = @ptrFromInt(101);
pub const sysctl_get_current_value: *align(1) const fn (ctx: *kern.SysCtl, buf: ?*u8, buf_len: c_ulong) c_long = @ptrFromInt(102);
pub const sysctl_get_new_value: *align(1) const fn (ctx: *kern.SysCtl, buf: ?*u8, buf_len: c_ulong) c_long = @ptrFromInt(103);
pub const sysctl_set_new_value: *align(1) const fn (ctx: *kern.SysCtl, buf: ?*const u8, buf_len: c_ulong) c_long = @ptrFromInt(104);
pub const strtol: *align(1) const fn (buf: *const u8, buf_len: c_ulong, flags: u64, res: *c_long) c_long = @ptrFromInt(105);
pub const strtoul: *align(1) const fn (buf: *const u8, buf_len: c_ulong, flags: u64, res: *c_ulong) c_long = @ptrFromInt(106);
pub const sk_storage_get: *align(1) const fn (map: *const kern.MapDef, sk: *kern.Sock, value: ?*anyopaque, flags: u64) ?*anyopaque = @ptrFromInt(107);
pub const sk_storage_delete: *align(1) const fn (map: *const kern.MapDef, sk: *kern.Sock) c_long = @ptrFromInt(108);
pub const send_signal: *align(1) const fn (sig: u32) c_long = @ptrFromInt(109);
pub const tcp_gen_syncookie: *align(1) const fn (sk: *kern.Sock, iph: ?*anyopaque, iph_len: u32, th: *TcpHdr, th_len: u32) i64 = @ptrFromInt(110);
pub const skb_output: *align(1) const fn (ctx: ?*anyopaque, map: *const kern.MapDef, flags: u64, data: ?*anyopaque, size: u64) c_long = @ptrFromInt(111);
pub const probe_read_user: *align(1) const fn (dst: ?*anyopaque, size: u32, unsafe_ptr: ?*const anyopaque) c_long = @ptrFromInt(112);
pub const probe_read_kernel: *align(1) const fn (dst: ?*anyopaque, size: u32, unsafe_ptr: ?*const anyopaque) c_long = @ptrFromInt(113);
pub const probe_read_user_str: *align(1) const fn (dst: ?*anyopaque, size: u32, unsafe_ptr: ?*const anyopaque) c_long = @ptrFromInt(114);
pub const probe_read_kernel_str: *align(1) const fn (dst: ?*anyopaque, size: u32, unsafe_ptr: ?*const anyopaque) c_long = @ptrFromInt(115);
pub const tcp_send_ack: *align(1) const fn (tp: ?*anyopaque, rcv_nxt: u32) c_long = @ptrFromInt(116);
pub const send_signal_thread: *align(1) const fn (sig: u32) c_long = @ptrFromInt(117);
pub const jiffies64: *align(1) const fn () u64 = @ptrFromInt(118);
pub const read_branch_records: *align(1) const fn (ctx: *kern.PerfEventData, buf: ?*anyopaque, size: u32, flags: u64) c_long = @ptrFromInt(119);
pub const get_ns_current_pid_tgid: *align(1) const fn (dev: u64, ino: u64, nsdata: *kern.PidNsInfo, size: u32) c_long = @ptrFromInt(120);
pub const xdp_output: *align(1) const fn (ctx: ?*anyopaque, map: *const kern.MapDef, flags: u64, data: ?*anyopaque, size: u64) c_long = @ptrFromInt(121);
pub const get_netns_cookie: *align(1) const fn (ctx: ?*anyopaque) u64 = @ptrFromInt(122);
pub const get_current_ancestor_cgroup_id: *align(1) const fn (ancestor_level: c_int) u64 = @ptrFromInt(123);
pub const sk_assign: *align(1) const fn (skb: *kern.SkBuff, sk: *kern.Sock, flags: u64) c_long = @ptrFromInt(124);
pub const ktime_get_boot_ns: *align(1) const fn () u64 = @ptrFromInt(125);
pub const seq_printf: *align(1) const fn (m: *kern.SeqFile, fmt: ?*const u8, fmt_size: u32, data: ?*const anyopaque, data_len: u32) c_long = @ptrFromInt(126);
pub const seq_write: *align(1) const fn (m: *kern.SeqFile, data: ?*const u8, len: u32) c_long = @ptrFromInt(127);
pub const sk_cgroup_id: *align(1) const fn (sk: *kern.BpfSock) u64 = @ptrFromInt(128);
pub const sk_ancestor_cgroup_id: *align(1) const fn (sk: *kern.BpfSock, ancestor_level: c_long) u64 = @ptrFromInt(129);
pub const ringbuf_output: *align(1) const fn (ringbuf: ?*anyopaque, data: ?*anyopaque, size: u64, flags: u64) c_long = @ptrFromInt(130);
pub const ringbuf_reserve: *align(1) const fn (ringbuf: ?*anyopaque, size: u64, flags: u64) ?*anyopaque = @ptrFromInt(131);
pub const ringbuf_submit: *align(1) const fn (data: ?*anyopaque, flags: u64) void = @ptrFromInt(132);
pub const ringbuf_discard: *align(1) const fn (data: ?*anyopaque, flags: u64) void = @ptrFromInt(133);
pub const ringbuf_query: *align(1) const fn (ringbuf: ?*anyopaque, flags: u64) u64 = @ptrFromInt(134);
pub const csum_level: *align(1) const fn (skb: *kern.SkBuff, level: u64) c_long = @ptrFromInt(135);
pub const skc_to_tcp6_sock: *align(1) const fn (sk: ?*anyopaque) ?*kern.Tcp6Sock = @ptrFromInt(136);
pub const skc_to_tcp_sock: *align(1) const fn (sk: ?*anyopaque) ?*kern.TcpSock = @ptrFromInt(137);
pub const skc_to_tcp_timewait_sock: *align(1) const fn (sk: ?*anyopaque) ?*kern.TcpTimewaitSock = @ptrFromInt(138);
pub const skc_to_tcp_request_sock: *align(1) const fn (sk: ?*anyopaque) ?*kern.TcpRequestSock = @ptrFromInt(139);
pub const skc_to_udp6_sock: *align(1) const fn (sk: ?*anyopaque) ?*kern.Udp6Sock = @ptrFromInt(140);
pub const get_task_stack: *align(1) const fn (task: ?*anyopaque, buf: ?*anyopaque, size: u32, flags: u64) c_long = @ptrFromInt(141);
pub const load_hdr_opt: *align(1) const fn (?*kern.BpfSockOps, ?*anyopaque, u32, u64) c_long = @ptrFromInt(142);
pub const store_hdr_opt: *align(1) const fn (?*kern.BpfSockOps, ?*const anyopaque, u32, u64) c_long = @ptrFromInt(143);
pub const reserve_hdr_opt: *align(1) const fn (?*kern.BpfSockOps, u32, u64) c_long = @ptrFromInt(144);
pub const inode_storage_get: *align(1) const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, u64) ?*anyopaque = @ptrFromInt(145);
pub const inode_storage_delete: *align(1) const fn (?*anyopaque, ?*anyopaque) c_int = @ptrFromInt(146);
pub const d_path: *align(1) const fn (?*kern.Path, [*c]u8, u32) c_long = @ptrFromInt(147);
pub const copy_from_user: *align(1) const fn (?*anyopaque, u32, ?*const anyopaque) c_long = @ptrFromInt(148);
pub const snprintf_btf: *align(1) const fn ([*c]u8, u32, ?*kern.BTFPtr, u32, u64) c_long = @ptrFromInt(149);
pub const seq_printf_btf: *align(1) const fn (?*kern.SeqFile, ?*kern.BTFPtr, u32, u64) c_long = @ptrFromInt(150);
pub const skb_cgroup_classid: *align(1) const fn (?*kern.SkBuff) u64 = @ptrFromInt(151);
pub const redirect_neigh: *align(1) const fn (u32, ?*kern.BpfRedirNeigh, c_int, u64) c_long = @ptrFromInt(152);
pub const per_cpu_ptr: *align(1) const fn (?*const anyopaque, u32) ?*anyopaque = @ptrFromInt(153);
pub const this_cpu_ptr: *align(1) const fn (?*const anyopaque) ?*anyopaque = @ptrFromInt(154);
pub const redirect_peer: *align(1) const fn (u32, u64) c_long = @ptrFromInt(155);
pub const task_storage_get: *align(1) const fn (?*anyopaque, ?*kern.Task, ?*anyopaque, u64) ?*anyopaque = @ptrFromInt(156);
pub const task_storage_delete: *align(1) const fn (?*anyopaque, ?*kern.Task) c_long = @ptrFromInt(157);
pub const get_current_task_btf: *align(1) const fn () ?*kern.Task = @ptrFromInt(158);
pub const bprm_opts_set: *align(1) const fn (?*kern.BinPrm, u64) c_long = @ptrFromInt(159);
pub const ktime_get_coarse_ns: *align(1) const fn () u64 = @ptrFromInt(160);
pub const ima_inode_hash: *align(1) const fn (?*kern.Inode, ?*anyopaque, u32) c_long = @ptrFromInt(161);
pub const sock_from_file: *align(1) const fn (?*kern.File) ?*kern.Socket = @ptrFromInt(162);
pub const check_mtu: *align(1) const fn (?*anyopaque, u32, [*c]u32, i32, u64) c_long = @ptrFromInt(163);
pub const for_each_map_elem: *align(1) const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, u64) c_long = @ptrFromInt(164);
pub const snprintf: *align(1) const fn ([*c]u8, u32, [*c]const u8, [*c]u64, u32) c_long = @ptrFromInt(165);
pub const sys_bpf: *align(1) const fn (u32, ?*anyopaque, u32) c_long = @ptrFromInt(166);
pub const btf_find_by_name_kind: *align(1) const fn ([*c]u8, c_int, u32, c_int) c_long = @ptrFromInt(167);
pub const sys_close: *align(1) const fn (u32) c_long = @ptrFromInt(168);
pub const timer_init: *align(1) const fn (?*kern.BpfTimer, ?*anyopaque, u64) c_long = @ptrFromInt(169);
pub const timer_set_callback: *align(1) const fn (?*kern.BpfTimer, ?*anyopaque) c_long = @ptrFromInt(170);
pub const timer_start: *align(1) const fn (?*kern.BpfTimer, u64, u64) c_long = @ptrFromInt(171);
pub const timer_cancel: *align(1) const fn (?*kern.BpfTimer) c_long = @ptrFromInt(172);
pub const get_func_ip: *align(1) const fn (?*anyopaque) u64 = @ptrFromInt(173);
pub const get_attach_cookie: *align(1) const fn (?*anyopaque) u64 = @ptrFromInt(174);
pub const task_pt_regs: *align(1) const fn (?*kern.Task) c_long = @ptrFromInt(175);
pub const get_branch_snapshot: *align(1) const fn (?*anyopaque, u32, u64) c_long = @ptrFromInt(176);
pub const trace_vprintk: *align(1) const fn ([*c]const u8, u32, ?*const anyopaque, u32) c_long = @ptrFromInt(177);
pub const skc_to_unix_sock: *align(1) const fn (?*anyopaque) ?*kern.UnixSock = @ptrFromInt(178);
pub const kallsyms_lookup_name: *align(1) const fn ([*c]const u8, c_int, c_int, [*c]u64) c_long = @ptrFromInt(179);
pub const find_vma: *align(1) const fn (?*kern.Task, u64, ?*anyopaque, ?*anyopaque, u64) c_long = @ptrFromInt(180);
pub const loop: *align(1) const fn (u32, ?*anyopaque, ?*anyopaque, u64) c_long = @ptrFromInt(181);
pub const strncmp: *align(1) const fn ([*c]const u8, u32, [*c]const u8) c_long = @ptrFromInt(182);
pub const get_func_arg: *align(1) const fn (?*anyopaque, u32, [*c]u64) c_long = @ptrFromInt(183);
pub const get_func_ret: *align(1) const fn (?*anyopaque, [*c]u64) c_long = @ptrFromInt(184);
pub const get_func_arg_cnt: *align(1) const fn (?*anyopaque) c_long = @ptrFromInt(185);
pub const get_retval: *align(1) const fn () c_int = @ptrFromInt(186);
pub const set_retval: *align(1) const fn (c_int) c_int = @ptrFromInt(187);
pub const xdp_get_buff_len: *align(1) const fn (?*kern.XdpMd) u64 = @ptrFromInt(188);
pub const xdp_load_bytes: *align(1) const fn (?*kern.XdpMd, u32, ?*anyopaque, u32) c_long = @ptrFromInt(189);
pub const xdp_store_bytes: *align(1) const fn (?*kern.XdpMd, u32, ?*anyopaque, u32) c_long = @ptrFromInt(190);
pub const copy_from_user_task: *align(1) const fn (?*anyopaque, u32, ?*const anyopaque, ?*kern.Task, u64) c_long = @ptrFromInt(191);
pub const skb_set_tstamp: *align(1) const fn (?*kern.SkBuff, u64, u32) c_long = @ptrFromInt(192);
pub const ima_file_hash: *align(1) const fn (?*kern.File, ?*anyopaque, u32) c_long = @ptrFromInt(193);
pub const kptr_xchg: *align(1) const fn (?*anyopaque, ?*anyopaque) ?*anyopaque = @ptrFromInt(194);
pub const map_lookup_percpu_elem: *align(1) const fn (?*anyopaque, ?*const anyopaque, u32) ?*anyopaque = @ptrFromInt(195);
pub const skc_to_mptcp_sock: *align(1) const fn (?*anyopaque) ?*kern.MpTcpSock = @ptrFromInt(196);
pub const dynptr_from_mem: *align(1) const fn (?*anyopaque, u32, u64, ?*kern.BpfDynPtr) c_long = @ptrFromInt(197);
pub const ringbuf_reserve_dynptr: *align(1) const fn (?*anyopaque, u32, u64, ?*kern.BpfDynPtr) c_long = @ptrFromInt(198);
pub const ringbuf_submit_dynptr: *align(1) const fn (?*kern.BpfDynPtr, u64) void = @ptrFromInt(199);
pub const ringbuf_discard_dynptr: *align(1) const fn (?*kern.BpfDynPtr, u64) void = @ptrFromInt(200);
pub const dynptr_read: *align(1) const fn (?*anyopaque, u32, ?*kern.BpfDynPtr, u32, u64) c_long = @ptrFromInt(201);
pub const dynptr_write: *align(1) const fn (?*kern.BpfDynPtr, u32, ?*anyopaque, u32, u64) c_long = @ptrFromInt(202);
pub const dynptr_data: *align(1) const fn (?*kern.BpfDynPtr, u32, u32) ?*anyopaque = @ptrFromInt(203);
pub const tcp_raw_gen_syncookie_ipv4: *align(1) const fn (?*kern.IpHdr, ?*TcpHdr, u32) i64 = @ptrFromInt(204);
pub const tcp_raw_gen_syncookie_ipv6: *align(1) const fn (?*kern.Ipv6Hdr, ?*TcpHdr, u32) i64 = @ptrFromInt(205);
pub const tcp_raw_check_syncookie_ipv4: *align(1) const fn (?*kern.IpHdr, ?*TcpHdr) c_long = @ptrFromInt(206);
pub const tcp_raw_check_syncookie_ipv6: *align(1) const fn (?*kern.Ipv6Hdr, ?*TcpHdr) c_long = @ptrFromInt(207);
pub const ktime_get_tai_ns: *align(1) const fn () u64 = @ptrFromInt(208);
pub const user_ringbuf_drain: *align(1) const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, u64) c_long = @ptrFromInt(209);
