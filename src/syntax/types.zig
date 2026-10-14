pub const AbstractSyntaxTree = struct {
    import_stmts: []ImportStmt,
    extern_stmts: []ExternStmt,
    body: []union(enum) {
        macro_defn: MacroDefn,
        type_defn: TypeDefn,
        alias_stmt: AliasStmt,
        var_decl: VarDecl,
        var_defn: VarDefn,
        fn_defn: FnDefn,
    },
    export_stmts: []ExportStmt,
};

pub const AliasStmt = struct {
    name: GenericDecl,
    type: GenericDecl,
};

pub const ArrayLit = struct {
    values: []Expr,
};

pub const BoolLit = struct {
    value: []u8,
};

pub const Branch = struct {
    expr: Expr,
    scope: FnScope,
};

pub const EnumDefn = struct {
    tag: GenericDecl,
    type: IntType,
    members: []VarDecl,
};

pub const EnumLit = struct {
    namespace: []u8,
    value: []u8,
};

pub const ExportStmt = struct {
    symbols: [][]u8,
};

pub const Expr = union(enum) {
    primary: Primary,
    expr: Expr,
    un_op: struct {
        op: []u8,
        expr: Expr,
    },
    bin_op: struct {
        op: []u8,
        expr0: Expr,
        expr1: Expr,
    },
    index: struct {
        base: Expr,
        offset: Expr,
    },
    lambda: struct {
        sig: FnSig,
        scope: FnScope,
    },
};

pub const ExternStmt = struct {
    name: []u8,
    sig: FnSig,
};

pub const FloatLit = struct {
    type: enum {
        float,
        double,
    },
    value: []u8,
};

pub const FnCall = struct {
    name: []u8,
    comp_args: []Expr,
    dynm_args: []Expr,
};

pub const FnDefn = struct {
    name: []u8,
    sig: FnSig,
    scope: FnScope,
};

pub const FnScope = union(enum) {
    body: []union(enum) {
        var_decl: VarDecl,
        var_defn: VarDefn,
        if_stmt: IfStmt,
        loop_stmt: LoopStmt,
        return_stmt: ReturnStmt,
        fn_call: FnCall,
    },
};

pub const FnSig = struct {
    args: []VarDecl,
    ret_type: GenericDecl,
};

pub const GenericDecl = struct {
    name: []u8,
    comp_args: []VarDecl,
};

pub const GenericDefn = struct {
    name: []u8,
    comp_args: []Expr,
};

pub const IfStmt = struct {
    @"if": Branch,
    elif: []Branch,
    @"else": ?Branch,
};

pub const ImportStmt = struct {
    path: [][]u8,
};

pub const IntLit = struct {
    type: IntType,
    value: []u8,
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

pub const Literal = union(enum) {
    int: IntLit,
    float: FloatLit,
    bool: BoolLit,
    array: ArrayLit,
    @"struct": StructLit,
    @"union": UnionLit,
    @"enum": EnumLit,
};

pub const LoopStmt = struct {
    scope: FnScope,
};

pub const MacroDefn = struct {
    name: []u8,
    args: []VarDecl,
    body: []u8,
};

pub const Primary = union(enum) {
    literal: Literal,
    fn_call: FnCall,
    lvalue: []u8,
};

pub const ReturnStmt = struct {
    value: ?Expr,
};

pub const StructDefn = struct {
    tag: GenericDecl,
    members: []VarDecl,
};

pub const StructLit = struct {
    tag: GenericDefn,
    members: []VarDefn,
};

pub const TypeDefn = union(enum) {
    @"struct": StructDefn,
    @"union": UnionDefn,
    @"enum": EnumDefn,
};

pub const UnionDefn = struct {
    tag: GenericDecl,
    members: []VarDecl,
};

pub const UnionLit = struct {
    tag: GenericDefn,
    member: VarDefn,
};

pub const VarDecl = struct {
    name: []u8,
    type: GenericDecl,
};

pub const VarDefn = struct {
    name: []u8,
    type: GenericDecl,
};
