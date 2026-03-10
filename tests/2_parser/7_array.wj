fn main() {
    val a = .[]
    val x: []i32 = .[1, 2, 3]
    val y = x[a + 2]
}

/***
Module {
    exprs: [
        FnDecl {
            name: 'main',
            is_extern: false,
            is_public: false,
            params: [],
            body: Block {
                exprs: [
                    VarDecl {
                        decl: val,
                        name: 'a',
                        value: ArrayValue {
                            elems: [],
                        },
                    },
                    VarDecl {
                        decl: val,
                        name: 'x',
                        type: []i32,
                        value: ArrayValue {
                            elems: [
                                Lit(1),
                                Lit(2),
                                Lit(3),
                            ],
                        },
                    },
                    VarDecl {
                        decl: val,
                        name: 'y',
                        value: ArrayIndex {
                            callee: Identifier('x'),
                            index: Binary {
                                op: +,
                                lhs: Identifier('a'),
                                rhs: Lit(2),
                            },
                        },
                    },
                ],
            },
        },
    ],
}
***/