fn main() {
    val simp: i32
    val arr: []i32
    val tuple: (i32, []i32, &Foo)
    val generic: Foo<Bar, i32, []i32>
    val nullable: ?i32
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
                        name: 'simp',
                        type: i32,
                    },
                    VarDecl {
                        decl: val,
                        name: 'arr',
                        type: []i32,
                    },
                    VarDecl {
                        decl: val,
                        name: 'tuple',
                        type: (i32, []i32, &Foo),
                    },
                    VarDecl {
                        decl: val,
                        name: 'generic',
                        type: Foo(Bar, i32, []i32),
                    },
                    VarDecl {
                        decl: val,
                        name: 'nullable',
                        type: ?i32,
                    },
                ],
            },
        },
    ],
}
***/