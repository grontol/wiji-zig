fn foo() {
    
}

fn main() {
    foo()
}

/***
Module {
    fn_decls: [
        FnDecl {
            is_extern: false,
            is_public: false,
            name: 'foo',
            params: [],
            body: Block {
                stmts: [],
            },
        },
        FnDecl {
            is_extern: false,
            is_public: false,
            name: 'main',
            params: [],
            body: Block {
                stmts: [
                    FnCall {
                        callee: <fn(): void> Identifier('foo'),
                        args: [],
                        return_type: void,
                    },
                ],
            },
        },
    ],
}
***/