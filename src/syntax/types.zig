pub const AbstractSyntaxTree = struct {
    items: []TopItem,
};

pub const AliasStmt = struct {
    name: TypeDecl,
    type: Type,
};

pub const ArrayLit = struct {
    values: []Expr,
};

pub const ArrayType = struct {
    len: *Expr,
    type: *Type,
};

pub const AssignStmt = struct {
    target: Expr,
    value: Expr,
};

pub const BinOp = struct {
    op: []const u8,
    expr0: *Expr,
    expr1: *Expr,
};

pub const BlockStmt = struct {
    scope: Scope,
};

pub const BoolLit = struct {
    value: []const u8,
};

pub const Branch = struct {
    var_defn: ?VarDefn,
    expr: Expr,
    scope: Scope,
};

pub const BreakStmt = struct {
    index: ?Expr,
};

pub const Cast = struct {
    expr: *Expr,
    type: Type,
};

pub const CharLit = struct {
    value: []const u8,
};

pub const ContinueStmt = struct {
    index: ?Expr,
};

pub const ElseBranch = struct {
    var_defn: ?VarDefn,
    scope: Scope,
};

pub const EnumDefn = struct {
    tag: TypeDecl,
    members: []EnumMember,
};

pub const EnumLit = struct {
    namespace: []const u8,
    value: []const u8,
};

pub const EnumMember = struct {
    name: []const u8,
    value: ?Expr,
};

pub const ExportStmt = struct {
    symbols: []const []const u8,
};

pub const Expr = union(enum) {
    primary: Primary,
    un_op: UnOp,
    bin_op: BinOp,
    cast: Cast,
    member: Member,
    index: Index,
    fn_call: FnCall,
};

pub const FloatLit = struct {
    type: enum {
        float,
        double,
    },
    value: []const u8,
};

pub const FnCall = struct {
    callee: *Expr, // compile-time arguments are part of the callee's ValueRef
    dynm_args: []Expr,
};

pub const FnDecl = struct {
    name: []const u8,
    comp_args: []const []const u8,
    sig: FnSig,
};

pub const FnDefn = struct {
    name: []const u8,
    comp_args: []const []const u8,
    sig: FnSig,
    scope: Scope,
};

pub const FnSig = struct {
    args: []VarDecl,
    variadic: bool,
    ret_type: ?*Type,
};

pub const ForStmt = struct {
    var_defn: VarDefn,
    expr: Expr,
    stmt: *Stmt,
    scope: Scope,
};

pub const GlobalVarDecl = struct {
    is_extern: bool,
    var_decl: VarDecl,
};

pub const IfStmt = struct {
    @"if": Branch,
    elif: []Branch,
    @"else": ?ElseBranch,
};

pub const ImportStmt = struct {
    path: []const []const u8,
};

pub const Index = struct {
    base: *Expr,
    offset: *Expr,
};

pub const IntLit = struct {
    type: IntType,
    value: []const u8,
};

pub const IntType = enum {
    char,
    short,
    int,
    long,
    longlong,
    uchar,
    ushort,
    uint,
    ulong,
    ulonglong,
};

pub const Lambda = struct {
    sig: FnSig,
    scope: Scope,
};

pub const Literal = union(enum) {
    int: IntLit,
    float: FloatLit,
    bool: BoolLit,
    array: ArrayLit,
    @"struct": StructLit,
    @"union": UnionLit,
    @"enum": EnumLit,
    string: StringLit,
    char: CharLit,
    null: void,
};

pub const MacroDefn = struct {
    kind: enum {
        smacro,
        cmacro,
    },
    name: []const u8,
    args: []const []const u8,
    variadic: bool,
    body: []const u8,
};

pub const Member = struct {
    base: *Expr,
    name: []const u8,
};

pub const PointerType = union(enum) {
    type: *Type,
    @"fn": []const u8, // coroutine context of the named function
};

pub const Primary = union(enum) {
    literal: Literal,
    value_ref: ValueRef,
    expr: *Expr, // parenthesized
    lambda: Lambda,
};

pub const ReturnStmt = struct {
    value: ?Expr,
};

pub const Scope = struct {
    stmts: []Stmt,
};

pub const Stmt = union(enum) {
    var_decl: VarDecl,
    assign_stmt: AssignStmt,
    if_stmt: IfStmt,
    for_stmt: ForStmt,
    return_stmt: ReturnStmt,
    break_stmt: BreakStmt,
    continue_stmt: ContinueStmt,
    yield_stmt: YieldStmt,
    fn_call: FnCall,
    block_stmt: BlockStmt,
};

pub const StringLit = struct {
    value: []const u8,
};

pub const StructDefn = struct {
    tag: TypeDecl,
    members: []VarDecl,
};

pub const StructLit = struct {
    tag: TypeRef,
    members: []VarDefn,
};

pub const TopItem = union(enum) {
    import_stmt: ImportStmt,
    macro_defn: MacroDefn,
    type_defn: TypeDefn,
    alias_stmt: AliasStmt,
    var_decl: GlobalVarDecl,
    fn_decl: FnDecl, // always extern
    var_defn: VarDefn,
    fn_defn: FnDefn,
    export_stmt: ExportStmt,
};

pub const Type = union(enum) {
    int: IntType,
    float: void,
    double: void,
    void: void,
    bool: void,
    named: TypeRef,
    pointer: PointerType,
    array: ArrayType,
    @"fn": FnSig,
};

pub const TypeDecl = struct {
    name: []const u8,
    comp_args: []const []const u8,
};

pub const TypeDefn = union(enum) {
    @"struct": StructDefn,
    @"union": UnionDefn,
    @"enum": EnumDefn,
};

pub const TypeRef = struct { // type_name, [comp_args_defn]
    name: []const u8,
    comp_args: []Type,
};

pub const UnionDefn = struct {
    tag: TypeDecl,
    members: []VarDecl,
};

pub const UnionLit = struct {
    tag: TypeRef,
    member: []const u8,
    value: *Expr,
};

pub const UnOp = struct {
    op: []const u8,
    expr: *Expr,
};

pub const ValueRef = struct { // value_name, [comp_args_defn]
    name: []const u8,
    comp_args: []Type,
};

pub const VarDecl = struct {
    name: []const u8,
    type: Type,
};

pub const VarDefn = struct {
    name: []const u8,
    value: Expr,
};

pub const YieldStmt = struct {
    value: ?Expr,
};
