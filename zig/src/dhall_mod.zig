// dhall_mod.zig — facade entry point so consumers can import the dhall-c Zig
// core as a SINGLE module.  The sibling modules import each other by bare
// filename (`@import("parser.zig")`), which only resolves when the module root
// lives in THIS directory.  This file re-exports the library entry points a
// host program (e.g. fx-core/fx-find) needs; it is intentionally NOT the CLI
// (main.zig).
const std = @import("std");

pub const dhall = @import("dhall.zig");
pub const arena = @import("arena.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const typecheck = @import("typecheck.zig");
pub const normalize = @import("normalize.zig");
pub const serialize = @import("serialize.zig");
pub const import_mod = @import("import.zig");
pub const bignum = @import("bignum.zig");
pub const builtins = @import("builtins.zig");
pub const lexer = @import("lexer.zig");
