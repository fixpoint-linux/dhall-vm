// dhall.zig — extern-struct MIRROR of ../src/dhall.h (single-TERM interpreter).
// Same field layout, same tag enum values, NUL-terminated arena-allocated
// strings, NULL-terminated TextPart linked list, Field arrays. This is the
// type foundation every other module imports. The representation deliberately
// mirrors the C ABI so a later C-ABI export layer is trivial.
//
// NOTE on the layout choice: these are `extern struct`/`extern enum`/`extern
// union` mirror types, NOT idiomatic Zig tagged unions. Keep them byte-identical
// to dhall.h; never "clean them up".

const std = @import("std");

pub const DHALL_VERSION = "0.1.0";

// ---------------------------------------------------------------------------
// Source locations
// ---------------------------------------------------------------------------
pub const SourceSpan = extern struct {
    file: ?[*:0]const u8,
    line: c_int,
    col: c_int,
};

pub const SPAN_NONE = SourceSpan{ .file = null, .line = 0, .col = 0 };

// ---------------------------------------------------------------------------
// Term structure
// ---------------------------------------------------------------------------
pub const ImportLoader = opaque {};

pub const ConstKind = enum(u32) {
    C_NAT,
    C_INT,
    C_DBL,
    C_BOOL,
};

pub const BigNat = extern struct {
    limbs: ?[*]u32,
    nlimbs: c_int,
};

pub const BigInt = extern struct {
    neg: bool,
    mag: BigNat,
};

pub const Const = extern struct {
    kind: ConstKind,
    nat: u64, // C_NAT
    i64: i64, // C_INT
    dbl: f64, // C_DBL
    b: bool, // C_BOOL
    bnat: ?*BigNat, // C_NAT: NULL iff value < 2^64 (held in .nat)
    big: ?*BigInt, // C_INT: NULL iff |value| < 2^63 (held in .i64)
};

pub const OpKind = enum(u32) {
    OP_ADD,
    OP_SUB,
    OP_MUL,
    OP_LT,
    OP_LE,
    OP_GT,
    OP_GE,
    OP_EQ,
    OP_NE,
    OP_AND,
    OP_OR,
};

pub const TermTag = enum(u32) {
    TmVar,
    TmConst,
    TmText,
    TmType,
    TmKind,
    TmSort,
    TmLam,
    TmPi,
    TmApp,
    TmIf,
    TmLet,
    TmAnn,
    TmNil,
    TmCons,
    TmTextAppend,
    TmRecordType,
    TmRecordLit,
    TmField,
    TmUnionType,
    TmUnionLit,
    TmMerge,
    TmBuiltin,
    TmSome,
    TmNone,
    TmOp,
    TmAssert,
    TmToMap,
    TmCombine,
    TmWith,
    TmListAppend,
    TmPrefer,
};

pub const TextPart = extern struct {
    lit: ?[*:0]u8, // literal chunk (arena), NULL if starts with expr
    expr: ?*Term, // interpolation expr, NULL if this is a literal chunk
    next: ?*TextPart,
};

pub const Field = extern struct {
    label: ?[*:0]u8, // arena
    type: ?*Term, // record/union type field, or NULL
    value: ?*Term, // record literal value / union selected value, or NULL
};

pub const Term = extern struct {
    tag: TermTag,
    loc: SourceSpan,
    as: TermUnion,
};

// Named mirror types for each anonymous struct inside the C union `as`.
pub const TermLam = extern struct { dom: ?*Term, body: ?*Term };
pub const TermPi = extern struct { dom: ?*Term, cod: ?*Term };
pub const TermApp = extern struct { fn_: ?*Term, arg: ?*Term };
pub const TermIf = extern struct { c: ?*Term, t: ?*Term, e: ?*Term };
pub const TermLet = extern struct { ann: ?*Term, val: ?*Term, body: ?*Term };
pub const TermAnn = extern struct { e: ?*Term, ty: ?*Term };
pub const TermCons = extern struct { head: ?*Term, tail: ?*Term };
pub const TermAppend = extern struct { a: ?*Term, b: ?*Term };
pub const TermRec = extern struct { fs: ?[*]Field, n: c_int };
pub const TermField = extern struct { label: ?[*:0]u8, rec: ?*Term };
pub const TermUni = extern struct { fs: ?[*]Field, n: c_int };
pub const TermMerge = extern struct { handlers: ?*Term, u: ?*Term };
pub const TermSome = extern struct { val: ?*Term };
pub const TermNone = extern struct { ty: ?*Term };
pub const TermOp = extern struct { op: OpKind, lhs: ?*Term, rhs: ?*Term };
pub const TermAssert = extern struct { body: ?*Term };
pub const TermTomap = extern struct { rec: ?*Term };
pub const TermCombine = extern struct { lhs: ?*Term, rhs: ?*Term };
pub const TermWith = extern struct { rec: ?*Term, path: ?[*]?[*:0]u8, npath: c_int, value: ?*Term };
pub const TermLappend = extern struct { a: ?*Term, b: ?*Term };
pub const TermPrefer = extern struct { lhs: ?*Term, rhs: ?*Term };

pub const TermUnion = extern union {
    idx: c_int, // TmVar
    c: Const, // TmConst
    text: ?*TextPart, // TmText
    lam: TermLam, // TmLam
    pi: TermPi, // TmPi
    app: TermApp, // TmApp
    if_: TermIf, // TmIf
    let_: TermLet, // TmLet
    ann: TermAnn, // TmAnn
    cons: TermCons, // TmCons
    append: TermAppend, // TmTextAppend
    rec: TermRec, // TmRecordType / TmRecordLit
    field: TermField, // TmField
    uni: TermUni, // TmUnionType / TmUnionLit
    merge: TermMerge, // TmMerge
    bname: ?[*:0]const u8, // TmBuiltin
    some: TermSome, // TmSome
    none: TermNone, // TmNone
    op: TermOp, // TmOp
    assert_: TermAssert, // TmAssert
    tomap: TermTomap, // TmToMap
    combine: TermCombine, // TmCombine
    with_: TermWith, // TmWith
    lappend: TermLappend, // TmListAppend
    prefer: TermPrefer, // TmPrefer
};

