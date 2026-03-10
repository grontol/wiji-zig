fn main() {
    a()
    a(10)
    a(10, 30)
    a(
        10,
        40,
    )
    
    foo(x)
    
    fn foo(self: Foo) {
        
    }
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
                    FnCall {
                        callee: Identifier('a'),
                        args: [],
                    },
                    FnCall {
                        callee: Identifier('a'),
                        args: [
                            Lit(10),
                        ],
                    },
                    FnCall {
                        callee: Identifier('a'),
                        args: [
                            Lit(10),
                            Lit(30),
                        ],
                    },
                    FnCall {
                        callee: Identifier('a'),
                        args: [
                            Lit(10),
                            Lit(40),
                        ],
                    },
                    FnCall {
                        callee: Identifier('foo'),
                        args: [
                            Identifier('x'),
                        ],
                    },
                    FnDecl {
                        name: 'foo',
                        is_extern: false,
                        is_public: false,
                        params: [
                            FnParam {
                                is_variadic: false,
                                name: 'self',
                                type: Foo,
                            },
                        ],
                        body: Block {
                            exprs: [],
                        },
                    },
                ],
            },
        },
    ],
}
***/