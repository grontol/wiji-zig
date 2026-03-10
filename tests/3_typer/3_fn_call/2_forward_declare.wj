fn main() {
    foo()
}

fn foo() {
    bar()
}

fn bar() {
    foo()
}

/***
Module {
    fn_decls: [
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
        FnDecl {
            is_extern: false,
            is_public: false,
            name: 'foo',
            params: [],
            body: Block {
                stmts: [
                    FnCall {
                        callee: <fn(): void> Identifier('bar'),
                        args: [],
                        return_type: void,
                    },
                ],
            },
        },
        FnDecl {
            is_extern: false,
            is_public: false,
            name: 'bar',
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