// ---------------------------------------------------------------------------
// Error reporting
// ---------------------------------------------------------------------------
pub const ErrorStage = enum(u32) {
    ERR_NONE = 0,
    ERR_LEX,
    ERR_PARSE,
    ERR_TYPE,
    ERR_SERIALIZE,
    ERR_IO,
    ERR_MISSING, // recoverable absent-import stage (caught by `?`)
};

pub const DhallError = extern struct {
    stage: ErrorStage,
    msg: [512]u8,
    span: SourceSpan,
    has_span: bool,
};

// ---------------------------------------------------------------------------
// Lexer
// ---------------------------------------------------------------------------
pub const TokType = enum(u32) {
    T_EOF,
    T_NAT,
    T_INT,
    T_DBL,
    T_STR_OPEN,
    T_STR_OPEN_MULTILINE,
    T_NAME,
    T_LAMBDA, // \
    T_ARROW, // ->
    T_COLON,
    T_EQUALS,
    T_COMMA,
    T_DOT,
    T_LPAREN,
    T_RPAREN,
    T_LBRACE,
    T_RBRACE,
    T_LANGLE,
    T_RANGLE,
    T_LBRACKET,
    T_RBRACKET,
    T_PLUSPLUS, // ++
    T_PLUS,
    T_MINUS,
    T_STAR,
    T_LT,
    T_LE,
    T_GT,
    T_GE,
    T_EQEQ,
    T_NE,
    T_IMPORT,
    T_SHA256,
    T_QMARK, // ?
    T_BAR, // |
    T_MERGE, // /\
    T_PREFER, // //
    T_AND, // &&
    T_OR, // ||
    T_HASH, // #
    T_ERROR,
};

pub const Token = extern struct {
    type: TokType,
    span: SourceSpan,
    c: Const,
    name: ?[*:0]u8, // T_NAME, T_IMPORT spec, T_SHA256 hex (arena)
};

pub const Lexer = extern struct {
    src: ?[*:0]const u8,
    len: usize,
    pos: usize,
    line: c_int,
    col: c_int,
    file: ?[*:0]const u8,
    after_operand: bool,
    peeked: Token,
    has_peek: bool,
    err: DhallError,
};

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------
pub const Parser = extern struct {
    lx: Lexer,
    names: ?[*]?[*:0]const u8, // de Bruijn name resolution stack
    nnames: c_int,
    namescap: c_int,
    depth: c_int,
    union_depth: c_int,
    loader: ?*ImportLoader,
    import_missing: bool,
    skip_imports: bool,
    missing_err: DhallError,
    err: DhallError,
};

pub const PARSE_MAX_DEPTH: c_int = 1000;

// ---------------------------------------------------------------------------
// Import / http
// ---------------------------------------------------------------------------
pub const MAX_IMPORT_DEPTH: c_int = 64;

// ---------------------------------------------------------------------------
// Value tree (serialize.c)
// ---------------------------------------------------------------------------
pub const SerFormat = enum(u32) {
    FMT_JSON,
    FMT_TOML,
    FMT_YAML,
};

pub const ValueKind = enum(u32) {
    VK_NULL,
    VK_NAT,
    VK_INT,
    VK_DBL,
    VK_BOOL,
    VK_TEXT,
    VK_ARRAY,
    VK_TABLE,
};

pub const Value = extern struct {
    kind: ValueKind,
    nat_big: bool, // VK_NAT: true iff .as.bnat holds an unbounded value
    int_big: bool, // VK_INT: true iff .as.big holds an unbounded value
    as: ValueUnion,
};

pub const ValueArr = extern struct { items: ?[*]?*Value, n: c_int };
pub const ValueTab = extern struct { keys: ?[*]?[*:0]u8, vals: ?[*]?*Value, n: c_int };

pub const ValueUnion = extern union {
    nat: u64, // VK_NAT (nat_big false)
    bnat: ?*BigNat, // VK_NAT (nat_big true)
    i64: i64, // VK_INT (int_big false)
    big: ?*BigInt, // VK_INT (int_big true)
    dbl: f64, // VK_DBL
    b: bool, // VK_BOOL
    text: ?[*:0]u8, // VK_TEXT
    arr: ValueArr, // VK_ARRAY
    tab: ValueTab, // VK_TABLE
};

// ---------------------------------------------------------------------------
// TmpBuf (growable malloc-backed char builder; declared in dhall.h)
// ---------------------------------------------------------------------------
pub const TmpBuf = extern struct {
    s: ?[*]u8,
    len: usize,
    cap: usize,
};

// Minimal compile-time smoke test that the mirror types lay out as the C
// originals do (pointer = 8 bytes here; enum tag = 4 bytes).
test "mirror struct sizes" {
    try std.testing.expectEqual(@sizeOf(SourceSpan), @sizeOf(extern struct { p: ?*anyopaque, a: c_int, b: c_int }));
    try std.testing.expectEqual(@sizeOf(Const), @sizeOf(extern struct {
        k: c_int,
        nat: u64,
        i64: i64,
        dbl: f64,
        b: bool,
        p1: ?*anyopaque,
        p2: ?*anyopaque,
    }));
}
